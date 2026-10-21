// apps/desktop/lib/ui/trash_actions.dart
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../app_services.dart';
import '../l10n/l10n.dart';
import '../services/library_index.dart';
import '../services/library_trash.dart';
import 'format.dart';

/// Deleting from the library, the same way everywhere: a question with how
/// many and how big, into "Recently deleted" (30 days), then 10 seconds to
/// undo. [media]: photos / videos (their Live Photo videos go along);
/// [files]: received files and converted copies (full paths).
/// Returns how many were deleted (0: cancelled).
Future<int> deleteToTrash(
  BuildContext context,
  AppServices s, {
  List<MediaItem> media = const [],
  List<String> files = const [],
}) async {
  final count = media.length + files.length;
  if (count == 0) return 0;
  final lib = s.library;
  var size = 0;
  for (final i in lib.withLive(media)) {
    size += i.size;
  }
  for (final p in files) {
    try {
      size += File(p).lengthSync();
    } catch (_) {}
  }
  final messenger = ScaffoldMessenger.of(context);
  final nav = Navigator.of(context);
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      icon: const Icon(Icons.delete_outline_rounded, size: 32),
      title: Text(tr('trash.confirm_title', {'count': count, 'size': formatBytes(size)})),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440),
        child: Text(tr('trash.confirm_body')),
      ),
      actions: [
        OutlinedButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('common.cancel'))),
        FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(tr('lib.delete'))),
      ],
    ),
  );
  if (ok != true || !context.mounted) return 0;

  // Many files: show how far it got (moving is quick, but thousands add up).
  final total = lib.withLive(media).length + files.length;
  final progress = ValueNotifier<(int, int)>((0, total));
  final showProgress = total >= 50;
  if (showProgress) {
    unawaited(showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => PopScope(
        canPop: false,
        child: AlertDialog(
          content: ValueListenableBuilder<(int, int)>(
            valueListenable: progress,
            builder: (_, v, _) => Column(mainAxisSize: MainAxisSize.min, children: [
              Text(tr('trash.deleting', {'done': v.$1, 'total': v.$2})),
              const SizedBox(height: 12),
              LinearProgressIndicator(value: v.$2 == 0 ? null : v.$1 / v.$2),
            ]),
          ),
        ),
      ),
    ));
  }
  final trash = s.server.trash;
  final made = <TrashEntry>[];
  try {
    final mediaTotal = lib.withLive(media).length;
    made.addAll(await trash.putMedia(media, onProgress: (d, _) => progress.value = (d, total)));
    made.addAll(await trash.putFiles(files, onProgress: (d, _) => progress.value = (mediaTotal + d, total)));
  } finally {
    if (showProgress) nav.pop();
    progress.dispose();
  }
  final missed = count - made.length;
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(
      duration: const Duration(seconds: 10),
      content: Text([
        tr('trash.deleted', {'count': made.length}),
        if (missed > 0) tr('trash.not_all', {'count': missed}),
      ].join('  ')),
      action: made.isEmpty
          ? null
          : SnackBarAction(
              label: tr('trash.undo'),
              onPressed: () async {
                final n = await trash.restore(made);
                messenger.showSnackBar(SnackBar(content: Text(tr('trash.restored', {'count': n}))));
              },
            ),
    ));
  return made.length;
}
