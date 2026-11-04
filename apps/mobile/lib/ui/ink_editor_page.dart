// apps/mobile/lib/ui/ink_editor_page.dart
import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:localroll_ink/localroll_ink.dart';

import '../l10n/l10n.dart';
import '../services/phone_notes.dart';

/// Opens the drawing page for a photo (or a paused video at [atMs]) and
/// keeps what was drawn. [background]: the picture, filling its box.
Future<void> openInkEditor(
  BuildContext context, {
  required String inkKey,
  required double aspect,
  required Widget background,
  int? atMs,
}) async {
  final notes = await PhoneNotes.instance.load(inkKey);
  if (!context.mounted) return;
  final out = await Navigator.of(context).push<List<Note>>(MaterialPageRoute(
    fullscreenDialog: true,
    builder: (_) => InkEditorPage(
      notes: [for (final n in notes) Note.fromJson(n.toJson())],
      aspect: aspect,
      background: background,
      atMs: atMs,
    ),
  ));
  if (out != null) await PhoneNotes.instance.save(inkKey, out);
}

/// Drawing on a photo or a paused video frame, by touch.
///
/// One finger draws. "Select": tap a mark to pick it, drag to move it, two
/// fingers to resize and turn it. Marks are kept as parts of the picture
/// (0–1), the same as on the PC.
class InkEditorPage extends StatefulWidget {
  const InkEditorPage({super.key, required this.notes, required this.aspect, required this.background, this.atMs});

  final List<Note> notes;
  final double aspect;
  final Widget background;

  /// A video: drawn at this moment (null: a photo).
  final int? atMs;

  @override
  State<InkEditorPage> createState() => _InkEditorPageState();
}

/// Colours offered.
const List<int> _colors = [0xFFFF3B30, 0xFFFFCC00, 0xFF34C759, 0xFF0A84FF, 0xFFFFFFFF, 0xFF000000];

/// Line widths (part of the picture's height): thin, medium, thick.
const List<double> _widths = [0.004, 0.008, 0.014];

/// Tools in the bar; null = select.
const List<InkTool?> _tools = [
  null,
  InkTool.pen,
  InkTool.marker,
  InkTool.arrow,
  InkTool.line,
  InkTool.rect,
  InkTool.ellipse,
  InkTool.text,
  InkTool.check,
  InkTool.cross,
  InkTool.number,
];

IconData _toolIcon(InkTool? t) => switch (t) {
      null => Icons.pan_tool_alt_rounded,
      InkTool.pen => Icons.edit_rounded,
      InkTool.marker => Icons.border_color_rounded,
      InkTool.arrow => Icons.north_east_rounded,
      InkTool.line => Icons.horizontal_rule_rounded,
      InkTool.rect => Icons.crop_square_rounded,
      InkTool.ellipse => Icons.circle_outlined,
      InkTool.text => Icons.text_fields_rounded,
      InkTool.check => Icons.check_rounded,
      InkTool.cross => Icons.close_rounded,
      InkTool.number => Icons.looks_one_rounded,
      _ => Icons.edit_rounded,
    };

/// Tools placed with a tap (not drawn).
bool _tapTool(InkTool? t) => t == InkTool.text || t == InkTool.check || t == InkTool.cross || t == InkTool.number;

class _InkEditorPageState extends State<InkEditorPage> {
  late final List<Note> _notes = widget.notes;
  late final Note _current = Note(
    id: InkMark.newId(),
    name: tr('ink.note_n', {'n': widget.notes.length + 1}),
    inks: [],
    startMs: widget.atMs ?? 0,
  );

  InkTool? _tool = InkTool.pen;
  int _color = _colors.first;
  int _width = 1;

  /// Repaints while drawing / moving (no rebuild).
  final ValueNotifier<int> _tick = ValueNotifier(0);
  final Stopwatch _clock = Stopwatch()..start();
  Size _size = Size.zero;

  InkMark? _drawing;
  int _drawStart = 0;

  /// The last stroke and when it ended: a second finger right after it
  /// meant a pinch, not a dot.
  InkMark? _lastStroke;
  int _lastEnd = 0;

