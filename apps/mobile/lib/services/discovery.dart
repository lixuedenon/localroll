// apps/mobile/lib/services/discovery.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:localroll_core/localroll_core.dart';
import 'package:nsd/nsd.dart' as nsd;

import '../l10n/l10n.dart';
import 'desktop_client.dart';
import 'mobile_settings.dart';

class FoundDesktop {
  const FoundDesktop({required this.id, required this.name, required this.hosts, required this.port});

  final String id;
  final String name;
  final List<String> hosts;
  final int port;
}

/// Watches the LAN for LocalRoll PCs (Bonjour/mDNS).
class DesktopDiscovery extends ChangeNotifier {
  nsd.Discovery? _discovery;
  List<FoundDesktop> found = const [];
  String? error;

  Future<void> start() async {
    if (_discovery != null) return;
    try {
      _discovery = await nsd.startDiscovery(LrProtocol.serviceType, ipLookupType: nsd.IpLookupType.any);
      _discovery!.addListener(_update);
      error = null;
    } catch (e) {
      error = '$e';
    }
    notifyListeners();
  }

  Future<void> stop() async {
    final d = _discovery;
    _discovery = null;
    if (d != null) {
      d.removeListener(_update);
      try {
        await nsd.stopDiscovery(d);
      } catch (_) {}
    }
  }

  void _update() {
    final services = _discovery?.services ?? const <nsd.Service>[];
    found = [
      for (final s in services)
        FoundDesktop(
          id: _txt(s, 'id') ?? s.name ?? '',
          name: s.name ?? 'PC',
          hosts: [
            ...?s.addresses?.where((a) => a.type == InternetAddressType.IPv4).map((a) => a.address),
            if ((s.addresses == null || s.addresses!.isEmpty) && s.host != null) s.host!,
          ],
          port: s.port ?? LrProtocol.defaultPort,
        ),
    ];
    notifyListeners();
  }

  static String? _txt(nsd.Service s, String key) {
    final v = s.txt?[key];
    if (v == null) return null;
    try {
      return utf8.decode(v);
    } catch (_) {
      return null;
    }
  }

  @override
  void dispose() {
    stop();
    super.dispose();
  }
}

/// Pairs with a PC: tries each address until one answers, then sends the PIN.
Future<PairedDesktop> pairWithDesktop({
  required MobileSettings settings,
  required List<String> hosts,
  required int port,
  required String pin,
}) async {
  Object? lastError;
  for (final host in hosts) {
    final client = DesktopClient(host: host, port: port);
    try {
      await client.info();
      final res = await client.pair(settings.deviceInfo, pin);
      final d = PairedDesktop(
        id: res.desktop.id,
        name: res.desktop.name,
        hosts: hosts,
        port: port,
        token: res.token,
        lastHost: host,
      );
      await settings.upsertDesktop(d);
      return d;
    } on LrHttpException catch (e) {
      // Reached the PC but it rejected us (wrong PIN…): no point trying other IPs.
      throw Exception(e.message);
    } catch (e) {
      lastError = e;
    } finally {
      client.close();
    }
  }
  throw Exception(tr('err.cannot_reach', {'error': lastError ?? tr('err.no_address')}));
}

final Map<String, DateTime> _lookChecked = {};

/// Paired PCs seen on the Wi-Fi: pick up a new name / icon / picture right
/// away (not only when sending). At most once a minute per PC.
Future<void> refreshPairedLooks(MobileSettings settings, List<FoundDesktop> found) async {
  for (final f in found) {
    final d = settings.byId(f.id);
    if (d == null) continue;
    final last = _lookChecked[f.id];
    if (last != null && DateTime.now().difference(last) < const Duration(minutes: 1)) continue;
    _lookChecked[f.id] = DateTime.now();
    for (final h in f.hosts) {
      final c = DesktopClient(host: h, port: f.port);
      try {
        final info = await c.info(timeout: const Duration(seconds: 3));
        if (info.id != d.id) continue;
        if (d.lastHost != h || d.port != f.port) {
          d.port = f.port;
          await settings.rememberHost(d, h);
        }
        await settings.updateLook(d, info);
        await _pullDeletions(settings, d, h, f.port);
        break;
      } catch (_) {
      } finally {
        c.close();
      }
    }
  }
}

