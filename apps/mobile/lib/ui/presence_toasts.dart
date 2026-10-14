// apps/mobile/lib/ui/presence_toasts.dart
import 'dart:async';

import 'package:flutter/material.dart';

import 'theme.dart';

/// "X is online / went offline" notes. One per device: a newer note about
/// the same device replaces the old one at once (no queue), notes about
/// different devices show together, each fades after a few seconds.
class PresenceToasts {
  PresenceToasts._();

  static OverlayEntry? _entry;
  static final ValueNotifier<List<_Toast>> _toasts = ValueNotifier(const []);

  static void show(
    OverlayState overlay, {
    required String key,
    required String text,
    required IconData icon,
    required bool online,
  }) {
    final old = _toasts.value.where((t) => t.key == key).toList();
    for (final t in old) {
      t.timer.cancel();
    }
    late final _Toast t;
    t = _Toast(key, text, icon, online, Timer(const Duration(seconds: 4), () => _remove(t)));
    _toasts.value = [..._toasts.value.where((x) => x.key != key), t];
    if (_entry == null) {
      _entry = OverlayEntry(builder: (_) => const _ToastHost());
      overlay.insert(_entry!);
    }
  }

  static void _remove(_Toast t) {
    _toasts.value = _toasts.value.where((x) => x != t).toList();
    if (_toasts.value.isEmpty) {
      _entry?.remove();
      _entry = null;
    }
  }
}

class _Toast {
  _Toast(this.key, this.text, this.icon, this.online, this.timer);

  final String key;
  final String text;
  final IconData icon;
  final bool online;
  final Timer timer;
}

class _ToastHost extends StatelessWidget {
  const _ToastHost();

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Align(
        alignment: Alignment.topCenter,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: ValueListenableBuilder<List<_Toast>>(
              valueListenable: PresenceToasts._toasts,
              builder: (context, list, _) => Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final t in list)
                    Padding(
                      key: ValueKey(t),
                      padding: const EdgeInsets.only(bottom: 8),
                      child: TweenAnimationBuilder<double>(
                        tween: Tween(begin: 0, end: 1),
                        duration: const Duration(milliseconds: 220),
                        builder: (context, v, child) => Opacity(opacity: v, child: child),
                        child: Material(
                          color: LrColors.raised,
                          elevation: 6,
                          borderRadius: BorderRadius.circular(12),
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(
                                color: t.online ? const Color(0xFF39F5A0) : LrColors.line,
                                width: t.online ? 1.5 : 1,
                              ),
                            ),
                            child: Row(children: [
                              Icon(t.icon, size: 20, color: t.online ? const Color(0xFF39F5A0) : LrColors.muted),
                              const SizedBox(width: 10),
                              Expanded(child: Text(t.text, style: const TextStyle(fontSize: 14))),
                            ]),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
