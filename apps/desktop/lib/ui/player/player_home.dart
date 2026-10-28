// apps/desktop/lib/ui/player/player_home.dart
import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';

import '../../app_services.dart';
import '../../l10n/l10n.dart';
import '../../services/annotations.dart';
import '../../services/player_memory.dart';
import '../../services/win_dialogs.dart';
import '../app_nav.dart';
import '../files_view.dart';
import '../media_thumb.dart';
import '../theme.dart';
import 'player_entry.dart';
import 'player_page.dart';

/// "Player" on the left: continue where you left off, open photos and
/// videos from anywhere on this PC (or drop them on the window), recent.
class PlayerHome extends StatelessWidget {
  const PlayerHome({super.key, required this.services});

  final AppServices services;

  Future<void> _openFiles(BuildContext context) async {
    final paths = await WinDialogs.pickFiles(
      title: tr('player.open_files'),
      typeLabel: tr('player.file_types'),
      extensions: [...playerImageExtensions, ...playerVideoExtensions],
    );
    if (paths.isEmpty || !context.mounted) return;
    await openInPlayer(context, services, paths);
  }

  Future<void> _openFolder(BuildContext context) async {
    final folder = await WinDialogs.pickFolder(title: tr('player.open_folder'));
    if (folder == null || !context.mounted) return;
    final paths = PlayerEntry.inFolder(folder);
    if (paths.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('player.folder_empty'))));
      return;
    }
    // The whole folder, from its first file.
    final entries = [for (final p in paths) ?PlayerEntry.fromPath(p, library: services.library)];
    if (entries.isEmpty || !context.mounted) return;
    await openPlayer(context, services, entries, 0);
  }

  /// A recent one: library items as they are now (they may have moved).
  PlayerEntry? _entryOf(RecentEntry r) {
    final lib = services.library;
    final rel = r.relPath;
    if (rel != null) {
      final i = lib.findByRel(rel);
      if (i != null) return PlayerEntry.fromItem(lib, i);
    }
    return PlayerEntry.fromPath(r.path, library: lib);
  }

  Future<void> _openRecent(BuildContext context, RecentEntry r) async {
    final e = _entryOf(r);
    if (e == null) {
      services.player.forget(r.path);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('player.missing'))));
      return;
    }
    if (e.item != null) {
      await openPlayer(context, services, [e], 0);
    } else {
      await openInPlayer(context, services, [e.path]);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final m = services.player;
    return ListenableBuilder(
      listenable: m,
      builder: (context, _) {
        final last = m.last;
        final at = m.lastKey == null ? null : m.positionOf(m.lastKey!);
        final recent = m.recent;
        return Scaffold(
          body: ListView(
            padding: const EdgeInsets.fromLTRB(28, 22, 28, 28),
            children: [
              Row(children: [
                Text(tr('nav.player'), style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700)),
                const SizedBox(width: 14),
                Expanded(
                  child: Text(tr('player.hint'), overflow: TextOverflow.ellipsis, style: const TextStyle(color: LrColors.muted, fontSize: 13)),
                ),
              ]),
              const SizedBox(height: 18),
              Wrap(spacing: 12, runSpacing: 12, children: [
                FilledButton.icon(
                  onPressed: () => _openFiles(context),
                  icon: const Icon(Icons.file_open_rounded),
                  label: Text(tr('player.open_files')),
                ),
                OutlinedButton.icon(
                  onPressed: () => _openFolder(context),
                  icon: const Icon(Icons.folder_open_rounded),
                  label: Text(tr('player.open_folder')),
                ),
                OutlinedButton.icon(
                  onPressed: () => AppNav.instance.selectTab(AppNav.screen),
                  icon: const Icon(Icons.screenshot_monitor_rounded, color: LrColors.danger),
                  label: Text(tr('screen.button')),
                ),
              ]),
              const SizedBox(height: 10),
              Text(tr('player.drop_hint'), style: const TextStyle(color: LrColors.muted, fontSize: 12.5)),
              const SizedBox(height: 22),
              _NoteSearch(services: services),
              if (last != null && at != null) ...[
                const SizedBox(height: 26),
                Text(tr('player.resume'), style: theme.textTheme.titleMedium),
                const SizedBox(height: 10),
                _ResumeCard(
                  services: services,
                  recent: last,
                  at: at,
                  entry: _entryOf(last),
                  onTap: () => _openRecent(context, last),
                ),
              ],
              const SizedBox(height: 26),
              Row(children: [
                Text(tr('player.recent'), style: theme.textTheme.titleMedium),
                const Spacer(),
                if (recent.isNotEmpty) TextButton(onPressed: m.clearRecent, child: Text(tr('player.clear_recent'))),
              ]),
              const SizedBox(height: 10),
              if (recent.isEmpty)
                Text(tr('player.recent_empty'), style: const TextStyle(color: LrColors.muted))
              else
                Wrap(spacing: 10, runSpacing: 10, children: [
                  for (final r in recent)
                    _RecentTile(
                      key: ValueKey(r.path),
                      services: services,
                      recent: r,
                      entry: _entryOf(r),
                      onTap: () => _openRecent(context, r),
                      onForget: () => m.forget(r.path),
                    ),
                ]),
            ],
          ),
        );
      },
    );
  }
}

