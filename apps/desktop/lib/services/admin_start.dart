// apps/desktop/lib/services/admin_start.dart
import 'dart:convert';
import 'dart:io';

import 'package:localroll_core/localroll_core.dart' show DiagLog;

import 'autostart.dart';

/// "Always open as administrator", without Windows asking each time: a
/// scheduled task with the highest rights starts Keepnear, and the desktop
/// shortcut (and starting with Windows) runs that task. Windows asks once,
/// when this is switched on or off.
class AdminStart {
  AdminStart._();

  static const task = 'Keepnear';
  static const startupTask = 'Keepnear (startup)';

  static String get _exe => Platform.resolvedExecutable;
  static String get _dir => File(_exe).parent.path;
  static String get shortcut => '${Platform.environment['USERPROFILE'] ?? ''}\\Desktop\\LocalRoll.lnk';

  static Future<bool> isOn() async {
    if (!Platform.isWindows) return false;
    try {
      return (await Process.run('schtasks', ['/query', '/tn', task])).exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  /// Switches it; true when it is now as asked.
  static Future<bool> set(bool on) async {
    if (!Platform.isWindows) return false;
    String q(String v) => v.replaceAll("'", "''");
    final user = '${Platform.environment['USERDOMAIN'] ?? ''}\\${Platform.environment['USERNAME'] ?? ''}';
    final cmd = on
        ? [
            r"$ErrorActionPreference = 'Stop'",
            "\$p = New-ScheduledTaskPrincipal -UserId '${q(user)}' -LogonType Interactive -RunLevel Highest",
            r'$s = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew',
            "Register-ScheduledTask -TaskName '$task' -Action (New-ScheduledTaskAction -Execute '${q(_exe)}' -WorkingDirectory '${q(_dir)}') -Principal \$p -Settings \$s -Force",
            "Register-ScheduledTask -TaskName '$startupTask' -Action (New-ScheduledTaskAction -Execute '${q(_exe)}' -Argument '${AutoStart.minimizedFlag}' -WorkingDirectory '${q(_dir)}') -Principal \$p -Settings \$s -Force",
          ].join('; ')
        : "Unregister-ScheduledTask -TaskName '$task' -Confirm:\$false -ErrorAction SilentlyContinue; "
            "Unregister-ScheduledTask -TaskName '$startupTask' -Confirm:\$false -ErrorAction SilentlyContinue";
    final units = <int>[];
    for (final u in cmd.codeUnits) {
      units
        ..add(u & 0xFF)
        ..add(u >> 8);
    }
    try {
      // Windows asks once ("allow changes?"); already administrator: it doesn't.
      await Process.run('powershell', [
        '-NoProfile',
        '-Command',
        "Start-Process -FilePath powershell -ArgumentList '-NoProfile -EncodedCommand ${base64.encode(units)}' -Verb RunAs -Wait -WindowStyle Hidden",
      ]);
    } catch (e) {
      DiagLog.log('admin', 'task ${on ? 'add' : 'remove'}: $e');
    }
    final now = await isOn();
    DiagLog.log('admin', 'always as administrator: ${now ? 'on' : 'off'} (asked ${on ? 'on' : 'off'})');
    if (now != on) return false;
    await _shortcut(on);
    // Starting with Windows goes the same way.
    if (await AutoStart.isEnabled()) await AutoStart.setEnabled(true);
    return true;
  }

  /// The desktop shortcut: runs the task (on), or Keepnear itself (off).
  static Future<void> _shortcut(bool on) async {
    String q(String v) => v.replaceAll("'", "''");
    final schtasks = '${Platform.environment['SystemRoot'] ?? r'C:\Windows'}\\System32\\schtasks.exe';
    final cmd = [
      "\$s = (New-Object -ComObject WScript.Shell).CreateShortcut('${q(shortcut)}')",
      if (on) ...[
        "\$s.TargetPath = '${q(schtasks)}'",
        "\$s.Arguments = '/run /tn \"$task\"'",
        r'$s.WindowStyle = 7',
      ] else ...[
        "\$s.TargetPath = '${q(_exe)}'",
        r"$s.Arguments = ''",
        r'$s.WindowStyle = 1',
      ],
      "\$s.WorkingDirectory = '${q(_dir)}'",
      "\$s.IconLocation = '${q(_exe)},0'",
      r'$s.Save()',
    ].join('; ');
    try {
      await Process.run('powershell', ['-NoProfile', '-NonInteractive', '-Command', cmd]);
    } catch (e) {
      DiagLog.log('admin', 'shortcut: $e');
    }
  }
}
