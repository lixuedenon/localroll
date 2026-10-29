// apps/desktop/lib/ui/screen/screen_page.dart
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../../app_services.dart';
import '../../l10n/l10n.dart';
import '../../services/network.dart';
import '../../services/peers.dart';
import '../../services/win_dialogs.dart';
import '../convert_dialog.dart';
import '../files_view.dart';
import '../format.dart';
import '../player/player_entry.dart';
import '../player/player_page.dart';
import '../player/snapshot.dart';
import '../send_page.dart';
import '../theme.dart';
import 'pen_bar.dart';
import 'screen_record.dart';

/// "Record screen" on the left: what to record (the whole screen, a
/// window, an area, or explaining a video in the player at its own
/// quality), and the recordings made so far.
class ScreenPage extends StatefulWidget {
  const ScreenPage({super.key, required this.services});

  final AppServices services;

  @override
  State<ScreenPage> createState() => _ScreenPageState();
}

class _ScreenPageState extends State<ScreenPage> {
  List<File> _made = const [];

  AppServices get s => widget.services;

  @override
  void initState() {
    super.initState();
    _reload();
    ScreenRecorder.instance.addListener(_onRecorder);
  }

  @override
  void dispose() {
    ScreenRecorder.instance.removeListener(_onRecorder);
    super.dispose();
  }

  bool _was = false;

  /// A recording just ended: its file shows up here.
  void _onRecorder() {
    final now = ScreenRecorder.instance.recording;
    if (_was && !now) Future<void>.delayed(const Duration(seconds: 3), _reload);
    _was = now;
    if (mounted) setState(() {});
  }

  /// Recordings and explanations, newest first.
  void _reload() {
    final out = <File>[];
    for (final dir in {Snapshots.folder(s, screen: true), Snapshots.folder(s, narration: true)}) {
      try {
        for (final e in Directory(dir).listSync()) {
          if (e is File && e.path.toLowerCase().endsWith('.mp4')) out.add(e);
        }
      } catch (_) {}
    }
    out.sort((a, b) => b.statSync().modified.compareTo(a.statSync().modified));
    if (mounted) setState(() => _made = out.take(40).toList());
  }

  Future<void> _record(ScreenMode mode) async {
    final su = await showScreenSetup(context, s, initial: mode);
    if (su != null) await ScreenRecorder.instance.begin(su);
  }

