// apps/mobile/lib/ui/incoming.dart
import 'package:flutter/material.dart';
import 'package:localroll_core/localroll_core.dart';

import '../l10n/l10n.dart';
import '../services/media_saver.dart';
import '../services/phone_server.dart';
import 'breathing.dart';
import 'theme.dart';

/// Ready-made reasons for declining (keys in the language files).
const List<String> declineReasonKeys = [
  'reason.later',
  'reason.no_space',
  'reason.too_big',
  'reason.wrong_person',
  'reason.have_it',
];

/// Longest reason one can type.
const int maxReasonLength = 100;

/// "X wants to send you N items": Accept / Decline / Decline with a reason.
Future<IncomingReply> askIncoming(BuildContext context, IncomingAsk ask) async {
  final pc = isDesktopPlatform(ask.from.platform);
  final reply = await showDialog<IncomingReply>(
    context: context,
    barrierDismissible: false,
    builder: (c) => AlertDialog(
      icon: Icon(pc ? Icons.computer_rounded : Icons.smartphone_rounded, size: 36, color: onlineGlow),
      title: Text(tr('incoming.title', {'name': ask.from.name})),
      content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(tr('incoming.body', {'count': ask.count})),
        // Names and ids can be copied by anyone on the Wi‑Fi: say so unless
        // it is a PC paired with this phone that proved it.
        if (!ask.verified) ...[
          const SizedBox(height: 12),
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Icon(Icons.gpp_maybe_outlined, size: 20, color: LrColors.safelight),
            const SizedBox(width: 8),
            Expanded(child: Text(tr('incoming.unverified'), style: Theme.of(c).textTheme.bodySmall)),
          ]),
        ],
      ]),
      actionsOverflowDirection: VerticalDirection.up,
      actionsOverflowButtonSpacing: 4,
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(c, const IncomingReply(accept: false)),
          child: Text(tr('incoming.decline')),
        ),
        TextButton(
          onPressed: () async {
            final reason = await askDeclineReason(c);
            if (reason != null && c.mounted) Navigator.pop(c, IncomingReply(accept: false, reason: reason));
          },
          child: Text(tr('incoming.decline_reason')),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(c, const IncomingReply(accept: true)),
          child: Text(tr('incoming.accept')),
        ),
      ],
    ),
  );
  return reply ?? const IncomingReply(accept: false);
}

/// Pick a ready-made reason or write one. Null when cancelled.
Future<String?> askDeclineReason(BuildContext context) {
  final ctrl = TextEditingController();
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    builder: (c) => Padding(
      padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + MediaQuery.of(c).viewInsets.bottom),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(tr('reason.title'), style: Theme.of(c).textTheme.titleMedium),
        const SizedBox(height: 12),
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (final k in declineReasonKeys)
            ActionChip(label: Text(tr(k)), onPressed: () => Navigator.pop(c, tr(k))),
        ]),
        const SizedBox(height: 16),
        TextField(
          controller: ctrl,
          maxLength: maxReasonLength,
          maxLines: 2,
          minLines: 1,
          decoration: InputDecoration(hintText: tr('reason.own'), border: const OutlineInputBorder()),
        ),
        const SizedBox(height: 8),
        FilledButton(
          onPressed: () {
            final t = ctrl.text.trim();
            if (t.isNotEmpty) Navigator.pop(c, t);
          },
          child: Text(tr('reason.send')),
        ),
      ]),
    ),
  );
}

/// "Received N items from X" — where to find them.
Future<void> showReceived(BuildContext context, Receiving r, {VoidCallback? onOpen}) => showDialog<void>(
      context: context,
      builder: (c) => AlertDialog(
        icon: const Icon(Icons.check_circle_rounded, color: LrColors.verified, size: 44),
        title: Text(tr('received.title', {'count': r.done, 'name': r.from.name})),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (r.toAlbum > 0) Text(tr('received.album', {'count': r.toAlbum, 'album': MediaSaver.albumFor(Sender(r.from.id, r.from.name))})),
          if (r.toFiles > 0) ...[
            const SizedBox(height: 6),
            Text(tr(Theme.of(c).platform == TargetPlatform.iOS ? 'received.files_ios' : 'received.files_android',
                {'count': r.toFiles, 'folder': MediaSaver.albumName})),
          ],
        ]),
        actions: [
          if (onOpen != null)
            TextButton(
              onPressed: () {
                Navigator.pop(c);
                onOpen();
              },
              child: Text(tr('mylib.view')),
            ),
          FilledButton(onPressed: () => Navigator.pop(c), child: Text(tr('common.ok'))),
        ],
      ),
    );

/// On the home screen while something arrives.
class ReceivingBanner extends StatelessWidget {
  const ReceivingBanner({super.key, required this.server});

  final PhoneServer server;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: server,
      builder: (context, _) {
        final r = server.receiving;
        if (r == null) return const SizedBox.shrink();
        final frac = r.size > 0 ? (r.bytes / r.size).clamp(0.0, 1.0) : null;
        return Padding(
          padding: const EdgeInsets.only(top: 10),
          child: Breathing(
            online: true,
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  const Icon(Icons.download_rounded, color: onlineGlow, size: 20),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(tr('received.receiving', {'name': r.from.name, 'done': r.done, 'total': r.total}),
                        style: const TextStyle(fontWeight: FontWeight.w600)),
                  ),
                ]),
                if (r.file != null) ...[
                  const SizedBox(height: 6),
                  Text(r.file!, maxLines: 1, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.bodySmall),
                  const SizedBox(height: 6),
                  LinearProgressIndicator(value: frac, minHeight: 4, borderRadius: BorderRadius.circular(2)),
                ],
              ]),
            ),
          ),
        );
      },
    );
  }
}
