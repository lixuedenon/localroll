// apps/desktop/lib/services/network.dart
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:localroll_core/localroll_core.dart';
import 'package:nsd/nsd.dart' as nsd;

/// LAN IPv4 addresses, real Wi-Fi/Ethernet adapters first.
///
/// Virtual adapters (Hyper-V, WSL, VirtualBox, VPNs) are moved to the end:
/// the v1 app put them in the QR code and phones could not connect.
Future<List<String>> localIPv4Addresses() async {
  final interfaces = await NetworkInterface.list(
    type: InternetAddressType.IPv4,
    includeLoopback: false,
    includeLinkLocal: false,
  );
  const virtualHints = [
    'vethernet', 'virtual', 'vmware', 'vbox', 'wsl', 'hyper-v', 'loopback',
    'bluetooth', 'tailscale', 'zerotier', 'vpn', 'tap', 'tun', 'docker',
  ];
  int score(NetworkInterface iface, InternetAddress addr) {
    final name = iface.name.toLowerCase();
    var s = 0;
    if (virtualHints.any(name.contains)) s += 100;
    final ip = addr.address;
    if (ip.startsWith('192.168.')) {
      s += 0;
    } else if (ip.startsWith('10.')) {
      s += 10;
    } else if (RegExp(r'^172\.(1[6-9]|2\d|3[01])\.').hasMatch(ip)) {
      s += 20; // Docker/WSL often live here.
    } else {
      s += 50;
    }
    return s;
  }

  final pairs = <(int, String)>[];
  for (final iface in interfaces) {
    for (final addr in iface.addresses) {
      if (addr.isLoopback || addr.address.startsWith('169.254.')) continue;
      pairs.add((score(iface, addr), addr.address));
    }
  }
  pairs.sort((a, b) => a.$1.compareTo(b.$1));
  return pairs.map((p) => p.$2).toSet().toList();
}

/// Advertises this PC via Bonjour/mDNS so phones can find it automatically.
class MdnsAdvertiser {
  nsd.Registration? _registration;

  Future<void> start({required String name, required String deviceId, required int port}) async {
    await stop();
    try {
      _registration = await nsd.register(nsd.Service(
        name: name,
        type: LrProtocol.serviceType,
        port: port,
        txt: {'id': Uint8List.fromList(utf8.encode(deviceId))},
      ));
    } catch (e) {
      // Not fatal: phones can still pair by QR code / IP.
      debugPrint('mDNS registration failed: $e');
    }
  }

  Future<void> stop() async {
    final r = _registration;
    _registration = null;
    if (r != null) {
      try {
        await nsd.unregister(r);
      } catch (_) {}
    }
  }
}

/// Adds inbound Windows Firewall rules for the receiver port and mDNS.
/// Shows the UAC prompt; returns false if the user declined or it failed.
Future<bool> addFirewallRules(int port) async {
  if (!Platform.isWindows) return false;
  final cmd = 'netsh advfirewall firewall delete rule name=LocalRoll & '
      'netsh advfirewall firewall add rule name=LocalRoll dir=in action=allow protocol=TCP localport=$port profile=any & '
      'netsh advfirewall firewall add rule name=LocalRoll dir=in action=allow protocol=UDP localport=5353 profile=any';
  try {
    final result = await Process.run('powershell', [
      '-NoProfile',
      '-Command',
      "Start-Process -FilePath cmd -ArgumentList '/c $cmd' -Verb RunAs -Wait -WindowStyle Hidden",
    ]);
    return result.exitCode == 0;
  } catch (e) {
    debugPrint('firewall rule failed: $e');
    return false;
  }
}

/// Opens Explorer with [path] selected (or the folder itself).
Future<void> revealInExplorer(String path) async {
  if (!Platform.isWindows) return;
  if (await File(path).exists()) {
    await Process.start('explorer.exe', ['/select,', path]);
  } else {
    await Process.start('explorer.exe', [path]);
  }
}
