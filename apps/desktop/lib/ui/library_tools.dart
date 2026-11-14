// apps/desktop/lib/ui/library_tools.dart
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:localroll_core/localroll_core.dart';

import '../app_services.dart';
import '../l10n/l10n.dart';
import '../services/library_index.dart';
import '../services/network.dart' show revealInExplorer;
import '../services/text_index.dart';
import '../services/win_dialogs.dart';
import 'format.dart';
import 'light_dialog.dart';
import 'light_look.dart';
import 'media_thumb.dart';
import 'trash_actions.dart';
import 'lr_dialog.dart';

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
  await showLrDialog<void>(context: context, builder: (_) => _Cleanup(s: s, groups: [('clean.dupes', dupes), ('clean.bursts', burst), ('clean.shots', shots), ('clean.big', big)]));
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
  Widget _thumb(MediaItem i, List<MediaItem> list) {
    final on = _picked.contains(i);
    return Tooltip(
      message: '${i.name} · ${formatBytes(i.size)}',
      child: SizedBox(
        width: 84,
        height: 84,
        child: Stack(fit: StackFit.expand, children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: GestureDetector(
              onTap: () => _preview(list, list.indexOf(i)),
              // Clear to see what it is; ticked to delete: dimmed and framed red.
              child: Container(
                foregroundDecoration: on
                    ? BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.45),
                        border: Border.all(color: LightLook.red, width: 2.5),
                        borderRadius: BorderRadius.circular(6),
                      )
                    : null,
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
                  size: 20, color: on ? LightLook.red : Colors.white, shadows: const [Shadow(color: Colors.black54, blurRadius: 4)]),
            ),
          ),
          if (i.kind == MediaKind.video)
            const Positioned(left: 3, bottom: 2, child: Icon(Icons.play_circle_fill_rounded, size: 16, color: Colors.white)),
        ]),
      ),
    );
  }

  /// Bigger, with ← / → through this group, and its tick.
  void _preview(List<MediaItem> list, int at) => showLrDialog<void>(
        context: context,
        builder: (c) => _Preview(
          s: widget.s,
          list: list,
          at: at,
          picked: _picked,
          onToggle: (i) => setState(() => _picked.contains(i) ? _picked.remove(i) : _picked.add(i)),
        ),
      );

  int get _bytes => _picked.fold<int>(0, (n, i) => n + i.size);

  @override
  Widget build(BuildContext context) => LightDialog(
        icon: Icons.cleaning_services_rounded,
        title: tr('clean.title'),
        subtitle: tr('clean.intro'),
        width: 640,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
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
                    for (final i in list.take(_open.contains(key) ? list.length : 12)) _thumb(i, list),
                    if (list.length > 12 && !_open.contains(key))
                      InkWell(
                        onTap: () => setState(() => _open.add(key)),
                        borderRadius: BorderRadius.circular(6),
                        child: Container(
                          width: 64,
                          height: 64,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(color: const Color(0xFFE6ECF5), borderRadius: BorderRadius.circular(6)),
                          child: Text('+${list.length - 12}', style: const TextStyle(fontWeight: FontWeight.w700)),
                        ),
                      ),
                  ]),
                ),
            ],
          ]),
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

/// A check-up: for each phone, how many of its photos are here, when it
/// last sent any, how many it still has (as it reported); "Back up now".
Future<void> showBackupReport(BuildContext context, AppServices s) async {
  if (!context.mounted) return;
  await showLrDialog<void>(context: context, builder: (c) => _BackupReport(s: s));
}

class _BackupReport extends StatefulWidget {
  const _BackupReport({required this.s});

  final AppServices s;

  @override
  State<_BackupReport> createState() => _BackupReportState();
}

class _BackupReportState extends State<_BackupReport> {
  final Set<String> _asked = {};

