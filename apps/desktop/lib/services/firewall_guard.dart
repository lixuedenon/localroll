// apps/desktop/lib/services/firewall_guard.dart
import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:localroll_core/localroll_core.dart' show DiagLog;

/// Keeps other devices able to send to this PC: Windows' firewall must let
/// Keepnear in. Looked at (no administrator needed) when Keepnear starts,
/// the moment Windows' firewall rules change (it is told by Windows), and
/// every few minutes besides. When Keepnear is not let in, [blocked] turns
/// true: the app asks the user once to allow it; that one click (and
/// Windows' "allow changes?") fixes it for good.
class FirewallGuard extends ChangeNotifier {
  FirewallGuard._();

  static final FirewallGuard instance = FirewallGuard._();

  /// Others can't send here (shown, with "Allow", until fixed).
  bool blocked = false;

  /// The user said "later" this time: not asked again until it changes.
  bool _putOff = false;

  /// Asks the user (set by the app's UI).
  Future<void> Function()? ask;

  Timer? _every;
  Timer? _soon;
  bool _looking = false;

  String get _exe => Platform.resolvedExecutable;

  void start() {
    if (!Platform.isWindows) return;
    unawaited(check());
    // Told by Windows when its firewall rules change; else (or anyway)
    // a look every few minutes.
    final watching = _watchRegistry();
    _every = Timer.periodic(Duration(minutes: watching ? 10 : 1), (_) => unawaited(check()));
  }

  void stop() {
    _every?.cancel();
    _soon?.cancel();
  }

  /// Looks whether Keepnear is let in; asks the user when it is not.
  Future<void> check() async {
    if (_looking) return;
    _looking = true;
    try {
      final ok = await _letIn();
      if (ok == null) return; // could not tell: leave it
      final was = blocked;
      blocked = !ok;
      if (blocked != was) {
        DiagLog.log('firewall', blocked ? 'Keepnear is not let in: other devices can\'t send here' : 'let in');
        if (!blocked) _putOff = false;
        notifyListeners();
      }
      if (blocked && !_putOff) {
        _putOff = true; // asked once per time it happens
        await ask?.call();
      }
    } finally {
      _looking = false;
    }
  }

  /// "Later": still shown on the home page, not asked again for now.
  void later() => _putOff = true;

  /// Null: could not tell.
  Future<bool?> _letIn() async {
    final exe = _exe.replaceAll("'", "''");
    // Windows' firewall off: nothing to let in. Else an enabled inbound rule
    // for this program must allow (for the network type in use) and none
    // may block — a block wins over an allow.
    final script = "\$ErrorActionPreference='SilentlyContinue';"
        "\$on=@(Get-NetFirewallProfile | Where-Object {\$_.Enabled -eq 'True'}).Count;"
        "if(\$on -eq 0){'ok';exit};"
        "\$cats=@(Get-NetConnectionProfile | ForEach-Object {[string]\$_.NetworkCategory});"
        "\$r=@(Get-NetFirewallApplicationFilter -Program '$exe' | Get-NetFirewallRule | Where-Object {\$_.Enabled -eq 'True' -and [string]\$_.Direction -eq 'Inbound'});"
        "if(@(\$r | Where-Object {[string]\$_.Action -eq 'Block'}).Count -gt 0){'blocked';exit};"
        "\$a=@(\$r | Where-Object {[string]\$_.Action -eq 'Allow'});"
        "foreach(\$c in \$cats){\$need=if(\$c -like 'Domain*'){'Domain'}else{\$c};"
        "if(@(\$a | Where-Object {([string]\$_.Profile) -eq 'Any' -or ([string]\$_.Profile) -like \"*\$need*\"}).Count -eq 0){'missing';exit}};"
        "if(\$a.Count -eq 0){'missing'}else{'ok'}";
    try {
      final r = await Process.run('powershell', ['-NoProfile', '-NonInteractive', '-EncodedCommand', _encode(script)])
          .timeout(const Duration(seconds: 30));
      final out = '${r.stdout}'.trim();
      if (out.endsWith('ok')) return true;
      if (out.endsWith('blocked') || out.endsWith('missing')) return false;
      return null;
    } catch (_) {
      return null;
    }
  }

