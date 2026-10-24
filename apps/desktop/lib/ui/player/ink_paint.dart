// apps/desktop/lib/ui/player/ink_paint.dart
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../services/annotations.dart';

/// Drawing marks onto a picture of [size] pixels (screen, or a full-size
/// screenshot): the same marks look the same at any size.
class InkGeometry {
  InkGeometry._();

  static Offset px(Offset p, Size s) => Offset(p.dx * s.width, p.dy * s.height);

  /// Line width in pixels.
  static double lineWidth(InkMark i, Size s) => math.max(1.0, i.width * s.height);

  /// Text / tick / number size in pixels.
  static double stampSize(InkMark i, Size s) => math.max(8.0, i.size * s.height);

  static TextPainter textPainter(InkMark i, Size s) => TextPainter(
        text: TextSpan(
          text: (i.text == null || i.text!.isEmpty) ? ' ' : i.text,
          style: TextStyle(
            color: Color(i.color),
            fontSize: stampSize(i, s),
            fontWeight: FontWeight.w600,
            height: 1.2,
            shadows: const [Shadow(color: Color(0x99000000), blurRadius: 3, offset: Offset(0, 1))],
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: math.max(40, s.width * 0.9));

  /// The box around the mark before it was moved / turned (pixels).
  static Rect box(InkMark i, Size s) {
    if (i.points.isEmpty) return Rect.zero;
    final p0 = px(i.points.first, s);
    switch (i.tool) {
      case InkTool.text:
        final tp = textPainter(i, s);
        return Rect.fromLTWH(p0.dx, p0.dy, tp.width, tp.height);
      case InkTool.check:
      case InkTool.cross:
      case InkTool.number:
        final d = stampSize(i, s);
        return Rect.fromCenter(center: p0, width: d, height: d);
      default:
        final b = i.bounds;
        final r = Rect.fromLTRB(b.left * s.width, b.top * s.height, b.right * s.width, b.bottom * s.height);
        final w = lineWidth(i, s) * (i.tool == InkTool.marker ? 3 : 1);
        return r.inflate(w / 2 + (i.tool == InkTool.arrow ? w * 2 : 0));
    }
  }

  /// Pixel position of a point of the mark after moving / resizing / turning.
  static Offset transform(InkMark i, Size s, Offset p) {
    final c = box(i, s).center;
    final v = (p - c) * i.scale;
    final cs = math.cos(i.rotation), sn = math.sin(i.rotation);
    return c + Offset(v.dx * cs - v.dy * sn, v.dx * sn + v.dy * cs) + Offset(i.dx * s.width, i.dy * s.height);
  }

  /// The other way: a pixel on screen into the mark's own (unmoved) space.
  static Offset untransform(InkMark i, Size s, Offset p) {
    final c = box(i, s).center;
    final v = p - c - Offset(i.dx * s.width, i.dy * s.height);
    final cs = math.cos(-i.rotation), sn = math.sin(-i.rotation);
    final r = Offset(v.dx * cs - v.dy * sn, v.dx * sn + v.dy * cs);
    return c + r / (i.scale == 0 ? 1 : i.scale);
  }

  /// The four corners of the moved / turned box (for the selection).
  static List<Offset> corners(InkMark i, Size s) {
    final b = box(i, s).inflate(4);
    return [for (final p in [b.topLeft, b.topRight, b.bottomRight, b.bottomLeft]) transform(i, s, p)];
  }

  static double _segDist(Offset p, Offset a, Offset b) {
    final ab = b - a;
    final len2 = ab.dx * ab.dx + ab.dy * ab.dy;
    if (len2 == 0) return (p - a).distance;
    final t = (((p - a).dx * ab.dx + (p - a).dy * ab.dy) / len2).clamp(0.0, 1.0);
    return (p - (a + ab * t)).distance;
  }

  static double _polyDist(Offset p, List<Offset> pts) {
    if (pts.length == 1) return (p - pts.first).distance;
    var best = double.infinity;
    for (var k = 0; k + 1 < pts.length; k++) {
      best = math.min(best, _segDist(p, pts[k], pts[k + 1]));
    }
    return best;
  }

  /// Is [p] (pixels) on the mark, give or take [slop] pixels?
  static bool hits(InkMark i, Size s, Offset p, {double slop = 6}) {
    if (i.points.isEmpty) return false;
    final q = untransform(i, s, p);
    final w = lineWidth(i, s) * (i.tool == InkTool.marker ? 3 : 1) / 2 + slop / (i.scale == 0 ? 1 : i.scale);
    final pts = [for (final x in i.points) px(x, s)];
    switch (i.tool) {
      case InkTool.pen:
      case InkTool.marker:
      case InkTool.line:
      case InkTool.arrow:
        return _polyDist(q, pts) <= w;
      case InkTool.rect:
        final r = Rect.fromPoints(pts.first, pts.last);
        return _polyDist(q, [r.topLeft, r.topRight, r.bottomRight, r.bottomLeft, r.topLeft]) <= w;
      case InkTool.ellipse:
        final r = Rect.fromPoints(pts.first, pts.last);
        final ring = [
          for (var k = 0; k <= 48; k++)
            Offset(r.center.dx + r.width / 2 * math.cos(k * math.pi / 24), r.center.dy + r.height / 2 * math.sin(k * math.pi / 24)),
        ];
        return _polyDist(q, ring) <= w;
      case InkTool.text:
      case InkTool.check:
      case InkTool.cross:
      case InkTool.number:
        return box(i, s).inflate(slop).contains(q);
    }
  }

  // --------------------------------------------------------------- paint

  /// [upto]: only what was drawn in its first [upto] ms (replay).
  static void paint(Canvas c, Size s, InkMark i, {int? upto}) {
    if (i.points.isEmpty) return;
    if (upto != null && upto < 0) return;
    final center = box(i, s).center;
    c.save();
    c.translate(center.dx + i.dx * s.width, center.dy + i.dy * s.height);
    c.rotate(i.rotation);
    c.scale(i.scale);
    c.translate(-center.dx, -center.dy);
    _paintPlain(c, s, i, upto == null || upto >= i.drawMs ? null : _partial(i, upto));
    c.restore();
  }

  /// The points drawn by [upto] ms (shapes grow to their size).
  static List<Offset> _partial(InkMark i, int upto) {
    final p = i.points, t = i.times;
    if (t.length != p.length || p.isEmpty) return p;
    switch (i.tool) {
      case InkTool.pen:
      case InkTool.marker:
        var n = 1;
        while (n < p.length && t[n] <= upto) {
          n++;
        }
        return p.sublist(0, n);
      case InkTool.line:
      case InkTool.arrow:
      case InkTool.rect:
      case InkTool.ellipse:
        final f = i.drawMs <= 0 ? 1.0 : (upto / i.drawMs).clamp(0.0, 1.0);
        return [p.first, Offset.lerp(p.first, p.last, f)!];
      default:
        return p;
    }
  }

  static Paint _stroke(InkMark i, double w, {double alpha = 1}) => Paint()
    ..color = Color(i.color).withValues(alpha: Color(i.color).a * alpha)
    ..style = PaintingStyle.stroke
    ..strokeWidth = w
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round
    ..isAntiAlias = true;

  static Path _smooth(List<Offset> p) {
    final path = Path()..moveTo(p.first.dx, p.first.dy);
    if (p.length == 1) {
      path.lineTo(p.first.dx + 0.01, p.first.dy);
      return path;
    }
    for (var k = 1; k + 1 < p.length; k++) {
      final mid = (p[k] + p[k + 1]) / 2;
      path.quadraticBezierTo(p[k].dx, p[k].dy, mid.dx, mid.dy);
    }
    path.lineTo(p.last.dx, p.last.dy);
    return path;
  }

  static void _paintPlain(Canvas c, Size s, InkMark i, [List<Offset>? only]) {
    final pts = [for (final x in only ?? i.points) px(x, s)];
    final w = lineWidth(i, s);
    switch (i.tool) {
      case InkTool.pen:
        c.drawPath(_smooth(pts), _stroke(i, w));
      case InkTool.marker:
        c.drawPath(_smooth(pts), _stroke(i, w * 3, alpha: 0.4)..strokeCap = StrokeCap.square);
      case InkTool.line:
        c.drawLine(pts.first, pts.last, _stroke(i, w));
      case InkTool.arrow:
        final a = pts.first, b = pts.last;
        c.drawLine(a, b, _stroke(i, w));
        final ang = math.atan2(b.dy - a.dy, b.dx - a.dx);
        final head = math.max(10.0, w * 4);
        final path = Path()
          ..moveTo(b.dx, b.dy)
          ..lineTo(b.dx - head * math.cos(ang - 0.45), b.dy - head * math.sin(ang - 0.45))
          ..lineTo(b.dx - head * math.cos(ang + 0.45), b.dy - head * math.sin(ang + 0.45))
          ..close();
        c.drawPath(path, Paint()..color = Color(i.color));
      case InkTool.rect:
        c.drawRect(Rect.fromPoints(pts.first, pts.last), _stroke(i, w));
      case InkTool.ellipse:
        c.drawOval(Rect.fromPoints(pts.first, pts.last), _stroke(i, w));
      case InkTool.text:
        textPainter(i, s).paint(c, pts.first);
      case InkTool.check:
        final r = box(i, s);
        Offset at(double x, double y) => Offset(r.left + r.width * x, r.top + r.height * y);
        final path = Path()
          ..moveTo(at(0.12, 0.55).dx, at(0.12, 0.55).dy)
          ..lineTo(at(0.4, 0.82).dx, at(0.4, 0.82).dy)
          ..lineTo(at(0.9, 0.18).dx, at(0.9, 0.18).dy);
        c.drawPath(path, _stroke(i, r.width * 0.13));
      case InkTool.cross:
        final r = box(i, s).deflate(box(i, s).width * 0.15);
        final p = _stroke(i, box(i, s).width * 0.13);
        c
          ..drawLine(r.topLeft, r.bottomRight, p)
          ..drawLine(r.topRight, r.bottomLeft, p);
      case InkTool.number:
        final r = box(i, s);
        final fill = Color(i.color);
        c.drawCircle(r.center, r.width / 2, Paint()..color = fill);
        final light = fill.computeLuminance() > 0.6;
        final tp = TextPainter(
          text: TextSpan(
            text: '${i.number ?? 1}',
            style: TextStyle(color: light ? Colors.black : Colors.white, fontSize: r.width * 0.58, fontWeight: FontWeight.w700),
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        tp.paint(c, r.center - Offset(tp.width / 2, tp.height / 2));
    }
  }
}

/// A replay of marks drawn while paused, [elapsedMs] into it.
typedef FreezeNow = ({FreezePlan plan, int elapsedMs});

/// Draws [notes] as they are at [now] ms into a video (a photo: all), the
/// way they were drawn: marks drawn while it played grow with the video;
/// marks drawn while paused are whole — or, while [freeze] replays them,
/// drawn again stroke by stroke.
void paintNotes(Canvas canvas, Size size, List<Note> notes, {required bool video, int now = 0, FreezeNow? freeze}) {
  for (final n in notes) {
    if (!video) {
      for (final i in n.inks) {
        InkGeometry.paint(canvas, size, i);
      }
      continue;
    }
    if (!n.shownAt(now)) continue;
    for (final i in n.inks) {
      final at = i.atMs ?? n.startMs;
      if (now < at) continue;
      if (i.live) {
        InkGeometry.paint(canvas, size, i, upto: now - at);
      } else if (freeze != null && freeze.plan.noteId == n.id && (freeze.plan.atMs - at).abs() <= 150) {
        InkGeometry.paint(canvas, size, i, upto: freeze.elapsedMs - (freeze.plan.start[i.id] ?? 0));
      } else {
        InkGeometry.paint(canvas, size, i);
      }
    }
  }
}

/// Paints annotations over a picture: [notes] as they are now, plus what
/// is being drawn ([draft], read each time it paints).
class InkPainter extends CustomPainter {
  InkPainter({
    required this.notes,
    required this.video,
    this.ms,
    this.freeze,
    this.draft,
    this.selected,
    super.repaint,
  });

  final List<Note> notes;
  final bool video;
  final ValueGetter<int>? ms;
  final ValueGetter<FreezeNow?>? freeze;
  final ValueGetter<List<InkMark>>? draft;
  final ValueGetter<InkMark?>? selected;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    paintNotes(canvas, size, notes, video: video, now: ms?.call() ?? 0, freeze: freeze?.call());
    for (final i in draft?.call() ?? const <InkMark>[]) {
      InkGeometry.paint(canvas, size, i);
    }
    final sel = selected?.call();
    if (sel != null) {
      final c = InkGeometry.corners(sel, size);
      final line = Paint()
        ..color = const Color(0xFF6FB3F0)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5;
      canvas.drawPath(Path()..addPolygon(c, true), line);
      final dot = Paint()..color = Colors.white;
      for (final p in c) {
        canvas
          ..drawCircle(p, 6, dot)
          ..drawCircle(p, 6, line);
      }
      final top = (c[0] + c[1]) / 2;
      final knob = rotateKnob(sel, size);
      canvas
        ..drawLine(top, knob, line)
        ..drawCircle(knob, 7, dot)
        ..drawCircle(knob, 7, line);
    }
    canvas.restore();
  }

  /// The round handle above a selected mark that turns it.
  static Offset rotateKnob(InkMark i, Size s) {
    final c = InkGeometry.corners(i, s);
    final top = (c[0] + c[1]) / 2;
    final mid = (c[0] + c[2]) / 2;
    final dir = top - mid;
    final len = dir.distance == 0 ? 1.0 : dir.distance;
    return top + dir / len * 26;
  }

  @override
  bool shouldRepaint(InkPainter old) => true;
}
