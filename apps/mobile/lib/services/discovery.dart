// apps/mobile/lib/services/discovery.dart
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