/// Reverse signal: photos deleted on the PC that are still on this phone lose
/// their ✓ and are listed as "not backed up any more".
Future<void> _pullDeletions(MobileSettings settings, PairedDesktop d, String host, int port) async {
  final c = DesktopClient(host: host, port: port, deviceId: settings.deviceId, token: d.token);
  try {
    final r = await c.changes(d.changesSinceMs);
    if (r.deleted.isNotEmpty) {
      final sent = settings.sentTo(d.id);
      final ours = r.deleted.where(sent.contains).toList();
      if (ours.isNotEmpty) {
        await settings.unmarkSent(d.id, ours);
        await settings.addLost(d.id, ours);
      }
    }
    d.changesSinceMs = r.now;
    await settings.saveDesktop();
  } catch (_) {
    // Older PC version or not paired any more: nothing to do.
  } finally {
    c.close();
  }
}

/// Tap-to-pair: asks the PC, then waits for Allow / Deny there.
/// [onWaiting] gets the three symbols to show (same as on the PC).
/// [cancelled] is polled; return true to give up.
Future<PairedDesktop?> pairByApproval({
  required MobileSettings settings,
  required List<String> hosts,
  required int port,
  required void Function(List<String> emoji) onWaiting,
  required bool Function() cancelled,
}) async {
  Object? lastError;
  for (final host in hosts) {
    final client = DesktopClient(host: host, port: port);
    try {
      final info = await client.info();
      final start = await client.requestApproval(settings.deviceInfo);
      onWaiting(pairingEmoji(start.requestId));
      final deadline = DateTime.now().add(LrProtocol.pairApprovalTimeout + const Duration(seconds: 5));
      while (DateTime.now().isBefore(deadline)) {
        if (cancelled()) return null;
        await Future<void>.delayed(const Duration(seconds: 1));
        final st = await client.approvalStatus(start.requestId);
        switch (st.status) {
          case PairApprovalStatus.pending:
            continue;
          case PairApprovalStatus.approved:
            final desk = st.desktop ?? info;
            final d = PairedDesktop(
              id: desk.id,
              name: desk.name,
              hosts: hosts,
              port: port,
              token: st.token!,
              lastHost: host,
              icon: desk.icon,
              color: desk.color,
              avatar: desk.avatar,
            );
            await settings.upsertDesktop(d);
            return d;
          case PairApprovalStatus.denied:
            throw Exception(tr('err.pair_denied'));
          case PairApprovalStatus.expired:
            throw Exception(tr('err.pair_expired'));
        }
      }
      throw Exception(tr('err.pair_expired'));
    } on LrHttpException catch (e) {
      throw Exception(e.message);
    } on SocketException catch (e) {
      lastError = e;
    } on TimeoutException catch (e) {
      lastError = e;
    } finally {
      client.close();
    }
  }
  throw Exception(tr('err.cannot_reach', {'error': lastError ?? tr('err.no_address')}));
}

/// Finds a working address for a paired PC and returns an authenticated client.
///
/// Tries the last working host:port first, then every known host with every
/// known port. mDNS can report a stale port (e.g. from a copy of the desktop
/// app that was closed), so it never replaces the port we paired with.
Future<DesktopClient> connectToDesktop(
  MobileSettings settings,
  PairedDesktop d, {
  List<FoundDesktop> discovered = const [],
}) async {
  final mine = discovered.where((f) => f.id == d.id).toList();
  final hosts = <String>{
    if (d.lastHost != null) d.lastHost!,
    ...d.hosts,
    for (final f in mine) ...f.hosts,
  };
  final ports = <int>{d.port, for (final f in mine) f.port};
  final endpoints = <(String, int)>[
    if (d.lastHost != null) (d.lastHost!, d.port),
    for (final p in ports)
      for (final h in hosts) (h, p),
  ];
  final tried = <String>[];
  final seen = <String>{};
  for (final (host, port) in endpoints) {
    if (!seen.add('$host:$port')) continue;
    final client = DesktopClient(host: host, port: port, deviceId: settings.deviceId, token: d.token);
    try {
      final info = await client.info(timeout: const Duration(seconds: 3));
      if (info.id != d.id) {
        tried.add('$host:$port other PC');
        client.close();
        continue;
      }
      await settings.updateLook(d, info);
      if (host != d.lastHost || port != d.port) {
        d.port = port;
        if (!d.hosts.contains(host)) d.hosts = [host, ...d.hosts];
        await settings.rememberHost(d, host);
      }
      return client;
    } catch (e) {
      tried.add('$host:$port ${_short(e)}');
      client.close();
    }
  }
  throw Exception('${tr('err.pc_not_found', {'name': d.name})}\n\n${tried.join('\n')}');
}

String _short(Object e) {
  final s = e.toString();
  if (s.contains('TimeoutException')) return 'timeout';
  if (s.contains('Connection refused')) return 'refused';
  if (s.contains('No route to host')) return 'no route';
  final m = RegExp(r'errno = (\d+)').firstMatch(s);
  if (m != null) return 'errno ${m.group(1)}';
  return s.length > 60 ? s.substring(0, 60) : s;
}