  InkMark? _sel;
  Offset _from = Offset.zero;
  double _dx0 = 0, _dy0 = 0, _k0 = 1, _r0 = 0;
  bool _pinch = false;

  final List<String> _undo = [];
  final List<String> _redo = [];
  bool _changed = false;

  bool get _video => widget.atMs != null;

  @override
  void dispose() {
    _tick.dispose();
    super.dispose();
  }

  // ------------------------------------------------------------ undo

  String _snap() => jsonEncode({
        'n': [for (final n in _notes) n.toJson()],
        'c': [for (final i in _current.inks) i.toJson()],
      });

  void _restore(String s) {
    final j = jsonDecode(s) as Map<String, dynamic>;
    _notes
      ..clear()
      ..addAll([for (final n in j['n'] as List) Note.fromJson(n as Map<String, dynamic>)]);
    _current.inks = [for (final i in j['c'] as List) InkMark.fromJson(i as Map<String, dynamic>)];
    _sel = null;
  }

  void _push() {
    _undo.add(_snap());
    if (_undo.length > 60) _undo.removeAt(0);
    _redo.clear();
    _changed = true;
  }

  void _doUndo() {
    if (_undo.isEmpty) return;
    setState(() {
      _redo.add(_snap());
      _restore(_undo.removeLast());
    });
  }

  void _doRedo() {
    if (_redo.isEmpty) return;
    setState(() {
      _undo.add(_snap());
      _restore(_redo.removeLast());
    });
  }

  // ------------------------------------------------------------ marks

  /// Marks on the picture now (a video: those showing at this moment).
  Iterable<InkMark> get _visible sync* {
    for (final n in [..._notes, _current]) {
      if (_video && n != _current && !n.shownAt(widget.atMs!)) continue;
      for (final i in n.inks) {
        if (_video && n != _current && !n.inkShownAt(i, widget.atMs!)) continue;
        yield i;
      }
    }
  }

  InkMark? _hitAt(Offset p) {
    final all = _visible.toList();
    for (final i in all.reversed) {
      if (InkGeometry.hits(i, _size, p, slop: 14)) return i;
    }
    return null;
  }

  Offset _rel(Offset p) => Offset(
        (p.dx / math.max(1, _size.width)).clamp(0.0, 1.0),
        (p.dy / math.max(1, _size.height)).clamp(0.0, 1.0),
      );

  InkMark _newMark(InkTool tool, Offset at) => InkMark(
        id: InkMark.newId(),
        tool: tool,
        color: _color,
        width: _widths[_width],
        points: [at],
        atMs: widget.atMs,
        wallMs: _clock.elapsedMilliseconds,
        times: [0],
      );

  void _onTap(TapUpDetails d) {
    final p = d.localPosition;
    if (_tool == null) {
      setState(() => _sel = _hitAt(p));
      return;
    }
    if (!_tapTool(_tool)) return;
    if (_tool == InkTool.text) {
      unawaited(_addText(p));
      return;
    }
    _push();
    final m = _newMark(_tool!, _rel(p));
    if (_tool == InkTool.number) {
      m.number = 1 + _visible.where((i) => i.tool == InkTool.number).fold<int>(0, (a, i) => math.max(a, i.number ?? 0));
    }
    setState(() => _current.inks.add(m));
  }

