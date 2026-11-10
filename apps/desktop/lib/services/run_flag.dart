// apps/desktop/lib/services/run_flag.dart
import 'dart:io';

import 'package:localroll_core/localroll_core.dart';
import 'package:path_provider/path_provider.dart';

/// A mark that Keepnear is running, removed when it quits normally. Found
/// at the next start: the last run ended without quitting (a crash, the
/// power, or an update closing it) — said in the log, so the lines before
/// it show what was going on.
class RunFlag {
  RunFlag._();

  static File? _file;

  static Future<void> start() async {
    try {
      final dir = await getApplicationSupportDirectory();
      final f = File('${dir.path}${Platform.pathSeparator}running.flag');
      _file = f;
      if (await f.exists()) {
        final since = (await f.readAsString()).trim();
        DiagLog.log('start', 'the last run (started $since) did not quit normally: a crash, power off, or an update closing it');
      }
      await f.writeAsString(DateTime.now().toIso8601String());
    } catch (_) {}
  }

  /// Quitting normally.
  static void clear() {
    try {
      _file?.deleteSync();
    } catch (_) {}
  }
}
