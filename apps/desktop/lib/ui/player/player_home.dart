// apps/desktop/lib/ui/player/player_home.dart
import 'dart:async';
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
import '../format.dart';
import '../light_look.dart';
import '../media_thumb.dart';
import '../theme.dart';
import 'player_entry.dart';
import 'player_page.dart';

/// "Player" on the left: continue where you left off, open photos and
/// videos from anywhere on this PC (or drop them on the window), recent.
class PlayerHome extends StatelessWidget {
  const PlayerHome({super.key, required this.services});

  final AppServices services;

  String _title(String what) => '${tr('player.open_files')} · $what';

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
  Widget build(BuildContext context) => _PlayerHomeBody(home: this);
}

/// The light look (like the library): a header with the search and "Open
/// files", cards for what to open, recent ones as a grid, my notes.
class _PlayerHomeBody extends StatefulWidget {
  const _PlayerHomeBody({required this.home});

  final PlayerHome home;

  @override
  State<_PlayerHomeBody> createState() => _PlayerHomeBodyState();
}

class _PlayerHomeBodyState extends State<_PlayerHomeBody> {
  final TextEditingController _q = TextEditingController();
  bool _allRecent = false;

  PlayerHome get h => widget.home;
  AppServices get services => h.services;

  @override
  void dispose() {
    _q.dispose();
    super.dispose();
  }

  Future<void> _pick(Set<String> exts, String label) async {
    final paths = await WinDialogs.pickFiles(title: h._title(label), typeLabel: label, extensions: [...exts]);
    if (paths.isEmpty || !mounted) return;
    await openInPlayer(context, services, paths);
  }

