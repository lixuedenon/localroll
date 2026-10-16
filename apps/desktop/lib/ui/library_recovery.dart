// apps/desktop/lib/ui/library_recovery.dart
import 'dart:io';

import 'package:flutter/material.dart';

import '../app_services.dart';
import '../l10n/l10n.dart';
import '../services/library_index.dart';
import '../services/win_dialogs.dart';
import 'theme.dart';

/// The library folder can't be reached. Two cases:
///  * its drive is unplugged → wait (it resumes by itself), or point to
///    where it is now;
///  * the folder itself is gone (deleted or moved) → find it in the Recycle
///    Bin, point to where it was moved, or start again with an empty one
///    (phones then see those items as not backed up and can send them
///    again).
class LibraryRecovery extends StatefulWidget {
  const LibraryRecovery({super.key, required this.services});

  final AppServices services;

  @override
  State<LibraryRecovery> createState() => _LibraryRecoveryState();
}

class _LibraryRecoveryState extends State<LibraryRecovery> {
  bool _busy = false;
  bool _binHint = false;

  LibraryIndex get _lib => widget.services.library;

  Future<void> _run(Future<void> Function() f) async {
    setState(() => _busy = true);
    try {
      await f();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _openBin() async {
    await Process.run('explorer.exe', ['shell:RecycleBinFolder']);
    if (mounted) setState(() => _binHint = true);
  }

  /// "It was moved": pick where it is now (or any folder to use instead).
  Future<void> _relocate() async {
    final dir = await WinDialogs.pickFolder(title: tr('recover.use_folder'));
    if (dir == null || !mounted) return;
    if (!await LibraryIndex.isLibraryFolder(dir)) {
      if (!mounted) return;
      final ok = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: Text(tr('recover.not_library_title')),
          content: Text(tr('recover.not_library_body', {'path': dir})),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: Text(tr('common.cancel'))),
            FilledButton(onPressed: () => Navigator.pop(c, true), child: Text(tr('recover.use_anyway'))),
          ],
        ),
      );
      if (ok != true) return;
    }
    await _run(() => widget.services.changeLibrary(dir));
    if (mounted && !_lib.offline) _toast(tr('recover.moved_done', {'path': dir}));
  }

  /// Start again here, empty.
  Future<void> _recreate() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        icon: const Icon(Icons.create_new_folder_outlined, size: 32),
        title: Text(tr('recover.recreate_title')),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460),
          child: Text(tr('recover.recreate_body', {'path': _lib.rootPath})),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: Text(tr('common.cancel'))),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: Text(tr('recover.recreate'))),
        ],
      ),
    );
    if (ok != true) return;
    var n = 0;
    await _run(() async => n = await _lib.recreate());
    if (!mounted) return;
    _toast(_lib.offline ? tr('recover.failed') : tr('recover.recreated', {'count': n}));
  }

  void _toast(String text) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final gone = _lib.loss == LibraryLoss.gone;
    final color = theme.colorScheme.error;
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(gone ? Icons.folder_off_rounded : Icons.usb_off_rounded, color: color),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(tr(gone ? 'recover.gone_title' : 'recover.unplugged_title'),
                  style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
              const SizedBox(height: 4),
              Text(tr(gone ? 'recover.gone_body' : 'recover.unplugged_body', {'path': _lib.rootPath}),
                  style: theme.textTheme.bodyMedium),
              if (_binHint) ...[
                const SizedBox(height: 8),
                Text(tr('recover.bin_hint'), style: const TextStyle(color: LrColors.safelight)),
              ],
            ]),
          ),
          if (_busy) const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
        ]),
        const SizedBox(height: 12),
        Wrap(spacing: 8, runSpacing: 8, alignment: WrapAlignment.end, children: [
          TextButton(onPressed: _busy ? null : () => _run(_lib.retry), child: Text(tr('common.retry'))),
          if (gone)
            OutlinedButton.icon(
              onPressed: _busy ? null : _openBin,
              icon: const Icon(Icons.delete_outline_rounded, size: 18),
              label: Text(tr('recover.open_bin')),
            ),
          OutlinedButton.icon(
            onPressed: _busy ? null : _relocate,
            icon: const Icon(Icons.drive_file_move_outline, size: 18),
            label: Text(tr('recover.relocate')),
          ),
          if (gone)
            FilledButton.icon(
              onPressed: _busy ? null : _recreate,
              icon: const Icon(Icons.create_new_folder_outlined, size: 18),
              label: Text(tr('recover.recreate')),
            ),
        ]),
      ]),
    );
  }
}
