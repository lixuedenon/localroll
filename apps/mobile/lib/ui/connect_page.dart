// apps/mobile/lib/ui/connect_page.dart
import 'package:flutter/material.dart';
import 'package:localroll_core/localroll_core.dart';

import '../l10n/l10n.dart';
import '../services/discovery.dart';
import '../services/mobile_settings.dart';
import 'scan_page.dart';

/// Choose / pair a PC: QR scan, PIN for an auto-discovered PC, or manual IP.
class ConnectPage extends StatefulWidget {
  const ConnectPage({super.key, required this.settings, required this.discovery});

  final MobileSettings settings;
  final DesktopDiscovery discovery;

  @override
  State<ConnectPage> createState() => _ConnectPageState();
}

class _ConnectPageState extends State<ConnectPage> {
  bool _busy = false;

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
            return ListView(
              padding: const EdgeInsets.all(16),
              children: [
                if (_busy) const LinearProgressIndicator(),
                FilledButton.icon(
                  onPressed: _scan,
                  icon: const Icon(Icons.qr_code_scanner),
                  label: Text(tr('connect.scan')),
                ),
                const SizedBox(height: 24),
                if (s.desktops.isNotEmpty) ...[
                  Text(tr('connect.paired'), style: Theme.of(context).textTheme.titleSmall),
                  for (final d in s.desktops)
                    ListTile(
                      leading: Icon(d.id == s.currentDesktopId ? Icons.radio_button_checked : Icons.radio_button_off),
                      title: Text(d.name),
                      subtitle: Text(found.any((f) => f.id == d.id) ? tr('connect.online') : (d.lastHost ?? '')),
                      onTap: () async {
                        await s.selectDesktop(d.id);
                        if (context.mounted) Navigator.of(context).pop();
                      },
                      trailing: IconButton(
                        tooltip: tr('connect.delete'),
                        icon: const Icon(Icons.delete_outline),
                        onPressed: () => s.removeDesktop(d.id),
                      ),
                    ),
                  const SizedBox(height: 16),
                ],
                Text(tr('connect.nearby'), style: Theme.of(context).textTheme.titleSmall),
                if (unpaired.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Text(widget.discovery.error != null
                        ? tr('connect.discovery_unavailable', {'error': widget.discovery.error})
                        : tr('connect.searching')),
                  ),
                for (final f in unpaired)
                  ListTile(
                    leading: const Icon(Icons.computer),
                    title: Text(f.name),
                    subtitle: Text(f.hosts.join(', ')),
                    trailing: Text(tr('connect.enter_pin')),
                    onTap: () => _pinFor(f),
                  ),
                const SizedBox(height: 16),
                TextButton(onPressed: _manual, child: Text(tr('connect.manual'))),
              ],
            );
          },
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
