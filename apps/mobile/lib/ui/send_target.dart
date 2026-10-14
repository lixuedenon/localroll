// apps/mobile/lib/ui/send_target.dart
import 'dart:async';

import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import '../services/discovery.dart';
import '../services/mobile_settings.dart';
import 'breathing.dart';
import 'device_badge.dart';
import 'theme.dart';

/// "Send to…": the PC this phone backs up to, or a phone nearby with
/// LocalRoll open (it will be asked to accept). Returns a [PairedDesktop],
/// a [NearbyPhone], or null.
Future<Object?> chooseSendTarget(BuildContext context, MobileSettings settings, DesktopDiscovery discovery) =>
    showModalBottomSheet<Object>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _TargetSheet(settings: settings, discovery: discovery),
    );

class _TargetSheet extends StatefulWidget {
  const _TargetSheet({required this.settings, required this.discovery});

  final MobileSettings settings;
  final DesktopDiscovery discovery;

  @override
  State<_TargetSheet> createState() => _TargetSheetState();
}

class _TargetSheetState extends State<_TargetSheet> {
  /// Phones that answered just now (mDNS can keep a killed one for a while).
  final Map<String, bool> _answers = {};
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    widget.discovery.addListener(_check);
    _check();
    _timer = Timer.periodic(const Duration(seconds: 6), (_) => _check());
  }

  @override
  void dispose() {
    _timer?.cancel();
    widget.discovery.removeListener(_check);
    super.dispose();
  }

  Future<void> _check() async {
    for (final p in widget.discovery.phones) {
      final ok = await phoneAnswers(p);
      if (!mounted) return;
      if (!ok && _answers[p.id] == false) widget.discovery.phoneGone(p.id);
      setState(() => _answers[p.id] = ok);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: widget.discovery,
      builder: (context, _) {
        final pcs = widget.settings.desktops;
        final phones = widget.discovery.phones;
        return SafeArea(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.75),
            child: ListView(
              shrinkWrap: true,
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              children: [
                Text(tr('send.choose_title'), style: theme.textTheme.titleLarge),
                const SizedBox(height: 14),
                if (pcs.isNotEmpty) ...[
                  Text(tr('send.my_pcs'), style: theme.textTheme.bodySmall),
                  const SizedBox(height: 6),
                  for (final d in pcs)
                    _tile(
                      online: widget.discovery.isOnline(d.id),
                      leading: DeviceBadge(icon: d.icon, color: d.color, size: 38),
                      title: d.name,
                      subtitle: widget.discovery.isOnline(d.id) ? tr('home.pc_online') : tr('home.pc_offline'),
                      onTap: () => Navigator.pop(context, d),
                    ),
                  const SizedBox(height: 10),
                ],
                Text(tr('send.nearby_phones'), style: theme.textTheme.bodySmall),
                const SizedBox(height: 6),
                if (phones.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Text(tr('send.no_phones'), style: const TextStyle(color: LrColors.muted)),
                  ),
                for (final p in phones)
                  _tile(
                    online: _answers[p.id] ?? true,
                    leading: CircleAvatar(
                      radius: 19,
                      backgroundColor: LrColors.raised,
                      child: Icon(p.platform == 'ios' ? Icons.phone_iphone_rounded : Icons.phone_android_rounded,
                          color: LrColors.muted),
                    ),
                    title: p.name,
                    subtitle: tr('send.phone_asks'),
                    onTap: () => Navigator.pop(context, p),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _tile({
    required bool online,
    required Widget leading,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) =>
      Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Breathing(
          online: online,
          child: Material(
            type: MaterialType.transparency,
            child: ListTile(
              onTap: onTap,
              leading: leading,
              title: Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
              subtitle: Text(subtitle, style: TextStyle(color: online ? onlineGlow : LrColors.muted, fontSize: 13)),
              trailing: const Icon(Icons.chevron_right_rounded),
            ),
          ),
        ),
      );
}
