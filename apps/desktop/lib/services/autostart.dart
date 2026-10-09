// apps/desktop/lib/services/autostart.dart
import 'dart:io';

/// "Start with Windows" via the per-user Run key (no admin rights needed).
/// Started that way, LocalRoll opens minimised and simply waits for phones.
class AutoStart {
  AutoStart._();

  static const String _key = r'HKCU\Software\Microsoft\Windows\CurrentVersion\Run';
  static const String _name = 'LocalRoll';

  /// Command-line flag used for the autostart entry.
  static const String minimizedFlag = '--minimized';

  static Future<bool> isEnabled() async {
    if (!Platform.isWindows) return false;
    try {
      final r = await Process.run('reg', ['query', _key, '/v', _name]);
      return r.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> setEnabled(bool on) async {
    if (!Platform.isWindows) return false;
    try {
      final r = on
          ? await Process.run('reg', [
              'add', _key, '/v', _name, '/t', 'REG_SZ',
              '/d', '"${Platform.resolvedExecutable}" $minimizedFlag', '/f',
            ])
          : await Process.run('reg', ['delete', _key, '/v', _name, '/f']);
      return r.exitCode == 0;
    } catch (_) {
      return false;
    }
  }
}
