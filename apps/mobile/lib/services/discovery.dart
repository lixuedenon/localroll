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

/// Finds LocalRoll PCs on the LAN: Bonjour/mDNS first, plus a direct scan
/// of the local network as a fallback (some routers and Wi-Fi setups drop
/// mDNS, so a PC can "disappear" even though it is running).
class DesktopDiscovery extends ChangeNotifier {
  nsd.Discovery? _discovery;
  List<FoundDesktop> found = const [];
  String? error;

  List<FoundDesktop> _mdns = const [];
  final Map<String, FoundDesktop> _scanned = {};
  bool scanning = false;

  void _merge() {
    found = [
      ..._mdns,
      for (final f in _scanned.values)
        if (!_mdns.any((m) => m.id == f.id)) f,
    ];
    notifyListeners();
  }

  /// Asks every address of this phone's /24 network on the usual LocalRoll
  /// ports. Takes a few seconds; results are merged into [found].
  Future<void> scanSubnet({Iterable<int> extraPorts = const []}) async {
    if (scanning) return;
    scanning = true;
    notifyListeners();
    try {
      final ports = <int>{LrProtocol.defaultPort, 41530, 31530, 21530, 8530, ...extraPorts};
      final prefixes = <String>{};
      for (final ni in await NetworkInterface.list(type: InternetAddressType.IPv4)) {
        for (final a in ni.addresses) {
          final ip = a.address;
          if (a.isLoopback || ip.startsWith('169.254.')) continue;
          prefixes.add(ip.substring(0, ip.lastIndexOf('.')));
        }
      }
      final targets = <(String, int)>[
        for (final pre in prefixes)
          for (var i = 1; i < 255; i++)
            for (final p in ports) ('$pre.$i', p),
      ];
      // Probe in parallel batches; a closed port answers (or times out) fast.
      // Bounded: never more than ~25 s, and one slow host can't hold a batch.
      const batch = 64;
      final until = DateTime.now().add(const Duration(seconds: 25));
      for (var i = 0; i < targets.length && DateTime.now().isBefore(until); i += batch) {
        await Future.wait([
          for (final (host, port) in targets.sublist(i, (i + batch).clamp(0, targets.length))) _probe(host, port),
        ]).timeout(const Duration(seconds: 6), onTimeout: () => const []);
      }
    } catch (_) {
      // No network interface info: nothing to scan.
    } finally {
      scanning = false;
      _merge();
    }
  }

