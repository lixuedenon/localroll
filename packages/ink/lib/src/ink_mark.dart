// packages/ink/lib/src/ink_mark.dart
import 'dart:math' as math;
import 'dart:ui' show Offset, Rect;

import 'stamp.dart';

/// What one mark on a picture is.
enum InkTool { pen, marker, line, arrow, rect, ellipse, text, check, cross, number, stamp, candle }

/// One mark: a stroke, a shape, a word, a tick… Stored as lines and
/// points, 0–1 of the picture's width / height, so it fits the picture at
/// any size. The original file is never touched.
class InkMark {
  InkMark({
    required this.id,
    required this.tool,
    required this.color,
    required this.width,
    required this.points,
    this.size = 0.05,
    this.text,
    this.number,
    this.atMs,
    this.dx = 0,
    this.dy = 0,
    this.scale = 1,
    this.rotation = 0,
    List<int>? times,
    this.live = false,
    this.wallMs,
    this.shape,
    this.color2,
  }) : times = times ?? [];

  /// A stamp: its whole picture (kept with the mark, so it shows anywhere,
  /// pack or no pack). [points]: two corners of its box; [text]: its name.
  StampShape? shape;

  /// A candle: the falling colour ([color]: rising). [points]: open,
  /// close, high, low (same x); [size]: body width (part of the height).
  int? color2;

  final String id;
  final InkTool tool;
  int color;

  /// Line width, part of the picture's height.
  double width;

  /// Text / tick / number size, part of the picture's height.
  double size;
  List<Offset> points;
  String? text;
  int? number;

  /// Videos: when it was drawn (it appears then).
  int? atMs;

  /// Moved (0–1 of the picture), resized, turned (radians) afterwards.
  double dx, dy, scale, rotation;

  /// When each point was drawn, ms after the first one (replaying shows
  /// it being drawn). Drawn while the video played ([live]): video time;
  /// drawn while paused: real time.
  List<int> times;

  /// Drawn while the video played (it grows with the video).
  bool live;

  /// Drawn while paused: when, in real time since drawing began (the
  /// order and pace of the replay).
  int? wallMs;

  /// How long drawing it took (ms).
  int get drawMs => times.isEmpty ? 0 : times.last;

  bool get isStamp => tool == InkTool.text || tool == InkTool.check || tool == InkTool.cross || tool == InkTool.number;

  InkMark copy() => InkMark.fromJson(toJson());

  Map<String, dynamic> toJson() => {
        'id': id,
        't': tool.name,
        'c': color,
        'w': _r(width),
        's': _r(size),
        'p': [for (final p in points) ...[_r(p.dx), _r(p.dy)]],
        'text': ?text,
        'n': ?number,
        'at': ?atMs,
        if (dx != 0) 'dx': _r(dx),
        if (dy != 0) 'dy': _r(dy),
        if (scale != 1) 'k': _r(scale),
        if (rotation != 0) 'r': _r(rotation),
        if (times.isNotEmpty) 'pt': times,
        if (live) 'lv': true,
        'wall': ?wallMs,
        if (shape != null) 'sh': shape!.toJson(),
        'c2': ?color2,
      };

  static double _r(double v) => (v * 100000).roundToDouble() / 100000;

  static InkMark fromJson(Map<String, dynamic> j) {
    final p = (j['p'] as List?) ?? const [];
    return InkMark(
      id: j['id'] as String? ?? newId(),
      tool: InkTool.values.firstWhere((t) => t.name == j['t'], orElse: () => InkTool.pen),
      color: (j['c'] as num?)?.toInt() ?? 0xFFFF3B30,
      width: (j['w'] as num?)?.toDouble() ?? 0.006,
      size: (j['s'] as num?)?.toDouble() ?? 0.05,
      points: [for (var i = 0; i + 1 < p.length; i += 2) Offset((p[i] as num).toDouble(), (p[i + 1] as num).toDouble())],
      text: j['text'] as String?,
      number: (j['n'] as num?)?.toInt(),
      atMs: (j['at'] as num?)?.toInt(),
      dx: (j['dx'] as num?)?.toDouble() ?? 0,
      dy: (j['dy'] as num?)?.toDouble() ?? 0,
      scale: (j['k'] as num?)?.toDouble() ?? 1,
      rotation: (j['r'] as num?)?.toDouble() ?? 0,
      times: [for (final t in (j['pt'] as List?) ?? const []) (t as num).toInt()],
      live: j['lv'] == true,
      wallMs: (j['wall'] as num?)?.toInt(),
      shape: j['sh'] is Map ? StampShape.fromJson((j['sh'] as Map).cast<String, dynamic>()) : null,
      color2: (j['c2'] as num?)?.toInt(),
    );
  }

  /// Where it is before moving / turning (0–1).
  Rect get bounds {
    if (points.isEmpty) return Rect.zero;
    var l = points.first.dx, r = l, t = points.first.dy, b = t;
    for (final p in points) {
      l = math.min(l, p.dx);
      r = math.max(r, p.dx);
      t = math.min(t, p.dy);
      b = math.max(b, p.dy);
    }
    return Rect.fromLTRB(l, t, r, b);
  }

  static int _seq = 0;
  static String newId() => '${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}${(_seq++).toRadixString(36)}';
}
