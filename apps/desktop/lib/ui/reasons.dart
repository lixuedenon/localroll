// apps/desktop/lib/ui/reasons.dart
import 'package:flutter/material.dart';

import '../l10n/l10n.dart';

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

/// "Decline with a reason": pick a ready-made one or write your own.
/// Returns the text, or null when cancelled.
Future<String?> askDeclineReason(BuildContext context) {
  final ctrl = TextEditingController();
  return showDialog<String>(
    context: context,
    builder: (c) => AlertDialog(
      title: Text(tr('reason.title')),
      content: SizedBox(
        width: 420,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
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
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c), child: Text(tr('common.cancel'))),
        FilledButton(
          onPressed: () {
            final t = ctrl.text.trim();
            if (t.isNotEmpty) Navigator.pop(c, t);
          },
          child: Text(tr('reason.send')),
        ),
      ],
    ),
  );
}
