// apps/desktop/lib/services/watchdog.dart
import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:localroll_core/localroll_core.dart';

/// Notices when LocalRoll stops responding ("Not responding" in Windows)
/// and writes it down at once — with the last things that happened — even
/// if the app then has to be closed by force.
///
/// It runs on a thread of its own: the app sends it a sign of life twice a
/// second plus every log line. No sign of life for 5 s → it appends
/// "STUCK" and the recent lines to the log file itself (the app can't: it
/// is the one that is stuck). Nothing is sent anywhere.
class Watchdog {
  Watchdog._();

  static SendPort? _to;

  static Future<void> start() async {
    final path = DiagLog.currentPath;
    if (path == null || _to != null) return;
    try {
      final ready = ReceivePort();
      await Isolate.spawn(_run, [ready.sendPort, path], debugName: 'watchdog');
      final to = await ready.first as SendPort;
      _to = to;
      DiagLog.onLine = to.send;
      Timer.periodic(const Duration(milliseconds: 500), (_) => to.send(0));
    } catch (e) {
      DiagLog.error('watchdog', e);
    }
  }
}

void _run(List<Object> args) {
  final reply = args[0] as SendPort;
  final path = args[1] as String;
  final port = ReceivePort();
  reply.send(port.sendPort);

  final recent = <String>[];
  var alive = DateTime.now();
  DateTime? stuckSince;
  var lastNote = DateTime.now();

  void write(String text) {
    try {
      File(path).writeAsStringSync('$text\n', mode: FileMode.append, flush: true);
    } catch (_) {}
  }

  String stamp(DateTime t) => t.toIso8601String();

  port.listen((m) {
    if (m is String) {
      recent.add(m);
      if (recent.length > 40) recent.removeAt(0);
    }
    final now = DateTime.now();
    final since = stuckSince;
    if (since != null) {
      write('${stamp(now)} [watchdog] responding again after ${now.difference(since).inSeconds} s');
      stuckSince = null;
    }
    alive = now;
  });

  var lastTick = DateTime.now();
  Timer.periodic(const Duration(seconds: 1), (_) {
    final now = DateTime.now();
    // The watchdog itself was paused too: the PC slept, nothing hung.
    final slept = now.difference(lastTick) > const Duration(seconds: 30);
    lastTick = now;
    if (slept) {
      if (stuckSince == null) alive = now;
      write('${stamp(now)} [watchdog] PC was asleep or paused, not counted');
      return;
    }
    final gap = now.difference(alive);
    if (stuckSince == null && gap > const Duration(seconds: 5)) {
      stuckSince = alive;
      lastNote = now;
      write('${stamp(now)} [watchdog] NOT RESPONDING since ${stamp(alive)}. Last events before it:');
      for (final l in recent) {
        write('    $l');
      }
    } else if (stuckSince != null && now.difference(lastNote) > const Duration(minutes: 1)) {
      lastNote = now;
      write('${stamp(now)} [watchdog] still not responding (${now.difference(stuckSince!).inSeconds} s)');
    }
  });
}
