// apps/mobile/lib/ui/simple_home.dart
import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import '../services/auto_sender.dart';
import '../services/mobile_settings.dart';
import 'device_badge.dart';
import 'theme.dart';

/// Simple mode (for elders): big text, the PC, one status line and one big
/// button. New photos also go by themselves (auto-send is on).
class SimpleHome extends StatelessWidget {
  const SimpleHome({
    super.key,
    required this.settings,
    required this.auto,
    required this.onConnect,
    required this.onSettings,
    required this.onPick,
  });

  final MobileSettings settings;
  final AutoSender auto;
  final VoidCallback onConnect;
  final VoidCallback onSettings;
  final VoidCallback onPick;

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    // Bigger text, but never smaller than what the phone already uses.
    final scale = (mq.textScaler.scale(16) / 16).clamp(1.3, 2.0).toDouble();
    return MediaQuery(
      data: mq.copyWith(textScaler: TextScaler.linear(scale)),
      child: Scaffold(
        appBar: AppBar(
          title: const Text('LocalRoll'),
          actions: [
            IconButton(
              tooltip: tr('settings.title'),
              onPressed: onSettings,
              icon: const Icon(Icons.settings_rounded),
            ),
          ],
        ),
        body: SafeArea(
          child: ListenableBuilder(
            listenable: Listenable.merge([settings, auto]),
            builder: (context, _) {
              final d = settings.current;
              return ListView(
                padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
                children: d == null ? _noPc(context) : _withPc(context, d),
              );
            },
          ),
        ),
      ),
    );
  }

  List<Widget> _noPc(BuildContext context) => [
        const SizedBox(height: 48),
        const Icon(Icons.computer_rounded, size: 96, color: LrColors.muted),
        const SizedBox(height: 24),
        Text(tr('simple.no_pc'), textAlign: TextAlign.center, style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 32),
        _bigButton(icon: Icons.add_link_rounded, label: tr('home.connect_pc'), onPressed: onConnect),
      ];

  List<Widget> _withPc(BuildContext context, PairedDesktop d) {
    final theme = Theme.of(context);
    final up = auto.uploader;
    final (IconData icon, Color color, String status) = switch (auto.state) {
      AutoState.sending => (
          Icons.bolt_rounded,
          LrColors.safelight,
          tr('auto.sending', {'done': up?.doneCount ?? 0, 'total': auto.pending, 'pc': d.name}),
        ),
      AutoState.waiting => (
          Icons.cloud_off_rounded,
          LrColors.safelight,
          '${tr('auto.waiting', {'count': auto.pending, 'pc': d.name})}\n${tr('auto.waiting_hint')}',
        ),
      AutoState.done => (Icons.verified_rounded, LrColors.verified, tr('auto.done', {'count': auto.lastSent, 'pc': d.name})),
      AutoState.idle => (Icons.verified_rounded, LrColors.verified, tr('simple.all_sent', {'pc': d.name})),
    };
    return [
      const SizedBox(height: 8),
      Center(
        child: DeviceBadge(
          icon: d.icon,
          color: d.color,
          image: d.avatarUrl == null ? null : NetworkImage(d.avatarUrl!),
          size: 96,
        ),
      ),
      const SizedBox(height: 12),
      Text(d.name, textAlign: TextAlign.center, style: theme.textTheme.headlineSmall),
      const SizedBox(height: 24),
      Container(
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          color: LrColors.surface,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: color.withValues(alpha: 0.6), width: 1.5),
        ),
        child: Column(
          children: [
            Row(children: [
              Icon(icon, color: color, size: 36),
              const SizedBox(width: 14),
              Expanded(child: Text(status, style: theme.textTheme.titleMedium)),
            ]),
            if (auto.state == AutoState.sending && up != null) ...[
              const SizedBox(height: 14),
              LinearProgressIndicator(
                value: auto.pending == 0 ? null : (up.doneCount + up.skippedCount) / auto.pending,
                minHeight: 10,
                borderRadius: BorderRadius.circular(5),
              ),
            ],
          ],
        ),
      ),
      const SizedBox(height: 28),
      _bigButton(
        icon: Icons.send_rounded,
        label: tr('simple.send_now'),
        onPressed: auto.state == AutoState.sending ? null : auto.check,
      ),
      const SizedBox(height: 16),
      _bigButton(icon: Icons.photo_library_rounded, label: tr('simple.pick'), onPressed: onPick, outlined: true),
      const SizedBox(height: 32),
      Center(
        child: TextButton(
          onPressed: () => settings.setSimpleMode(false),
          child: Text(tr('simple.exit')),
        ),
      ),
    ];
  }

  Widget _bigButton({
    required IconData icon,
    required String label,
    required VoidCallback? onPressed,
    bool outlined = false,
  }) {
    final style = ButtonStyle(
      minimumSize: const WidgetStatePropertyAll(Size.fromHeight(72)),
      shape: WidgetStatePropertyAll(RoundedRectangleBorder(borderRadius: BorderRadius.circular(20))),
      textStyle: const WidgetStatePropertyAll(TextStyle(fontSize: 20, fontWeight: FontWeight.w600)),
    );
    final child = Icon(icon, size: 30);
    return outlined
        ? OutlinedButton.icon(style: style, onPressed: onPressed, icon: child, label: Text(label))
        : FilledButton.icon(style: style, onPressed: onPressed, icon: child, label: Text(label));
  }
}