  Future<void> _probe(String host, int port) async {
    try {
      final sock = await Socket.connect(host, port, timeout: const Duration(milliseconds: 400));
      sock.destroy();
    } catch (_) {
      return;
    }
    final c = DesktopClient(host: host, port: port);
    try {
      final info = await c.info(timeout: const Duration(seconds: 2));
      final prev = _scanned[info.id];
      _scanned[info.id] = FoundDesktop(
        id: info.id,
        name: info.name,
        hosts: {...?prev?.hosts, host}.toList(),
        port: port,
      );
      _merge();
    } catch (_) {
    } finally {
      c.close();
    }
  }

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
    _mdns = [
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
    _merge();
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
/// [fingerprint] comes from the QR code: then only that certificate is
/// accepted. Typed PIN / address: the certificate seen first is kept.
Future<PairedDesktop> pairWithDesktop({
  required MobileSettings settings,
  required List<String> hosts,
  required int port,
  required String pin,
  String? fingerprint,
  int? tlsPort,
}) async {
  Object? lastError;
  for (final host in hosts) {
    DesktopClient? client;
    try {
      final probe = DesktopClient(host: host, port: port);
      final DeviceInfo info;
      try {
        info = await probe.info();
      } finally {
        probe.close();
      }
      final fp = fingerprint ?? info.fingerprint;
      final c = fp != null
          ? DesktopClient(host: host, port: tlsPort ?? info.tlsPort ?? port, secure: true, pin: fingerprint)
          : DesktopClient(host: host, port: port);
      client = c;
      final res = await c.pair(settings.deviceInfo, pin);
      final d = PairedDesktop(
        id: res.desktop.id,
        name: res.desktop.name,
        hosts: hosts,
        port: port,
        token: res.token,
        lastHost: host,
        fingerprint: c.secure ? (fingerprint ?? c.seenFingerprint) : null,
      );
      await settings.upsertDesktop(d);
      return d;
    } on LrHttpException catch (e) {
      // Reached the PC but it rejected us (wrong PIN…): no point trying other IPs.
      throw Exception(e.message);
    } catch (e) {
      lastError = e;
    } finally {
      client?.close();
    }
  }
  throw Exception(tr('err.cannot_reach', {'error': lastError ?? tr('err.no_address')}));
}

final Map<String, DateTime> _lookChecked = {};

/// Paired PCs seen on the Wi-Fi: pick up a new name / icon / picture right
/// away (not only when sending). At most once a minute per PC.
Future<void> refreshPairedLooks(MobileSettings settings, List<FoundDesktop> found) async {
  // Paired PCs the Wi-Fi search has not (re)found: try where they were last.
  final all = [
    ...found,
    for (final d in settings.desktops)
      if (!found.any((f) => f.id == d.id))
        FoundDesktop(id: d.id, name: d.name, hosts: [if (d.lastHost != null) d.lastHost!, ...d.hosts], port: d.port),
  ];
  for (final f in all) {
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
        await _pullDeletions(settings, d, h, f.port, info);
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
Future<void> _pullDeletions(MobileSettings settings, PairedDesktop d, String host, int port, DeviceInfo info) async {
  DesktopClient? c;
  try {
    c = await openDesktop(settings, d, host, port, info);
    final r = await c.changes(d.changesSinceMs);
    if (r.deleted.isNotEmpty) {
      final sent = settings.sentTo(d.id);
      // A Live Photo whose video was deleted on the PC is not fully backed
      // up any more either: treat it as its photo (re-sending then only
      // sends the missing video).
      final ours = {
        for (final id in r.deleted)
          if (sent.contains(livePhotoIdOf(id))) livePhotoIdOf(id),
      }.toList();
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
    c?.close();
  }
}

/// An authenticated client for paired PC [d] answering at [host]:[port]
/// ([info] is what it just said about itself).
///
/// * Paired with HTTPS: only the remembered certificate is accepted; a PC
///   showing a different one was reinstalled — or something is in between —
///   so we stop and ask to pair again.
/// * Paired before encryption, and the PC now has HTTPS: move over once
///   (a new token over HTTPS; the old one stops working), then remember the
///   certificate.
/// * Older PC without HTTPS: plain HTTP as before.
Future<DesktopClient> openDesktop(
  MobileSettings settings,
  PairedDesktop d,
  String host,
  int port,
  DeviceInfo info,
) async {
  final tlsPort = info.tlsPort ?? port;
  final pinned = d.fingerprint;
  if (pinned != null) {
    if (info.fingerprint != null && info.fingerprint != pinned) {
      throw Exception(tr('err.cert_changed', {'name': d.name}));
    }
    return DesktopClient(host: host, port: tlsPort, secure: true, pin: pinned, deviceId: settings.deviceId, token: d.token);
  }
  final offered = info.fingerprint;
  if (offered == null) return DesktopClient(host: host, port: port, deviceId: settings.deviceId, token: d.token);
  final up = DesktopClient(host: host, port: tlsPort, secure: true, pin: offered, deviceId: settings.deviceId, token: d.token);
  try {
    d.token = await up.upgrade();
  } finally {
    up.close();
  }
  d.fingerprint = offered;
  await settings.saveDesktop();
  return DesktopClient(host: host, port: tlsPort, secure: true, pin: offered, deviceId: settings.deviceId, token: d.token);
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
    var client = DesktopClient(host: host, port: port);
    try {
      final info = await client.info();
      // Newer PC: ask over HTTPS and bind the symbols to the certificate we
      // actually see — a device in between would make them differ.
      if (info.fingerprint != null) {
        client.close();
        client = DesktopClient(host: host, port: info.tlsPort ?? port, secure: true);
      }
      final start = await client.requestApproval(settings.deviceInfo);
      final seen = client.secure ? client.seenFingerprint : null;
      if (client.secure && seen == null) throw const SocketException('no certificate');
      onWaiting(pairingEmoji(start.requestId, fingerprint: seen));
      if (seen != null) {
        // From now on only that certificate.
        client.close();
        client = DesktopClient(host: host, port: info.tlsPort ?? port, secure: true, pin: seen);
      }
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
              fingerprint: seen,
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
    final probe = DesktopClient(host: host, port: port);
    final DeviceInfo info;
    try {
      info = await probe.info(timeout: const Duration(seconds: 3));
    } catch (e) {
      tried.add('$host:$port ${_short(e)}');
      continue;
    } finally {
      probe.close();
    }
    if (info.id != d.id) {
      tried.add('$host:$port other PC');
      continue;
    }
    await settings.updateLook(d, info);
    if (host != d.lastHost || port != d.port) {
      d.port = port;
      if (!d.hosts.contains(host)) d.hosts = [host, ...d.hosts];
      await settings.rememberHost(d, host);
    }
    // Certificate changed: stop here (the message says to pair again).
    return openDesktop(settings, d, host, port, info);
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

/// Forget a PC: tell it (best effort, it may be off) and remove it here.
Future<void> forgetDesktop(MobileSettings settings, PairedDesktop d) async {
  final hosts = <String>{if (d.lastHost != null) d.lastHost!, ...d.hosts};
  for (final h in hosts) {
    DesktopClient? c;
    try {
      final probe = DesktopClient(host: h, port: d.port);
      final DeviceInfo info;
      try {
        info = await probe.info(timeout: const Duration(seconds: 3));
      } finally {
        probe.close();
      }
      if (info.id != d.id) continue;
      c = await openDesktop(settings, d, h, d.port, info);
      await c.unpair();
      break;
    } catch (_) {
    } finally {
      c?.close();
    }
  }
  await settings.clearLost(d.id);
  await settings.removeDesktop(d.id);
}
