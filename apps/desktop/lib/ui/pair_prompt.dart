// apps/desktop/lib/ui/pair_prompt.dart
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:localroll_core/localroll_core.dart';
import 'package:window_manager/window_manager.dart';

import '../l10n/l10n.dart';
import '../server/transfer_server.dart';
import 'app_nav.dart';
import 'device_badge.dart';
import 'theme.dart';

/// Shows an Allow / Deny dialog for each phone that taps this PC.
class PairPrompter {
  PairPrompter(this.server) {
    server.pairRequests.addListener(_onChange);
  }

  final TransferServer server;
  final Set<String> _shown = {};

  void dispose() => server.pairRequests.removeListener(_onChange);

  void _onChange() {
    for (final p in server.pairRequests.value) {
      if (_shown.add(p.id)) _show(p);
    }
  }

  Future<void> _show(PendingPair p) async {
    // The window may be minimised (started with Windows) or behind others:
    // bring it to the front so the Allow / Deny question is actually seen.
    try {
      if (await windowManager.isMinimized()) await windowManager.restore();
      await windowManager.show();
      await windowManager.setAlwaysOnTop(true);
      await windowManager.focus();
      Future<void>.delayed(const Duration(seconds: 2), () => windowManager.setAlwaysOnTop(false));
    } catch (_) {}
    final ctx = AppNav.instance.navigatorKey.currentContext;
    if (ctx == null) return;
    final allow = await showDialog<bool>(
      context: ctx,
      barrierDismissible: false,
      builder: (_) => _PairDialog(request: p),
    );
    await server.answerPair(p, allow: allow == true);
  }
}

class _PairDialog extends StatefulWidget {
  const _PairDialog({required this.request});

  final PendingPair request;

  @override
  State<_PairDialog> createState() => _PairDialogState();
}

class _PairDialogState extends State<_PairDialog> {
  Timer? _timeout;

  @override
  void initState() {
    super.initState();
    // Nobody answered in time: close as "deny" (the phone sees "expired").
    final left = LrProtocol.pairApprovalTimeout - DateTime.now().difference(widget.request.created);
    _timeout = Timer(left.isNegative ? Duration.zero : left, () {
      if (mounted) Navigator.of(context).pop(false);
    });
  }

  @override
  void dispose() {
    _timeout?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.request;
    final theme = Theme.of(context);
    return AlertDialog(
      contentPadding: const EdgeInsets.fromLTRB(28, 28, 28, 8),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 380),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            DeviceBadge(icon: 'phone', color: p.device.color ?? LrColors.verified.toARGB32(), size: 64),
            const SizedBox(height: 16),
            Text(tr('pair.ask', {'name': p.device.name}),
                textAlign: TextAlign.center, style: theme.textTheme.titleLarge),
            const SizedBox(height: 20),
            // The same three symbols are on the phone.
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
              decoration: BoxDecoration(
                color: LrColors.ink,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: LrColors.line),
              ),
              child: Text(p.emoji.join('  '), style: const TextStyle(fontSize: 40)),
            ),
            const SizedBox(height: 12),
            Text(tr('pair.check'), textAlign: TextAlign.center, style: theme.textTheme.bodySmall),
          ],
        ),
      ),
      actionsAlignment: MainAxisAlignment.center,
      actions: [
        OutlinedButton(onPressed: () => Navigator.of(context).pop(false), child: Text(tr('pair.deny'))),
        FilledButton(onPressed: () => Navigator.of(context).pop(true), child: Text(tr('pair.allow'))),
      ],
    );
  }
}
