// apps/mobile/lib/ui/home_look.dart
import 'dart:math' as math;

import 'package:flutter/material.dart';

/// The home page's light look: a blue sky at the top with soft swirls,
/// frosted white cards, pastel tiles. (The other pages keep the dark look
/// for now.)
class HomeColors {
  HomeColors._();

  static const skyTop = Color(0xFF1456E8);
  static const skyMid = Color(0xFF2F7BFF);
  static const skyLow = Color(0xFF7DB4FF);
  static const page = Color(0xFFEFF4FD);
  static const ink = Color(0xFF0C1E45);
  static const muted = Color(0xFF5D6D8E);
  static const blue = Color(0xFF1E63F0);
  static const blueDeep = Color(0xFF0B47C9);
  static const green = Color(0xFF1FB86A);
  static const line = Color(0xFFDDE6F6);
  static const glass = Color(0xE6FFFFFF);
}

/// The home page's theme (light, blue), inside the app's dark one.
ThemeData homeTheme(ThemeData base) {
  final scheme = ColorScheme.fromSeed(seedColor: HomeColors.blue, brightness: Brightness.light).copyWith(
    primary: HomeColors.blue,
    onPrimary: Colors.white,
    surface: Colors.white,
    onSurface: HomeColors.ink,
    onSurfaceVariant: HomeColors.muted,
    outline: HomeColors.line,
  );
  return base.copyWith(
    colorScheme: scheme,
    scaffoldBackgroundColor: HomeColors.page,
    textTheme: base.textTheme.apply(bodyColor: HomeColors.ink, displayColor: HomeColors.ink),
    iconTheme: const IconThemeData(color: HomeColors.blue),
    dividerTheme: const DividerThemeData(color: HomeColors.line),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith((s) => Colors.white),
      trackColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? HomeColors.blue : const Color(0xFFC9D4E8)),
      trackOutlineColor: WidgetStateProperty.all(Colors.transparent),
    ),
    textButtonTheme: TextButtonThemeData(style: TextButton.styleFrom(foregroundColor: HomeColors.blue)),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: HomeColors.blue,
        side: const BorderSide(color: Color(0xFFB9CDF5)),
        backgroundColor: Colors.white.withValues(alpha: 0.7),
        shape: const StadiumBorder(),
      ),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: Colors.white,
      indicatorColor: HomeColors.blue,
      iconTheme: WidgetStateProperty.resolveWith(
        (s) => IconThemeData(color: s.contains(WidgetState.selected) ? Colors.white : const Color(0xFF7A88A6)),
      ),
      labelTextStyle: WidgetStateProperty.resolveWith(
        (s) => TextStyle(
          fontSize: 12,
          fontWeight: s.contains(WidgetState.selected) ? FontWeight.w700 : FontWeight.w500,
          color: s.contains(WidgetState.selected) ? HomeColors.blue : const Color(0xFF7A88A6),
        ),
      ),
    ),
  );
}

/// The sky behind the top of the home page: a blue gradient fading into
/// the page, with a few soft light swirls.
class HomeBackdrop extends StatelessWidget {
  const HomeBackdrop({super.key, required this.height});

  final double height;

  @override
  Widget build(BuildContext context) => SizedBox(
        height: height,
        width: double.infinity,
        child: CustomPaint(painter: _SkyPainter()),
      );
}

class _SkyPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final r = Offset.zero & size;
    canvas.drawRect(
      r,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomCenter,
          colors: [HomeColors.skyTop, HomeColors.skyMid, HomeColors.skyLow, HomeColors.page],
          stops: [0, 0.45, 0.78, 1],
        ).createShader(r),
    );
    // Swirls: wide soft strokes of light.
    void swirl(double y, double amp, double width, double alpha, double phase) {
      final p = Path()..moveTo(-20, y);
      for (var x = -20.0; x <= size.width + 20; x += 8) {
        p.lineTo(x, y + math.sin(x / size.width * math.pi * 1.4 + phase) * amp);
      }
      canvas.drawPath(
        p,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = width
          ..strokeCap = StrokeCap.round
          ..color = Colors.white.withValues(alpha: alpha)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6),
      );
    }

    swirl(size.height * 0.18, 26, 38, 0.10, 0.6);
    swirl(size.height * 0.34, 34, 22, 0.14, 2.2);
    swirl(size.height * 0.52, 20, 54, 0.08, 4.0);
    // A glow at the top right.
    canvas.drawCircle(
      Offset(size.width * 0.88, size.height * 0.08),
      size.width * 0.38,
      Paint()
        ..shader = RadialGradient(colors: [Colors.white.withValues(alpha: 0.22), Colors.white.withValues(alpha: 0)])
            .createShader(Rect.fromCircle(center: Offset(size.width * 0.88, size.height * 0.08), radius: size.width * 0.38)),
    );
  }

  @override
  bool shouldRepaint(_SkyPainter old) => false;
}

