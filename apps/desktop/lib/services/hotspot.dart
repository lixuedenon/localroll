// apps/desktop/lib/services/hotspot.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:localroll_core/localroll_core.dart' show DiagLog;

/// Windows' own "Mobile hotspot", switched on and off from Keepnear: for a
/// Wi-Fi that keeps its devices apart (school, office, hotel), the phone
/// joins this PC's hotspot instead. The PC stays on its Wi-Fi; the phone
/// reaches the internet through it. Name and password are Windows' own.
class Hotspot extends ChangeNotifier {
  Hotspot._();
  static final Hotspot instance = Hotspot._();

  bool on = false;
  String ssid = '';
  String pass = '';
  int clients = 0;

  /// Why it could not start (Windows' word for it), or null.
  String? why;

  bool busy = false;

  /// Off by itself after this long with nobody joined.
  static const idleOff = Duration(minutes: 10);
  bool autoOff = true;
  DateTime _lastClient = DateTime.now();
  Timer? _poll;

  /// The Wi-Fi network to join, as a QR code says it.
  String get qr => 'WIFI:T:WPA;S:${_esc(ssid)};P:${_esc(pass)};;';
  static String _esc(String v) => v.replaceAllMapped(RegExp(r'([\\;,:"])'), (m) => '\\${m[1]}');

  void setAutoOff(bool v) {
    autoOff = v;
    notifyListeners();
  }

  Future<bool> start() => _run('start');
  Future<bool> stop() => _run('stop');
  Future<bool> refresh() => _run('state');

  Future<bool> _run(String op) async {
    if (!Platform.isWindows) return false;
    busy = op != 'state';
    if (busy) notifyListeners();
    try {
      final f = File('${Directory.systemTemp.path}${Platform.pathSeparator}keepnear_hotspot.ps1');
      await f.writeAsString(_script, encoding: utf8, flush: true);
      final r = await Process.run('powershell', ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', f.path, op],
          stdoutEncoding: utf8, stderrEncoding: utf8);
      final out = '${r.stdout}'.trim().split('\n').lastWhere((l) => l.trim().startsWith('{'), orElse: () => '');
      if (out.isEmpty) {
        why = 'error';
        DiagLog.log('hotspot', '$op: no answer: ${'${r.stderr}'.trim().split('\n').firstOrNull ?? ''}');
        return false;
      }
      final j = jsonDecode(out) as Map<String, dynamic>;
      if (j['ok'] != true) {
        why = '${j['why'] ?? 'error'}';
        DiagLog.log('hotspot', '$op failed: $why ${j['msg'] ?? ''}');
        if (op == 'state') {
          on = false;
          _watch();
        }
        return false;
      }
      final was = on;
      on = j['on'] == true;
      ssid = '${j['ssid'] ?? ''}';
      pass = '${j['pass'] ?? ''}';
      clients = (j['clients'] as num?)?.toInt() ?? 0;
      why = null;
      if (clients > 0 || on != was) _lastClient = DateTime.now();
      if (op != 'state' || on != was) DiagLog.log('hotspot', '$op: ${on ? 'on' : 'off'}, $clients joined');
      _watch();
      return true;
    } catch (e) {
      why = 'error';
      DiagLog.log('hotspot', '$op: $e');
      return false;
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  /// While on: who has joined, every few seconds; off by itself when idle.
  void _watch() {
    if (!on) {
      _poll?.cancel();
      _poll = null;
      return;
    }
    _poll ??= Timer.periodic(const Duration(seconds: 5), (_) async {
      await refresh();
      if (on && autoOff && clients == 0 && DateTime.now().difference(_lastClient) > idleOff) {
        DiagLog.log('hotspot', 'nobody joined for ${idleOff.inMinutes} min: off');
        await stop();
      }
    });
  }

  // Windows Runtime's tethering manager, from Windows PowerShell 5.1.
  static const _script = r'''
param([string]$op = 'state')
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
function Out($h) { $h | ConvertTo-Json -Compress }
try {
  Add-Type -AssemblyName System.Runtime.WindowsRuntime
  $asTask = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object { $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1' })[0]
  function Await($o, [Type]$t) { $task = $asTask.MakeGenericMethod($t).Invoke($null, @($o)); $task.Wait(-1) | Out-Null; $task.Result }
  [Windows.Networking.Connectivity.NetworkInformation, Windows.Networking.Connectivity, ContentType = WindowsRuntime] | Out-Null
  [Windows.Networking.NetworkOperators.NetworkOperatorTetheringManager, Windows.Networking.NetworkOperators, ContentType = WindowsRuntime] | Out-Null
  [Windows.Networking.NetworkOperators.NetworkOperatorTetheringOperationResult, Windows.Networking.NetworkOperators, ContentType = WindowsRuntime] | Out-Null
  $p = [Windows.Networking.Connectivity.NetworkInformation]::GetInternetConnectionProfile()
  if ($null -eq $p) { Out @{ ok = $false; why = 'no_internet' }; exit }
  $cap = [Windows.Networking.NetworkOperators.NetworkOperatorTetheringManager]::GetTetheringCapabilityFromConnectionProfile($p)
  if ("$cap" -ne 'Enabled') { Out @{ ok = $false; why = "$cap" }; exit }
  $tm = [Windows.Networking.NetworkOperators.NetworkOperatorTetheringManager]::CreateFromConnectionProfile($p)
  $T = [Windows.Networking.NetworkOperators.NetworkOperatorTetheringOperationResult]
  if ($op -eq 'start' -and "$($tm.TetheringOperationalState)" -ne 'On') {
    $r = Await ($tm.StartTetheringAsync()) $T
    if ("$($r.Status)" -ne 'Success') { Out @{ ok = $false; why = "$($r.Status)"; msg = "$($r.AdditionalErrorMessage)" }; exit }
  }
  if ($op -eq 'stop' -and "$($tm.TetheringOperationalState)" -eq 'On') {
    $r = Await ($tm.StopTetheringAsync()) $T
  }
  $c = $tm.GetCurrentAccessPointConfiguration()
  Out @{ ok = $true; on = ("$($tm.TetheringOperationalState)" -eq 'On'); ssid = $c.Ssid; pass = $c.Passphrase; clients = $tm.ClientCount }
} catch {
  Out @{ ok = $false; why = 'error'; msg = "$($_.Exception.Message)" }
}
''';
}