  Future<void> _addText(Offset p) async {
    final ctl = TextEditingController();
    final text = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        content: TextField(
          controller: ctl,
          autofocus: true,
          maxLines: 3,
          minLines: 1,
          decoration: InputDecoration(hintText: tr('ink.type_here')),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(tr('common.cancel'))),
          FilledButton(onPressed: () => Navigator.pop(ctx, ctl.text), child: Text(tr('common.ok'))),
        ],
      ),
    );
    ctl.dispose();
    if (!mounted || text == null || text.trim().isEmpty) return;
    _push();
    setState(() => _current.inks.add(_newMark(InkTool.text, _rel(p))..text = text.trim()));
  }

  void _onStart(ScaleStartDetails d) {
    final p = d.localFocalPoint;
    if (d.pointerCount >= 2) {
      // A second finger just after the first one began a stroke: it was a
      // pinch, the little stroke goes.
      final last = _lastStroke;
      if (last != null && _clock.elapsedMilliseconds - _lastEnd < 400 && last.points.length < 8) {
        _current.inks.remove(last);
        if (_undo.isNotEmpty) _undo.removeLast();
        _lastStroke = null;
      }
      _pinch = true;
      final s = _sel;
      if (s != null) {
        _push();
        _from = p;
        _dx0 = s.dx;
        _dy0 = s.dy;
        _k0 = s.scale;
        _r0 = s.rotation;
      }
      _tick.value++;
      return;
    }
    _pinch = false;
    if (_tool == null) {
      final hit = _hitAt(p);
      setState(() => _sel = hit);
      if (hit != null) {
        _push();
        _from = p;
        _dx0 = hit.dx;
        _dy0 = hit.dy;
      }
      return;
    }
    if (_tapTool(_tool)) return;
    _push();
    final at = _rel(p);
    final m = _newMark(_tool!, at);
    if (_tool != InkTool.pen && _tool != InkTool.marker) {
      m.points = [at, at];
      m.times = [0, 0];
    }
    _drawing = m;
    _drawStart = _clock.elapsedMilliseconds;
    _current.inks.add(m);
    _tick.value++;
  }

  void _onUpdate(ScaleUpdateDetails d) {
    final p = d.localFocalPoint;
    final s = _sel;
    if (_pinch || d.pointerCount >= 2) {
      if (s == null) return;
      s
        ..scale = (_k0 * d.scale).clamp(0.1, 20.0)
        ..rotation = Candles.noTurn(s) ? s.rotation : _r0 + d.rotation
        ..dx = _dx0 + (p.dx - _from.dx) / math.max(1, _size.width)
        ..dy = _dy0 + (p.dy - _from.dy) / math.max(1, _size.height);
      _tick.value++;
      return;
    }
    if (_tool == null) {
      if (s == null) return;
      s
        ..dx = _dx0 + (p.dx - _from.dx) / math.max(1, _size.width)
        ..dy = _dy0 + (p.dy - _from.dy) / math.max(1, _size.height);
      _tick.value++;
      return;
    }
    final m = _drawing;
    if (m == null) return;
    final at = _rel(p);
    final t = _clock.elapsedMilliseconds - _drawStart;
    if (m.tool == InkTool.pen || m.tool == InkTool.marker) {
      final last = m.points.last;
      if ((Offset((at.dx - last.dx) * _size.width, (at.dy - last.dy) * _size.height)).distance < 1.5) return;
      m.points.add(at);
      m.times.add(t);
    } else {
      m.points = [m.points.first, at];
      m.times = [0, t];
    }
    _tick.value++;
  }

  void _onEnd(ScaleEndDetails d) {
    final m = _drawing;
    _drawing = null;
    if (m != null) {
      // A shape too small to see: a slip, not a mark.
      if (m.tool != InkTool.pen && m.tool != InkTool.marker) {
        final a = m.points.first, b = m.points.last;
        if (Offset((a.dx - b.dx) * _size.width, (a.dy - b.dy) * _size.height).distance < 6) {
          _current.inks.remove(m);
          if (_undo.isNotEmpty) _undo.removeLast();
        }
      }
      _lastStroke = m;
      _lastEnd = _clock.elapsedMilliseconds;
    }
    if (d.pointerCount == 0) _pinch = false;
    setState(() {});
  }

  void _delete() {
    final s = _sel;
    if (s == null) return;
    _push();
    setState(() {
      for (final n in [..._notes, _current]) {
        n.inks.remove(s);
      }
      _sel = null;
    });
  }

  void _pickColor(int c) {
    setState(() => _color = c);
    final s = _sel;
    if (s != null && s.tool != InkTool.stamp) {
      _push();
      setState(() => s.color = c);
    }
  }

  void _pickWidth() {
    setState(() => _width = (_width + 1) % _widths.length);
    final s = _sel;
    if (s != null) {
      _push();
      setState(() => s.width = _widths[_width]);
    }
  }

  void _done() {
    final now = DateTime.now().millisecondsSinceEpoch;
    final out = [
      for (final n in _notes)
        if (n.inks.isNotEmpty) n,
      if (_current.inks.isNotEmpty) _current..modifiedMs = now,
    ];
    Navigator.of(context).pop(out);
  }

  Future<void> _leave() async {
    if (!_changed) {
      Navigator.of(context).pop();
      return;
    }
    final drop = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        content: Text(tr('ink.discard')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('ink.keep_editing'))),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: Text(tr('ink.discard_yes'))),
        ],
      ),
    );
    if (drop == true && mounted) Navigator.of(context).pop();
  }

  // ------------------------------------------------------------ build

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return PopScope(
      canPop: !_changed,
      onPopInvokedWithResult: (did, _) {
        if (!did) unawaited(_leave());
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(
          backgroundColor: Colors.black,
          foregroundColor: Colors.white,
          leading: IconButton(icon: const Icon(Icons.close_rounded), onPressed: () => unawaited(_leave())),
          title: Text(tr('ink.title'), style: const TextStyle(fontSize: 16)),
          actions: [
            IconButton(
              tooltip: tr('ink.undo'),
              onPressed: _undo.isEmpty ? null : _doUndo,
              icon: const Icon(Icons.undo_rounded),
            ),
            IconButton(
              tooltip: tr('ink.redo'),
              onPressed: _redo.isEmpty ? null : _doRedo,
              icon: const Icon(Icons.redo_rounded),
            ),
            TextButton(onPressed: _done, child: Text(tr('ink.done'))),
          ],
        ),
        body: Column(children: [
          Expanded(
            child: Center(
              child: AspectRatio(
                aspectRatio: widget.aspect,
                child: LayoutBuilder(builder: (context, box) {
                  _size = box.biggest;
                  return Stack(fit: StackFit.expand, children: [
                    widget.background,
                    GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTapUp: _onTap,
                      onScaleStart: _onStart,
                      onScaleUpdate: _onUpdate,
                      onScaleEnd: _onEnd,
                      child: CustomPaint(
                        painter: InkPainter(
                          notes: [..._notes, _current],
                          video: _video,
                          ms: () => widget.atMs ?? 0,
                          selected: () => _sel,
                          repaint: _tick,
                        ),
                      ),
                    ),
                  ]);
                }),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            child: Text(
              tr(_tool == null ? 'ink.hint_select' : 'ink.hint_draw'),
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white60, fontSize: 12),
            ),
          ),
        ]),
        bottomNavigationBar: SafeArea(
          child: Container(
            color: const Color(0xFF151515),
            padding: const EdgeInsets.fromLTRB(4, 6, 4, 6),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(children: [
                  for (final t in _tools)
                    IconButton(
                      tooltip: tr('ink.tool_${t?.name ?? 'select'}'),
                      isSelected: _tool == t,
                      style: IconButton.styleFrom(
                        backgroundColor: _tool == t ? theme.colorScheme.primary.withValues(alpha: 0.3) : null,
                      ),
                      onPressed: () => setState(() {
                        _tool = t;
                        if (t != null) _sel = null;
                      }),
                      icon: Icon(_toolIcon(t), color: _tool == t ? theme.colorScheme.primary : Colors.white),
                    ),
                ]),
              ),
              Row(children: [
                const SizedBox(width: 8),
                for (final c in _colors)
                  GestureDetector(
                    onTap: () => _pickColor(c),
                    child: Container(
                      width: 28,
                      height: 28,
                      margin: const EdgeInsets.symmetric(horizontal: 4),
                      decoration: BoxDecoration(
                        color: Color(c),
                        shape: BoxShape.circle,
                        border: Border.all(color: _color == c ? theme.colorScheme.primary : Colors.white38, width: _color == c ? 3 : 1),
                      ),
                    ),
                  ),
                const Spacer(),
                IconButton(
                  tooltip: tr('ink.width'),
                  onPressed: _pickWidth,
                  icon: Container(
                    width: 26,
                    height: [3.0, 6.0, 10.0][_width],
                    decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(5)),
                  ),
                ),
                IconButton(
                  tooltip: tr('ink.delete'),
                  onPressed: _sel == null ? null : _delete,
                  icon: Icon(Icons.delete_outline_rounded, color: _sel == null ? Colors.white24 : Colors.white),
                ),
              ]),
            ]),
          ),
        ),
      ),
    );
  }
}
