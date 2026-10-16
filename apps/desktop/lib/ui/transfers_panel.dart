// apps/desktop/lib/ui/transfers_panel.dart
import 'package:flutter/material.dart';

import '../app_services.dart';
import '../l10n/l10n.dart';
import '../services/peers.dart';
import '../services/receive_hub.dart';
import 'app_nav.dart';
import 'receive_page.dart' show TransferTile;
import 'send_page.dart' show JobTile;
import 'theme.dart';

/// Transfers going on now (received and sent).
int activeTransfers(AppServices s) =>
    s.hub.transfers.where((t) => t.state == TransferState.receiving || t.state == TransferState.verifying).length +
    s.sender.jobs.where((j) => !j.over).length;

/// The title bar's "Transfers" button: how many are going on now.
class TransfersButton extends StatelessWidget {
  const TransfersButton({super.key, required this.services});

  final AppServices services;

  @override
  Widget build(BuildContext context) {
    final s = services;
    return ListenableBuilder(
      listenable: Listenable.merge([s.hub, s.sender]),
      builder: (context, _) {
        final n = activeTransfers(s);
        final color = n > 0 ? LrColors.safelight : LrColors.muted;
        // The title bar sits above the Navigator: give the button its own Material.
        return Material(
          type: MaterialType.transparency,
          child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 7),
          child: OutlinedButton.icon(
            style: OutlinedButton.styleFrom(
              foregroundColor: color,
              side: BorderSide(color: n > 0 ? LrColors.safelight : LrColors.line),
              padding: const EdgeInsets.symmetric(horizontal: 12),
              visualDensity: VisualDensity.compact,
            ),
            onPressed: () {
              final ctx = AppNav.instance.navigatorKey.currentContext;
              if (ctx != null) showTransfers(ctx, s);
            },
            icon: Icon(n > 0 ? Icons.swap_vert_circle_rounded : Icons.swap_vert_rounded, size: 18),
            label: Text(n > 0 ? tr('xfer.active', {'count': n}) : tr('xfer.title')),
          ),
          ),
        );
      },
    );
  }
}

/// Everything received and sent lately, in one panel at the top right.
Future<void> showTransfers(BuildContext context, AppServices s) => showGeneralDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierLabel: tr('xfer.title'),
      barrierColor: Colors.black26,
      pageBuilder: (ctx, _, _) => SafeArea(
        child: Align(
          alignment: Alignment.topRight,
          child: Padding(
            padding: const EdgeInsets.only(top: 8, right: 16),
            child: Material(
              color: LrColors.surface,
              elevation: 12,
              borderRadius: BorderRadius.circular(16),
              child: ConstrainedBox(
                constraints: BoxConstraints(maxWidth: 460, maxHeight: MediaQuery.of(ctx).size.height * 0.8),
                child: ListenableBuilder(
                  listenable: Listenable.merge([s.hub, s.sender]),
                  builder: (context, _) {
                    final received = s.hub.transfers;
                    final sent = s.sender.jobs;
                    return Padding(
                      padding: const EdgeInsets.fromLTRB(18, 14, 10, 14),
                      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                        Row(children: [
                          Expanded(child: Text(tr('xfer.title'), style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700))),
                          if (received.isNotEmpty || sent.any((j) => j.over))
                            TextButton(
                              onPressed: () {
                                s.hub.clearFinished();
                                s.sender.clearFinished();
                              },
                              child: Text(tr('common.clear_finished')),
                            ),
                          IconButton(tooltip: tr('common.close'), onPressed: () => Navigator.pop(ctx), icon: const Icon(Icons.close_rounded)),
                        ]),
                        if (received.isEmpty && sent.isEmpty)
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 24),
                            child: Text(tr('xfer.none'), style: const TextStyle(color: LrColors.muted)),
                          ),
                        Flexible(
                          child: ListView(shrinkWrap: true, padding: const EdgeInsets.only(right: 8), children: [
                            if (sent.isNotEmpty) ...[
                              _head(tr('xfer.sent')),
                              for (final SendJob j in sent.reversed)
                                JobTile(job: j, onCancel: () => s.sender.cancel(j), onResend: () => s.sender.resend(j)),
                            ],
                            if (received.isNotEmpty) ...[
                              _head(tr('xfer.received')),
                              for (final t in received) TransferTile(t: t),
                            ],
                          ]),
                        ),
                      ]),
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      ),
    );

Widget _head(String t) => Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 6),
      child: Text(t, style: const TextStyle(color: LrColors.muted, fontSize: 13, fontWeight: FontWeight.w600)),
    );
