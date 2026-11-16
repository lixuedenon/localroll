// apps/desktop/lib/ui/firewall_prompt.dart
import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import '../services/firewall_guard.dart';
import 'app_nav.dart';
import 'light_look.dart';
import 'lr_dialog.dart';

/// "Let other devices send files to this PC": asked when Windows' firewall
/// doesn't let Keepnear in (first run, or a rule was removed).
Future<void> askFirewall() async {
  final context = AppNav.instance.navigatorKey.currentContext;
  if (context == null || !context.mounted) return;
  final yes = await showLrDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (c) => AlertDialog(
      icon: const Icon(Icons.shield_rounded, color: LightLook.blue, size: 34),
      title: Text(tr('fw.title')),
      content: SizedBox(width: 440, child: Text(tr('fw.body'))),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c, false), child: Text(tr('fw.later'))),
        FilledButton(onPressed: () => Navigator.pop(c, true), child: Text(tr('fw.allow'))),
      ],
    ),
  );
  if (yes == true) {
    await fixFirewall();
  } else {
    FirewallGuard.instance.later();
  }
}

/// One click: Windows asks "allow changes?", then others can send here.
Future<void> fixFirewall() async {
  final ok = await FirewallGuard.instance.fix();
  final context = AppNav.instance.navigatorKey.currentContext;
  if (context == null || !context.mounted) return;
  ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(tr(ok ? 'fw.fixed' : 'fw.not_fixed'))));
}
