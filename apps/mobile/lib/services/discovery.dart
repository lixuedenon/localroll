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
Future<DesktopClient> connectToDesktop(
  MobileSettings settings,
  PairedDesktop d, {
  List<FoundDesktop> discovered = const [],
}) async {
  final candidates = <String>{
    if (d.lastHost != null) d.lastHost!,
    for (final f in discovered.where((f) => f.id == d.id)) ...f.hosts,
    ...d.hosts,
  };
  var port = d.port;
  for (final f in discovered.where((f) => f.id == d.id)) {
    port = f.port;
  }
  for (final host in candidates) {
    final client = DesktopClient(host: host, port: port, deviceId: settings.deviceId, token: d.token);
    try {
      final info = await client.info(timeout: const Duration(seconds: 2));
      if (info.id != d.id) {
        client.close();
        continue;
      }
      if (host != d.lastHost || port != d.port) {
        d.port = port;
        if (!d.hosts.contains(host)) d.hosts = [host, ...d.hosts];
        await settings.rememberHost(d, host);
      }
      return client;
    } catch (_) {
      client.close();
    }
  }
  throw Exception(tr('err.pc_not_found', {'name': d.name}));
}
