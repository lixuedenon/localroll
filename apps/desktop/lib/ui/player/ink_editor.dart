// apps/desktop/lib/ui/player/ink_editor.dart
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/l10n.dart';
import '../../services/annotations.dart';
import '../theme.dart';
import 'ink_paint.dart';

/// What the next press on the picture does.
enum EditTool { pen, marker, line, arrow, rect, ellipse, text, check, cross, number, select, eraser }

const List<Color> inkColors = [
  Color(0xFFFF3B30), // red
  Color(0xFFFF9500), // orange
  Color(0xFFFFCC00), // yellow
  Color(0xFF34C759), // green
  Color(0xFF32D3E6), // cyan
  Color(0xFF0A84FF), // blue
  Color(0xFFBF5AF2), // purple
  Color(0xFFFFFFFF), // white
  Color(0xFF000000), // black
];

/// Three sizes: line width and text / tick size (parts of the picture's height).
const List<double> _widths = [0.003, 0.006, 0.012];
const List<double> _sizes = [0.035, 0.05, 0.075];

/// Drawing one annotation: the marks so far, the tool, undo / redo, the
/// selected mark. [clock] says where the video is (marks drawn on a video
/// remember when).
class InkEditor extends ChangeNotifier {
  InkEditor({required this.video, required this.clock, bool Function()? playing, this.sessionClock, List<InkMark>? inks, this.original})
      : playing = playing ?? (() => false),
        inks = [for (final i in inks ?? const <InkMark>[]) i.copy()] {
    // Continue the real-time line of an annotation being changed.
    final last = this.inks.fold<int>(0, (m, i) => math.max(m, (i.wallMs ?? 0) + i.drawMs));
    _wallBase = last == 0 ? 0 : last + 1000;
    _number = 1 + this.inks.fold<int>(0, (m, i) => math.max(m, i.number ?? 0));
  }

  final bool video;
  final int Function() clock;

  /// The video is playing (marks then grow with it).
  final bool Function() playing;

  /// Real time since drawing began (paused marks replay at this pace).
  final Stopwatch _wall = Stopwatch()..start();
  int _wallBase = 0;
  final Stopwatch _stroke = Stopwatch();

  /// Recording an explanation: its clock (ms). Each mark then also keeps
  /// when it was started on that clock and each point's real time, so the
  /// recording shows it being drawn as it was.
  final int Function()? sessionClock;
  final Map<String, int> sessionStart = {};
  final Map<String, List<int>> sessionTimes = {};

  /// Editing this annotation (null: a new one).
  final Note? original;

  final List<InkMark> inks;
  EditTool tool = EditTool.pen;
  Color color = inkColors.first;
  int level = 1;
  String? selectedId;

  /// A text being typed (its mark).
  String? typingId;

  int _number = 1;
  bool get isEmpty => inks.isEmpty;
  bool get canUndo => _undoInks.isNotEmpty;
  bool get canRedo => _redoInks.isNotEmpty;

  InkMark? get selected => selectedId == null ? null : inks.where((i) => i.id == selectedId).firstOrNull;

  // Undo keeps copies of the marks.
  final List<List<InkMark>> _undoInks = [];
  final List<List<InkMark>> _redoInks = [];

  /// Before a change: remember how it was.
  void remember() {
    _undoInks.add([for (final i in inks) i.copy()]);
    if (_undoInks.length > 100) _undoInks.removeAt(0);
    _redoInks.clear();
  }

  void undo() {
    if (_undoInks.isEmpty) return;
    _redoInks.add([for (final i in inks) i.copy()]);
    inks
      ..clear()
      ..addAll(_undoInks.removeLast());
    selectedId = null;
    notifyListeners();
  }

  void redo() {
    if (_redoInks.isEmpty) return;
    _undoInks.add([for (final i in inks) i.copy()]);
    inks
      ..clear()
      ..addAll(_redoInks.removeLast());
    selectedId = null;
    notifyListeners();
  }

  void clear() {
    if (inks.isEmpty) return;
    remember();
    inks.clear();
    selectedId = null;
    notifyListeners();
  }

  void setTool(EditTool t) {
    tool = t;
    if (t != EditTool.select) selectedId = null;
    notifyListeners();
  }

  void setColor(Color c) {
    color = c;
    final s = selected;
    if (s != null) {
      remember();
      s.color = c.toARGB32();
    }
    notifyListeners();
  }

  void setLevel(int l) {
    level = l.clamp(0, 2);
    final s = selected;
    if (s != null) {
      remember();
      s
        ..width = _widths[level]
        ..size = _sizes[level];
    }
    notifyListeners();
  }

