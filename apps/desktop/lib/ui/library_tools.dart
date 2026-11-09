// apps/desktop/lib/ui/library_tools.dart
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:localroll_core/localroll_core.dart';

import '../app_services.dart';
import '../l10n/l10n.dart';
import '../services/library_index.dart';
import '../services/network.dart' show revealInExplorer;
import '../services/text_index.dart';
import '../services/win_dialogs.dart';
import 'format.dart';
import 'media_thumb.dart';
import 'theme.dart';
import 'trash_actions.dart';

// Library helpers that work on this PC only (no AI service, no cost):
// cleaning suggestions, a package for AI assistants, a backup check-up.

// ------------------------------------------------------------- cleaning

/// What could go to free space: the same file twice, burst shots (all but
/// the largest of each burst), old screenshots, the largest videos.
Future<void> showCleanup(BuildContext context, AppServices s) async {
  final items = s.library.items;
  final now = DateTime.now().millisecondsSinceEpoch;
  // The same content twice (kept once: the oldest).
  final bySha = <String, List<MediaItem>>{};
  for (final i in items) {
    if (i.sha256 != null) (bySha[i.sha256!] ??= []).add(i);
  }
  final dupes = [
    for (final g in bySha.values)
      if (g.length > 1) ...(g..sort((a, b) => a.receivedMs.compareTo(b.receivedMs))).skip(1),
  ];
  // Bursts: photos from one device within 2 seconds of each other.
  final photos = [for (final i in items) if (i.kind == MediaKind.image && i.captureMs > 0) i]..sort((a, b) => a.captureMs.compareTo(b.captureMs));
  final burst = <MediaItem>[];
  var run = <MediaItem>[];
  void flush() {
    if (run.length > 2) {
      final keep = run.reduce((a, b) => a.size >= b.size ? a : b);
      burst.addAll(run.where((i) => i != keep));
    }
    run = [];
  }

  for (final p in photos) {
    if (run.isNotEmpty && (p.captureMs - run.last.captureMs > 2000 || p.deviceId != run.last.deviceId)) flush();
    run.add(p);
  }
  flush();
  // Screenshots older than 30 days.
  bool shot(MediaItem i) {
    final n = i.name.toLowerCase();
    return n.contains('screenshot') || n.contains('截屏') || n.contains('截图') || n.contains('screen shot');
  }

  final shots = [for (final i in items) if (i.kind == MediaKind.image && shot(i) && now - i.receivedMs > const Duration(days: 30).inMilliseconds) i];
  final videos = [for (final i in items) if (i.kind == MediaKind.video) i]..sort((a, b) => b.size.compareTo(a.size));
  final big = videos.take(20).where((v) => v.size > 200 * 1024 * 1024).toList();
  if (!context.mounted) return;
  await showDialog<void>(context: context, builder: (_) => _Cleanup(s: s, groups: [('clean.dupes', dupes), ('clean.bursts', burst), ('clean.shots', shots), ('clean.big', big)]));
}

class _Cleanup extends StatefulWidget {
  const _Cleanup({required this.s, required this.groups});

  final AppServices s;
  final List<(String, List<MediaItem>)> groups;

  @override
  State<_Cleanup> createState() => _CleanupState();
}

class _CleanupState extends State<_Cleanup> {
  final Set<MediaItem> _picked = {};
  final Set<String> _open = {};

