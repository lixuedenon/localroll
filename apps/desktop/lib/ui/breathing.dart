// apps/desktop/lib/ui/breathing.dart
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'theme.dart';

/// Brighter than the theme's cyan, so "online" catches the eye.
const Color onlineGlow = Color(0xFF39F5A0);

/// One shared, slow "breath" for everything online, so all of them glow
/// together. 15 frames a second (plenty for a 2.6 s breath), only while
/// something online is on screen and the app is visible.
class BreathClock extends ChangeNotifier with WidgetsBindingObserver {
  BreathClock._() {
    WidgetsBinding.instance.addObserver(this);
  }

  static final BreathClock instance = BreathClock._();

  static const Duration period = Duration(milliseconds: 2600);

  /// 0 (dim) … 1 (bright).
  double value = 0;
  int _users = 0;
  Timer? _timer;
  bool _visible = true;
  final Stopwatch _clock = Stopwatch()..start();

  void _use() {
    _users++;
    _sync();
  }

  void _unuse() {
    _users = math.max(0, _users - 1);
    _sync();
  }

  void _sync() {
    final run = _users > 0 && _visible;
    if (run && _timer == null) {
      _timer = Timer.periodic(const Duration(milliseconds: 66), (_) {
        final phase = (_clock.elapsedMilliseconds % period.inMilliseconds) / period.inMilliseconds;
        value = 0.5 - 0.5 * math.cos(2 * math.pi * phase);
        notifyListeners();
      });
    } else if (!run && _timer != null) {
      _timer!.cancel();
      _timer = null;
    }
  }

  // Minimised / in the background: no frames at all.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _visible = state == AppLifecycleState.resumed || state == AppLifecycleState.inactive;
    _sync();
  }
}

/// A device's box (card, chip, pill). Online: its own border and background
/// slowly glow and fade. Offline: a plain grey frame, still.
class Breathing extends StatefulWidget {
  const Breathing({
    super.key,
    required this.online,
    required this.child,
    this.radius = 14,
    this.color = LrColors.surface,
  });

  final bool online;
  final Widget child;
  final double radius;

  /// Background when dim / offline.
  final Color color;

  @override
  State<Breathing> createState() => _BreathingState();
}

class _BreathingState extends State<Breathing> {
  bool _using = false;

  void _sync(bool want) {
    if (want == _using) return;
    _using = want;
    want ? BreathClock.instance._use() : BreathClock.instance._unuse();
  }

  @override
  void dispose() {
    _sync(false);
    super.dispose();
  }

  BoxDecoration _deco(double v) {
    final r = BorderRadius.circular(widget.radius);
    if (!widget.online) {
      return BoxDecoration(color: widget.color, borderRadius: r, border: Border.all(color: LrColors.line));
    }
    return BoxDecoration(
      color: Color.lerp(widget.color, onlineGlow, 0.06 + 0.10 * v),
      borderRadius: r,
      border: Border.all(color: Color.lerp(onlineGlow.withValues(alpha: 0.45), onlineGlow, v)!, width: 1.6),
      boxShadow: [
        BoxShadow(color: onlineGlow.withValues(alpha: 0.45 * v), blurRadius: 16 * v, spreadRadius: 1.5 * v),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final still = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    final animate = widget.online && !still;
    _sync(animate);
    if (!animate) {
      return DecoratedBox(decoration: _deco(widget.online ? 0.7 : 0), child: widget.child);
    }
    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: BreathClock.instance,
        child: widget.child,
        builder: (context, child) => DecoratedBox(decoration: _deco(BreathClock.instance.value), child: child),
      ),
    );
  }
}

/// A small device button (name + icon) that breathes when online.
class PresenceChip extends StatelessWidget {
  const PresenceChip({super.key, required this.label, required this.icon, required this.online, this.onTap});

  final String label;
  final IconData icon;
  final bool online;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Breathing(
      online: online,
      radius: 20,
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(icon, size: 16, color: online ? onlineGlow : LrColors.muted),
              const SizedBox(width: 6),
              Text(label, style: TextStyle(fontSize: 13, color: online ? null : LrColors.muted)),
            ]),
          ),
        ),
      ),
    );
  }
}