  void deleteSelected() {
    final id = selectedId;
    if (id == null) return;
    remember();
    inks.removeWhere((i) => i.id == id);
    selectedId = null;
    notifyListeners();
  }

  InkTool? get _inkTool => switch (tool) {
        EditTool.pen => InkTool.pen,
        EditTool.marker => InkTool.marker,
        EditTool.line => InkTool.line,
        EditTool.arrow => InkTool.arrow,
        EditTool.rect => InkTool.rect,
        EditTool.ellipse => InkTool.ellipse,
        EditTool.text => InkTool.text,
        EditTool.check => InkTool.check,
        EditTool.cross => InkTool.cross,
        EditTool.number => InkTool.number,
        _ => null,
      };

  InkMark _new(InkTool t, Offset at) {
    final live = video && playing();
    _stroke
      ..reset()
      ..start();
    final id = InkMark.newId();
    final sc = sessionClock;
    if (sc != null) {
      sessionStart[id] = sc();
      sessionTimes[id] = [0];
    }
    return InkMark(
      id: id,
      tool: t,
      color: color.toARGB32(),
      width: _widths[level],
      size: _sizes[level],
      points: [at],
      atMs: video ? clock() : null,
      times: [0],
      live: live,
      wallMs: video && !live ? _wallBase + _wall.elapsedMilliseconds : null,
    );
  }

  /// When this point of [d] is drawn: video time while playing, else real time.
  int _tick(InkMark d) {
    final t = d.live ? clock() - (d.atMs ?? 0) : _stroke.elapsedMilliseconds;
    return math.max(t, d.times.isEmpty ? 0 : d.times.last);
  }

  /// A new mark is being drawn (not in [inks] until it ends).
  InkMark? drawing;

  void begin(Offset at) {
    final t = _inkTool;
    if (t == null) return;
    if (t == InkTool.check || t == InkTool.cross || t == InkTool.number) {
      remember();
      final i = _new(t, at);
      if (t == InkTool.number) i.number = _number++;
      inks.add(i);
      notifyListeners();
      return;
    }
    if (t == InkTool.text) {
      remember();
      final i = _new(t, at)..text = '';
      inks.add(i);
      typingId = i.id;
      notifyListeners();
      return;
    }
    drawing = _new(t, at);
    if (t != InkTool.pen && t != InkTool.marker) {
      drawing!.points.add(at);
      drawing!.times.add(0);
    }
    notifyListeners();
  }

  void extend(Offset at, {bool straight = false}) {
    final d = drawing;
    if (d == null) return;
    if (d.tool == InkTool.pen || d.tool == InkTool.marker) {
      if ((d.points.last - at).distance > 0.0008) {
        d.points.add(at);
        d.times.add(_tick(d));
        sessionTimes[d.id]?.add(_stroke.elapsedMilliseconds);
      }
    } else {
      var to = at;
      // Shift: level / upright lines, squares and circles.
      if (straight) {
        final a = d.points.first;
        final v = at - a;
        if (d.tool == InkTool.rect || d.tool == InkTool.ellipse) {
          final m = math.max(v.dx.abs(), v.dy.abs());
          to = a + Offset(m * v.dx.sign, m * v.dy.sign);
        } else {
          final ang = (math.atan2(v.dy, v.dx) / (math.pi / 4)).round() * (math.pi / 4);
          to = a + Offset(math.cos(ang), math.sin(ang)) * v.distance;
        }
      }
      d.points[d.points.length - 1] = to;
      d.times[d.times.length - 1] = _tick(d);
      final st = sessionTimes[d.id];
      if (st != null) {
        if (st.length < d.points.length) st.add(_stroke.elapsedMilliseconds);
        st[st.length - 1] = _stroke.elapsedMilliseconds;
      }
    }
    notifyListeners();
  }

  void end() {
    final d = drawing;
    drawing = null;
    if (d == null) return;
    final tiny = d.points.length >= 2 && (d.points.first - d.points.last).distance < 0.002 && d.tool != InkTool.pen && d.tool != InkTool.marker;
    if (!tiny) {
      remember();
      inks.add(d);
    }
    notifyListeners();
  }

  /// The text being typed changed / ended (empty: removed).
  void setText(String id, String text, {bool done = false}) {
    final i = inks.where((x) => x.id == id).firstOrNull;
    if (i == null) return;
    i.text = text;
    if (done) {
      typingId = null;
      if (text.trim().isEmpty) inks.remove(i);
    }
    notifyListeners();
  }

  void editText(InkMark i) {
    remember();
    typingId = i.id;
    notifyListeners();
  }

