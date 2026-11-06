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
    _held?.cancel();
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
    if ((twice || heldBack) && ed.tool != EditTool.text) {
      if (made != null) ed.dropMade(made);
      final hit = ed.topAt(p, s);
      if (hit != null) {
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
        // A word already there: change it.
        final hit = ed.inks.reversed.where((i) => i.tool == InkTool.text && InkGeometry.hits(i, s, p)).firstOrNull;
        if (hit != null) {
          ed.editText(hit);
        } else {
          ed.begin(_n(p, s));
        }
        _startTyping();
      default:
        const oneClick = {EditTool.stamp, EditTool.check, EditTool.cross, EditTool.number};
        if (oneClick.contains(ed.tool) && ed.topAt(p, s) != null) {
          final at = _heldAt = _n(p, s);
          _held = Timer(const Duration(milliseconds: 380), () {
            if (!mounted) return;
            ed.begin(at);
            ed.end();
          });
          return;
        }
        _drag = _Drag.draw;
        final before = ed.inks.length;
        ed.begin(_n(p, s));
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
    if (_drag == _Drag.draw) widget.editor?.end();
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
          repaint: Listenable.merge([?widget.clock, ?widget.freeze, ?ed, ?ed?.strokes]),
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
