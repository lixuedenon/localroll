// apps/desktop/lib/services/elevation.dart
import 'dart:ffi';
import 'dart:io';

/// Keepnear never needs to run as administrator (the few system changes
/// ask Windows for it on their own). Started from an elevated shell it
/// becomes one, and then Windows blocks dragging files in from Explorer.
class Elevation {
  Elevation._();

  static bool? _admin;

  /// Running as administrator (elevated)?
  static bool get isAdmin => _admin ??= _check();

  static bool _check() {
    if (!Platform.isWindows) return false;
    try {
      final f = DynamicLibrary.open('shell32.dll').lookupFunction<Int32 Function(), int Function()>('IsUserAnAdmin');
      return f() != 0;
    } catch (_) {
      return false;
    }
  }

  /// Starts this program again a moment from now as a normal user (through
  /// Explorer, which runs as one). The caller then quits.
  static Future<bool> startAgainAsUser() async {
    final exe = Platform.resolvedExecutable.replaceAll("'", "''");
    try {
      await Process.start(
        'powershell',
        ['-NoProfile', '-WindowStyle', 'Hidden', '-Command', "Start-Sleep -Seconds 2; Start-Process explorer.exe -ArgumentList '\"$exe\"'"],
        mode: ProcessStartMode.detached,
      );
      return true;
    } catch (_) {
      return false;
    }
  }
}