  Widget _header() => Row(children: [
        const _PlayBadge(size: 76),
        const SizedBox(width: 20),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(tr('nav.player'),
                style: const TextStyle(fontSize: 34, fontWeight: FontWeight.w800, color: LightLook.text, letterSpacing: -0.5)),
            const SizedBox(height: 4),
            Text(tr('player.hint'), maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 15, color: LightLook.muted)),
          ]),
        ),
        const SizedBox(width: 16),
        SizedBox(
          width: 320,
          height: 50,
          child: TextField(
            controller: _q,
            onChanged: (_) => setState(() {}),
            textAlignVertical: TextAlignVertical.center,
            decoration: InputDecoration(
              filled: true,
              fillColor: Colors.white,
              contentPadding: EdgeInsets.zero,
              prefixIcon: const Icon(Icons.search_rounded, color: LightLook.muted),
              hintText: tr('ink.search_all'),
              hintStyle: const TextStyle(color: LightLook.muted, fontSize: 14),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(25), borderSide: const BorderSide(color: Color(0xFFDCE3F0))),
              enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(25), borderSide: const BorderSide(color: Color(0xFFDCE3F0))),
              suffixIcon: _q.text.isEmpty
                  ? null
                  : IconButton(onPressed: () => setState(_q.clear), icon: const Icon(Icons.close_rounded, size: 18)),
            ),
          ),
        ),
        const SizedBox(width: 14),
        SizedBox(
          height: 50,
          child: FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor: LightLook.blue,
              padding: const EdgeInsets.symmetric(horizontal: 24),
              shape: const StadiumBorder(),
              textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            ),
            onPressed: () => h._openFiles(context),
            icon: const Icon(Icons.add_rounded),
            label: Text(tr('player.open_files')),
          ),
        ),
      ]);

  Widget _kinds() {
    final cards = [
      _Kind(
        icon: Icons.image_rounded,
        colors: const [Color(0xFF4FC3F7), Color(0xFF1E88E5)],
        title: tr('player.kind_photo'),
        sub: 'JPG, PNG, HEIC…',
        onTap: () => _pick(playerImageExtensions, tr('player.kind_photo')),
      ),
      _Kind(
        icon: Icons.movie_rounded,
        colors: const [Color(0xFFB388FF), Color(0xFF7C4DFF)],
        title: tr('player.kind_video'),
        sub: 'MP4, MOV, MKV…',
        onTap: () => _pick(playerVideoExtensions, tr('player.kind_video')),
      ),
      _Kind(
        icon: Icons.photo_library_rounded,
        colors: const [Color(0xFF5B8CFF), Color(0xFF2F5BEA)],
        title: tr('nav.library'),
        sub: tr('player.file_types'),
        onTap: () => AppNav.instance.selectTab(AppNav.library),
      ),
      _Kind(
        icon: Icons.folder_rounded,
        colors: const [Color(0xFFFFCA28), Color(0xFFFB8C00)],
        title: tr('player.open_folder'),
        sub: tr('player.folder_sub'),
        onTap: () => h._openFolder(context),
      ),
    ];
    return Row(children: [
      for (var i = 0; i < cards.length; i++) ...[
        if (i > 0) const SizedBox(width: 16),
        Expanded(child: cards[i]),
      ],
    ]);
  }

  Widget _section(IconData icon, Color color, String title, {Widget? end}) => Row(children: [
        Icon(icon, color: color, size: 26),
        const SizedBox(width: 10),
        Text(title, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: LightLook.text)),
        const Spacer(),
        ?end,
      ]);

  @override
  Widget build(BuildContext context) {
    final m = services.player;
    return ListenableBuilder(
      listenable: m,
      builder: (context, _) {
        final last = m.last;
        final at = m.lastKey == null ? null : m.positionOf(m.lastKey!);
        final recent = m.recent;
        final searching = _q.text.trim().isNotEmpty;
        return Theme(
          data: LightLook.theme(Theme.of(context)),
          child: Scaffold(
            backgroundColor: LightLook.page,
            body: DecoratedBox(
              decoration: LightLook.wash,
              child: LayoutBuilder(builder: (context, box) {
                const gap = 16.0;
                final inner = box.maxWidth - 64;
                final cols = ((inner + gap) / (230 + gap)).floor().clamp(2, 8);
                final tileW = (inner - gap * (cols - 1)) / cols;
                final shown = _allRecent ? recent : recent.take(cols * 2).toList();
                return ListView(
                  padding: const EdgeInsets.fromLTRB(32, 28, 32, 32),
                  children: [
                    _header(),
                    const SizedBox(height: 26),
                    _kinds(),
                    const SizedBox(height: 10),
                    Text(tr('player.drop_hint'), style: const TextStyle(color: LightLook.muted, fontSize: 12.5)),
                    if (!searching) ...[
                      const SizedBox(height: 26),
                      _section(
                        Icons.schedule_rounded,
                        LightLook.blue,
                        tr('player.recent'),
                        end: recent.isEmpty
                            ? null
                            : Row(mainAxisSize: MainAxisSize.min, children: [
                                if (recent.length > shown.length || _allRecent)
                                  TextButton(
                                    onPressed: () => setState(() => _allRecent = !_allRecent),
                                    child: Text(_allRecent ? tr('player.show_less') : tr('player.show_more', {'count': recent.length})),
                                  ),
                                TextButton(
                                  style: TextButton.styleFrom(foregroundColor: LightLook.muted),
                                  onPressed: m.clearRecent,
                                  child: Text(tr('player.clear_recent')),
                                ),
                              ]),
                      ),
                      const SizedBox(height: 14),
                      if (recent.isEmpty)
                        Container(
                          decoration: LightLook.card(),
                          padding: const EdgeInsets.all(24),
                          child: Text(tr('player.recent_empty'), style: const TextStyle(color: LightLook.muted)),
                        )
                      else
                        Wrap(spacing: gap, runSpacing: gap, children: [
                          for (final r in shown)
                            _RecentTile(
                              key: ValueKey(r.path),
                              width: tileW,
                              services: services,
                              recent: r,
                              entry: h._entryOf(r),
                              // The one left part-way: where it stopped.
                              resumeAt: last != null && at != null && r.path == last.path ? at : null,
                              onTap: () => h._openRecent(context, r),
                              onForget: () => m.forget(r.path),
                            ),
                        ]),
                    ],
                    const SizedBox(height: 28),
                    _section(
                      searching ? Icons.manage_search_rounded : Icons.draw_rounded,
                      LightLook.amber,
                      searching ? tr('player.found_notes') : tr('player.my_notes'),
                    ),
                    const SizedBox(height: 14),
                    Container(
                      decoration: LightLook.card(),
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      child: _NoteSearch(services: services, query: _q.text),
                    ),
                  ],
                );
              }),
            ),
          ),
        );
      },
    );
  }
}

/// The big play sign at the top: a blue gradient tile with a triangle.
class _PlayBadge extends StatelessWidget {
  const _PlayBadge({required this.size});

  final double size;

  @override
  Widget build(BuildContext context) => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(size * 0.26),
          gradient: const LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [Color(0xFF6FB6FF), Color(0xFF1F63F0)]),
          boxShadow: const [BoxShadow(color: Color(0x332F6BFF), blurRadius: 18, offset: Offset(0, 8))],
        ),
        child: Icon(Icons.play_arrow_rounded, color: Colors.white, size: size * 0.72),
      );
}

/// One "what to open" card: a coloured icon, a name, what it takes.
class _Kind extends StatefulWidget {
  const _Kind({required this.icon, required this.colors, required this.title, required this.sub, required this.onTap});