  /// Rubs out the marks under [px] (pixels on a picture of [size]).
  void eraseAt(Offset px, Size size, {required bool first}) {
    final hit = inks.where((i) => InkGeometry.hits(i, size, px, slop: 10)).toList();
    if (hit.isEmpty) return;
    if (first) remember();
    inks.removeWhere(hit.contains);
    notifyListeners();
  }

  /// The top mark under [px], selected (null: none).
  InkMark? pick(Offset px, Size size) {
    final hit = inks.reversed.where((i) => InkGeometry.hits(i, size, px, slop: 8)).firstOrNull;
    selectedId = hit?.id;
    notifyListeners();
    return hit;
  }

  void touched() => notifyListeners();

  /// The marks to keep (the one being typed included).
  List<InkMark> get result => [for (final i in inks) if (!(i.tool == InkTool.text && (i.text ?? '').trim().isEmpty)) i];
}

/// What a drag on a selected mark does.
enum _Drag { none, draw, erase, move, scale, rotate }

/// The marks over a picture; with an [editor], drawing on it too. Sits
/// exactly on the picture (same size), so marks stay put when zooming.
class InkLayer extends StatefulWidget {
  const InkLayer({super.key, required this.notes, required this.video, this.clock, this.freeze, this.editor});

  final List<Note> notes;
  final bool video;
  final ValueNotifier<int>? clock;

  /// A replay of marks drawn while paused (the video is stopped for it).
  final ValueNotifier<FreezeNow?>? freeze;
  final InkEditor? editor;

  @override
  State<InkLayer> createState() => _InkLayerState();
}

class _InkLayerState extends State<InkLayer> {
  _Drag _drag = _Drag.none;
  Offset _from = Offset.zero;
  InkMark? _start;
  final TextEditingController _text = TextEditingController();
  final FocusNode _textFocus = FocusNode();
  String? _textFor;

  @override
  void initState() {
    super.initState();
    _textFocus.addListener(() {
      if (!_textFocus.hasFocus) _endTyping();
    });
  }

  @override
  void dispose() {
    _endTyping();
    _text.dispose();
    _textFocus.dispose();
    super.dispose();
  }

  void _endTyping() {
    final id = _textFor;
    if (id == null) return;
    _textFor = null;
    widget.editor?.setText(id, _text.text, done: true);
  }

  Offset _n(Offset p, Size s) => Offset((p.dx / s.width).clamp(0.0, 1.0), (p.dy / s.height).clamp(0.0, 1.0));

  void _down(PointerDownEvent e, Size s) {
    final ed = widget.editor;
    if (ed == null || e.buttons != kPrimaryButton) return;
    if (_textFor != null) {
      _textFocus.unfocus();
      _endTyping();
    }
    final p = e.localPosition;
    switch (ed.tool) {
      case EditTool.eraser:
        _drag = _Drag.erase;
        ed.eraseAt(p, s, first: true);
      case EditTool.select:
        final sel = ed.selected;
        if (sel != null) {
          final knob = InkPainter.rotateKnob(sel, s);
          final corners = InkGeometry.corners(sel, s);
          if ((p - knob).distance < 12) {
            ed.remember();
            _drag = _Drag.rotate;
          } else if (corners.any((c) => (p - c).distance < 10)) {
            ed.remember();
            _drag = _Drag.scale;
          }
          if (_drag != _Drag.none) {
            _from = p;
            _start = sel.copy();
            return;
          }
        }
        final hit = ed.pick(p, s);
        if (hit != null) {
          ed.remember();
          _drag = _Drag.move;
          _from = p;
          _start = hit.copy();
        }
      case EditTool.text:
        // A word already there: change it.
        final hit = ed.inks.reversed.where((i) => i.tool == InkTool.text && InkGeometry.hits(i, s, p)).firstOrNull;
        if (hit != null) {
          ed.editText(hit);
        } else {
          ed.begin(_n(p, s));
        }
        _startTyping();
      default:
        _drag = _Drag.draw;
        ed.begin(_n(p, s));
    }
  }