  /// Takes away rules that block Keepnear and lets it in on every network
  /// type (one "allow changes?" from Windows). True when let in after.
  Future<bool> fix() async {
    final exe = _exe.replaceAll("'", "''");
    final inner = "Get-NetFirewallApplicationFilter -Program '$exe' | Get-NetFirewallRule | Where-Object {[string]\$_.Action -eq 'Block'} | Remove-NetFirewallRule;"
        "Get-NetFirewallRule -DisplayName 'Keepnear' -ErrorAction SilentlyContinue | Remove-NetFirewallRule;"
        "New-NetFirewallRule -DisplayName 'Keepnear' -Direction Inbound -Action Allow -Program '$exe' -Profile Any | Out-Null";
    final outer = "Start-Process powershell -Verb RunAs -Wait -WindowStyle Hidden -ArgumentList '-NoProfile','-EncodedCommand','${_encode(inner)}'";
    try {
      await Process.run('powershell', ['-NoProfile', '-NonInteractive', '-EncodedCommand', _encode(outer)]).timeout(const Duration(minutes: 2));
    } catch (e) {
      DiagLog.log('firewall', 'fix: $e');
    }
    final ok = await _letIn() ?? false;
    DiagLog.log('firewall', ok ? 'fixed: other devices can send here' : 'not fixed (declined?)');
    if (ok != !blocked) {
      blocked = !ok;
      notifyListeners();
    }
    return ok;
  }

  static String _encode(String script) {
    final units = <int>[];
    for (final u in script.codeUnits) {
      units
        ..add(u & 0xFF)
        ..add(u >> 8);
    }
    return base64.encode(units);
  }

  /// Windows tells a waiting thread when the firewall's rules change in the
  /// registry. False when this user may not watch there.
  bool _watchRegistry() {
    if (!_canOpen()) return false;
    final port = ReceivePort();
    port.listen((_) {
      // Several changes come at once: look a moment after the last.
      _soon?.cancel();
      _soon = Timer(const Duration(seconds: 2), () => unawaited(check()));
    });
    unawaited(Isolate.spawn(_watch, port.sendPort, errorsAreFatal: false).then((_) {}, onError: (Object e) {
      DiagLog.log('firewall', 'watch not started: $e');
    }));
    return true;
  }

  static const _key = r'SYSTEM\CurrentControlSet\Services\SharedAccess\Parameters\FirewallPolicy\FirewallRules';

  static bool _canOpen() {
    try {
      final h = calloc<IntPtr>();
      final name = _key.toNativeUtf16();
      final r = _RegApi.open(_hklm, name, 0, _keyNotify | _keyRead, h);
      if (r == 0) _RegApi.close(h.value);
      calloc.free(name);
      calloc.free(h);
      return r == 0;
    } catch (_) {
      return false;
    }
  }

  /// In its own isolate: waits on Windows' notice, says each change.
  static void _watch(SendPort out) {
    final h = calloc<IntPtr>();
    final name = _key.toNativeUtf16();
    if (_RegApi.open(_hklm, name, 0, _keyNotify | _keyRead, h) != 0) return;
    while (true) {
      // Blocks until a value is set or a rule (value) added / removed.
      final r = _RegApi.notify(h.value, 0, _notifyName | _notifyLastSet, 0, 0);
      if (r != 0) break;
      out.send(true);
    }
    _RegApi.close(h.value);
  }

  // HKEY_LOCAL_MACHINE: 0x80000002, sign-extended on 64-bit.
  static const int _hklm = -0x7FFFFFFE;
  static const int _keyNotify = 0x0010;
  static const int _keyRead = 0x20019;
  static const int _notifyName = 0x1;
  static const int _notifyLastSet = 0x4;
}

class _RegApi {
  static final _lib = DynamicLibrary.open('advapi32.dll');

  static final open = _lib.lookupFunction<Int32 Function(IntPtr, Pointer<Utf16>, Uint32, Uint32, Pointer<IntPtr>),
      int Function(int, Pointer<Utf16>, int, int, Pointer<IntPtr>)>('RegOpenKeyExW');

  static final notify = _lib.lookupFunction<Int32 Function(IntPtr, Int32, Uint32, IntPtr, Int32), int Function(int, int, int, int, int)>(
      'RegNotifyChangeKeyValue');

  static final close = _lib.lookupFunction<Int32 Function(IntPtr), int Function(int)>('RegCloseKey');
}
