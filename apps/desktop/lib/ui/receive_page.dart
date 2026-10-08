// apps/desktop/lib/ui/receive_page.dart
import 'dart:ui' show FontFeature;

import 'package:flutter/material.dart';
import 'package:localroll_core/localroll_core.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../app_services.dart';
import '../l10n/l10n.dart';
import '../services/network.dart';
import '../services/receive_hub.dart';
import 'format.dart';

/// Pairing QR/PIN plus live progress of incoming files.
class ReceivePage extends StatelessWidget {
  const ReceivePage({super.key, required this.services});

  final AppServices services;

  @override
  Widget build(BuildContext context) {
    final s = services;
    return Scaffold(
      appBar: AppBar(title: Text(tr('receive.title'))),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          ListenableBuilder(
            listenable: Listenable.merge([s.server, s.server.pin, s.addresses]),
            builder: (context, _) => _PairingCard(services: s),
          ),
          const SizedBox(height: 24),
          ListenableBuilder(
            listenable: s.hub,
            builder: (context, _) => _TransfersCard(hub: s.hub),
          ),
        ],
      ),
    );
  }
}

class _PairingCard extends StatelessWidget {
  const _PairingCard({required this.services});

  final AppServices services;

  @override
  Widget build(BuildContext context) {
    final s = services;
    final theme = Theme.of(context);

    if (!s.server.running) {
      return Card(
        color: theme.colorScheme.errorContainer,
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(tr('receive.not_running'), style: theme.textTheme.titleMedium),
              const SizedBox(height: 8),
              Text(s.server.error ?? tr('common.unknown_error')),
              const SizedBox(height: 12),
              FilledButton(onPressed: s.startNetworking, child: Text(tr('common.retry'))),
            ],
          ),
        ),
      );
    }

    final hosts = s.addresses.value;
    final payload = PairingPayload(
      deviceId: s.settings.deviceId,
      name: s.settings.deviceName,
      hosts: hosts,
      port: s.server.port,
      pin: s.server.pin.value,
    ).encode();

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Wrap(
          spacing: 32,
          runSpacing: 24,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Container(
              color: Colors.white,
              padding: const EdgeInsets.all(12),
              child: QrImageView(data: payload, size: 220, backgroundColor: Colors.white),
            ),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(tr('receive.scan_title'), style: theme.textTheme.titleLarge),
                  const SizedBox(height: 8),
                  Text(tr('receive.scan_body')),
                  const SizedBox(height: 20),
                  Text(tr('receive.or_pin'), style: theme.textTheme.labelLarge),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      SelectableText(
                        s.server.pin.value,
                        style: theme.textTheme.displaySmall?.copyWith(
                          fontFeatures: const [FontFeature.tabularFigures()],
                          letterSpacing: 6,
                          color: theme.colorScheme.primary,
                        ),
                      ),
                      const SizedBox(width: 8),
                      IconButton(
                        tooltip: tr('receive.new_pin'),
                        onPressed: s.server.rotatePin,
                        icon: const Icon(Icons.refresh),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Text(
                    hosts.isEmpty
                        ? tr('receive.no_address')
                        : tr('receive.address', {'addresses': hosts.map((h) => '$h:${s.server.port}').join('   ')}),
                    style: theme.textTheme.bodySmall,
                  ),
                  const SizedBox(height: 16),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      OutlinedButton.icon(
                        onPressed: s.refreshAddresses,
                        icon: const Icon(Icons.wifi_find),
                        label: Text(tr('receive.refresh')),
                      ),
                      OutlinedButton.icon(
                        onPressed: () async {
                          final ok = await addFirewallRules(s.server.port);
                          if (!context.mounted) return;
                          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                            content: Text(ok ? tr('receive.firewall_ok') : tr('receive.firewall_fail')),
                          ));
                        },
                        icon: const Icon(Icons.shield_outlined),
                        label: Text(tr('receive.firewall_button')),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TransfersCard extends StatelessWidget {
  const _TransfersCard({required this.hub});

  final ReceiveHub hub;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final list = hub.transfers;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(tr('receive.history'), style: theme.textTheme.titleMedium),
                const Spacer(),
                if (list.isNotEmpty)
                  TextButton(onPressed: hub.clearFinished, child: Text(tr('common.clear_finished'))),
              ],
            ),
            if (list.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 24),
                child: Text(tr('receive.none')),
              ),
            for (final t in list) _TransferTile(t: t),
          ],
        ),
      ),
    );
  }
}

class _TransferTile extends StatelessWidget {
  const _TransferTile({required this.t});

  final TransferProgress t;

  @override
  Widget build(BuildContext context) {
    final (icon, label) = switch (t.state) {
      TransferState.receiving => (Icons.downloading, tr('transfer.receiving')),
      TransferState.verifying => (Icons.verified_outlined, tr('transfer.verifying')),
      TransferState.saved => (Icons.check_circle, tr('common.saved')),
      TransferState.failed => (Icons.error_outline, t.error ?? tr('common.failed')),
    };
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(icon, color: t.state == TransferState.failed ? Theme.of(context).colorScheme.error : null),
      title: Text(t.fileName, overflow: TextOverflow.ellipsis),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 4),
          LinearProgressIndicator(value: t.state == TransferState.saved ? 1 : t.fraction),
          const SizedBox(height: 4),
          Text('${t.deviceName} · $label · ${formatBytes(t.received)}'
              '${t.total > 0 ? ' / ${formatBytes(t.total)}' : ''}'),
        ],
      ),
    );
  }
}
