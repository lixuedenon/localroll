// packages/ink/lib/src/packs/draw.dart
part of '../stamp_packs.dart';

// Small drawing helpers for the packs. Everything is in the stamp's own box:
// x 0–1 across, y 0–1 down; line widths are parts of the box's height.

const double _tau = math.pi * 2;

StampShape _sh(double aspect, List<StampPart> parts, {bool noTurn = false}) => StampShape(aspect: aspect, parts: parts, noTurn: noTurn);

/// Lines (each list one stroke).
StampPart _ln(List<List<Offset>> strokes, {double w = 0.05, int? color}) => StampPart(polys: strokes, fill: false, w: w, color: color);

/// Filled outlines.
StampPart _fl(List<List<Offset>> outlines, {int? color}) => StampPart(polys: outlines, color: color);

/// A word.
StampPart _tx(String t, {double x = 0.5, double y = 0.5, double size = 0.5, int? color}) =>
    StampPart(text: t, at: Offset(x, y), size: size, color: color);

Offset _o(double x, double y) => Offset(x, y);

/// An ellipse (or part of one, [a0]..[a1] radians, clockwise from the right).
List<Offset> _el(double cx, double cy, double rx, double ry, {double a0 = 0, double a1 = _tau, int n = 48}) {
  final full = (a1 - a0).abs() >= _tau - 1e-6;
  final pts = [for (var k = 0; k <= n; k++) Offset(cx + rx * math.cos(a0 + (a1 - a0) * k / n), cy + ry * math.sin(a0 + (a1 - a0) * k / n))];
  if (full) pts[n] = pts[0];
  return pts;
}

List<Offset> _ci(double cx, double cy, double r, {double a0 = 0, double a1 = _tau, int n = 48, double aspect = 1}) =>
    _el(cx, cy, r / aspect, r, a0: a0, a1: a1, n: n);

/// A rectangle (closed).
List<Offset> _rc(double l, double t, double r, double b) => [_o(l, t), _o(r, t), _o(r, b), _o(l, b), _o(l, t)];

/// A rounded rectangle (closed), corners [rad] high ([aspect]: the box's).
List<Offset> _rr(double l, double t, double r, double b, double rad, {double aspect = 1}) {
  final rx = rad / aspect, ry = rad;
  final out = <Offset>[];
  void arc(double cx, double cy, double a0) {
    for (var k = 0; k <= 6; k++) {
      final a = a0 + math.pi / 2 * k / 6;
      out.add(Offset(cx + rx * math.cos(a), cy + ry * math.sin(a)));
    }
  }

  arc(r - rx, t + ry, -math.pi / 2);
  arc(r - rx, b - ry, 0);
  arc(l + rx, b - ry, math.pi / 2);
  arc(l + rx, t + ry, math.pi);
  out.add(out.first);
  return out;
}

/// An arrow from [a] to [b]: its line, and its filled head ([head]: length
/// as part of the box height; [aspect]: the box's).
List<StampPart> _arrow(Offset a, Offset b, {double w = 0.06, double head = 0.22, double aspect = 1, int? color, bool both = false}) {
  List<Offset> tip(Offset from, Offset to) {
    final dx = (to.dx - from.dx) * aspect, dy = to.dy - from.dy;
    final len = math.sqrt(dx * dx + dy * dy);
    if (len == 0) return const [];
    final ux = dx / len, uy = dy / len;
    Offset p(double along, double side) => Offset(to.dx + (-ux * along - uy * side) / aspect, to.dy + (-uy * along + ux * side));
    return [to, p(head, head * 0.5), p(head * 0.8, 0), p(head, -head * 0.5), to];
  }

  Offset back(Offset from, Offset to) {
    final dx = (to.dx - from.dx) * aspect, dy = to.dy - from.dy;
    final len = math.sqrt(dx * dx + dy * dy);
    if (len == 0) return to;
    final k = (len - head * 0.7) / len;
    return Offset(from.dx + (to.dx - from.dx) * k, from.dy + (to.dy - from.dy) * k);
  }

  return [
    _ln([
      [both ? back(b, a) : a, back(a, b)]
    ], w: w, color: color),
    _fl([tip(a, b), if (both) tip(b, a)], color: color),
  ];
}

/// An arrow along a curve [pts] (head at the last point).
List<StampPart> _curveArrow(List<Offset> pts, {double w = 0.06, double head = 0.22, double aspect = 1, int? color}) {
  final n = pts.length;
  return [
    _ln([pts.sublist(0, n - 1)], w: w, color: color),
    ..._arrow(pts[n - 2], pts[n - 1], w: w, head: head, aspect: aspect, color: color),
  ];
}

/// A wavy line from x0 to x1 at height y.
List<Offset> _wave(double x0, double x1, double y, double amp, double periods, {int n = 60}) =>
    [for (var k = 0; k <= n; k++) Offset(x0 + (x1 - x0) * k / n, y + amp * math.sin(_tau * periods * k / n))];

/// A zigzag from [a] to [b] with [teeth] points, [amp] off the line.
List<Offset> _zig(Offset a, Offset b, int teeth, double amp, {double aspect = 1}) {
  final dx = (b.dx - a.dx) * aspect, dy = b.dy - a.dy;
  final len = math.sqrt(dx * dx + dy * dy);
  final nx = -dy / len, ny = dx / len;
  return [
    a,
    for (var k = 0; k < teeth; k++)
      Offset(a.dx + (b.dx - a.dx) * (k + 0.5) / teeth + nx * amp * (k.isEven ? 1 : -1) / aspect,
          a.dy + (b.dy - a.dy) * (k + 0.5) / teeth + ny * amp * (k.isEven ? 1 : -1)),
    b,
  ];
}

/// A dashed line from [a] to [b] ([dash] parts of its length on, then off).
List<List<Offset>> _dash(Offset a, Offset b, {int dashes = 8}) => [
      for (var k = 0; k < dashes; k++)
        [Offset.lerp(a, b, k / dashes)!, Offset.lerp(a, b, (k + 0.55) / dashes)!],
    ];

/// A grid of [cols] × [rows] cells in [l, t, r, b].
List<List<Offset>> _grid(double l, double t, double r, double b, int cols, int rows) => [
      for (var c = 0; c <= cols; c++) [Offset(l + (r - l) * c / cols, t), Offset(l + (r - l) * c / cols, b)],
      for (var w = 0; w <= rows; w++) [Offset(l, t + (b - t) * w / rows), Offset(r, t + (b - t) * w / rows)],
    ];

/// A function's curve over x 0–1 (y up), drawn in [l, t, r, b].
List<Offset> _curve(double Function(double x) f, double l, double t, double r, double b, {int n = 60}) =>
    [for (var k = 0; k <= n; k++) Offset(l + (r - l) * k / n, b - (b - t) * f(k / n).clamp(0.0, 1.0))];

/// Small x / y axes with arrows in [l, t, r, b].
List<StampPart> _axes(double l, double t, double r, double b, {double aspect = 1, double w = 0.035}) => [
      ..._arrow(Offset(l, b), Offset(r, b), w: w, head: 0.12, aspect: aspect),
      ..._arrow(Offset(l, b), Offset(l, t), w: w, head: 0.12, aspect: aspect),
    ];