  final IconData icon;
  final List<Color> colors;
  final String title;
  final String sub;
  final VoidCallback onTap;

  @override
  State<_Kind> createState() => _KindState();
}

class _KindState extends State<_Kind> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) => MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 140),
            height: 96,
            padding: const EdgeInsets.symmetric(horizontal: 18),
            decoration: LightLook.card(border: _hover ? LightLook.blue.withValues(alpha: 0.5) : null),
            transform: Matrix4.translationValues(0, _hover ? -2 : 0, 0),
            child: Row(children: [
              LightBadge(icon: widget.icon, colors: widget.colors, size: 50),
              const SizedBox(width: 14),
              Expanded(
                child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(widget.title,
                      maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: LightLook.text)),
                  const SizedBox(height: 4),
                  Text(widget.sub, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13, color: LightLook.muted)),
                ]),
              ),
            ]),
          ),
        ),
      );
}

Widget _thumb(AppServices s, PlayerEntry? e, double box) {
  final icon = Container(
    color: const Color(0xFFEFF2F8),
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

class _RecentTile extends StatelessWidget {
  const _RecentTile({
    super.key,
    required this.width,
    required this.services,
    required this.recent,
    required this.entry,
    required this.resumeAt,
    required this.onTap,
    required this.onForget,
  });

  final double width;
  final AppServices services;
  final RecentEntry recent;
  final PlayerEntry? entry;
  final Duration? resumeAt;
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
  Widget build(BuildContext context) {
    final thumbH = width * 0.58;
    final at = resumeAt;
    return Tooltip(
      message: recent.path,
      waitDuration: const Duration(milliseconds: 600),
      child: GestureDetector(
        onTap: onTap,
        onSecondaryTapUp: (d) => _menu(context, d.globalPosition),
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: Container(
            width: width,
            decoration: LightLook.card(),
            clipBehavior: Clip.antiAlias,
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              SizedBox(
                width: width,
                height: thumbH,
                child: Stack(fit: StackFit.expand, children: [
                  Opacity(opacity: entry == null ? 0.4 : 1, child: _thumb(services, entry, width)),
                  if (recent.video)
                    Center(
                      child: Container(
                        width: 46,
                        height: 46,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: Colors.black.withValues(alpha: 0.35),
                          border: Border.all(color: Colors.white, width: 2),
                        ),
                        child: const Icon(Icons.play_arrow_rounded, color: Colors.white, size: 30),
                      ),
                    ),
                  if (at != null)
                    Positioned(
                      right: 8,
                      bottom: 8,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.65), borderRadius: BorderRadius.circular(6)),
                        child: Text(tr('player.resume_at', {'time': playerTime(at)}),
                            style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600)),
                      ),
                    ),
                ]),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(recent.name,
                      maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: LightLook.text)),
                  const SizedBox(height: 3),
                  Text(
                    entry == null
                        ? tr('player.missing')
                        : recent.openedMs > 0
                            ? formatWhen(DateTime.fromMillisecondsSinceEpoch(recent.openedMs))
                            : '',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12, color: LightLook.muted),
                  ),
                ]),
              ),
            ]),
          ),
        ),
      ),
    );
  }
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

  // On the Transfers page, files dropped on a device are sent to it.
  bool get _transfers => AppNav.instance.tab == AppNav.devices;

  @override
  Widget build(BuildContext context) => DropTarget(
        onDragEntered: (_) {
          if (!_transfers) setState(() => _over = true);
        },
        onDragExited: (_) => setState(() => _over = false),
        onDragDone: (d) {
          setState(() => _over = false);
          if (_transfers) return;
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
  const _NoteSearch({required this.services, required this.query});

  final AppServices services;

  /// What is typed in the header's search.
  final String query;

  @override
  State<_NoteSearch> createState() => _NoteSearchState();
}

class _NoteSearchState extends State<_NoteSearch> {

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

  Future<void> _rename(NoteHit h) async {
    final c = TextEditingController(text: h.note.name);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('recs.rename')),
        content: SizedBox(width: 420, child: TextField(controller: c, autofocus: true, onSubmitted: (v) => Navigator.pop(ctx, v))),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(tr('common.cancel'))),
          FilledButton(onPressed: () => Navigator.pop(ctx, c.text), child: Text(tr('common.ok'))),
        ],
      ),
    );
    c.dispose();
    if (name == null || name.trim().isEmpty) return;
    h.note.name = name.trim();
    await widget.services.notes.save(h.set);
  }

  /// Deleted (the original is not touched); 10 seconds to undo.
  Future<void> _delete(NoteSet set, List<Note> notes) async {
    if (notes.length > 1) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(tr('ink.delete_all_title', {'n': notes.length, 'name': set.name})),
          content: SizedBox(width: 420, child: Text(tr('ink.delete_all_text'), style: const TextStyle(height: 1.5))),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('common.cancel'))),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: LrColors.danger),
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(tr('lib.delete')),
            ),
          ],
        ),
      );
      if (ok != true) return;
    }
    final before = List.of(set.notes);
    set.notes.removeWhere(notes.contains);
    await widget.services.notes.save(set);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      duration: const Duration(seconds: 10),
      content: Text(notes.length == 1 ? tr('ink.deleted', {'name': notes.first.name}) : tr('ink.deleted_n', {'n': notes.length})),
      action: SnackBarAction(
        label: tr('trash.undo'),
        onPressed: () async {
          set.notes
            ..clear()
            ..addAll(before);
          await widget.services.notes.save(set);
        },
      ),
    ));
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: widget.services.notes,
        builder: (context, _) {
          final searching = widget.query.trim().isNotEmpty;
          // Nothing typed: the latest annotations ("My notes").
          // By video (the one drawn on last first); searching: the matches,
          // by video.
          final hits = searching ? widget.services.notes.search(widget.query) : widget.services.notes.recent(100000);
          final groups = <String, List<NoteHit>>{};
          for (final h in hits) {
            groups.putIfAbsent(h.set.key, () => []).add(h);
          }
          String day(int ms) {
            final d = DateTime.fromMillisecondsSinceEpoch(ms);
            return '${d.month}-${d.day.toString().padLeft(2, '0')}';
          }

          return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (!searching && hits.isEmpty)
              Padding(
                padding: const EdgeInsets.all(12),
                child: Text(tr('player.notes_empty'), style: const TextStyle(color: LightLook.muted)),
              ),
            if (searching || hits.isNotEmpty) ...[
              if (hits.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(tr('ink.no_hits'), style: const TextStyle(color: LightLook.muted)),
                )
              else
                for (final g in groups.values.take(30))
                  SizedBox(
                    child: ExpansionTile(
                      key: PageStorageKey('notes-${g.first.set.key}-$searching'),
                      initiallyExpanded: searching,
                      tilePadding: const EdgeInsets.symmetric(horizontal: 6),
                      leading: Icon(g.first.set.video ? Icons.movie_rounded : Icons.image_rounded, color: LrColors.muted),
                      title: Text(g.first.set.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                        PopupMenuButton<String>(
                          tooltip: tr('ink.more'),
                          icon: const Icon(Icons.more_vert_rounded, size: 18),
                          onSelected: (a) {
                            if (a == 'open') unawaited(_open(g.first));
                            if (a == 'delete') unawaited(_delete(g.first.set, [for (final h in g) h.note]));
                          },
                          itemBuilder: (_) => [
                            PopupMenuItem(value: 'open', child: Text(tr('lib.open'))),
                            PopupMenuItem(
                              value: 'delete',
                              child: Text(tr(searching ? 'ink.delete_found' : 'ink.delete_all'), style: const TextStyle(color: LrColors.danger)),
                            ),
                          ],
                        ),
                        const Icon(Icons.expand_more_rounded, color: LrColors.muted),
                      ]),
                      subtitle: Text(
                        tr('player.notes_group', {'n': g.length, 'day': day(g.first.note.modifiedMs)}),
                        style: const TextStyle(color: LrColors.muted, fontSize: 12),
                      ),
                      children: [
                        for (final h in ([...g]..sort((a, b) => a.note.startMs.compareTo(b.note.startMs))))
                          ListTile(
                            dense: true,
                            contentPadding: const EdgeInsets.only(left: 46, right: 6),
                            title: Text(h.note.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                            subtitle: Text(
                              [
                                if (h.set.video) _time(h.note.startMs),
                                if (h.note.narration) tr('ink.from_narration'),
                              ].join(' · '),
                              style: const TextStyle(color: LrColors.muted),
                            ),
                            onTap: () => _open(h),
                            trailing: PopupMenuButton<String>(
                              tooltip: tr('ink.more'),
                              icon: const Icon(Icons.more_vert_rounded, size: 18),
                              onSelected: (a) {
                                if (a == 'open') unawaited(_open(h));
                                if (a == 'rename') unawaited(_rename(h));
                                if (a == 'delete') unawaited(_delete(h.set, [h.note]));
                              },
                              itemBuilder: (_) => [
                                PopupMenuItem(value: 'open', child: Text(tr('lib.open'))),
                                PopupMenuItem(value: 'rename', child: Text(tr('recs.rename'))),
                                PopupMenuItem(value: 'delete', child: Text(tr('ink.delete'), style: const TextStyle(color: LrColors.danger))),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ),
            ],
          ]);
        },
      );
}

