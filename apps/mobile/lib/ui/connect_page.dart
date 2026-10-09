// apps/mobile/lib/ui/connect_page.dart
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:localroll_core/localroll_core.dart';

import '../l10n/l10n.dart';
import '../services/desktop_client.dart';
import '../services/discovery.dart';
import '../services/mobile_settings.dart';
import 'device_badge.dart';
import 'scan_page.dart';
import 'theme.dart';

/// Choose / pair a PC. Main way: tap a PC found on the Wi-Fi and click
/// "Allow" on the PC. Also: QR scan, PIN, or a typed address.
class ConnectPage extends StatefulWidget {
  const ConnectPage({super.key, required this.settings, required this.discovery});

  final MobileSettings settings;
  final DesktopDiscovery discovery;

  @override
  State<ConnectPage> createState() => _ConnectPageState();
}

class _ConnectPageState extends State<ConnectPage> {
  bool _busy = false;

  /// Stop the "searching" spinner after a while so it never spins forever.
  bool _searchedLong = false;
  Timer? _searchTimer;

  @override
  void initState() {
    super.initState();
    _searchTimer = Timer(const Duration(seconds: 8), () {
      if (mounted) setState(() => _searchedLong = true);
    });
  }

  @override
  void dispose() {
    _searchTimer?.cancel();
    super.dispose();
  }

  /// Name / icon / picture of PCs found on the Wi-Fi (read from /info).
  final Map<String, Future<DeviceInfo?>> _looks = {};

  Future<DeviceInfo?> _lookOf(FoundDesktop f) => _looks.putIfAbsent(f.id, () async {
        for (final h in f.hosts) {
          final c = DesktopClient(host: h, port: f.port);
          try {
            return await c.info(timeout: const Duration(seconds: 3));
          } catch (_) {
          } finally {
            c.close();
          }
        }
        return null;
      });