  void _startTyping() {
    final ed = widget.editor;
    final id = ed?.typingId;
    if (ed == null || id == null) return;
    final i = ed.inks.where((x) => x.id == id).firstOrNull;
    _textFor = id;
    _text.text = i?.text ?? '';
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _textFocus.requestFocus();
    });
    setState(() {});
  }

  void _move(PointerMoveEvent e, Size s) {
    final ed = widget.editor;
    if (ed == null) return;
    final p = e.localPosition;
    switch (_drag) {
      case _Drag.draw:
        ed.extend(_n(p, s), straight: HardwareKeyboard.instance.isShiftPressed);
      case _Drag.erase:
        ed.eraseAt(p, s, first: false);
      case _Drag.move:
        final sel = ed.selected, st = _start;
        if (sel == null || st == null) return;
        sel
          ..dx = st.dx + (p.dx - _from.dx) / s.width
          ..dy = st.dy + (p.dy - _from.dy) / s.height;
        ed.touched();
      case _Drag.scale:
        final sel = ed.selected, st = _start;
        if (sel == null || st == null) return;
        final c = InkGeometry.box(st, s).center + Offset(st.dx * s.width, st.dy * s.height);
        final d0 = (_from - c).distance;
        if (d0 < 1) return;
        sel.scale = (st.scale * (p - c).distance / d0).clamp(0.1, 20.0);
        ed.touched();
      case _Drag.rotate:
        final sel = ed.selected, st = _start;
        if (sel == null || st == null) return;
        final c = InkGeometry.box(st, s).center + Offset(st.dx * s.width, st.dy * s.height);
        final a0 = math.atan2(_from.dy - c.dy, _from.dx - c.dx);
        final a1 = math.atan2(p.dy - c.dy, p.dx - c.dx);
        var r = st.rotation + a1 - a0;
        // Shift: in steps of 15°.
        if (HardwareKeyboard.instance.isShiftPressed) r = (r / (math.pi / 12)).round() * (math.pi / 12);
        sel.rotation = r;
        ed.touched();
      case _Drag.none:
        break;
    }
  }

  void _up() {
    if (_drag == _Drag.draw) widget.editor?.end();
    _drag = _Drag.none;
    _start = null;
  }

  Widget _typingField(Size s) {
    final ed = widget.editor;
    final id = _textFor;
    if (ed == null || id == null) return const SizedBox.shrink();
    final i = ed.inks.where((x) => x.id == id).firstOrNull;
    if (i == null || i.points.isEmpty) return const SizedBox.shrink();
    final at = InkGeometry.transform(i, s, InkGeometry.px(i.points.first, s));
    final fs = InkGeometry.stampSize(i, s) * i.scale;
    return Positioned(
      left: at.dx,
      top: at.dy - 4,
      child: ConstrainedBox(
        constraints: BoxConstraints(minWidth: 120, maxWidth: math.max(160, s.width - at.dx - 8)),
        child: IntrinsicWidth(
          child: TextField(
            controller: _text,
            focusNode: _textFocus,
            autofocus: true,
            maxLines: null,
            onChanged: (t) => ed.setText(id, t),
            style: TextStyle(color: Color(i.color), fontSize: fs, fontWeight: FontWeight.w600, height: 1.2),
            cursorColor: Color(i.color),
            decoration: InputDecoration(
              isDense: true,
              filled: true,
              fillColor: const Color(0x55000000),
              contentPadding: const EdgeInsets.all(4),
              hintText: tr('ink.type_here'),
              hintStyle: TextStyle(color: Colors.white54, fontSize: math.min(fs, 18)),
              border: OutlineInputBorder(borderSide: BorderSide(color: Color(i.color))),
            ),
          ),
        ),
      ),
    );
  }

  MouseCursor get _cursor => switch (widget.editor?.tool) {
        null => MouseCursor.defer,
        EditTool.select => SystemMouseCursors.basic,
        EditTool.text => SystemMouseCursors.text,
        _ => SystemMouseCursors.precise,
      };

  @override
  Widget build(BuildContext context) {
    final ed = widget.editor;
    return LayoutBuilder(builder: (context, c) {
      final size = Size(c.maxWidth, c.maxHeight);
      final paint = CustomPaint(
        size: size,
        painter: InkPainter(
          notes: widget.notes,
          video: widget.video,
          ms: widget.clock == null ? null : () => widget.clock!.value,
          freeze: widget.freeze == null ? null : () => widget.freeze!.value,
          // Read at each paint: what is being drawn shows as it is drawn.
          draft: ed == null
              ? null
              : () => [
                    for (final i in ed.inks)
                      if (i.id != _textFor) i,
                    ?ed.drawing,
                  ],
          selected: ed == null ? null : () => ed.selected,
          repaint: Listenable.merge([?widget.clock, ?widget.freeze, ?ed]),
        ),
      );
      if (ed == null) return IgnorePointer(child: paint);
      return MouseRegion(
        cursor: _cursor,
        child: Listener(
          behavior: HitTestBehavior.opaque,
          onPointerDown: (e) => _down(e, size),
          onPointerMove: (e) => _move(e, size),
          onPointerUp: (_) => _up(),
          onPointerCancel: (_) => _up(),
          child: Stack(clipBehavior: Clip.none, children: [paint, _typingField(size)]),
        ),
      );
    });
  }
}

