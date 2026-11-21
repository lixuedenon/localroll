// apps/desktop/lib/ui/player/ink_editor.dart
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/l10n.dart';
import '../../services/annotations.dart';
import '../../services/stamp_library.dart';
import '../stamps/candle_panel.dart';
import '../stamps/stamp_picker.dart';
import '../theme.dart';
import 'ink_paint.dart';

/// What the next press on the picture does.
enum EditTool { pen, marker, line, arrow, rect, ellipse, text, check, cross, number, stamp, candle, select, eraser }

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
const List<double> _candleW = [0.016, 0.026, 0.04];

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

  /// The number whose words are being written (a box by it): opened when
  /// a number is put down, or with its ✎.
  String? notingId;

  /// The next number: the smallest one not on the page (5 deleted: 5 again).
  int get _nextNumber {
    final used = {for (final i in inks) if (i.number != null) i.number!};
    var n = 1;
    while (used.contains(n)) {
      n++;
    }
    return n;
  }

  bool get hasNumbers => inks.any((i) => i.tool == InkTool.number);

  int _typedAt = 0;
  String? _typedOn;

  /// A digit typed while a number is selected: it becomes that number;
  /// digits typed quickly one after another make one number (1, 2 → 12).
  /// False: nothing to change.
  bool typeDigit(int d) {
    final s = selected;
    if (s == null || s.tool != InkTool.number) return false;
    final now = DateTime.now().millisecondsSinceEpoch;
    final more = _typedOn == s.id && now - _typedAt < 1200;
    final n = more ? (s.number ?? 0) * 10 + d : d;
    _typedAt = now;
    _typedOn = s.id;
    if (n <= 0 || n > 999) return true;
    if (!more) remember();
    s.number = n;
    notifyListeners();
    return true;
  }

  /// Numbers 1, 2, 3… again, in the order they were put down.
  void renumber() {
    if (!hasNumbers) return;
    remember();
    var n = 1;
    for (final i in inks) {
      if (i.tool == InkTool.number) i.number = n++;
    }
    notifyListeners();
  }

  bool get isEmpty => inks.isEmpty;
  bool get canUndo => _undoInks.isNotEmpty;
  bool get canRedo => _redoInks.isNotEmpty;

  InkMark? get selected => selectedId == null ? null : inks.where((i) => i.id == selectedId).firstOrNull;

  // Undo keeps copies of the marks.
  final List<List<InkMark>> _undoInks = [];
  final List<List<InkMark>> _redoInks = [];

  /// Before a change: remember how it was.
  /// A page keeping one undo for everything (the PDF editor): told before
  /// each change, and does undo / redo itself.
  VoidCallback? beforeChange, undoAll, redoAll;

  /// The last change told by [beforeChange] came to nothing (a dot taken
  /// back): forget it.
  VoidCallback? forgetChange;

  /// The marks put back as they were (the page's own undo).
  void restore(List<InkMark> marks) {
    inks
      ..clear()
      ..addAll([for (final m in marks) m.copy()]);
    selectedId = null;
    typingId = null;
    notingId = null;
    notifyListeners();
  }

  void remember() {
    beforeChange?.call();
    _undoInks.add([for (final i in inks) i.copy()]);
    if (_undoInks.length > 100) _undoInks.removeAt(0);
    _redoInks.clear();
  }

  void undo() {
    if (undoAll != null) return undoAll!();
    if (_undoInks.isEmpty) return;
    _redoInks.add([for (final i in inks) i.copy()]);
    inks
      ..clear()
      ..addAll(_undoInks.removeLast());
    selectedId = null;
    notifyListeners();
  }

  void redo() {
    if (redoAll != null) return redoAll!();
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
      // A candle: its rising or falling colour, as it is drawn.
      if (s.tool == InkTool.candle && !Candles.rising(s)) {
        s.color2 = c.toARGB32();
      } else {
        s.color = c.toARGB32();
      }
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

  /// The words box by a number opened / closed.
  void openNote(String? id) {
    notingId = id;
    notifyListeners();
  }

  /// What a number says.
  void setNote(String id, String text) {
    final m = inks.where((i) => i.id == id).firstOrNull;
    if (m == null || (m.note ?? '') == text) return;
    remember();
    m.note = text.isEmpty ? null : text;
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
        EditTool.stamp => stamp == null ? null : InkTool.stamp,
        EditTool.candle => InkTool.candle,
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

  /// Ticks at each new point of the line being drawn: only the picture
  /// is painted again then (not the tools), so the line keeps up with the
  /// pointer.
  final ValueNotifier<int> strokes = ValueNotifier(0);

  @override
  void dispose() {
    strokes.dispose();
    super.dispose();
  }

  /// The stamp being placed (its name, for finding it later).
  StampShape? stamp;
  String stampName = '';

  /// Candles: rising / falling colours.
  int upColor = Candles.green, downColor = Candles.red;
  CandleKind candleKind = CandleKind.normal;

  /// The picture's width for 1 high (stamps keep their proportions).
  double aspect = 16 / 9;

  void setStamp(StampShape shape, String name) {
    stamp = shape;
    stampName = name;
    setTool(EditTool.stamp);
  }

  void begin(Offset at) {
    final t = _inkTool;
    if (t == null) return;
    if (t == InkTool.stamp) {
      drawing = _new(t, at)
        ..points = [at, at]
        ..times = [0, 0]
        ..shape = stamp!.resolved(upColor, downColor)
        ..text = stampName;
      notifyListeners();
      return;
    }
    if (t == InkTool.candle) {
      drawing = _new(t, at)
        ..points = [at, at]
        ..times = [0, 0]
        ..size = _candleW[level]
        ..color = upColor
        ..color2 = downColor;
      Candles.autoWicks(drawing!, candleKind);
      notifyListeners();
      return;
    }
    if (t == InkTool.check || t == InkTool.cross || t == InkTool.number) {
      remember();
      final i = _new(t, at);
      if (t == InkTool.number) i.number = _nextNumber;
      inks.add(i);
      // A number: what it says can be written straight away.
      if (t == InkTool.number) notingId = i.id;
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
    if (d.tool == InkTool.stamp) {
      // Dragged out: its own proportions, as big as the drag.
      final a = d.points.first, v = at - a;
      final k = (d.shape?.aspect ?? 1) / aspect;
      final h = math.max(v.dy.abs(), v.dx.abs() / k);
      d.points[1] = a + Offset(h * k * (v.dx < 0 ? -1 : 1), h * (v.dy < 0 ? -1 : 1));
      strokes.value++;
      return;
    }
    if (d.tool == InkTool.candle) {
      // Pressed at the open, let go at the close.
      d.points[1] = Offset(d.points[0].dx, at.dy);
      Candles.autoWicks(d, candleKind);
      strokes.value++;
      return;
    }
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
    strokes.value++;
  }

  void end() {
    final d = drawing;
    drawing = null;
    if (d == null) return;
    if (d.tool == InkTool.stamp && (d.points.first - d.points.last).distance < 0.004) {
      // Clicked: its usual size, centred there.
      final h = _sizes[level] * 2.4, w = h * (d.shape?.aspect ?? 1) / aspect;
      final c = d.points.first;
      d.points = [c - Offset(w / 2, h / 2), c + Offset(w / 2, h / 2)];
    }
    if (d.tool == InkTool.candle && (d.points[0] - d.points[1]).distance < 0.004) {
      // Clicked after a candle: the next one, opening at its close.
      final prev = inks.lastWhere((i) => i.tool == InkTool.candle && i.points.length >= 4, orElse: () => d);
      if (identical(prev, d)) {
        notifyListeners();
        return;
      }
      final x = prev.points[0].dx + prev.dx + prev.size * 1.7 / aspect;
      final open = prev.points[1].dy + prev.dy;
      d
        ..size = prev.size
        ..points = [Offset(x, open), Offset(x, d.points[0].dy)];
      Candles.autoWicks(d, candleKind == CandleKind.doji ? CandleKind.normal : candleKind);
    }
    final tiny = d.points.length >= 2 &&
        (d.points.first - d.points.last).distance < 0.002 &&
        d.tool != InkTool.pen &&
        d.tool != InkTool.marker &&
        d.tool != InkTool.stamp &&
        d.tool != InkTool.candle;
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
      if (text.trim().isEmpty) {
        inks.remove(i);
      } else {
        // Typed: chosen, like any other mark (move, corners, turn knob).
        selectedId = i.id;
      }
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

  /// The top mark under [px] (selection unchanged).
  InkMark? topAt(Offset px, Size size) => inks.reversed.where((i) => InkGeometry.hits(i, size, px, slop: 8)).firstOrNull;

  void select(String? id) {
    selectedId = id;
    notifyListeners();
  }

  /// Takes back mark [id] that a click just made (the first click of a
  /// double-click), without leaving an undo step.
  void dropMade(String id) {
    if (drawing?.id == id) drawing = null;
    final gone = inks.where((i) => i.id == id).firstOrNull;
    if (gone != null) {
      inks.remove(gone);
      if (_undoInks.isNotEmpty) _undoInks.removeLast();
      forgetChange?.call();
    }
    sessionStart.remove(id);
    sessionTimes.remove(id);
    notifyListeners();
  }

  /// The marks to keep (the one being typed included).
  List<InkMark> get result => [for (final i in inks) if (!(i.tool == InkTool.text && (i.text ?? '').trim().isEmpty)) i];
}

/// What a drag on a selected mark does.
enum _Drag { none, draw, erase, move, scale, rotate, candle }

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

  /// Double-click: the first click's time and place, and the mark it made.
  DateTime _lastDown = DateTime(0);
  Offset _lastAt = Offset.zero;
  String? _clickMade;

  /// A one-click mark (stamp, ✓, ✗, number) clicked onto another mark:
  /// held a moment, in case it is the first click of a double-click
  /// (which selects) — it no longer flashes up and away.
  Timer? _held;
  Offset? _heldAt;
  Offset _from = Offset.zero;
  InkMark? _start;

  /// Text: the one just chosen by this click (a double-click on it then
  /// keeps it, a later double-click deletes it); a click (no drag) on the
  /// chosen one changes its words — after a moment, in case of a second
  /// click.
  String? _justPicked;
  String? _maybeEdit;

  /// The words box by a number ([InkEditor.notingId]).
  final TextEditingController _noteCtl = TextEditingController();
  final FocusNode _noteFocus = FocusNode();
  String? _noteFor;

  /// Drawing began on a mark already there: a click (no drag) chooses that
  /// mark instead of leaving a dot.
  InkMark? _clickOn;
  Offset _clickFrom = Offset.zero;
  bool _clickMoved = false;
  Timer? _editSoon;
  final TextEditingController _text = TextEditingController();
  final FocusNode _textFocus = FocusNode();
  String? _textFor;

  /// The layer's own keys: a digit changes the chosen number, Enter opens
  /// its words. Clicks on the layer (and the words box closing) bring the
  /// keys back here.
  final FocusNode _keys = FocusNode(debugLabel: 'ink');
  String? _shownNote;

  @override
  void initState() {
    super.initState();
    _textFocus.addListener(() {
      if (!_textFocus.hasFocus) _endTyping();
    });
    widget.editor?.addListener(_edChanged);
  }

  @override
  void didUpdateWidget(covariant InkLayer old) {
    super.didUpdateWidget(old);
    if (old.editor != widget.editor) {
      old.editor?.removeListener(_edChanged);
      widget.editor?.addListener(_edChanged);
    }
  }

  /// The words box shown / gone as soon as the editor says so.
  void _edChanged() {
    final id = widget.editor?.notingId;
    if (id != _shownNote && mounted) setState(() => _shownNote = id);
  }

  KeyEventResult _key(FocusNode _, KeyEvent e) {
    final ed = widget.editor;
    if (ed == null || e is! KeyDownEvent || ed.notingId != null || _textFor != null) return KeyEventResult.ignored;
    final digit = inkDigitOf(e.logicalKey);
    if (digit != null && ed.typeDigit(digit)) return KeyEventResult.handled;
    final sel = ed.selected;
    if ((e.logicalKey == LogicalKeyboardKey.enter || e.logicalKey == LogicalKeyboardKey.numpadEnter) &&
        !HardwareKeyboard.instance.isControlPressed &&
        sel != null &&
        sel.tool == InkTool.number) {
      _openNote(sel.id);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  void dispose() {
    _held?.cancel();
    _editSoon?.cancel();
    widget.editor?.removeListener(_edChanged);
    _keys.dispose();
    _noteCtl.dispose();
    _noteFocus.dispose();
    _endTyping();
    _text.dispose();
    _textFocus.dispose();
    super.dispose();
  }

  /// The words box by a number: right of it (left when there is no room).
  static const _noteW = 240.0, _noteH = 132.0;

  Rect? _noteRect(Size s) {
    final ed = widget.editor;
    final id = ed?.notingId;
    if (ed == null || id == null) return null;
    final m = ed.inks.where((i) => i.id == id).firstOrNull;
    if (m == null) return null;
    final b = InkGeometry.box(m, s);
    final left = b.right + 8 + _noteW > s.width && b.left - 8 - _noteW >= 0 ? b.left - 8 - _noteW : b.right + 8;
    // Inside the layer: a box hanging off it could not be clicked.
    final top = (b.top - 6).clamp(0.0, math.max(0.0, s.height - _noteH)).toDouble();
    return Rect.fromLTWH(left.clamp(0.0, math.max(0.0, s.width - _noteW)).toDouble(), top, _noteW, _noteH);
  }

  void _openNote(String id) {
    final ed = widget.editor;
    final m = ed?.inks.where((i) => i.id == id).firstOrNull;
    if (ed == null || m == null) return;
    _noteFor = id;
    _noteCtl.text = m.note ?? '';
    _noteCtl.selection = TextSelection.collapsed(offset: _noteCtl.text.length);
    ed.openNote(id);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _noteFocus.requestFocus();
    });
  }

  /// ✓ (or a click elsewhere): the words kept.
  void _saveNote() {
    final ed = widget.editor;
    final id = ed?.notingId;
    if (ed == null || id == null) return;
    ed.setNote(id, _noteCtl.text.trim());
    _noteFor = null;
    ed.openNote(null);
    _keys.requestFocus();
  }

  /// ✕: the words not kept (the number stays).
  void _cancelNote() {
    _noteFor = null;
    widget.editor?.openNote(null);
    _keys.requestFocus();
  }

  /// The words box by a number.
  List<Widget> _noteWidgets(Size s) {
    final ed = widget.editor;
    final r = _noteRect(s);
    Widget icon(IconData i, String tip, Color c, VoidCallback on) => Tooltip(
          message: tip,
          child: InkWell(
            onTap: on,
            borderRadius: BorderRadius.circular(12),
            child: Padding(padding: const EdgeInsets.all(3), child: Icon(i, size: 18, color: c)),
          ),
        );
    return [
      if (ed != null && r != null)
        Positioned.fromRect(
          rect: r,
          child: Material(
            elevation: 4,
            color: Colors.white,
            borderRadius: BorderRadius.circular(10),
            child: CallbackShortcuts(
              bindings: {
                const SingleActivator(LogicalKeyboardKey.enter, control: true): _saveNote,
                const SingleActivator(LogicalKeyboardKey.escape): _cancelNote,
              },
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Row(children: [
                  Padding(
                    padding: const EdgeInsets.only(left: 10),
                    child: Text(
                      '${ed.inks.where((i) => i.id == ed.notingId).firstOrNull?.number ?? ''}',
                      style: const TextStyle(fontWeight: FontWeight.w800, color: Color(0xFF1F2937)),
                    ),
                  ),
                  const Spacer(),
                  icon(Icons.check_rounded, '${tr('common.ok')} (Ctrl+Enter)', const Color(0xFF16A34A), _saveNote),
                  icon(Icons.close_rounded, '${tr('common.cancel')} (Esc)', const Color(0xFF6B7280), _cancelNote),
                  const SizedBox(width: 4),
                ]),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(10, 0, 10, 8),
                    child: TextField(
                      controller: _noteCtl,
                      focusNode: _noteFocus,
                      maxLines: null,
                      expands: true,
                      keyboardType: TextInputType.multiline,
                      style: const TextStyle(fontSize: 13.5, color: Color(0xFF1F2937), height: 1.35),
                      decoration: const InputDecoration(isDense: true, border: InputBorder.none, contentPadding: EdgeInsets.zero),
                    ),
                  ),
                ),
              ]),
            ),
          ),
        ),
    ];
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
    // The words box is above this layer: clicks on it never come here.
    // Clicked elsewhere with the box open: the words kept, the box closed,
    // and that click does nothing else.
    if (ed.notingId != null) {
      _saveNote();
      return;
    }
    if (_textFor == null) _keys.requestFocus();
    _editSoon?.cancel();
    _editSoon = null;
    _maybeEdit = null;
    if (_textFor != null) {
      _textFocus.unfocus();
      _endTyping();
    }
    final p = e.localPosition;
    // Double-click on a mark (any tool): select it; on the selected one:
    // delete it (undo brings it back).
    final now = DateTime.now();
    final twice = now.difference(_lastDown).inMilliseconds < 400 && (p - _lastAt).distance < 8;
    _lastDown = now;
    _lastAt = p;
    final made = _clickMade;
    _clickMade = null;
    var heldBack = _held?.isActive ?? false;
    _held?.cancel();
    _held = null;
    // Not a double-click after all (elsewhere): the held mark goes down now.
    if (heldBack && !twice && _heldAt != null) {
      ed.begin(_heldAt!);
      ed.end();
      heldBack = false;
    }
    ed.aspect = s.height <= 0 ? 16 / 9 : s.width / s.height;
    // A selected candle: its high / open / close / low handles.
    final sc = ed.selected;
    if (sc != null && sc.tool == InkTool.candle && sc.points.length >= 4 && !twice) {
      final hs = Candles.handles(sc, s);
      for (var k = 0; k < 4; k++) {
        if ((InkGeometry.transform(sc, s, hs[k]) - p).distance < 9) {
          ed.remember();
          _drag = _Drag.candle;
          _handle = const [2, 0, 1, 3][k];
          return;
        }
      }
    }
    final picked = _justPicked;
    _justPicked = null;
    if (twice || heldBack) {
      if (made != null) ed.dropMade(made);
      final hit = ed.topAt(p, s);
      // A double-click on a number: its words.
      if (hit != null && hit.tool == InkTool.number) {
        ed.select(hit.id);
        _drag = _Drag.none;
        _lastDown = DateTime(0);
        _openNote(hit.id);
        return;
      }
      if (hit != null) {
        if (ed.selectedId == hit.id && picked == hit.id) {
          // The first click of this double-click chose it: keep it chosen.
          _drag = _Drag.none;
          return;
        }
        if (ed.selectedId == hit.id) {
          ed.deleteSelected();
          _lastDown = DateTime(0);
          _deleted(ed);
        } else {
          ed.select(hit.id);
        }
        _drag = _Drag.none;
        return;
      }
    }
    // Something selected while drawing: drag it (or its corners / knob);
    // a click elsewhere lets it go.
    final sel = ed.selected;
    if (sel != null && ed.tool != EditTool.select && ed.tool != EditTool.eraser) {
      final knob = InkPainter.rotateKnob(sel, s);
      if ((p - knob).distance < 12 && !Candles.noTurn(sel)) {
        _drag = _Drag.rotate;
      } else if (InkGeometry.corners(sel, s).any((c) => (p - c).distance < 10)) {
        _drag = _Drag.scale;
      } else if (InkGeometry.hits(sel, s, p, slop: 8)) {
        _drag = _Drag.move;
        if (sel.tool == InkTool.text && ed.tool == EditTool.text && !twice) _maybeEdit = sel.id;
      } else {
        ed.select(null);
        return;
      }
      ed.remember();
      _from = p;
      _start = sel.copy();
      return;
    }
    switch (ed.tool) {
      case EditTool.eraser:
        _drag = _Drag.erase;
        ed.eraseAt(p, s, first: true);
      case EditTool.select:
        final sel = ed.selected;
        if (sel != null) {
          final knob = InkPainter.rotateKnob(sel, s);
          final corners = InkGeometry.corners(sel, s);
          if ((p - knob).distance < 12 && !Candles.noTurn(sel)) {
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
        // A word already there: choose it (like any mark: move, corners,
        // turn; a click on it then changes its words).
        final hit = ed.inks.reversed.where((i) => i.tool == InkTool.text && InkGeometry.hits(i, s, p)).firstOrNull;
        if (hit != null) {
          ed.select(hit.id);
          _justPicked = hit.id;
          ed.remember();
          _drag = _Drag.move;
          _from = p;
          _start = hit.copy();
          return;
        }
        ed.begin(_n(p, s));
        if (ed.notingId != null && ed.notingId != _noteFor) _openNote(ed.notingId!);
        _startTyping();
      default:
        const oneClick = {EditTool.stamp, EditTool.check, EditTool.cross, EditTool.number};
        // A click on a mark already there chooses it (any tool).
        final under = ed.topAt(p, s);
        if (oneClick.contains(ed.tool) && under != null) {
          ed.select(under.id);
          _justPicked = under.id;
          ed.remember();
          _drag = _Drag.move;
          _from = p;
          _start = under.copy();
          return;
        }
        _drag = _Drag.draw;
        _clickOn = under;
        _clickFrom = p;
        _clickMoved = false;
        final before = ed.inks.length;
        ed.begin(_n(p, s));
        if (ed.notingId != null && ed.notingId != _noteFor) _openNote(ed.notingId!);
        _clickMade = ed.drawing?.id ?? (ed.inks.length > before ? ed.inks.last.id : null);
    }
  }

  void _deleted(InkEditor ed) {
    final m = ScaffoldMessenger.maybeOf(context);
    m?.hideCurrentSnackBar();
    m?.showSnackBar(SnackBar(
      duration: const Duration(seconds: 4),
      content: Text(tr('ink.deleted')),
      action: SnackBarAction(label: tr('ink.undo'), onPressed: ed.undo),
    ));
  }

  void _finishTyping() {
    _textFocus.unfocus();
    _endTyping();
    setState(() {});
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
        if ((p - _clickFrom).distance > 3) _clickMoved = true;
        ed.extend(_n(p, s), straight: HardwareKeyboard.instance.isShiftPressed);
      case _Drag.erase:
        ed.eraseAt(p, s, first: false);
      case _Drag.move:
        final sel = ed.selected, st = _start;
        if (sel == null || st == null) return;
        if ((p - _from).distance > 3) _maybeEdit = null;
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
      case _Drag.candle:
        final sel = ed.selected;
        if (sel == null || sel.points.length < 4) return;
        final q = InkGeometry.untransform(sel, s, p);
        sel.points[_handle] = Offset(sel.points[_handle].dx, (q.dy / s.height).clamp(0.0, 1.0));
        ed.touched();
      case _Drag.none:
        break;
    }
  }

  int _handle = 0;

  void _up() {
    final edit = _maybeEdit;
    _maybeEdit = null;
    if (edit != null) {
      _editSoon = Timer(const Duration(milliseconds: 400), () {
        final ed = widget.editor;
        final i = ed?.inks.where((x) => x.id == edit).firstOrNull;
        if (!mounted || ed == null || i == null || ed.selectedId != edit) return;
        ed.editText(i);
        _startTyping();
      });
    }
    final ed0 = widget.editor;
    if (_drag == _Drag.draw && ed0 != null) {
      final made = ed0.drawing?.id;
      ed0.end();
      // A click (no drag) on a mark already there: choose it, no dot.
      final on = _clickOn;
      if (on != null && !_clickMoved && ed0.inks.any((i) => i.id == on.id)) {
        final dot = made ?? _clickMade;
        if (dot != null) ed0.dropMade(dot);
        _clickMade = null;
        ed0.select(on.id);
        _justPicked = on.id;
      }
    }
    _clickOn = null;
    if (_drag == _Drag.candle) {
      final sel = widget.editor?.selected;
      if (sel != null) Candles.tidy(sel);
      widget.editor?.touched();
    }
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
        // As wide as the words: a new line only where Enter was pressed
        // (Backspace takes one back). Ctrl+Enter / Esc: done.
        constraints: const BoxConstraints(minWidth: 120, maxWidth: 4000),
        child: IntrinsicWidth(
          child: CallbackShortcuts(
            bindings: {
              const SingleActivator(LogicalKeyboardKey.enter, control: true): _finishTyping,
              const SingleActivator(LogicalKeyboardKey.escape): _finishTyping,
            },
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
      ),
    );
  }

  MouseCursor get _own => switch (widget.editor?.tool) {
        null => MouseCursor.defer,
        EditTool.select => SystemMouseCursors.basic,
        EditTool.text => SystemMouseCursors.text,
        _ => SystemMouseCursors.precise,
      };

  /// The pointer's shape where it is (see [inkCursor]).
  MouseCursor? _hoverCursor;

  void _hover(Offset p, Size s) {
    final ed = widget.editor;
    if (ed == null || _drag != _Drag.none) return;
    final c = inkCursor(ed, p, s) ?? _own;
    if (c != _hoverCursor) setState(() => _hoverCursor = c);
  }

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
          repaint: Listenable.merge([?widget.clock, ?widget.freeze, ?ed, ?ed?.strokes]),
        ),
      );
      if (ed == null) return IgnorePointer(child: paint);
      return Focus(
        focusNode: _keys,
        onKeyEvent: _key,
        child: SizedBox.fromSize(
          size: size,
          child: Stack(clipBehavior: Clip.none, children: [
            Positioned.fill(
              child: MouseRegion(
                cursor: _hoverCursor ?? _own,
                onHover: (e) => _hover(e.localPosition, size),
                child: Listener(
                  behavior: HitTestBehavior.opaque,
                  onPointerDown: (e) => _down(e, size),
                  onPointerMove: (e) => _move(e, size),
                  onPointerUp: (_) => _up(),
                  onPointerCancel: (_) => _up(),
                  child: Stack(clipBehavior: Clip.none, children: [paint, _typingField(size)]),
                ),
              ),
            ),
            // Above the clicking layer: clicks on the box are the box's.
            ..._noteWidgets(size),
          ]),
        ),
      );
    });
  }
}