  @override
  Widget build(BuildContext context) {
    final s = widget.s;
    return ListenableBuilder(
      listenable: Listenable.merge([s.transferLog, s.server]),
      builder: (context, _) {
        final items = s.library.items;
        final now = DateTime.now();
        final rows = <(String, String, int, int, DateTime?)>[]; // id, name, count, bytes, last
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
          rows.add((t.id, t.name, n, bytes, last == 0 ? null : DateTime.fromMillisecondsSinceEpoch(last)));
        }
        final total = items.fold<int>(0, (n, i) => n + i.size);
        final noHash = items.where((i) => i.sha256 == null).length;
        final missing = s.library.pendingMissing.length;
        final needing = rows.where((r) => r.$5 == null || now.difference(r.$5!).inDays >= 7).length;
        final pendingAll = rows.fold<int>(0, (n, r) => n + (s.transferLog.backup[r.$1]?.pending ?? 0));
        Widget stat(String n, String label, {Color? color}) => Expanded(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(14)),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(n, style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: color ?? LightLook.text)),
                  Text(label, style: const TextStyle(fontSize: 12.5, color: LightLook.muted)),
                ]),
              ),
            );
        return LightDialog(
          icon: Icons.health_and_safety_rounded,
          title: tr('report.title'),
          subtitle: [
            tr('report.library', {'count': items.length, 'size': formatBytes(total)}),
            if (missing == 0) tr('report.files_ok'),
          ].join(' · '),
          actions: [FilledButton(onPressed: () => Navigator.pop(context), child: Text(tr('common.ok')))],
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              stat('${rows.length}', tr('report.n_phones')),
              const SizedBox(width: 10),
              stat('$needing', tr('report.n_need'), color: needing > 0 ? LightLook.amberText : null),
              const SizedBox(width: 10),
              stat('$pendingAll', tr('report.n_left')),
            ]),
            const SizedBox(height: 12),
            if (rows.isEmpty) Text(tr('report.no_phones'), style: const TextStyle(color: LightLook.muted)),
            for (final (id, name, n, bytes, last) in rows) _phone(context, id, name, n, bytes, last, now),
            if (missing > 0)
              Text('⚠ ${tr('report.missing', {'count': missing})}', style: const TextStyle(color: LightLook.red)),
            if (noHash > 0) Text(tr('report.nohash', {'count': noHash}), style: const TextStyle(color: LightLook.muted, fontSize: 12.5)),
            const SizedBox(height: 4),
            Text(tr('report.tip2'), style: const TextStyle(color: LightLook.muted, fontSize: 12)),
          ]),
        );
      },
    );
  }

  Widget _phone(BuildContext context, String id, String name, int n, int bytes, DateTime? last, DateTime now) {
    final s = widget.s;
    final days = last == null ? null : now.difference(last).inDays;
    final rep = s.transferLog.backup[id];
    final online = s.phoneTarget(id) != null || s.isOnline(id);
    final sub = [
      if (last != null) tr('report.have', {'count': n, 'size': formatBytes(bytes)}) else tr('report.never'),
      if (rep != null)
        tr('report.left', {'count': rep.pending, 'when': formatWhen(rep.when)})
      else if (last != null)
        tr('report.not_reported'),
    ].join(' · ');
    final chip = days == null
        ? LightChip.grey(tr('report.chip_never'))
        : days >= 7
            ? LightChip.warn(tr('report.chip_days', {'days': days}))
            : LightChip.ok(tr('report.chip_ok'));
    final asked = _asked.contains(id);
    return LightRow(
      icon: Icons.smartphone_rounded,
      iconBg: days == null ? const Color(0xFFECEFF3) : const Color(0xFFE6F0FF),
      title: name,
      sub: sub,
      trailing: Column(crossAxisAlignment: CrossAxisAlignment.end, mainAxisSize: MainAxisSize.min, children: [
        chip,
        const SizedBox(height: 6),
        SizedBox(
          height: 30,
          child: FilledButton.tonalIcon(
            style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 12), visualDensity: VisualDensity.compact),
            onPressed: asked
                ? null
                : () {
                    final now = s.server.askBackup(id);
                    setState(() => _asked.add(id));
                    ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(
                      content: Text(tr(now ? 'report.asked' : 'report.asked_later', {'name': name})),
                      duration: const Duration(seconds: 6),
                    ));
                  },
            icon: Icon(asked ? Icons.check_rounded : Icons.cloud_upload_rounded, size: 16),
            label: Text(tr(asked ? (online ? 'report.asked_short' : 'report.later_short') : 'report.backup_now')),
          ),
        ),
      ]),
    );
  }
}

class _Preview extends StatefulWidget {
  const _Preview({required this.s, required this.list, required this.at, required this.picked, required this.onToggle});

  final AppServices s;
  final List<MediaItem> list;
  final int at;
  final Set<MediaItem> picked;
  final void Function(MediaItem) onToggle;

  @override
  State<_Preview> createState() => _PreviewState();
}

class _PreviewState extends State<_Preview> {
  late int _at = widget.at;
  final FocusNode _focus = FocusNode();

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  void _go(int d) {
    final n = (_at + d).clamp(0, widget.list.length - 1);
    if (n != _at) setState(() => _at = n);
  }

  void _toggle(MediaItem i) {
    widget.onToggle(i);
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final i = widget.list[_at];
    final on = widget.picked.contains(i);
    final still = i.kind == MediaKind.image && const {'jpg', 'jpeg', 'png', 'gif', 'webp', 'bmp'}.contains(i.name.split('.').last.toLowerCase());
    Widget arrow(IconData icon, int d, bool enabled) => IconButton.filledTonal(
          iconSize: 28,
          onPressed: enabled ? () => _go(d) : null,
          icon: Icon(icon),
        );
    return KeyboardListener(
      focusNode: _focus,
      autofocus: true,
      onKeyEvent: (e) {
        if (e is! KeyDownEvent) return;
        if (e.logicalKey == LogicalKeyboardKey.arrowLeft) _go(-1);
        if (e.logicalKey == LogicalKeyboardKey.arrowRight) _go(1);
        if (e.logicalKey == LogicalKeyboardKey.space) _toggle(i);
      },
      child: Dialog(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Row(mainAxisSize: MainAxisSize.min, children: [
              arrow(Icons.chevron_left_rounded, -1, _at > 0),
              const SizedBox(width: 8),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 820, maxHeight: 560),
                child: still
                    ? Image.file(File(widget.s.library.absPath(i)), key: ValueKey(i.relPath), fit: BoxFit.contain)
                    : SizedBox(
                        width: 640,
                        height: 480,
                        child: MediaThumb(key: ValueKey(i.relPath), item: i, library: widget.s.library, ffmpeg: widget.s.ffmpeg),
                      ),
              ),
              const SizedBox(width: 8),
              arrow(Icons.chevron_right_rounded, 1, _at < widget.list.length - 1),
            ]),
            const SizedBox(height: 10),
            Row(mainAxisSize: MainAxisSize.min, children: [
              Text('${_at + 1} / ${widget.list.length}', style: const TextStyle(fontWeight: FontWeight.w700)),
              const SizedBox(width: 14),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: Text('${i.name} · ${formatBytes(i.size)}', maxLines: 1, overflow: TextOverflow.ellipsis),
              ),
              const SizedBox(width: 14),
              FilterChip(selected: on, onSelected: (_) => _toggle(i), label: Text(tr(on ? 'clean.will_delete' : 'clean.keep'))),
            ]),
          ]),
        ),
      ),
    );
  }
}
