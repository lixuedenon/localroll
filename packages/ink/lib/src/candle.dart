// packages/ink/lib/src/candle.dart
import 'dart:math' as math;
import 'dart:ui';

import 'ink_mark.dart';
import 'stamp.dart';

/// How a hand-drawn candle's wicks come out.
enum CandleKind { normal, longUpper, longLower, bald, doji }

/// Hand-drawn candles (K lines): one mark each. points: open, close,
/// high, low (0–1 of the picture, same x); size: body width (part of the
/// picture's height); color rising, color2 falling.
class Candles {
  static const int red = 0xFFE53935, green = 0xFF16A34A;

  /// Rising green, falling red (US / international) unless asked otherwise.
  static (int up, int down) colors(bool redUp) => redUp ? (red, green) : (green, red);

  /// Never turned.
  static bool noTurn(InkMark m) => m.tool == InkTool.candle || (m.shape?.noTurn ?? false);

  static bool rising(InkMark m) => m.points.length >= 2 && m.points[1].dy <= m.points[0].dy;

  /// High / low from the body, as [kind] says. A doji: open = close, the
  /// drag sets how long its wicks are.
  static void autoWicks(InkMark m, [CandleKind kind = CandleKind.normal]) {
    if (m.points.length < 2) return;
    final o = m.points[0];
    var c = m.points[1];
    if (kind == CandleKind.doji) {
      final reach = math.max((c.dy - o.dy).abs(), 0.02);
      m.points = [o, o, Offset(o.dx, o.dy - reach), Offset(o.dx, o.dy + reach)];
      return;
    }
    final top = math.min(o.dy, c.dy), bot = math.max(o.dy, c.dy), body = bot - top;
    final short = math.max(body * 0.25, 0.012), long = math.max(body * 2, 0.06);
    final (up, down) = switch (kind) {
      CandleKind.longUpper => (long, math.max(body * 0.1, 0.006)),
      CandleKind.longLower => (math.max(body * 0.1, 0.006), long),
      CandleKind.bald => (0.0, 0.0),
      _ => (short, short),
    };
    c = Offset(o.dx, c.dy);
    final hi = Offset(o.dx, top - up), lo = Offset(o.dx, bot + down);
    if (m.points.length < 4) {
      m.points = [o, c, hi, lo];
    } else {
      m.points[1] = c;
      m.points[2] = hi;
      m.points[3] = lo;
    }
  }

  /// High above the body, low below it (after a handle was dragged).
  static void tidy(InkMark m) {
    if (m.points.length < 4) return;
    final x = m.points[0].dx;
    final o = m.points[0].dy, c = m.points[1].dy;
    final hi = math.min(m.points[2].dy, math.min(o, c)), lo = math.max(m.points[3].dy, math.max(o, c));
    m.points = [Offset(x, o), Offset(x, c), Offset(x, hi), Offset(x, lo)];
  }

  /// Its box in pixels on a picture [s] big.
  static Rect box(InkMark m, Size s) {
    if (m.points.length < 4) return Rect.zero;
    final x = m.points[0].dx * s.width, w = math.max(4.0, m.size * s.height);
    return Rect.fromLTRB(x - w / 2, m.points[2].dy * s.height, x + w / 2, m.points[3].dy * s.height);
  }

  /// The 4 handles (high, open, close, low) in pixels, before moving.
  static List<Offset> handles(InkMark m, Size s) => [
        for (final i in const [2, 0, 1, 3]) Offset(m.points[0].dx * s.width, m.points[i].dy * s.height),
      ];

  static void paint(Canvas c, InkMark m, Size s) {
    if (m.points.length < 4) return;
    final x = m.points[0].dx * s.width, w = math.max(4.0, m.size * s.height);
    final o = m.points[0].dy * s.height, cl = m.points[1].dy * s.height;
    final col = Color(rising(m) ? m.color : (m.color2 ?? m.color));
    final p = Paint()
      ..color = col
      ..strokeWidth = math.max(1.2, w * 0.12);
    c.drawLine(Offset(x, m.points[2].dy * s.height), Offset(x, m.points[3].dy * s.height), p);
    final top = math.min(o, cl), bot = math.max(o, cl);
    c.drawRect(Rect.fromLTRB(x - w / 2, top, x + w / 2, math.max(bot, top + 1.5)), Paint()..color = col);
  }

  /// A row of candles as one stamp: each (open, close, high, low), 0 at
  /// the bottom, 1 at the top. Rising / falling colours are set on placing.
  static StampShape pattern(List<(double, double, double, double)> cs, {String? role}) {
    final n = cs.length;
    final parts = <StampPart>[];
    for (var i = 0; i < n; i++) {
      final (o, c, h, l) = cs[i];
      final x = (i + 0.5) / n, bw = 0.62 / n;
      final r = role ?? (c >= o ? 'u' : 'd');
      final top = 1.0 - math.max(o, c), bot = 1.0 - math.min(o, c);
      parts.add(StampPart(polys: [[Offset(x, 1.0 - h), Offset(x, 1.0 - l)]], fill: false, w: 0.035, role: r));
      parts.add(StampPart(
        polys: [[Offset(x - bw / 2, top), Offset(x + bw / 2, top), Offset(x + bw / 2, math.max(bot, top + 0.02)), Offset(x - bw / 2, math.max(bot, top + 0.02))]],
        role: r,
      ));
    }
    return StampShape(aspect: math.max(0.45, n * 0.42), parts: parts, noTurn: true);
  }
}
