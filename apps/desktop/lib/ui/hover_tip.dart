// apps/desktop/lib/ui/hover_tip.dart
import 'package:flutter/material.dart';

import 'theme.dart';

/// How long the mouse rests before an explanation shows.
const Duration hoverWait = Duration(milliseconds: 250);

/// An explanation that shows when the mouse rests on [child]: a few lines,
/// at most about 340 pixels wide (long ones wrap instead of crossing the
/// screen).
class HoverTip extends StatelessWidget {
  const HoverTip({super.key, required this.text, required this.child});

  final String text;
  final Widget child;

  @override
  Widget build(BuildContext context) => Tooltip(
        waitDuration: hoverWait,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        decoration: BoxDecoration(
          color: LrColors.raised,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: LrColors.line),
        ),
        richMessage: WidgetSpan(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 340),
            child: Text(text, style: const TextStyle(color: LrColors.text, fontSize: 12.5, height: 1.5)),
          ),
        ),
        child: child,
      );
}

/// A title that has an explanation: its own colour and a dashed underline,
/// so it can be told apart from ordinary titles.
class TipTitle extends StatelessWidget {
  const TipTitle({super.key, required this.text, required this.tip, this.style});

  final String text;
  final String tip;
  final TextStyle? style;

  static const Color color = Color(0xFF6FB3F0);

  @override
  Widget build(BuildContext context) => HoverTip(
        text: tip,
        child: MouseRegion(
          cursor: SystemMouseCursors.help,
          child: Text(
            text,
            style: (style ?? Theme.of(context).appBarTheme.titleTextStyle ?? const TextStyle(fontSize: 20)).copyWith(
              color: color,
              decoration: TextDecoration.underline,
              decorationStyle: TextDecorationStyle.dashed,
              decorationColor: color.withValues(alpha: 0.7),
            ),
          ),
        ),
      );
}

/// A tool button: a coloured icon, maybe a short word next to it (what is
/// picked now), and an explanation on hover.
class ToolIcon extends StatelessWidget {
  const ToolIcon({super.key, required this.icon, required this.color, this.label});

  final IconData icon;
  final Color color;
  final String? label;

  @override
  Widget build(BuildContext context) => Container(
        height: 36,
        padding: EdgeInsets.symmetric(horizontal: label == null ? 8 : 10),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: label == null ? Colors.transparent : color.withValues(alpha: 0.55)),
          color: label == null ? null : color.withValues(alpha: 0.12),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 20, color: color),
          if (label != null) ...[
            const SizedBox(width: 6),
            Text(label!, style: TextStyle(fontSize: 13, color: color)),
          ],
        ]),
      );
}

/// Colours of the tool buttons, by what they do.
class ToolColors {
  ToolColors._();

  static const senders = Color(0xFF3FC79C);
  static const sort = Color(0xFF9B93F0);
  static const people = Color(0xFFE5759C);
  static const select = Color(0xFFEFA93A);
  static const size = Color(0xFF5AA3EA);
  static const trash = Color(0xFFEA7A52);
  static const plain = LrColors.muted;
}
