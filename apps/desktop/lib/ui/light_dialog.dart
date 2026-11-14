// apps/desktop/lib/ui/light_dialog.dart
import 'package:flutter/material.dart';

import 'light_look.dart';

/// Dialogs opened from the light pages (Home, Library): white, a blue
/// header with soft bands of light, rows as small cards.
class LightDialog extends StatelessWidget {
  const LightDialog({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    required this.child,
    this.actions = const [],
    this.width = 580,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final Widget child;
  final List<Widget> actions;
  final double width;

  @override
  Widget build(BuildContext context) => Theme(
        data: ThemeData(
          brightness: Brightness.light,
          colorSchemeSeed: LightLook.blue,
          fontFamily: Theme.of(context).textTheme.bodyMedium?.fontFamily,
          fontFamilyFallback: Theme.of(context).textTheme.bodyMedium?.fontFamilyFallback,
        ),
        child: Dialog(
          backgroundColor: Colors.white,
          clipBehavior: Clip.antiAlias,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
          child: SizedBox(
            width: width,
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Container(
                height: 112,
                decoration: const BoxDecoration(
                  gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [Color(0xFF2F7CF6), Color(0xFF1559D6)]),
                ),
                child: Stack(children: [
                  const Positioned.fill(child: CustomPaint(painter: LightBands())),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(26, 22, 26, 16),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Row(children: [
                        Icon(icon, color: Colors.white, size: 26),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(title, style: const TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.w800)),
                        ),
                      ]),
                      if (subtitle != null) ...[
                        const SizedBox(height: 6),
                        Text(subtitle!, maxLines: 2, style: TextStyle(color: Colors.white.withValues(alpha: 0.88), fontSize: 13.5)),
                      ],
                    ]),
                  ),
                ]),
              ),
              Flexible(
                child: Container(
                  color: const Color(0xFFF4F7FC),
                  child: SingleChildScrollView(padding: const EdgeInsets.fromLTRB(20, 16, 20, 16), child: child),
                ),
              ),
              if (actions.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 12, 20, 14),
                  child: Wrap(alignment: WrapAlignment.end, spacing: 10, runSpacing: 8, children: actions),
                ),
            ]),
          ),
        ),
      );
}

/// One row: a coloured icon, a title and a line under it, something at the end.
class LightRow extends StatelessWidget {
  const LightRow({super.key, required this.icon, required this.iconBg, required this.title, this.sub, this.trailing, this.iconColor});

  final IconData icon;
  final Color iconBg;
  final Color? iconColor;
  final String title;
  final String? sub;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(14),
          boxShadow: const [BoxShadow(color: Color(0x0F1E3C78), blurRadius: 8, offset: Offset(0, 2))],
        ),
        child: Row(children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(color: iconBg, borderRadius: BorderRadius.circular(12)),
            child: Icon(icon, size: 20, color: iconColor ?? LightLook.text),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: const TextStyle(fontWeight: FontWeight.w700, color: LightLook.text, fontSize: 14.5)),
              if (sub != null) ...[
                const SizedBox(height: 2),
                Text(sub!, style: const TextStyle(fontSize: 12.5, color: LightLook.muted)),
              ],
            ]),
          ),
          if (trailing != null) ...[const SizedBox(width: 10), trailing!],
        ]),
      );
}

/// A small coloured label ("OK", "18 days").
class LightChip extends StatelessWidget {
  const LightChip(this.text, {super.key, required this.bg, required this.fg});

  const LightChip.ok(this.text, {super.key})
      : bg = const Color(0xFFE3F7EC),
        fg = const Color(0xFF1D9A52);

  const LightChip.warn(this.text, {super.key})
      : bg = const Color(0xFFFFF1DC),
        fg = const Color(0xFFD8840B);

  const LightChip.bad(this.text, {super.key})
      : bg = const Color(0xFFFFE3E3),
        fg = const Color(0xFFD64545);

  const LightChip.grey(this.text, {super.key})
      : bg = const Color(0xFFECEFF3),
        fg = const Color(0xFF6B7A90);

  final String text;
  final Color bg, fg;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(999)),
        child: Text(text, style: TextStyle(color: fg, fontWeight: FontWeight.w700, fontSize: 12.5)),
      );
}

/// Soft curved bands of light (drawn, so sharp at any size).
class LightBands extends CustomPainter {
  const LightBands();

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    void band(double x0, double y0, double cx, double cy, double x1, double y1, double width, double alpha) {
      canvas.drawPath(
        Path()
          ..moveTo(w * x0, h * y0)
          ..quadraticBezierTo(w * cx, h * cy, w * x1, h * y1),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = width
          ..color = Colors.white.withValues(alpha: alpha),
      );
    }

    band(0.2, -0.2, 0.65, 0.1, 1.05, 0.95, 40, 0.14);
    band(0.45, -0.25, 0.8, 0.0, 1.05, 0.5, 8, 0.26);
    band(0.57, -0.2, 0.86, -0.02, 1.05, 0.25, 3, 0.4);
  }

  @override
  bool shouldRepaint(LightBands old) => false;
}