/// The pointer's shape over the marks: on the chosen mark's corners,
/// slanted arrows (as it is turned); on its turning knob, four arrows
/// (Windows has no turning shape); on the chosen mark, a hand; on any mark
/// with the pointer / text tool (a click chooses it), a hand; else null
/// (the tool's own shape).
MouseCursor? inkCursor(InkEditor ed, Offset p, Size s) {
  final sel = ed.selected;
  if (sel != null) {
    if ((p - InkPainter.rotateKnob(sel, s)).distance < 12 && !Candles.noTurn(sel)) return SystemMouseCursors.move;
    final cs = InkGeometry.corners(sel, s);
    if (cs.length == 4) {
      final mid = (cs[0] + cs[2]) / 2;
      for (final q in cs) {
        if ((p - q).distance < 10) {
          final d = q - mid;
          return d.dx * d.dy > 0 ? SystemMouseCursors.resizeUpLeftDownRight : SystemMouseCursors.resizeUpRightDownLeft;
        }
      }
    }
    if (InkGeometry.hits(sel, s, p, slop: 8)) return SystemMouseCursors.click;
  }
  final over = ed.topAt(p, s);
  if (over != null && (ed.tool == EditTool.select || (ed.tool == EditTool.text && over.tool == InkTool.text))) return SystemMouseCursors.click;
  return null;
}

