// apps/desktop/lib/ui/net_check.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_services.dart';
import '../l10n/l10n.dart';
import '../services/network.dart';
import 'light_dialog.dart';
import 'light_look.dart';
import 'lr_dialog.dart';

/// "Why can't they find me / why is it slow": each thing checked, what to do,
/// a button where it can be fixed from here.
Future<void> showNetCheck(BuildContext context, AppServices s) =>
    showLrDialog<void>(context: context, builder: (_) => _NetCheck(s: s));

enum _Level { ok, warn, bad }

class _Item {
  _Item(this.level, this.title, this.sub, {this.fix, this.fixLabel});

  final _Level level;
  final String title;
  final String sub;
  final Future<void> Function()? fix;
  final String? fixLabel;
}

class _NetCheck extends StatefulWidget {
  const _NetCheck({required this.s});

  final AppServices s;

  @override
  State<_NetCheck> createState() => _NetCheckState();
}

class _NetCheckState extends State<_NetCheck> {
  List<_Item>? _items;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    unawaited(_run());
  }

  Future<void> _run() async {
    setState(() => _items = null);
    final items = <_Item>[];
    final s = widget.s;
    final mine = await localIPv4Addresses();
    // 1. The network type ("Public" blocks being found).
    final profiles = await _profiles();
    final wifi = await _wifi();
    final public = profiles.where((p) => p.$2 == 'Public').toList();
    if (profiles.isEmpty) {
      items.add(_Item(_Level.bad, tr('net.no_network'), tr('net.no_network_sub')));
    } else if (public.isNotEmpty) {
      items.add(_Item(_Level.bad, tr('net.public', {'name': public.first.$1}), tr('net.public_sub'),
          fix: _makePrivate, fixLabel: tr('net.fix')));
    } else {
      items.add(_Item(_Level.ok, tr('net.private', {'name': profiles.first.$1}), [
        if (wifi != null) wifi.$2 ? '5 GHz' : '2.4 GHz',
        ...mine,
      ].join(' · ')));
    }
    // 2. Wi-Fi band: 2.4 GHz is several times slower.
    if (wifi != null && !wifi.$2) {
      items.add(_Item(_Level.warn, tr('net.slow_band'), tr('net.slow_band_sub', {'ssid': wifi.$1})));
    }
    // 3. The firewall.
    final health = await checkNetworkHealth(s.server.port);
    items.add(health.firewallRule
        ? _Item(_Level.ok, tr('net.firewall_ok'), tr('net.firewall_ok_sub', {'port': s.server.port}))
        : _Item(_Level.bad, tr('net.firewall_bad'), tr('net.firewall_bad_sub'), fix: () async {
            await addFirewallRules(s.server.port);
          }, fixLabel: tr('net.fix')));
    // 4. Every paired device: reachable? same network? how fast to answer?
    final ids = {...s.settings.peers.keys, ...s.settings.trusted.keys};
    for (final id in ids) {
      final name = s.deviceName(id);
      String? host;
      int? port;
      final pc = s.settings.peers[id];
      if (pc != null) {
        host = pc.lastHost ?? pc.hosts.firstOrNull;
        port = pc.port;
      } else {
        final ep = s.server.phoneEndpoint(id);
        host = ep?.host;
        port = ep?.port;
      }
      if (host == null || port == null || port == 0) {
        items.add(_Item(_Level.warn, tr('net.dev_unknown', {'name': name}), tr(pc == null ? 'net.phone_closed' : 'net.pc_unknown')));
        continue;
      }
      final same = mine.any((m) => _subnet(m) == _subnet(host!));
      final ms = await _ping(host, port);
      if (ms == null) {
        items.add(_Item(_Level.bad, tr('net.dev_down', {'name': name}),
            same ? tr('net.dev_down_sub', {'ip': host}) : tr('net.other_subnet', {'ip': host})));
      } else {
        items.add(_Item(same ? _Level.ok : _Level.warn, tr('net.dev_ok', {'name': name}),
            [host, tr('net.ms', {'ms': ms}), if (!same) tr('net.routed')].join(' · ')));
      }
    }
    // 5. The guest page's port (short address).
    if (s.guest.running) {
      items.add(_Item(_Level.ok, tr('net.guest_port_ok', {'port': s.guest.port}), tr('net.guest_in_use')));
    } else {
      final free = await _portFree(80);
      items.add(free
          ? _Item(_Level.ok, tr('net.guest_port_ok', {'port': 80}), tr('net.guest_port_free'))
          : _Item(_Level.warn, tr('net.guest_port_busy'), tr('net.guest_port_busy_sub')));
    }
    if (mounted) setState(() => _items = items);
  }

  static String _subnet(String ip) {
    final p = ip.split('.');
    return p.length == 4 ? '${p[0]}.${p[1]}.${p[2]}' : ip;
  }

  static Future<int?> _ping(String host, int port) async {
    final w = Stopwatch()..start();
    try {
      final sock = await Socket.connect(host, port, timeout: const Duration(seconds: 2));
      sock.destroy();
      return w.elapsedMilliseconds;
    } catch (_) {
      return null;
    }
  }

  static Future<bool> _portFree(int port) async {
    try {
      final sock = await ServerSocket.bind(InternetAddress.anyIPv4, port);
      await sock.close();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// (name, category) of each connected network.
  static Future<List<(String, String)>> _profiles() async {
    if (!Platform.isWindows) return const [];
    try {
      final r = await Process.run('powershell', [
        '-NoProfile',
        '-NonInteractive',
        '-Command',
        r'Get-NetConnectionProfile | ForEach-Object { "$($_.Name)|$($_.NetworkCategory)" }',
      ], stdoutEncoding: utf8);
      return [
        for (final line in '${r.stdout}'.split('\n'))
          if (line.contains('|')) (line.split('|').first.trim(), line.split('|').last.trim()),
      ];
    } catch (_) {
      return const [];
    }
  }

  /// (SSID, 5 GHz?) of the Wi-Fi in use, or null (cable / none).
  static Future<(String, bool)?> _wifi() async {
    if (!Platform.isWindows) return null;
    try {
      final r = await Process.run('netsh', ['wlan', 'show', 'interfaces']);
      final out = '${r.stdout}';
      final ssid = RegExp(r'^\s*SSID\s*:\s*(.+)$', multiLine: true).firstMatch(out)?.group(1)?.trim();
      final ch = int.tryParse(RegExp(r'^\s*(?:Channel|信道|通道)\s*:\s*(\d+)', multiLine: true).firstMatch(out)?.group(1) ?? '');
      if (ssid == null || ch == null) return null;
      return (ssid, ch > 14);
    } catch (_) {
      return null;
    }
  }

  Future<void> _makePrivate() async {
    const cmd = "Get-NetConnectionProfile | Where-Object NetworkCategory -eq 'Public' | Set-NetConnectionProfile -NetworkCategory Private";
    final units = <int>[];
    for (final u in cmd.codeUnits) {
      units
        ..add(u & 0xFF)
        ..add(u >> 8);
    }
    final enc = base64.encode(units);
    try {
      await Process.run('powershell', [
        '-NoProfile',
        '-Command',
        "Start-Process -FilePath powershell -ArgumentList '-NoProfile -EncodedCommand $enc' -Verb RunAs -Wait -WindowStyle Hidden",
      ]);
    } catch (_) {}
  }

  String _report() => [
        for (final i in _items ?? const <_Item>[]) '${switch (i.level) { _Level.ok => '✓', _Level.warn => '!', _Level.bad => '✕' }} ${i.title} — ${i.sub}',
      ].join('\n');

  @override
  Widget build(BuildContext context) {
    final items = _items;
    return LightDialog(
      icon: Icons.health_and_safety_rounded,
      title: tr('net.title'),
      subtitle: tr('net.subtitle'),
      actions: [
        OutlinedButton(
          onPressed: items == null
              ? null
              : () {
                  unawaited(Clipboard.setData(ClipboardData(text: _report())));
                  ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(tr('net.copied'))));
                },
          child: Text(tr('net.copy')),
        ),
        OutlinedButton(onPressed: items == null || _busy ? null : _run, child: Text(tr('net.again'))),
        FilledButton(onPressed: () => Navigator.pop(context), child: Text(tr('common.done'))),
      ],
      child: items == null
          ? const Padding(padding: EdgeInsets.all(30), child: Center(child: CircularProgressIndicator()))
          : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              for (final i in items)
                LightRow(
                  icon: switch (i.level) { _Level.ok => Icons.check_rounded, _Level.warn => Icons.priority_high_rounded, _Level.bad => Icons.close_rounded },
                  iconBg: switch (i.level) { _Level.ok => const Color(0xFFE3F7EC), _Level.warn => const Color(0xFFFFF1DC), _Level.bad => const Color(0xFFFFE3E3) },
                  iconColor: switch (i.level) { _Level.ok => LightLook.green, _Level.warn => LightLook.amberText, _Level.bad => LightLook.red },
                  title: i.title,
                  sub: i.sub,
                  trailing: i.fix != null
                      ? FilledButton(
                          onPressed: _busy
                              ? null
                              : () async {
                                  setState(() => _busy = true);
                                  await i.fix!();
                                  if (!mounted) return;
                                  setState(() => _busy = false);
                                  await _run();
                                },
                          child: Text(i.fixLabel ?? tr('net.fix')),
                        )
                      : switch (i.level) {
                          _Level.ok => LightChip.ok(tr('net.ok')),
                          _Level.warn => LightChip.warn(tr('net.look')),
                          _Level.bad => LightChip.bad(tr('net.problem')),
                        },
                ),
            ]),
    );
  }
}
