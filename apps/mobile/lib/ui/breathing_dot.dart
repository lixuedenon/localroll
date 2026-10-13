// apps/mobile/lib/ui/breathing_dot.dart
import 'package:flutter/material.dart';

import 'theme.dart';

/// Online marker: a green dot that slowly "breathes" (glows and fades,
/// about every 2.6 s). Offline: a still grey dot. Still when the system
/// asks for less motion.
class BreathingDot extends StatefulWidget {
  const BreathingDot({super.key, required this.online, this.size = 12});

  /// Brighter than the theme's cyan, so it catches the eye.
  static const Color glow = Color(0xFF39F5A0);

  final bool online;
  final double size;

  @override
  State<BreathingDot> createState() => _BreathingDotState();
}

class _BreathingDotState extends State<BreathingDot> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1300));

  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(BreathingDot old) {
    super.didUpdateWidget(old);
    _sync();
  }

  void _sync() {
    if (widget.online && !_c.isAnimating) {
      _c.repeat(reverse: true);
    } else if (!widget.online && _c.isAnimating) {
      _c.stop();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.size;
    final still = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    if (!widget.online || still) {
      return SizedBox.square(
        dimension: s * 2.2,
        child: Center(
          child: Container(
            width: s,
            height: s,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: widget.online ? BreathingDot.glow : LrColors.muted.withValues(alpha: 0.6),
            ),
          ),
        ),
      );
    }
    return SizedBox.square(
      dimension: s * 2.2,
      child: AnimatedBuilder(
        animation: _c,
        builder: (context, _) {
          final t = Curves.easeInOut.transform(_c.value);
          return Center(
            child: Container(
              width: s,
              height: s,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Color.lerp(BreathingDot.glow.withValues(alpha: 0.65), const Color(0xFFB8FFDC), t),
                boxShadow: [
                  BoxShadow(
                    color: BreathingDot.glow.withValues(alpha: 0.75 * t),
                    blurRadius: s * 1.1 * t,
                    spreadRadius: s * 0.45 * t,
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}
