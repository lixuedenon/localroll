// apps/desktop/lib/services/boot.dart
import 'package:flutter/foundation.dart';
import 'package:localroll_core/localroll_core.dart';

/// Start-up: how long each step took (written to the diagnostics log, to
/// see what makes starting slow) and the step now (shown while starting).
class Boot {
  Boot._();

  static final Stopwatch clock = Stopwatch()..start();

  /// The step being done now (a key of `boot.<step>` texts).
  static final ValueNotifier<String> step = ValueNotifier('start');

  static final List<String> _early = [];
  static bool _logReady = false;
  static int _last = 0;

  /// [name] is done / starts now.
  static void mark(String name, {String? next}) {
    final now = clock.elapsedMilliseconds;
    final line = '$name: ${now - _last} ms (at $now ms)';
    _last = now;
    if (_logReady) {
      DiagLog.log('startup', line);
    } else {
      _early.add(line);
    }
    if (next != null) step.value = next;
  }

  /// The log can be written now: what came before goes in first.
  static void logReady() {
    _logReady = true;
    for (final l in _early) {
      DiagLog.log('startup', l);
    }
    _early.clear();
  }
}