/// LocalRoll's mark drawn here: a play button in a soft rounded tile, with
/// a blue and a green arrow going round it (send and receive).
class LogoMark extends StatelessWidget {
  const LogoMark({super.key, this.size = 52});

  final double size;

  @override
  Widget build(BuildContext context) => SizedBox(width: size, height: size, child: CustomPaint(painter: _LogoPainter()));
}

class _LogoPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size s) {
    final c = s.center(Offset.zero);
    final r = s.width / 2;
    // The tile.
    final tile = RRect.fromRectAndRadius(Rect.fromCircle(center: c, radius: r * 0.62), Radius.circular(r * 0.36));
    canvas.drawRRect(
      tile.shift(Offset(0, r * 0.06)),
      Paint()
        ..color = const Color(0x33000A40)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4),
    );
    canvas.drawRRect(
      tile,
      Paint()
        ..shader = const LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [Colors.white, Color(0xFFD9E7FF)])
            .createShader(tile.outerRect),
    );
    // Play.
    final t = Path()
      ..moveTo(c.dx - r * 0.18, c.dy - r * 0.26)
      ..lineTo(c.dx + r * 0.28, c.dy)
      ..lineTo(c.dx - r * 0.18, c.dy + r * 0.26)
      ..close();
    canvas.drawPath(
      t,
      Paint()
        ..shader = const LinearGradient(colors: [HomeColors.blue, Color(0xFF00B4FF)]).createShader(t.getBounds()),
    );
    // Two arrows round it.
    void arc(double start, double sweep, List<Color> colors) {
      final rect = Rect.fromCircle(center: c, radius: r * 0.86);
      final p = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = r * 0.16
        ..strokeCap = StrokeCap.round
        ..shader = SweepGradient(startAngle: start, endAngle: start + sweep, colors: colors).createShader(rect);
      canvas.drawArc(rect, start, sweep, false, p);
      // The arrow head.
      final end = start + sweep;
      final tip = c + Offset(math.cos(end), math.sin(end)) * r * 0.86;
      final dir = Offset(-math.sin(end), math.cos(end));
      final side = Offset(math.cos(end), math.sin(end));
      final head = Path()
        ..moveTo(tip.dx + dir.dx * r * 0.2, tip.dy + dir.dy * r * 0.2)
        ..lineTo(tip.dx + side.dx * r * 0.16, tip.dy + side.dy * r * 0.16)
        ..lineTo(tip.dx - side.dx * r * 0.16, tip.dy - side.dy * r * 0.16)
        ..close();
      canvas.drawPath(head, Paint()..color = colors.last);
    }

    arc(math.pi * 0.95, math.pi * 0.85, const [Color(0xFF7FC4FF), Color(0xFF29A8FF)]);
    arc(-math.pi * 0.05, math.pi * 0.85, const [Color(0xFF9BE38C), Color(0xFF2CC46B)]);
  }

  @override
  bool shouldRepaint(_LogoPainter old) => false;
}

/// A frosted white card.
class GlassCard extends StatelessWidget {
  const GlassCard({super.key, required this.child, this.padding = const EdgeInsets.fromLTRB(18, 16, 18, 8)});

  final Widget child;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) => Container(
        padding: padding,
        decoration: BoxDecoration(
          color: HomeColors.glass,
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: Colors.white, width: 1.2),
          boxShadow: const [BoxShadow(color: Color(0x1F1E4FB8), blurRadius: 24, offset: Offset(0, 10))],
        ),
        child: child,
      );
}

/// A pastel tile: a coloured icon, a title, a line under it, a small ›.
class PastelTile extends StatelessWidget {
  const PastelTile({
    super.key,
    required this.icon,
    required this.title,
    required this.sub,
    required this.tint,
    required this.onTap,
    this.subColor,
  });

