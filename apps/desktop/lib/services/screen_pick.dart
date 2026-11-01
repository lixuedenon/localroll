// apps/desktop/lib/services/screen_pick.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show Rect;

import 'package:localroll_core/localroll_core.dart';

/// "Point at what to record" (lr_pick.exe next to LocalRoll's exe): the
/// part under the mouse is outlined, a click takes it, the wheel goes to
/// the part around it and back. [back]: Esc (drag a box instead).
class ScreenPick {
  static String get exe => '${File(Platform.resolvedExecutable).parent.path}${Platform.pathSeparator}lr_pick.exe';

  static bool get available => Platform.isWindows && File(exe).existsSync();

  /// The part clicked (screen pixels); null rect: given up, or Esc ([back]).
  static Future<({Rect? rect, bool back})> run(String tip) async {
    if (!available) return (rect: null, back: true);
    try {
      final p = await Process.start(exe, [tip]);
      final done = Completer<({Rect? rect, bool back})>();
      p.stdout.transform(const Utf8Decoder(allowMalformed: true)).transform(const LineSplitter()).listen((l) {
        if (done.isCompleted) return;
        if (l.startsWith('rect ')) {
          final v = l.substring(5).split(' ').map((e) => double.tryParse(e) ?? 0).toList();
          if (v.length == 4) done.complete((rect: Rect.fromLTWH(v[0], v[1], v[2], v[3]), back: false));
        } else if (l == 'back') {
          done.complete((rect: null, back: true));
        } else if (l == 'cancel') {
          done.complete((rect: null, back: false));
        } else if (l.startsWith('error')) {
          DiagLog.log('screen', 'pointing: $l');
          done.complete((rect: null, back: true));
        }
      });
      p.stderr.drain<void>().ignore();
      unawaited(p.exitCode.then((_) {
        if (!done.isCompleted) done.complete((rect: null, back: true));
      }));
      // Not forever: after 3 minutes, the box instead.
      final r = await done.future.timeout(const Duration(minutes: 3), onTimeout: () => (rect: null, back: true));
      try {
        p.stdin.writeln('quit');
        await p.stdin.close();
      } catch (_) {}
      unawaited(p.exitCode.timeout(const Duration(seconds: 3), onTimeout: () {
        p.kill();
        return -1;
      }));
      return r;
    } catch (e) {
      DiagLog.log('screen', 'pointing not started: $e');
      return (rect: null, back: true);
    }
  }
}