  /// Explain a video / photo: choose it, the player opens and records.
  Future<void> _explain() async {
    final recent = [for (final r in s.player.recent) if (File(r.path).existsSync()) r].take(8).toList();
    final path = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('screen.explain_pick')),
        content: SizedBox(
          width: 460,
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(tr('screen.explain_tip'), style: const TextStyle(color: LrColors.muted, fontSize: 12.5, height: 1.5)),
            const SizedBox(height: 12),
            if (recent.isNotEmpty) ...[
              Text(tr('player.recent'), style: const TextStyle(color: LrColors.muted)),
              const SizedBox(height: 4),
              for (final r in recent)
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(r.video ? Icons.movie_rounded : Icons.image_rounded),
                  title: Text(r.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                  onTap: () => Navigator.pop(ctx, r.path),
                ),
            ],
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(tr('common.cancel'))),
          FilledButton.icon(
            onPressed: () async {
              final picked = await WinDialogs.pickFiles(
                title: tr('player.open_files'),
                typeLabel: tr('player.file_types'),
                extensions: [...playerImageExtensions, ...playerVideoExtensions],
              );
              if (picked.isNotEmpty && ctx.mounted) Navigator.pop(ctx, picked.first);
            },
            icon: const Icon(Icons.file_open_rounded, size: 18),
            label: Text(tr('player.open_files')),
          ),
        ],
      ),
    );
    if (path == null || !mounted) return;
    await openInPlayer(context, s, [path], record: true);
  }

  Future<void> _send(File f) async {
    final lib = s.library;
    final root = '${lib.rootPath}${Platform.pathSeparator}';
    final item = lib.rootPath.isNotEmpty && f.path.toLowerCase().startsWith(root.toLowerCase())
        ? lib.findByRel(f.path.substring(root.length).replaceAll(Platform.pathSeparator, '/'))
        : null;
    final name = f.path.split(Platform.pathSeparator).last;
    final file = item != null ? SendFile.fromLibrary(lib, item) : SendFile.plain(f, name);
    if (file != null && mounted) await sendToPc(context, s, [file], name);
  }

  Future<void> _convert(File f) async {
    final lib = s.library;
    final root = '${lib.rootPath}${Platform.pathSeparator}';
    final item = lib.rootPath.isNotEmpty && f.path.toLowerCase().startsWith(root.toLowerCase())
        ? lib.findByRel(f.path.substring(root.length).replaceAll(Platform.pathSeparator, '/'))
        : null;
    await convertWithDialog(context, s, items: [?item], path: item == null ? f.path : null, video: true);
  }

  Widget _choice(IconData icon, String title, String tip, VoidCallback onTap, {bool special = false}) => SizedBox(
        width: 250,
        child: Material(
          color: LrColors.surface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: BorderSide(color: special ? LrColors.safelight : LrColors.line),
          ),
          child: InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: ScreenRecorder.instance.recording ? null : onTap,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Icon(icon, size: 30, color: special ? LrColors.safelight : LrColors.danger),
                const SizedBox(height: 10),
                Text(title, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                const SizedBox(height: 6),
                Text(tip, style: const TextStyle(color: LrColors.muted, fontSize: 12.5, height: 1.45)),
              ]),
            ),
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: ListView(
        padding: const EdgeInsets.fromLTRB(28, 22, 28, 28),
        children: [
          Row(children: [
            Text(tr('nav.screen'), style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(width: 14),
            Expanded(child: Text(tr('screen.page_hint'), overflow: TextOverflow.ellipsis, style: const TextStyle(color: LrColors.muted, fontSize: 13))),
          ]),
          const SizedBox(height: 18),
          Wrap(spacing: 14, runSpacing: 14, children: [
            _choice(Icons.desktop_windows_rounded, tr('screen.mode_screen'), tr('screen.choice_screen'), () => _record(ScreenMode.screen)),
            _choice(Icons.web_asset_rounded, tr('screen.mode_window'), tr('screen.choice_window'), () => _record(ScreenMode.window)),
            _choice(Icons.crop_rounded, tr('screen.mode_area'), tr('screen.choice_area'), () => _record(ScreenMode.area)),
            _choice(Icons.record_voice_over_rounded, tr('screen.mode_explain'), tr('screen.choice_explain'), _explain, special: true),
            _choice(Icons.draw_rounded, tr('pen.only'), tr('pen.only_tip'), () => unawaited(PenSession.instance.start())),
          ]),
          const SizedBox(height: 12),
          Text(tr('screen.keys_tip'), style: const TextStyle(color: LrColors.muted, fontSize: 12.5, height: 1.5)),
          const SizedBox(height: 26),
          Row(children: [
            Text(tr('screen.made'), style: theme.textTheme.titleMedium),
            const Spacer(),
            IconButton(tooltip: tr('common.refresh'), onPressed: _reload, icon: const Icon(Icons.refresh_rounded)),
          ]),
          const SizedBox(height: 8),
          if (_made.isEmpty)
            Text(tr('screen.made_empty'), style: const TextStyle(color: LrColors.muted))
          else
            Wrap(spacing: 12, runSpacing: 12, children: [for (final f in _made) _tile(f)]),
        ],
      ),
    );
  }

  Widget _tile(File f) {
    final st = f.statSync();
    final name = f.path.split(Platform.pathSeparator).last;
    return SizedBox(
      width: 220,
      child: Material(
        color: LrColors.surface,
        borderRadius: BorderRadius.circular(12),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => unawaited(openInPlayer(context, s, [f.path])),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            AspectRatio(
              aspectRatio: 16 / 9,
              child: FileThumb(
                key: ValueKey(f.path),
                path: f.path,
                size: st.size,
                modified: st.modified,
                services: s,
                icon: const Icon(Icons.movie_rounded, color: LrColors.muted),
                box: 220,
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 8, 4, 6),
              child: Row(children: [
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12.5)),
                    Text('${formatBytes(st.size)} · ${st.modified.month}/${st.modified.day} ${st.modified.hour}:${st.modified.minute.toString().padLeft(2, '0')}',
                        style: const TextStyle(color: LrColors.muted, fontSize: 11.5)),
                  ]),
                ),
                PopupMenuButton<String>(
                  tooltip: tr('ink.more'),
                  onSelected: (v) {
                    if (v == 'send') unawaited(_send(f));
                    if (v == 'convert') unawaited(_convert(f));
                    if (v == 'reveal') revealInExplorer(f.path);
                  },
                  itemBuilder: (_) => [
                    PopupMenuItem(value: 'send', child: Text(tr('player.send'))),
                    PopupMenuItem(value: 'convert', child: Text(tr('convert.menu'))),
                    PopupMenuItem(value: 'reveal', child: Text(tr('common.show_in_folder'))),
                  ],
                ),
              ]),
            ),
          ]),
        ),
      ),
    );
  }
}