  final IconData icon;
  final String title;
  final String sub;

  /// The tile's colour (its icon; the background is a light wash of it).
  final Color tint;
  final Color? subColor;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Material(
        color: Colors.transparent,
        child: Ink(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Color.alphaBlend(tint.withValues(alpha: 0.16), Colors.white), Color.alphaBlend(tint.withValues(alpha: 0.06), Colors.white)],
            ),
            borderRadius: BorderRadius.circular(22),
            border: Border.all(color: Colors.white, width: 1.2),
            boxShadow: [BoxShadow(color: tint.withValues(alpha: 0.16), blurRadius: 16, offset: const Offset(0, 6))],
          ),
          child: InkWell(
            borderRadius: BorderRadius.circular(22),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(8, 16, 8, 10),
              child: Column(children: [
                Container(
                  width: 50,
                  height: 50,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [Color.alphaBlend(Colors.white.withValues(alpha: 0.25), tint), tint],
                    ),
                    boxShadow: [BoxShadow(color: tint.withValues(alpha: 0.35), blurRadius: 10, offset: const Offset(0, 4))],
                  ),
                  child: Icon(icon, color: Colors.white, size: 26),
                ),
                const SizedBox(height: 10),
                Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15, color: HomeColors.ink)),
                const SizedBox(height: 3),
                Text(sub, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: subColor ?? HomeColors.muted)),
                const SizedBox(height: 8),
                Container(
                  width: 26,
                  height: 26,
                  decoration: BoxDecoration(shape: BoxShape.circle, color: Colors.white.withValues(alpha: 0.8)),
                  child: const Icon(Icons.chevron_right_rounded, size: 18, color: HomeColors.muted),
                ),
              ]),
            ),
          ),
        ),
      );
}

/// A wide pill button with the blue gradient.
class SkyButton extends StatelessWidget {
  const SkyButton({super.key, required this.label, required this.onPressed, this.icon});

  final String label;
  final IconData? icon;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => Opacity(
        opacity: onPressed == null ? 0.5 : 1,
        child: Material(
          color: Colors.transparent,
          child: Ink(
            height: 54,
            decoration: BoxDecoration(
              gradient: const LinearGradient(colors: [Color(0xFF2F7BFF), HomeColors.blueDeep]),
              borderRadius: BorderRadius.circular(27),
              boxShadow: const [BoxShadow(color: Color(0x552F7BFF), blurRadius: 16, offset: Offset(0, 6))],
            ),
            child: InkWell(
              borderRadius: BorderRadius.circular(27),
              onTap: onPressed,
              child: Center(
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  if (icon != null) ...[Icon(icon, color: Colors.white, size: 22), const SizedBox(width: 10)],
                  Flexible(
                    child: Text(label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.w800)),
                  ),
                ]),
              ),
            ),
          ),
        ),
      );
}

/// Small floating tiles (photo, video, document) for the card's corner.
class FloatingKinds extends StatelessWidget {
  const FloatingKinds({super.key});

  @override
  Widget build(BuildContext context) {
    Widget tile(IconData i, List<Color> c, double angle, double size) => Transform.rotate(
          angle: angle,
          child: Container(
            width: size,
            height: size,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(size * 0.28),
              gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: c),
              boxShadow: [BoxShadow(color: c.last.withValues(alpha: 0.35), blurRadius: 10, offset: const Offset(0, 4))],
            ),
            child: Icon(i, color: Colors.white, size: size * 0.55),
          ),
        );
    return SizedBox(
      width: 112,
      height: 74,
      child: Stack(children: [
        Positioned(left: 0, top: 14, child: tile(Icons.image_rounded, const [Color(0xFF6CC3FF), Color(0xFF2F7BFF)], -0.18, 38)),
        Positioned(left: 38, top: 0, child: tile(Icons.play_arrow_rounded, const [Color(0xFFB18CFF), Color(0xFF7B4DFF)], 0.12, 40)),
        Positioned(left: 76, top: 22, child: tile(Icons.picture_as_pdf_rounded, const [Color(0xFFFF8A80), Color(0xFFE5393B)], 0.2, 34)),
      ]),
    );
  }
}