Widget _thumb(AppServices s, PlayerEntry? e, double box) {
  final icon = Container(
    color: LrColors.raised,
    alignment: Alignment.center,
    child: Icon(e?.video ?? false ? Icons.movie_rounded : Icons.image_rounded, color: LrColors.muted),
  );
  if (e == null) return icon;
  final item = e.item;
  if (item != null) return MediaThumb(key: ValueKey(item.relPath), item: item, library: s.library, ffmpeg: s.ffmpeg);
  return FileThumb(
    key: ValueKey(e.path),
    path: e.path,
    size: e.size,
    modified: DateTime.fromMillisecondsSinceEpoch(e.modifiedMs),
    services: s,
    icon: icon,
    box: box,
  );
}

class _ResumeCard extends StatelessWidget {
  const _ResumeCard({required this.services, required this.recent, required this.at, required this.entry, required this.onTap});

  final AppServices services;
  final RecentEntry recent;
  final Duration at;
  final PlayerEntry? entry;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Align(
        alignment: Alignment.centerLeft,
        child: Material(
          color: LrColors.surface,
          borderRadius: BorderRadius.circular(12),
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: onTap,
            child: Container(
              width: 460,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(borderRadius: BorderRadius.circular(12), border: Border.all(color: LrColors.line)),
              child: Row(children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: SizedBox(width: 128, height: 72, child: _thumb(services, entry, 128)),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(recent.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600)),
                    const SizedBox(height: 4),
                    Text(tr('player.resume_at', {'time': playerTime(at)}), style: const TextStyle(color: LrColors.muted, fontSize: 12.5)),
                  ]),
                ),
                const Icon(Icons.play_circle_fill_rounded, size: 36, color: LrColors.safelight),
                const SizedBox(width: 6),
              ]),
            ),
          ),
        ),
      );
}

class _RecentTile extends StatelessWidget {
  const _RecentTile({
    super.key,
    required this.services,
    required this.recent,
    required this.entry,
    required this.onTap,
    required this.onForget,
  });

  final AppServices services;
  final RecentEntry recent;
  final PlayerEntry? entry;
  final VoidCallback onTap;
  final VoidCallback onForget;

  Future<void> _menu(BuildContext context, Offset at) async {
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final choice = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(at & const Size(1, 1), Offset.zero & overlay.size),
      items: [
        PopupMenuItem(value: 'open', child: Text(tr('lib.open'))),
        PopupMenuItem(value: 'forget', child: Text(tr('player.remove_recent'))),
      ],
    );
    if (!context.mounted) return;
    if (choice == 'open') onTap();
    if (choice == 'forget') onForget();
  }

  @override
  Widget build(BuildContext context) => Tooltip(
        message: recent.path,
        waitDuration: const Duration(milliseconds: 600),
        child: GestureDetector(
          onTap: onTap,
          onSecondaryTapUp: (d) => _menu(context, d.globalPosition),
          child: MouseRegion(
            cursor: SystemMouseCursors.click,
            child: SizedBox(
              width: 168,
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: SizedBox(
                    width: 168,
                    height: 112,
                    child: Stack(fit: StackFit.expand, children: [
                      Opacity(opacity: entry == null ? 0.4 : 1, child: _thumb(services, entry, 168)),
                      if (recent.video)
                        const Positioned(
                          right: 6,
                          bottom: 6,
                          child: Icon(Icons.play_circle_outline_rounded, color: Colors.white, size: 22),
                        ),
                    ]),
                  ),
                ),
                const SizedBox(height: 6),
                Text(recent.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12.5)),
                if (entry == null) Text(tr('player.missing'), style: const TextStyle(color: LrColors.muted, fontSize: 11)),
              ]),
            ),
          ),
        ),
      );
}

/// Files given on the command line / dropped on the window (paths that
/// exist), for [openInPlayer].
List<String> existingFiles(Iterable<String> paths) => [
      for (final p in paths)
        if (p.isNotEmpty && !p.startsWith('--') && File(p).existsSync()) p,
    ];

/// Photos and videos dragged from Explorer onto LocalRoll open in the
/// player, wherever in the app they are dropped.
class PlayerDropTarget extends StatefulWidget {
  const PlayerDropTarget({super.key, required this.services, required this.child});

  final AppServices services;
  final Widget child;

  @override
  State<PlayerDropTarget> createState() => _PlayerDropTargetState();
}