/// The tools above the picture while drawing.
class InkToolbar extends StatelessWidget {
  const InkToolbar({super.key, required this.editor, required this.onDone, this.onCancel, this.doneLabel, this.extra = const []});

  final InkEditor editor;
  final VoidCallback onDone;

  /// Null: no cancel button.
  final VoidCallback? onCancel;
  final String? doneLabel;

  /// More buttons before Done.
  final List<Widget> extra;

  static IconData icon(EditTool t) => switch (t) {
        EditTool.pen => Icons.edit_rounded,
        EditTool.marker => Icons.border_color_rounded,
        EditTool.line => Icons.horizontal_rule_rounded,
        EditTool.arrow => Icons.north_east_rounded,
        EditTool.rect => Icons.crop_square_rounded,
        EditTool.ellipse => Icons.circle_outlined,
        EditTool.text => Icons.text_fields_rounded,
        EditTool.check => Icons.check_rounded,
        EditTool.cross => Icons.close_rounded,
        EditTool.number => Icons.looks_one_rounded,
        EditTool.select => Icons.open_with_rounded,
        EditTool.eraser => Icons.cleaning_services_rounded,
      };

  static String label(EditTool t) => tr('ink.tool_${t.name}');

  Widget _tool(EditTool t) {
    final on = editor.tool == t;
    return IconButton(
      tooltip: label(t),
      onPressed: () => editor.setTool(t),
      style: IconButton.styleFrom(backgroundColor: on ? LrColors.safelight.withValues(alpha: 0.25) : null),
      icon: Icon(icon(t), size: 20, color: on ? LrColors.safelight : Colors.white),
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: editor,
        builder: (context, _) => Container(
          margin: const EdgeInsets.only(top: 8),
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(
            color: const Color(0xE6202020),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: const Color(0x33FFFFFF)),
          ),
          child: Wrap(crossAxisAlignment: WrapCrossAlignment.center, alignment: WrapAlignment.center, children: [
            for (final t in EditTool.values) _tool(t),
            const SizedBox(width: 6),
            PopupMenuButton<Color>(
              tooltip: tr('ink.color'),
              onSelected: editor.setColor,
              itemBuilder: (_) => [
                for (final c in inkColors)
                  PopupMenuItem<Color>(
                    value: c,
                    height: 36,
                    child: Row(children: [
                      Container(
                        width: 22,
                        height: 22,
                        decoration: BoxDecoration(color: c, shape: BoxShape.circle, border: Border.all(color: Colors.white54)),
                      ),
                      if (c == editor.color) ...[const SizedBox(width: 10), const Icon(Icons.check_rounded, size: 18)],
                    ]),
                  ),
              ],
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: Container(
                  width: 22,
                  height: 22,
                  decoration: BoxDecoration(color: editor.color, shape: BoxShape.circle, border: Border.all(color: Colors.white70, width: 2)),
                ),
              ),
            ),
            for (var l = 0; l < 3; l++)
              IconButton(
                tooltip: tr('ink.size_${['small', 'medium', 'large'][l]}'),
                onPressed: () => editor.setLevel(l),
                icon: Container(
                  width: 6.0 + l * 5,
                  height: 6.0 + l * 5,
                  decoration: BoxDecoration(color: editor.level == l ? LrColors.safelight : Colors.white70, shape: BoxShape.circle),
                ),
              ),
            const SizedBox(width: 6),
            IconButton(
              tooltip: tr('ink.undo'),
              onPressed: editor.canUndo ? editor.undo : null,
              icon: const Icon(Icons.undo_rounded, size: 20),
              color: Colors.white,
            ),
            IconButton(
              tooltip: tr('ink.redo'),
              onPressed: editor.canRedo ? editor.redo : null,
              icon: const Icon(Icons.redo_rounded, size: 20),
              color: Colors.white,
            ),
            IconButton(
              tooltip: tr('ink.clear'),
              onPressed: editor.isEmpty ? null : editor.clear,
              icon: const Icon(Icons.delete_sweep_rounded, size: 20),
              color: Colors.white,
            ),
            const SizedBox(width: 6),
            ...extra,
            if (onCancel != null) TextButton(onPressed: onCancel, child: Text(tr('common.cancel'))),
            const SizedBox(width: 4),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: FilledButton.icon(
                onPressed: onDone,
                icon: const Icon(Icons.check_rounded, size: 18),
                label: Text(doneLabel ?? tr('ink.done')),
              ),
            ),
          ]),
        ),
      );
}