  /// Tap a PC → it asks "Allow?" → done.
  Future<void> _tapToPair(FoundDesktop f, String name) async {
    var cancelled = false;
    final emoji = ValueNotifier<List<String>?>(null);
    final dialog = showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        content: ValueListenableBuilder<List<String>?>(
          valueListenable: emoji,
          builder: (ctx, e, _) => Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (e == null) ...[
                const SizedBox(height: 8),
                const CircularProgressIndicator(),
                const SizedBox(height: 16),
                Text(tr('pair.contacting', {'name': name}), textAlign: TextAlign.center),
              ] else ...[
                Text(tr('pair.waiting', {'name': name}),
                    textAlign: TextAlign.center, style: Theme.of(ctx).textTheme.titleMedium),
                const SizedBox(height: 18),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                  decoration: BoxDecoration(
                    color: LrColors.ink,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: LrColors.line),
                  ),
                  child: Text(e.join('  '), style: const TextStyle(fontSize: 36)),
                ),
                const SizedBox(height: 12),
                Text(tr('pair.same_symbols'), textAlign: TextAlign.center, style: Theme.of(ctx).textTheme.bodySmall),
                const SizedBox(height: 12),
                const LinearProgressIndicator(),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              cancelled = true;
              Navigator.of(ctx).pop();
            },
            child: Text(tr('common.cancel')),
          ),
        ],
      ),
    );
    try {
      final d = await pairByApproval(
        settings: widget.settings,
        hosts: f.hosts,
        port: f.port,
        onWaiting: (e) => emoji.value = e,
        cancelled: () => cancelled,
      );
      if (!mounted || cancelled) return;
      Navigator.of(context).pop(); // the waiting dialog
      if (d == null) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('connect.paired_ok', {'name': d.name}))));
      Navigator.of(context).pop();
    } catch (e) {
      if (!mounted) return;
      if (!cancelled) Navigator.of(context).pop();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.toString().replaceFirst('Exception: ', ''))),
      );
    } finally {
      dialog.whenComplete(emoji.dispose);
    }
  }

  Future<void> _pair(List<String> hosts, int port, String pin) async {
    setState(() => _busy = true);
    try {
      final d = await pairWithDesktop(settings: widget.settings, hosts: hosts, port: port, pin: pin);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('connect.paired_ok', {'name': d.name}))));
      Navigator.of(context).pop();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.toString().replaceFirst('Exception: ', ''))),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _scan() async {
    final payload = await Navigator.of(context).push<PairingPayload>(
      MaterialPageRoute(builder: (_) => const ScanPage()),
    );
    if (payload != null) await _pair(payload.hosts, payload.port, payload.pin);
  }

  Future<void> _pinFor(FoundDesktop f) async {
    final pin = await _ask(context, title: tr('connect.pin_title', {'name': f.name}), fields: [tr('connect.pin_field')]);
    if (pin != null) await _pair(f.hosts, f.port, pin.first);
  }

  Future<void> _manual() async {
    final v = await _ask(context,
        title: tr('connect.manual_title'), fields: [tr('connect.address_field'), tr('connect.pin_field')]);
    if (v == null) return;
    // Accept "192.168.1.68" or "192.168.1.68:41530".
    final parts = v[0].split(':');
    final port = parts.length > 1 ? int.tryParse(parts[1]) ?? LrProtocol.defaultPort : LrProtocol.defaultPort;
    await _pair([parts[0]], port, v[1]);
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.settings;
    return Scaffold(
      appBar: AppBar(title: Text(tr('connect.title'))),
      body: AbsorbPointer(
        absorbing: _busy,
        child: ListenableBuilder(
          listenable: Listenable.merge([s, widget.discovery]),
          builder: (context, _) {
            final found = widget.discovery.found;
            final unpaired = found.where((f) => s.byId(f.id) == null).toList();
            final theme = Theme.of(context);
            return ListView(
              padding: const EdgeInsets.all(16),
              children: [
                if (_busy) const LinearProgressIndicator(),

                // PCs on this Wi-Fi: tap one, click Allow on the PC.
                Text(tr('connect.nearby'), style: theme.textTheme.titleMedium),
                const SizedBox(height: 4),
                Text(tr('connect.tap_hint'), style: theme.textTheme.bodySmall),
                const SizedBox(height: 12),
                if (unpaired.isEmpty)
                  _Card(
                    child: Row(children: [
                      if (found.isNotEmpty)
                        // Every PC on this Wi-Fi is already paired — nothing to do here.
                        const Icon(Icons.check_circle_rounded, color: LrColors.verified)
                      else if (!_searchedLong && widget.discovery.error == null)
                        const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2))
                      else
                        const Icon(Icons.wifi_find_rounded, color: LrColors.muted),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Text(widget.discovery.error != null
                            ? tr('connect.discovery_unavailable', {'error': widget.discovery.error})
                            : found.isNotEmpty
                                ? tr('connect.all_paired')
                                : _searchedLong
                                    ? tr('connect.none_found')
                                    : tr('connect.searching')),
                      ),
                    ]),
                  ),
                for (final f in unpaired)
                  FutureBuilder<DeviceInfo?>(
                    future: _lookOf(f),
                    builder: (context, snap) {
                      final info = snap.data;
                      final name = info?.name ?? f.name;
                      final host = f.hosts.isEmpty ? null : f.hosts.first;
                      return _Card(
                        onTap: () => _tapToPair(f, name),
                        child: Row(children: [
                          DeviceBadge(
                            icon: info?.icon,
                            color: info?.color,
                            image: (info != null && info.avatar != 0 && host != null)
                                ? NetworkImage('http://$host:${f.port}${LrProtocol.pathAvatar}?v=${info.avatar}')
                                : null,
                            size: 52,
                          ),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              Text(name, style: theme.textTheme.titleMedium),
                              const SizedBox(height: 2),
                              Text(tr('connect.tap_to_connect'), style: theme.textTheme.bodySmall),
                            ]),
                          ),
                          TextButton(onPressed: () => _pinFor(f), child: Text(tr('connect.enter_pin'))),
                        ]),
                      );
                    },
                  ),

                if (s.desktops.isNotEmpty) ...[
                  const SizedBox(height: 24),
                  Text(tr('connect.paired'), style: theme.textTheme.titleMedium),
                  const SizedBox(height: 12),
                  for (final d in s.desktops)
                    _Card(
                      selected: d.id == s.currentDesktopId,
                      onTap: () async {
                        await s.selectDesktop(d.id);
                        if (context.mounted) Navigator.of(context).pop();
                      },
                      child: Row(children: [
                        DeviceBadge(
                          icon: d.icon,
                          color: d.color,
                          image: d.avatarUrl == null ? null : NetworkImage(d.avatarUrl!),
                          size: 52,
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Text(d.name, style: theme.textTheme.titleMedium),
                            const SizedBox(height: 2),
                            Text(
                              found.any((f) => f.id == d.id) ? tr('connect.online') : tr('connect.offline'),
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: found.any((f) => f.id == d.id) ? LrColors.verified : LrColors.muted,
                              ),
                            ),
                          ]),
                        ),
                        IconButton(
                          tooltip: tr('connect.delete'),
                          icon: const Icon(Icons.delete_outline_rounded),
                          onPressed: () => s.removeDesktop(d.id),
                        ),
                      ]),
                    ),
                ],

                const SizedBox(height: 28),
                Text(tr('connect.other_ways'), style: theme.textTheme.titleMedium),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: _scan,
                  icon: const Icon(Icons.qr_code_scanner_rounded),
                  label: Text(tr('connect.scan')),
                ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: _manual,
                  icon: const Icon(Icons.keyboard_rounded),
                  label: Text(tr('connect.manual')),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// Tappable card used for PCs.
class _Card extends StatelessWidget {
  const _Card({required this.child, this.onTap, this.selected = false});

  final Widget child;
  final VoidCallback? onTap;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: LrColors.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: selected ? LrColors.safelight : LrColors.line, width: selected ? 2 : 1),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(padding: const EdgeInsets.all(14), child: child),
        ),
      ),
    );
  }
}

/// Simple text-input dialog; returns the values or null if cancelled.
Future<List<String>?> _ask(BuildContext context, {required String title, required List<String> fields}) {
  final controllers = [for (final _ in fields) TextEditingController()];
  return showDialog<List<String>>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < fields.length; i++)
            TextField(
              controller: controllers[i],
              autofocus: i == 0,
              keyboardType: i == fields.length - 1 ? TextInputType.number : TextInputType.url,
              decoration: InputDecoration(labelText: fields[i]),
            ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: Text(tr('common.cancel'))),
        FilledButton(
          onPressed: () {
            final v = controllers.map((c) => c.text.trim()).toList();
            if (v.any((x) => x.isEmpty)) return;
            Navigator.pop(ctx, v);
          },
          child: Text(tr('connect.connect')),
        ),
      ],
    ),
  );
}
