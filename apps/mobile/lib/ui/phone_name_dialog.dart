// apps/mobile/lib/ui/phone_name_dialog.dart
import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import '../services/discovery.dart';
import '../services/mobile_settings.dart';
import '../services/phone_names.dart';

/// "This phone's name": the phone's own name, a random pleasant one, or
/// one of the person's own (the last two followed by iPhone / Android).
Future<void> editPhoneName(BuildContext context, MobileSettings settings, DesktopDiscovery discovery) async {
  final own = await PhoneNames.systemName();
  if (!context.mounted) return;
  final device = PhoneNames.device;
  final ctrl = TextEditingController(text: PhoneNames.baseOf(settings.deviceName));
  final offered = <String>{settings.deviceName};
  final name = await showDialog<String>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, set) {
        final shown = PhoneNames.withDevice(ctrl.text);
        return AlertDialog(
          title: Text(tr('phone.name_title')),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: ctrl,
                  autofocus: true,
                  maxLength: 30,
                  textCapitalization: TextCapitalization.words,
                  onChanged: (_) => set(() {}),
                  onSubmitted: (_) => Navigator.pop(ctx, PhoneNames.withDevice(ctrl.text)),
                  decoration: InputDecoration(suffixText: ' $device'),
                ),
                Text(tr('phone.shown_as', {'name': shown}), style: Theme.of(ctx).textTheme.bodySmall),
                const SizedBox(height: 12),
                Wrap(spacing: 8, runSpacing: 8, children: [
                  OutlinedButton.icon(
                    onPressed: () {
                      final n = PhoneNames.random(avoid: offered);
                      offered.add(n);
                      ctrl.text = PhoneNames.baseOf(n);
                      set(() {});
                    },
                    icon: const Icon(Icons.casino_rounded, size: 18),
                    label: Text(tr('phone.name_random')),
                  ),
                  OutlinedButton.icon(
                    onPressed: () => Navigator.pop(ctx, own),
                    icon: const Icon(Icons.smartphone_rounded, size: 18),
                    label: Text(tr('phone.use_own', {'name': own})),
                  ),
                ]),
                const SizedBox(height: 10),
                Text(tr('phone.name_explain'), style: Theme.of(ctx).textTheme.bodySmall),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: Text(tr('common.cancel'))),
            FilledButton(
              onPressed: ctrl.text.trim().isEmpty ? null : () => Navigator.pop(ctx, PhoneNames.withDevice(ctrl.text)),
              child: Text(tr('common.ok')),
            ),
          ],
        );
      },
    ),
  );
  ctrl.dispose();
  if (name == null || name.trim().isEmpty) return;
  await PhoneNames.rename(settings, discovery, name);
}
