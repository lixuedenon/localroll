// apps/desktop/lib/services/open_with.dart
import 'dart:ffi';
import 'dart:io';

import 'package:localroll_core/localroll_core.dart';

import '../l10n/l10n.dart';
import '../ui/player/player_entry.dart';

/// Puts LocalRoll in Explorer's "Open with" list for photos and videos —
/// for this Windows user only, no admin rights. It never makes itself the
/// default program: what opens on a double-click stays as it was.
class OpenWith {
  OpenWith._();

  static const String progId = 'LocalRoll.Media';

  /// Bumped when what is written changes.
  static const String _version = '2';

  static String get _exe => Platform.resolvedExecutable;
  static String get _exeName => _exe.split(Platform.pathSeparator).last;

  static Future<void> register() async {
    if (!Platform.isWindows) return;
    try {
      // Already there for this copy of LocalRoll?
      final verb = tr('player.open_verb');
      final q = await Process.run('reg', ['query', r'HKCU\Software\Classes\' '$progId', '/v', 'LocalRollSetup']);
      if (q.exitCode == 0 && '${q.stdout}'.contains('$_version|$_exe|${shortKey(verb)}')) return;
      final file = File('${Directory.systemTemp.path}${Platform.pathSeparator}localroll-openwith.reg');
      // .reg files are UTF-16 LE with a byte-order mark.
      final text = regFile(exe: _exe, exeName: _exeName, verb: verb, extensions: [...playerImageExtensions, ...playerVideoExtensions]);
      final units = text.codeUnits;
      final bytes = <int>[0xFF, 0xFE];
      for (final u in units) {
        bytes
          ..add(u & 0xFF)
          ..add(u >> 8);
      }
      await file.writeAsBytes(bytes, flush: true);
      final r = await Process.run('reg', ['import', file.path]);
      DiagLog.log('player', r.exitCode == 0 ? 'open-with registered' : 'open-with not registered: ${r.stderr}');
      // Explorer reads it again now (not only after signing in again).
      _refreshExplorer();
      try {
        await file.delete();
      } catch (_) {}
    } catch (e) {
      DiagLog.log('player', 'open-with not registered: $e');
    }
  }

  static void _refreshExplorer() {
    try {
      final shell = DynamicLibrary.open('shell32.dll');
      final notify = shell.lookupFunction<Void Function(Int32, Uint32, Pointer<Void>, Pointer<Void>), void Function(int, int, Pointer<Void>, Pointer<Void>)>(
          'SHChangeNotify');
      // SHCNE_ASSOCCHANGED, SHCNF_IDLIST
      notify(0x08000000, 0, nullptr, nullptr);
    } catch (_) {}
  }

  static String _q(String v) => '"${v.replaceAll(r'\', r'\\').replaceAll('"', r'\"')}"';

  /// The registry entries, as a .reg file.
  static String regFile({required String exe, required String exeName, required String verb, required Iterable<String> extensions}) {
    const root = r'HKEY_CURRENT_USER\Software\Classes';
    final command = _q('"$exe" "%1"');
    final b = StringBuffer('Windows Registry Editor Version 5.00\r\n\r\n')
      ..write('[$root\\$progId]\r\n@=${_q('LocalRoll')}\r\n"FriendlyTypeName"=${_q('LocalRoll')}\r\n')
      ..write('"LocalRollSetup"=${_q('$_version|$exe|${shortKey(verb)}')}\r\n\r\n')
      ..write('[$root\\$progId\\DefaultIcon]\r\n@=${_q('"$exe",0')}\r\n\r\n')
      ..write('[$root\\$progId\\shell\\open]\r\n"FriendlyAppName"=${_q('LocalRoll')}\r\n\r\n')
      ..write('[$root\\$progId\\shell\\open\\command]\r\n@=$command\r\n\r\n')
      ..write('[$root\\Applications\\$exeName]\r\n"FriendlyAppName"=${_q('LocalRoll')}\r\n\r\n')
      ..write('[$root\\Applications\\$exeName\\shell\\open\\command]\r\n@=$command\r\n\r\n')
      ..write('[$root\\Applications\\$exeName\\SupportedTypes]\r\n');
    final exts = extensions.toSet().toList()..sort();
    for (final e in exts) {
      b.write('".$e"=""\r\n');
    }
    b.write('\r\n');
    for (final e in exts) {
      // Listed under "Open with" — the default stays untouched.
      b.write('[$root\\.$e\\OpenWithProgids]\r\n"$progId"=hex(0):\r\n\r\n');
      // "Play with LocalRoll" in the right-click menu (Windows 11: under
      // "Show more options").
      b
        ..write('[$root\\SystemFileAssociations\\.$e\\shell\\LocalRoll.Play]\r\n')
        ..write('"MUIVerb"=${_q(verb)}\r\n"Icon"=${_q('"$exe",0')}\r\n\r\n')
        ..write('[$root\\SystemFileAssociations\\.$e\\shell\\LocalRoll.Play\\command]\r\n@=$command\r\n\r\n');
    }
    // A registered program: Windows lists it in "Open with" from the start.
    b
      ..write('[HKEY_CURRENT_USER\\Software\\LocalRoll\\Capabilities]\r\n')
      ..write('"ApplicationName"=${_q('LocalRoll')}\r\n"ApplicationDescription"=${_q('LocalRoll')}\r\n\r\n')
      ..write('[HKEY_CURRENT_USER\\Software\\LocalRoll\\Capabilities\\FileAssociations]\r\n');
    for (final e in exts) {
      b.write('".$e"=${_q(progId)}\r\n');
    }
    b
      ..write('\r\n[HKEY_CURRENT_USER\\Software\\RegisteredApplications]\r\n')
      ..write('"LocalRoll"=${_q(r'Software\LocalRoll\Capabilities')}\r\n\r\n');
    return b.toString();
  }
}