/// What numbers say: a small card by a number when the pointer is on it
/// (or near). [marks]: read each time.
class NumberNotes extends StatefulWidget {
  const NumberNotes({super.key, required this.marks, this.repaint});

  final List<InkMark> Function() marks;
  final Listenable? repaint;

  @override
  State<NumberNotes> createState() => _NumberNotesState();
}

class _NumberNotesState extends State<NumberNotes> {
  InkMark? _on;

  static Offset _at(InkMark m) => m.points.isEmpty ? Offset.zero : m.points.first + Offset(m.dx, m.dy);

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, c) {
        final size = Size(c.maxWidth, c.maxHeight);
        final on = _on;
        return MouseRegion(
          opaque: false,
          hitTestBehavior: HitTestBehavior.translucent,
          onExit: (_) {
            if (_on != null) setState(() => _on = null);
          },
          onHover: (e) {
            InkMark? best;
            var bestD = 22.0;
            for (final m in widget.marks()) {
              if (m.tool != InkTool.number || (m.note ?? '').isEmpty) continue;
              final p = _at(m);
              final d = (Offset(p.dx * size.width, p.dy * size.height) - e.localPosition).distance;
              if (d < bestD) {
                bestD = d;
                best = m;
              }
            }
            if (!identical(best, _on)) setState(() => _on = best);
          },
          child: Stack(clipBehavior: Clip.none, children: [
            if (on != null)
              Builder(builder: (_) {
                final p = _at(on);
                final x = p.dx * size.width, y = p.dy * size.height;
                const w = 260.0;
                return Positioned(
                  left: (x + 16).clamp(0.0, math.max(0.0, size.width - w)),
                  top: (y + 16).clamp(0.0, math.max(0.0, size.height - 60)),
                  width: w,
                  child: IgnorePointer(
                    child: Material(
                      elevation: 6,
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(10),
                      child: Padding(
                        padding: const EdgeInsets.all(10),
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                          Text('${on.number ?? ''}', style: TextStyle(color: Color(on.color), fontWeight: FontWeight.w800)),
                          const SizedBox(height: 2),
                          Text(on.note ?? '', style: const TextStyle(color: Color(0xFF16213E), fontSize: 13, height: 1.5)),
                        ]),
                      ),
                    ),
                  ),
                );
              }),
          ]),
        );
      });
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
        EditTool.stamp => Icons.emoji_symbols_rounded,
        EditTool.candle => Icons.candlestick_chart_rounded,
        EditTool.select => Icons.open_with_rounded,
        EditTool.eraser => Icons.cleaning_services_rounded,
      };

  static String label(EditTool t) => tr('ink.tool_${t.name}');

  /// The toolbar's own stamps (up to three, one click each), and a fold.
  List<Widget> _quick(BuildContext context) {
    final lib = StampLibrary.instance;
    return [
      if (lib.quickShown)
        for (final id in lib.quick)
          GestureDetector(
            onSecondaryTapUp: (d) => unawaited(quickMenu(context, id, d.globalPosition, () => showStampPicker(context))),
            child: IconButton(
              tooltip: stampName(id),
              onPressed: () {
                final q = quickStamp(id);
                if (q == null) {
                  unawaited(pickCandleInto(context, editor));
                  return;
                }
                editor
                  ..upColor = lib.colors.$1
                  ..downColor = lib.colors.$2;
                editor.setStamp(q.shape, q.name);
              },
              icon: StampThumb(id: id, size: 22),
            ),
          ),
      IconButton(
        tooltip: tr(lib.quickShown ? 'stamp.quick_fold' : 'stamp.quick_unfold'),
        visualDensity: VisualDensity.compact,
        onPressed: () => lib.setQuickShown(!lib.quickShown),
        icon: Icon(lib.quickShown ? Icons.chevron_left_rounded : Icons.chevron_right_rounded, size: 18, color: Colors.white54),
      ),
    ];
  }

  Widget _tool(BuildContext context, EditTool t) {
    final on = editor.tool == t;
    return IconButton(
      tooltip: label(t),
      onPressed: () {
        if (t == EditTool.stamp) {
          unawaited(pickStampInto(context, editor));
        } else if (t == EditTool.candle) {
          unawaited(pickCandleInto(context, editor));
        } else {
          editor.setTool(t);
        }
      },
      style: IconButton.styleFrom(backgroundColor: on ? LrColors.safelight.withValues(alpha: 0.25) : null),
      icon: Icon(icon(t), size: 20, color: on ? LrColors.safelight : Colors.white),
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: Listenable.merge([editor, StampLibrary.instance]),
        builder: (context, _) => Container(
          margin: const EdgeInsets.only(top: 8),
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(
            color: const Color(0xE6202020),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: const Color(0x33FFFFFF)),
          ),
          child: Wrap(crossAxisAlignment: WrapCrossAlignment.center, alignment: WrapAlignment.center, children: [
            // Candles are in the stamp panel now (finance), or a toolbar stamp.
            for (final t in EditTool.values)
              if (t != EditTool.candle) ...[_tool(context, t), if (t == EditTool.stamp) ..._quick(context)],
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
            if (editor.hasNumbers)
              IconButton(
                tooltip: tr('ink.renumber'),
                onPressed: editor.renumber,
                icon: const Icon(Icons.format_list_numbered_rounded, size: 20),
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

/// Typing in a text box now: keys are its own (a digit, Delete…).
bool inkTyping() {
  final c = FocusManager.instance.primaryFocus?.context;
  return c != null && (c.widget is EditableText || c.findAncestorWidgetOfExactType<EditableText>() != null);
}

/// A digit key (top row or number pad) → its digit.
int? inkDigitOf(LogicalKeyboardKey k) {
  const top = [
    LogicalKeyboardKey.digit0, LogicalKeyboardKey.digit1, LogicalKeyboardKey.digit2, LogicalKeyboardKey.digit3, LogicalKeyboardKey.digit4,
    LogicalKeyboardKey.digit5, LogicalKeyboardKey.digit6, LogicalKeyboardKey.digit7, LogicalKeyboardKey.digit8, LogicalKeyboardKey.digit9,
  ];
  const pad = [
    LogicalKeyboardKey.numpad0, LogicalKeyboardKey.numpad1, LogicalKeyboardKey.numpad2, LogicalKeyboardKey.numpad3, LogicalKeyboardKey.numpad4,
    LogicalKeyboardKey.numpad5, LogicalKeyboardKey.numpad6, LogicalKeyboardKey.numpad7, LogicalKeyboardKey.numpad8, LogicalKeyboardKey.numpad9,
  ];
  final a = top.indexOf(k);
  if (a >= 0) return a;
  final b = pad.indexOf(k);
  return b >= 0 ? b : null;
}
