// apps/desktop/lib/ui/light_look.dart
import 'package:flutter/material.dart';

// The light look (bright blue, white cards) the pages are moving to:
// Home first, then the library.

/// Colors of the light look.
class LightLook {
  LightLook._();

  static const page = Color(0xFFF3F6FC);
  static const text = Color(0xFF16213E);
  static const muted = Color(0xFF6B7A99);
  static const blue = Color(0xFF2F6BFF);
  static const green = Color(0xFF12A35F);
  static const red = Color(0xFFE5484D);
  static const amber = Color(0xFFF5A524);
  static const amberText = Color(0xFFC46A00);

  static BoxDecoration card({Color? border}) => BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: border ?? const Color(0xFFE6ECF7), width: border == null ? 1 : 1.5),
        boxShadow: const [BoxShadow(color: Color(0x141D3B8A), blurRadius: 18, offset: Offset(0, 6))],
      );

  /// Behind a page: a soft blue-white wash.
  static const BoxDecoration wash = BoxDecoration(
    gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [Color(0xFFEFF4FF), Color(0xFFF7F9FD), Color(0xFFEFF7FB)]),
  );

  static ThemeData theme(ThemeData dark) {
    final scheme = ColorScheme.fromSeed(seedColor: blue, brightness: Brightness.light).copyWith(primary: blue, surface: Colors.white, onSurface: text);
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      fontFamily: dark.textTheme.bodyMedium?.fontFamily,
      fontFamilyFallback: dark.textTheme.bodyMedium?.fontFamilyFallback,
      scaffoldBackgroundColor: page,
      tooltipTheme: dark.tooltipTheme,
    );
  }
}

/// A white card, raised a little; lifts more under the mouse.
class LightCard extends StatefulWidget {
  const LightCard({required this.child, this.onTap, this.border, this.padding = const EdgeInsets.all(16)});

  final Widget child;
  final VoidCallback? onTap;
  final Color? border;
  final EdgeInsets padding;

  @override
  State<LightCard> createState() => _LightCardState();
}

class _LightCardState extends State<LightCard> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) => MouseRegion(
        cursor: widget.onTap == null ? MouseCursor.defer : SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            transform: Matrix4.translationValues(0, _hover && widget.onTap != null ? -2 : 0, 0),
            padding: widget.padding,
            decoration: LightLook.card(border: widget.border).copyWith(
              boxShadow: [BoxShadow(color: const Color(0xFF1D3B8A).withValues(alpha: _hover && widget.onTap != null ? 0.14 : 0.08), blurRadius: 18, offset: const Offset(0, 6))],
            ),
            child: widget.child,
          ),
        ),
      );
}

/// A round icon on a soft gradient.
class LightBadge extends StatelessWidget {
  const LightBadge({required this.icon, required this.colors, this.size = 48});

  final IconData icon;
  final List<Color> colors;
  final double size;

  @override
  Widget build(BuildContext context) => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: colors),
          boxShadow: [BoxShadow(color: colors.last.withValues(alpha: 0.35), blurRadius: 12, offset: const Offset(0, 4))],
        ),
        child: Icon(icon, color: Colors.white, size: size * 0.5),
      );
}

