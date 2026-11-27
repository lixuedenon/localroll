// apps/desktop/lib/ui/copy_in_ui.dart
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../app_services.dart';
import '../l10n/l10n.dart';
import '../services/bg_tasks.dart';
import '../services/copy_in.dart';
import '../services/network.dart';
import 'app_nav.dart';

/// Copies [paths] into the library (each where its kind belongs) as a
/// background task, then says what happened.
Future<void> copyIntoLibrary(AppServices s, List<String> paths) async {
  final list = [for (final p in paths) if (CopyIn.outside(s, p)) p];
  if (list.isEmpty) {
    // All of them are in the library already.
    final ctx = AppNav.instance.navigatorKey.currentContext;
    if (paths.isNotEmpty && ctx != null && ctx.mounted) {
      ScaffoldMessenger.maybeOf(ctx)?.showSnackBar(SnackBar(content: Text(tr('copyin.inside'))));
    }
    return;
  }
  final r = await BgTasks.instance.run<CopyInResult>(
    title: tr('copyin.working', {'count': list.length}),
    open: () => AppNav.instance.selectTab(AppNav.library),
    job: (t) => CopyIn.copy(s, list, progress: (d, all) => t.setProgress(all == 0 ? 1 : d / all)),
  );
  if (r == null) return;
  final ctx = AppNav.instance.navigatorKey.currentContext;
  if (ctx == null || !ctx.mounted) return;
  final parts = <String>[
    if (r.added.isNotEmpty) tr('copyin.added', {'count': r.added.length, 'photos': r.photos, 'docs': r.docs, 'others': r.others}),
    if (r.had.isNotEmpty) tr('copyin.had', {'count': r.had.length}),
    if (r.failed.isNotEmpty) tr('copyin.failed', {'names': r.failed.take(5).join('、')}),
  ];
  final show = r.added.isNotEmpty ? r.added.first : (r.had.isNotEmpty ? r.had.first : null);
  ScaffoldMessenger.maybeOf(ctx)?.showSnackBar(SnackBar(
    content: Text(parts.join('  ')),
    duration: const Duration(seconds: 8),
    action: show == null ? null : SnackBarAction(label: tr('copyin.show'), onPressed: () => unawaited(revealInExplorer(show))),
  ));
}

/// After opening files from outside the library: offers to copy them in.
void offerCopyIn(BuildContext context, AppServices s, List<String> paths) {
  final out = [for (final p in paths) if (File(p).existsSync() && CopyIn.outside(s, p)) p];
  if (out.isEmpty) return;
  ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(
    content: Text(out.length == 1 ? tr('copyin.offer_one') : tr('copyin.offer_many', {'count': out.length})),
    duration: const Duration(seconds: 12),
    showCloseIcon: true,
    action: SnackBarAction(label: tr('copyin.do'), onPressed: () => unawaited(copyIntoLibrary(s, out))),
  ));
}