  /// One suggestion: its picture (click: see it bigger), ticked = delete.
  Widget _thumb(MediaItem i) {
    final on = _picked.contains(i);
    return Tooltip(
      message: '${i.name} · ${formatBytes(i.size)}',
      child: SizedBox(
        width: 64,
        height: 64,
        child: Stack(fit: StackFit.expand, children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: GestureDetector(
              onTap: () => _preview(i),
              child: Opacity(
                opacity: on ? 1 : 0.45,
                child: MediaThumb(key: ValueKey(i.relPath), item: i, library: widget.s.library, ffmpeg: widget.s.ffmpeg),
              ),
            ),
          ),
          Positioned(
            right: 2,
            top: 2,
            child: GestureDetector(
              onTap: () => setState(() => on ? _picked.remove(i) : _picked.add(i)),
              child: Icon(on ? Icons.check_circle : Icons.radio_button_unchecked_rounded,
                  size: 20, color: on ? LrColors.safelight : Colors.white, shadows: const [Shadow(color: Colors.black54, blurRadius: 4)]),
            ),
          ),
          if (i.kind == MediaKind.video)
            const Positioned(left: 3, bottom: 2, child: Icon(Icons.play_circle_fill_rounded, size: 16, color: Colors.white)),
        ]),
      ),
    );
  }

  void _preview(MediaItem i) => showDialog<void>(
        context: context,
        builder: (c) => Dialog(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 820, maxHeight: 560),
              child: i.kind == MediaKind.image && const {'jpg', 'jpeg', 'png', 'gif', 'webp', 'bmp'}.contains(i.name.split('.').last.toLowerCase())
                  ? Image.file(File(widget.s.library.absPath(i)), fit: BoxFit.contain)
                  : SizedBox(width: 640, height: 480, child: MediaThumb(item: i, library: widget.s.library, ffmpeg: widget.s.ffmpeg)),
            ),
            Padding(padding: const EdgeInsets.all(10), child: Text('${i.name} · ${formatBytes(i.size)}')),
          ]),
        ),
      );

  @override
  void initState() {
    super.initState();
    // Duplicates and burst extras are picked to start with; the rest asked.
    _picked
      ..addAll(widget.groups[0].$2)
      ..addAll(widget.groups[1].$2);
  }

  int get _bytes => _picked.fold<int>(0, (n, i) => n + i.size);

  @override
  Widget build(BuildContext context) => AlertDialog(
        icon: const Icon(Icons.cleaning_services_rounded, size: 30),
        title: Text(tr('clean.title')),
        content: SizedBox(
          width: 560,
          height: 460,
          child: ListView(children: [
            Text(tr('clean.intro'), style: const TextStyle(color: LrColors.muted)),
            for (final (key, list) in widget.groups) ...[
              const SizedBox(height: 10),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: list.isNotEmpty && list.every(_picked.contains),
                onChanged: list.isEmpty ? null : (v) => setState(() => v == true ? _picked.addAll(list) : _picked.removeAll(list)),
                title: Text(tr(key, {'count': list.length, 'size': formatBytes(list.fold<int>(0, (n, i) => n + i.size))})),
              ),
              if (list.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(left: 40),
                  child: Wrap(spacing: 6, runSpacing: 6, children: [
                    for (final i in list.take(_open.contains(key) ? list.length : 12)) _thumb(i),
                    if (list.length > 12 && !_open.contains(key))
                      InkWell(
                        onTap: () => setState(() => _open.add(key)),
                        borderRadius: BorderRadius.circular(6),
                        child: Container(
                          width: 64,
                          height: 64,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(color: Colors.white10, borderRadius: BorderRadius.circular(6)),
                          child: Text('+${list.length - 12}', style: const TextStyle(fontWeight: FontWeight.w700)),
                        ),
                      ),
                  ]),
                ),
            ],
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: Text(tr('common.cancel'))),
          FilledButton.icon(
            onPressed: _picked.isEmpty
                ? null
                : () async {
                    final n = await deleteToTrash(context, widget.s, media: _picked.toList());
                    if (n > 0 && context.mounted) Navigator.pop(context);
                  },
            icon: const Icon(Icons.delete_outline_rounded),
            label: Text(tr('clean.delete', {'count': _picked.length, 'size': formatBytes(_bytes)})),
          ),
        ],
      );
}

// ------------------------------------------------------------- AI package

