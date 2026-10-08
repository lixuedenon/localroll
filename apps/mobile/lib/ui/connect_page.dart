// apps/mobile/lib/ui/connect_page.dart
import 'package:flutter/material.dart';
import 'package:localroll_core/localroll_core.dart';

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
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('已配对：${d.name}')));
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
    final pin = await _ask(context, title: '输入「${f.name}」上显示的配对码', fields: const ['6 位配对码']);
    if (pin != null) await _pair(f.hosts, f.port, pin.first);
  }

  Future<void> _manual() async {
    final v = await _ask(context, title: '手动连接', fields: const ['电脑 IP 地址（如 192.168.1.68）', '6 位配对码']);
    if (v == null) return;
    await _pair([v[0]], LrProtocol.defaultPort, v[1]);
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.settings;
    return Scaffold(
      appBar: AppBar(title: const Text('连接电脑')),
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
                  label: const Text('扫描电脑上的二维码'),
                ),
                const SizedBox(height: 24),
                if (s.desktops.isNotEmpty) ...[
                  Text('已配对的电脑', style: Theme.of(context).textTheme.titleSmall),
                  for (final d in s.desktops)
                    ListTile(
                      leading: Icon(d.id == s.currentDesktopId ? Icons.radio_button_checked : Icons.radio_button_off),
                      title: Text(d.name),
                      subtitle: Text(found.any((f) => f.id == d.id) ? '在线' : (d.lastHost ?? '')),
                      onTap: () async {
                        await s.selectDesktop(d.id);
                        if (context.mounted) Navigator.of(context).pop();
                      },
                      trailing: IconButton(
                        tooltip: '删除',
                        icon: const Icon(Icons.delete_outline),
                        onPressed: () => s.removeDesktop(d.id),
                      ),
                    ),
                  const SizedBox(height: 16),
                ],
                Text('附近的电脑', style: Theme.of(context).textTheme.titleSmall),
                if (unpaired.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Text(widget.discovery.error != null
                        ? '自动查找不可用：${widget.discovery.error}'
                        : '正在查找…（电脑上要先打开 LocalRoll）'),
                  ),
                for (final f in unpaired)
                  ListTile(
                    leading: const Icon(Icons.computer),
                    title: Text(f.name),
                    subtitle: Text(f.hosts.join(', ')),
                    trailing: const Text('输入配对码'),
                    onTap: () => _pinFor(f),
                  ),
                const SizedBox(height: 16),
                TextButton(onPressed: _manual, child: const Text('找不到？手动输入 IP 地址')),
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
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: InputDecoration(labelText: fields[i]),
            ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
        FilledButton(
          onPressed: () {
            final v = controllers.map((c) => c.text.trim()).toList();
            if (v.any((x) => x.isEmpty)) return;
            Navigator.pop(ctx, v);
          },
          child: const Text('连接'),
        ),
      ],
    ),
  );
}