class _PlayerDropTargetState extends State<PlayerDropTarget> {
  bool _over = false;

  @override
  Widget build(BuildContext context) => DropTarget(
        onDragEntered: (_) => setState(() => _over = true),
        onDragExited: (_) => setState(() => _over = false),
        onDragDone: (d) {
          setState(() => _over = false);
          final paths = [for (final f in d.files) f.path];
          final media = [for (final p in existingFiles(paths)) if (PlayerEntry.playable(p)) p];
          if (media.isEmpty) {
            final ctx = AppNav.instance.navigatorKey.currentContext;
            if (ctx != null) ScaffoldMessenger.maybeOf(ctx)?.showSnackBar(SnackBar(content: Text(tr('player.nothing_playable'))));
            return;
          }
          PlayerLauncher.request(widget.services, media);
        },
        child: Stack(children: [
          Positioned.fill(child: widget.child),
          if (_over)
            Positioned.fill(
              child: IgnorePointer(
                child: Material(
                  type: MaterialType.transparency,
                  child: Container(
                  color: const Color(0xAA000000),
                  alignment: Alignment.center,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 20),
                    decoration: BoxDecoration(
                      color: LrColors.surface,
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: LrColors.safelight, width: 2),
                    ),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      const Icon(Icons.play_circle_outline_rounded, color: LrColors.safelight, size: 30),
                      const SizedBox(width: 12),
                      Text(tr('player.drop_here'), style: const TextStyle(fontSize: 16)),
                    ]),
                  ),
                ),
                ),
              ),
            ),
        ]),
      );
}

/// Search every annotation (library and other files on this PC): names,
/// typed words, tool names. A result opens at its moment.
class _NoteSearch extends StatefulWidget {
  const _NoteSearch({required this.services});

  final AppServices services;

  @override
  State<_NoteSearch> createState() => _NoteSearchState();
}

class _NoteSearchState extends State<_NoteSearch> {
  final TextEditingController _q = TextEditingController();

  @override
  void dispose() {
    _q.dispose();
    super.dispose();
  }

  Future<void> _open(NoteHit h) async {
    final s = widget.services;
    final lib = s.library;
    final set = h.set;
    PlayerEntry? inLibrary;
    if (set.rel != null) {
      final i = (set.sha != null ? lib.findSame(set.size, set.sha!) : null) ?? lib.findByRel(set.rel!);
      if (i != null) inLibrary = PlayerEntry.fromItem(lib, i);
    }
    final lead = h.note.startMs - s.player.leadSec * 1000;
    final int? at = set.video ? (lead < 0 ? 0 : lead) : null;
    if (inLibrary != null) {
      await openPlayer(context, s, [inLibrary], 0, startMs: at);
      return;
    }
    if (!File(set.path).existsSync()) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('player.missing'))));
      return;
    }
    await openInPlayer(context, s, [set.path], startMs: at);
  }

  String _time(int ms) => playerTime(Duration(milliseconds: ms));

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: widget.services.notes,
        builder: (context, _) {
          final searching = _q.text.trim().isNotEmpty;
          // Nothing typed: the latest annotations ("My notes").
          final hits = searching ? widget.services.notes.search(_q.text) : widget.services.notes.recent(10);
          return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SizedBox(
              width: 460,
              child: TextField(
                controller: _q,
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                  isDense: true,
                  prefixIcon: const Icon(Icons.search_rounded, size: 20),
                  hintText: tr('ink.search_all'),
                  border: const OutlineInputBorder(),
                  suffixIcon: _q.text.isEmpty
                      ? null
                      : IconButton(
                          onPressed: () => setState(_q.clear),
                          icon: const Icon(Icons.close_rounded, size: 18),
                        ),
                ),
              ),
            ),
            if (searching || hits.isNotEmpty) ...[
              const SizedBox(height: 8),
              if (!searching)
                Padding(
                  padding: const EdgeInsets.only(top: 10, bottom: 4),
                  child: Text(tr('player.my_notes'), style: Theme.of(context).textTheme.titleMedium),
                ),
              if (hits.isEmpty)
                Text(tr('ink.no_hits'), style: const TextStyle(color: LrColors.muted))
              else
                for (final h in hits.take(40))
                  SizedBox(
                    width: 460,
                    child: ListTile(
                      dense: true,
                      contentPadding: const EdgeInsets.symmetric(horizontal: 6),
                      leading: Icon(h.set.video ? Icons.movie_rounded : Icons.image_rounded, color: LrColors.muted),
                      title: Text(h.note.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                      subtitle: Text(
                        [h.set.name, if (h.set.video) _time(h.note.startMs)].join(' · '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: LrColors.muted),
                      ),
                      onTap: () => _open(h),
                    ),
                  ),
            ],
          ]);
        },
      );
}