/// The chosen files, copied into one folder (and a .zip of it) with an
/// index: names, dates, sizes and the words found in them — easy to hand
/// to an AI assistant. Made here; nothing is uploaded.
Future<void> packForAi(BuildContext context, AppServices s, List<MediaItem> media, List<String> files) async {
  if (media.isEmpty && files.isEmpty) return;
  final where = await WinDialogs.pickFolder(title: tr('aipack.where'));
  if (where == null) return;
  final sep = Platform.pathSeparator;
  final stamp = DateTime.now();
  final name = 'Keepnear-AI-${stamp.year}${stamp.month.toString().padLeft(2, '0')}${stamp.day.toString().padLeft(2, '0')}-${stamp.hour.toString().padLeft(2, '0')}${stamp.minute.toString().padLeft(2, '0')}';
  final dir = Directory('$where$sep$name');
  await dir.create(recursive: true);
  final idx = s.server.textIndex;
  await idx.load();
  final md = StringBuffer('# $name\n\n${tr('aipack.readme')}\n\n');
  var k = 0;
  Future<void> add(String path, String title, int size, DateTime? when, String key) async {
    k++;
    final dest = '${dir.path}$sep${k.toString().padLeft(3, '0')}-${sanitizeFileName(title)}';
    try {
      await File(path).copy(dest);
    } catch (_) {
      return;
    }
    md.writeln('## $k. $title');
    md.writeln('- ${tr('aipack.size')}: ${formatBytes(size)}');
    if (when != null) md.writeln('- ${tr('aipack.date')}: ${when.toIso8601String().substring(0, 16).replaceAll('T', ' ')}');
    final text = idx[key]?.text.trim() ?? '';
    if (text.isNotEmpty) {
      md.writeln('- ${tr('aipack.text')}:');
      md.writeln('');
      md.writeln('```');
      md.writeln(text.length > 4000 ? '${text.substring(0, 4000)}…' : text);
      md.writeln('```');
    }
    md.writeln('');
  }

  for (final i in media) {
    await add(s.library.absPath(i), i.name, i.size, DateTime.fromMillisecondsSinceEpoch(i.captureMs > 0 ? i.captureMs : i.receivedMs), TextIndex.mediaKey(i));
  }
  for (final p in files) {
    final f = File(p);
    final size = f.existsSync() ? f.lengthSync() : 0;
    await add(p, f.uri.pathSegments.last, size, f.existsSync() ? f.lastModifiedSync() : null,
        TextIndex.fileKey(s.server.files.relOf(p) ?? p, size));
  }
  await File('${dir.path}${sep}index.md').writeAsString(md.toString());
  // And a .zip of it (Windows' own PowerShell), one file to drag into a chat.
  try {
    await Process.run('powershell', ['-NoProfile', '-Command', 'Compress-Archive -Path "${dir.path}\\*" -DestinationPath "${dir.path}.zip" -Force']);
  } catch (_) {}
  DiagLog.log('library', 'AI package made ($k files)');
  if (context.mounted) {
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(
      content: Text(tr('aipack.done', {'count': k})),
      action: SnackBarAction(label: tr('common.show_in_folder'), onPressed: () => revealInExplorer(File('${dir.path}.zip').existsSync() ? '${dir.path}.zip' : dir.path)),
    ));
  }
}

// ------------------------------------------------------------- backup report

/// A check-up: for each phone, how many of its photos are here and when it
/// last sent any; what could be wrong (no backup for a week, missing files).
Future<void> showBackupReport(BuildContext context, AppServices s) async {
  final items = s.library.items;
  final now = DateTime.now();
  final rows = <(String, int, int, DateTime?)>[]; // name, count, bytes, last
  for (final t in s.settings.trusted.values) {
    if (isDesktopPlatform(t.platform)) continue;
    var n = 0, bytes = 0, last = 0;
    for (final i in items) {
      if (i.deviceId == t.id) {
        n++;
        bytes += i.size;
        if (i.receivedMs > last) last = i.receivedMs;
      }
    }
    rows.add((t.name, n, bytes, last == 0 ? null : DateTime.fromMillisecondsSinceEpoch(last)));
  }
  final total = items.fold<int>(0, (n, i) => n + i.size);
  final noHash = items.where((i) => i.sha256 == null).length;
  final missing = s.library.pendingMissing.length;
  if (!context.mounted) return;
  await showDialog<void>(
    context: context,
    builder: (c) => AlertDialog(
      icon: const Icon(Icons.health_and_safety_rounded, size: 30, color: LrColors.verified),
      title: Text(tr('report.title')),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(tr('report.library', {'count': items.length, 'size': formatBytes(total)})),
            const SizedBox(height: 12),
            if (rows.isEmpty) Text(tr('report.no_phones'), style: const TextStyle(color: LrColors.muted)),
            for (final (name, n, bytes, last) in rows)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(
                  last != null && now.difference(last).inDays < 7 ? Icons.check_circle_rounded : Icons.warning_amber_rounded,
                  color: last != null && now.difference(last).inDays < 7 ? LrColors.verified : LrColors.safelight,
                ),
                title: Text(name),
                subtitle: Text(last == null
                    ? tr('report.never')
                    : tr('report.phone', {'count': n, 'size': formatBytes(bytes), 'days': now.difference(last).inDays})),
              ),
            const Divider(),
            if (missing > 0) Text('⚠ ${tr('report.missing', {'count': missing})}', style: const TextStyle(color: LrColors.safelight)),
            if (noHash > 0) Text(tr('report.nohash', {'count': noHash}), style: const TextStyle(color: LrColors.muted, fontSize: 13)),
            if (missing == 0) Text('✓ ${tr('report.files_ok')}', style: const TextStyle(color: LrColors.verified)),
            const SizedBox(height: 8),
            Text(tr('report.tip'), style: const TextStyle(color: LrColors.muted, fontSize: 12)),
          ]),
        ),
      ),
      actions: [FilledButton(onPressed: () => Navigator.pop(c), child: Text(tr('common.ok')))],
    ),
  );
}
