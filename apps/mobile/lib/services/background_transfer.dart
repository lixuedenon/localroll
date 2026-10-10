// apps/mobile/lib/services/background_transfer.dart
import 'package:flutter/services.dart';

/// How the current transfer is protected when the app leaves the foreground.
enum BackgroundMode {
  /// Android foreground service: keeps going with the screen off.
  service,

  /// iOS 26+ continued-processing task: keeps going, iOS shows the progress.
  continued,

  /// Older iOS: only ~30 s of grace; keep the app open.
  short,

  /// No native support (tests, other platforms).
  none,
}

/// Thin wrapper around the native side (MainActivity.kt / AppDelegate.swift,
/// channel `localroll/background`). The upload loop itself stays in Dart.
class BackgroundTransfer {
  BackgroundTransfer._();

  static const MethodChannel _channel = MethodChannel('localroll/background');
  static bool _listening = false;
  static DateTime _lastUpdate = DateTime.fromMillisecondsSinceEpoch(0);

  /// Called when iOS takes the background time back (the user can resume later).
  static void Function()? onExpired;

  static void _listen() {
    if (_listening) return;
    _listening = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'expired') onExpired?.call();
    });
  }

  /// [channel] is the Android notification-category name shown in system
  /// settings (translated, like everything the user sees).
  static Future<BackgroundMode> start({required String channel, required String title, required String text}) async {
    _listen();
    try {
      final mode = await _channel.invokeMethod<String>('start', {'channel': channel, 'title': title, 'text': text});
      return switch (mode) {
        'service' => BackgroundMode.service,
        'continued' => BackgroundMode.continued,
        'short' => BackgroundMode.short,
        _ => BackgroundMode.none,
      };
    } catch (_) {
      return BackgroundMode.none;
    }
  }

  /// [progress] 0..1 for the whole batch, or negative when unknown.
  /// Throttled to about once a second unless [force] is set.
  static Future<void> update({
    required String title,
    required String text,
    double progress = -1,
    bool force = false,
  }) async {
    final now = DateTime.now();
    if (!force && now.difference(_lastUpdate) < const Duration(seconds: 1)) return;
    _lastUpdate = now;
    try {
      await _channel.invokeMethod<void>('update', {'title': title, 'text': text, 'progress': progress});
    } catch (_) {}
  }

  static Future<void> stop({bool success = true}) async {
    try {
      await _channel.invokeMethod<void>('stop', {'success': success});
    } catch (_) {}
  }
}
