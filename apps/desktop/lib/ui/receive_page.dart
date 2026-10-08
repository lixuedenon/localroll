// apps/desktop/lib/ui/receive_page.dart
import 'dart:ui' show FontFeature;

import 'package:flutter/material.dart';
import 'package:localroll_core/localroll_core.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../app_services.dart';
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
      appBar: AppBar(title: const Text('接收手机文件')),
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
              Text('接收服务没有启动', style: theme.textTheme.titleMedium),
              const SizedBox(height: 8),
              Text(s.server.error ?? '未知错误'),
              const SizedBox(height: 12),
              FilledButton(onPressed: s.startNetworking, child: const Text('重试')),
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
                  Text('用手机上的 LocalRoll 扫码配对', style: theme.textTheme.titleLarge),
                  const SizedBox(height: 8),
                  const Text('手机和电脑连同一个 Wi-Fi。配对一次后，以后打开手机 App 会自动找到这台电脑。'),
                  const SizedBox(height: 20),
                  Text('或在手机上输入配对码', style: theme.textTheme.labelLarge),
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
                        tooltip: '换一个配对码',
                        onPressed: s.server.rotatePin,
                        icon: const Icon(Icons.refresh),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Text(
                    hosts.isEmpty
                        ? '没有检测到局域网地址，请检查网络连接'
                        : '本机地址：${hosts.map((h) => '$h:${s.server.port}').join('   ')}',
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
                        label: const Text('刷新地址'),
                      ),
                      OutlinedButton.icon(
                        onPressed: () async {
                          final ok = await addFirewallRules(s.server.port);
                          if (!context.mounted) return;
                          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                            content: Text(ok ? '防火墙规则已添加' : '没有添加（可能取消了管理员授权）'),
                          ));
                        },
                        icon: const Icon(Icons.shield_outlined),
                        label: const Text('手机连不上？允许防火墙'),
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
                Text('传输记录', style: theme.textTheme.titleMedium),
                const Spacer(),
                if (list.isNotEmpty)
                  TextButton(onPressed: hub.clearFinished, child: const Text('清除已完成')),
              ],
            ),
            if (list.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 24),
                child: Text('还没有收到文件'),
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
      TransferState.receiving => (Icons.downloading, '接收中'),
      TransferState.verifying => (Icons.verified_outlined, '校验中'),
      TransferState.saved => (Icons.check_circle, '已保存'),
      TransferState.failed => (Icons.error_outline, t.error ?? '失败'),
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
