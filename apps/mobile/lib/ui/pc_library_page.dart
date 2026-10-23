// apps/mobile/lib/ui/pc_library_page.dart
import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:localroll_core/localroll_core.dart';
import 'package:video_player/video_player.dart';

import '../l10n/l10n.dart';
import '../services/discovery.dart';
import '../services/mobile_settings.dart';
import '../services/pc_library.dart';
import '../services/pdf_pages.dart';
import '../services/phone_server.dart';
import 'cleanup_page.dart' show formatSize;
import 'first_page_view.dart';
import 'open_file.dart';
import 'theme.dart';

/// The PC's library on this phone: browse by day, open, play, save to this
/// phone; delete (to the PC's Recycle Bin) when the PC allows it; change
/// "only me" on one's own photos.
class PcLibraryPage extends StatefulWidget {
  const PcLibraryPage({
    super.key,
    required this.settings,
    required this.discovery,
    required this.desktop,
    required this.server,
    this.onSwitch,
  });

  /// Shown as a tab with more than one PC: tap the title to pick another.
  final VoidCallback? onSwitch;

  final MobileSettings settings;
  final DesktopDiscovery discovery;
  final PairedDesktop desktop;
  final PhoneServer server;

  @override
  State<PcLibraryPage> createState() => _PcLibraryPageState();
}

class _PcLibraryPageState extends State<PcLibraryPage> {
  late final PcLibrary lib = PcLibrary(
    settings: widget.settings,
    discovery: widget.discovery,
    desktop: widget.desktop,
    server: widget.server,
  );
  final Set<String> _selected = {};
  bool _busy = false;

  /// Search: words in photos / files (read on the PC) and their names.
  final TextEditingController _searchCtrl = TextEditingController();
  Timer? _searchSoon;

  void _onSearch(String v) {
    _searchSoon?.cancel();
    _searchSoon = Timer(const Duration(milliseconds: 450), () {
      if (!mounted || lib.query == v.trim()) return;
      lib.query = v.trim();
      setState(_selected.clear);
      unawaited(lib.refresh());
    });
  }

  @override
  void initState() {
    super.initState();
    unawaited(lib.loadMore());
  }

  @override
  void dispose() {
    _searchSoon?.cancel();
    _searchCtrl.dispose();
    lib.dispose();
    super.dispose();
  }

  void _toast(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _run(Future<void> Function() f) async {
    setState(() => _busy = true);
    try {
      await f();
    } catch (e) {
      _toast(lib.describe(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save(List<String> paths) => _run(() async {
        final n = await lib.saveToPhone(paths);
        _toast(tr('pclib.saving', {'count': n, 'pc': widget.desktop.name}));
        setState(_selected.clear);
      });

  Future<void> _delete(List<String> paths) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(tr('pclib.delete_title', {'count': paths.length})),
        content: Text(tr('pclib.delete_body', {'pc': widget.desktop.name})),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: Text(tr('common.cancel'))),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: LrColors.danger),
            onPressed: () => Navigator.pop(c, true),
            child: Text(tr('pclib.delete')),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await _run(() async {
      final n = await lib.delete(paths);
      _toast(tr('pclib.deleted', {'count': n, 'pc': widget.desktop.name}));
      setState(_selected.clear);
    });
  }

  Future<void> _visibility(List<String> paths, bool private) => _run(() async {
        await lib.setPrivate(paths, private);
        _toast(tr(private ? 'pclib.now_private' : 'pclib.now_shared', {'count': paths.length}));
        setState(_selected.clear);
      });

  /// A received file: fetched (a moment, shown), then opened here.
  Future<void> _openFile(RemoteItem item) async {
    final nav = Navigator.of(context);
    var shown = false;
    final wait = Timer(const Duration(milliseconds: 300), () {
      if (!mounted) return;
      shown = true;
      unawaited(showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => const Center(child: CircularProgressIndicator()),
      ));
    });
    String? path;
    Object? problem;
    try {
      path = await lib.fetch(item);
    } catch (e) {
      problem = e;
    }
    wait.cancel();
    if (shown && mounted) nav.pop();
    if (!mounted) return;
    if (path == null) {
      _toast(lib.describe(problem ?? 'not_found'));
      return;
    }
    lib.hold = true;
    try {
      await openDocument(context, path, name: item.name, onSend: () => _save([item.path]));
    } finally {
      lib.hold = false;
    }
  }

  Future<void> _openViewer(int index) async {
    lib.hold = true;
    try {
      await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => _Viewer(lib: lib, start: index, onSave: _save, onDelete: _delete, onVisibility: _visibility, onOpenFile: _openFile),
      ));
    } finally {
      lib.hold = false;
    }
  }

  void _sortBy(bool received) {
    if (lib.byReceived == received) return;
    lib.byReceived = received;
    _selected.clear();
    unawaited(lib.refresh());
  }

  List<RemoteItem> get _chosen => [for (final i in lib.items) if (_selected.contains(i.path)) i];

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: lib,
      builder: (context, _) {
        final selecting = _selected.isNotEmpty;
        final chosen = _chosen;
        final allMine = chosen.isNotEmpty && chosen.every((i) => i.mine);
        return Scaffold(
          appBar: AppBar(
            leading: selecting ? IconButton(onPressed: () => setState(_selected.clear), icon: const Icon(Icons.close_rounded)) : null,
            title: selecting
                ? Text(tr('pclib.selected', {'count': _selected.length}))
                : widget.onSwitch == null
                    ? Text(tr('pclib.title', {'pc': widget.desktop.name}))
                    : InkWell(
                        onTap: widget.onSwitch,
                        child: Row(mainAxisSize: MainAxisSize.min, children: [
                          Flexible(child: Text(tr('pclib.title', {'pc': widget.desktop.name}), overflow: TextOverflow.ellipsis)),
                          const Icon(Icons.arrow_drop_down_rounded),
                        ]),
                      ),
            actions: [
              if (!selecting)
                PopupMenuButton<bool>(
                  tooltip: tr('pclib.sort'),
                  icon: const Icon(Icons.sort_rounded),
                  onSelected: _sortBy,
                  itemBuilder: (_) => [
                    CheckedPopupMenuItem(value: false, checked: !lib.byReceived, child: Text(tr('pclib.sort_taken'))),
                    CheckedPopupMenuItem(value: true, checked: lib.byReceived, child: Text(tr('pclib.sort_received'))),
                  ],
                ),
              if (_busy) const Padding(padding: EdgeInsets.all(14), child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))),
              if (selecting) ...[
                IconButton(
                  tooltip: tr('pclib.save'),
                  onPressed: _busy ? null : () => _save(_selected.toList()),
                  icon: const Icon(Icons.download_rounded),
                ),
                if (allMine)
                  PopupMenuButton<bool>(
                    tooltip: tr('pclib.visibility'),
                    icon: const Icon(Icons.visibility_outlined),
                    onSelected: (p) => _visibility(_selected.toList(), p),
                    itemBuilder: (_) => [
                      PopupMenuItem(value: true, child: Text(tr('pclib.make_private'))),
                      PopupMenuItem(value: false, child: Text(tr('pclib.make_shared'))),
                    ],
                  ),
                if (lib.canDelete)
                  IconButton(
                    tooltip: tr('pclib.delete'),
                    onPressed: _busy ? null : () => _delete(_selected.toList()),
                    icon: const Icon(Icons.delete_outline_rounded),
                  ),
              ],
            ],
            bottom: PreferredSize(
              preferredSize: const Size.fromHeight(104),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                child: Column(children: [
                  SizedBox(
                    height: 42,
                    child: TextField(
                      controller: _searchCtrl,
                      onChanged: _onSearch,
                      textInputAction: TextInputAction.search,
                      decoration: InputDecoration(
                        isDense: true,
                        hintText: tr('pclib.search_hint'),
                        prefixIcon: const Icon(Icons.search_rounded, size: 20),
                        suffixIcon: ValueListenableBuilder(
                          valueListenable: _searchCtrl,
                          builder: (_, v, _) => v.text.isEmpty
                              ? const SizedBox.shrink()
                              : IconButton(
                                  icon: const Icon(Icons.close_rounded, size: 18),
                                  onPressed: () {
                                    _searchCtrl.clear();
                                    _onSearch('');
                                  },
                                ),
                        ),
                        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  SegmentedButton<MediaKind?>(
                  segments: [
                    ButtonSegment(value: null, label: Text(tr('pclib.all'))),
                    ButtonSegment(value: MediaKind.image, label: Text(tr('pclib.photos'))),
                    ButtonSegment(value: MediaKind.video, label: Text(tr('pclib.videos'))),
                    ButtonSegment(value: MediaKind.other, label: Text(tr('pclib.files'))),
                  ],
                  showSelectedIcon: false,
                  selected: {lib.kind},
                  onSelectionChanged: (v) {
                    lib.kind = v.first;
                    _selected.clear();
                    unawaited(lib.refresh());
                  },
                  ),
                ]),
              ),
            ),
          ),
          body: RefreshIndicator(onRefresh: lib.refresh, child: _body(context)),
        );
      },
    );
  }

  /// The PC hasn't read everything yet: results may be incomplete.
  Widget _readingNote() => Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
        child: Row(children: [
          const Icon(Icons.hourglass_top_rounded, size: 16, color: LrColors.muted),
          const SizedBox(width: 8),
          Expanded(child: Text(tr('pclib.pc_reading'), style: const TextStyle(color: LrColors.muted, fontSize: 13))),
        ]),
      );

  Widget _body(BuildContext context) {
    final theme = Theme.of(context);
    if (lib.items.isEmpty) {
      return ListView(children: [
        if (lib.query.isNotEmpty && lib.reading) _readingNote(),
        const SizedBox(height: 120),
        if (lib.loading)
          const Center(child: CircularProgressIndicator())
        else
          Padding(
            padding: const EdgeInsets.all(32),
            child: Column(children: [
              Icon(lib.error == null ? Icons.photo_library_outlined : Icons.cloud_off_rounded, size: 48, color: LrColors.muted),
              const SizedBox(height: 12),
              Text(lib.error ?? (lib.query.isEmpty ? tr('pclib.empty') : tr('pclib.search_none', {'q': lib.query})),
                  textAlign: TextAlign.center),
              if (lib.error != null) ...[
                const SizedBox(height: 16),
                FilledButton(onPressed: lib.refresh, child: Text(tr('common.retry'))),
              ],
            ]),
          ),
      ]);
    }
    // By day, newest first (the PC sends them in that order): the day
    // taken, or the day it arrived.
    final days = <DateTime, List<int>>{};
    for (var k = 0; k < lib.items.length; k++) {
      final i = lib.items[k];
      final t = DateTime.fromMillisecondsSinceEpoch(lib.byReceived && i.receivedMs > 0 ? i.receivedMs : i.takenMs);
      (days[DateTime(t.year, t.month, t.day)] ??= []).add(k);
    }
    final loc = MaterialLocalizations.of(context);
    return NotificationListener<ScrollNotification>(
      onNotification: (n) {
        if (n.metrics.pixels > n.metrics.maxScrollExtent - 1200) unawaited(lib.loadMore());
        return false;
      },
      child: CustomScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
              child: Row(children: [
                Expanded(
                  child: Text(
                    '${tr('pclib.count', {'count': lib.total})} · ${tr(lib.byReceived ? 'pclib.sort_received' : 'pclib.sort_taken')}',
                    style: theme.textTheme.bodySmall?.copyWith(color: LrColors.muted),
                  ),
                ),
                // Arrived in the last day: one tap shows them first.
                if (lib.recent > 0 && !lib.byReceived)
                  ActionChip(
                    avatar: const Icon(Icons.fiber_new_rounded, size: 18, color: LrColors.verified),
                    label: Text(tr('pclib.recent', {'count': lib.recent})),
                    onPressed: () => _sortBy(true),
                  ),
              ]),
            ),
          ),
          if (lib.query.isNotEmpty && lib.reading) SliverToBoxAdapter(child: _readingNote()),
          // The PC got something new while this list was being looked at.
          if (lib.newer)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                child: Material(
                  color: LrColors.raised,
                  borderRadius: BorderRadius.circular(12),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(12),
                    onTap: () => unawaited(lib.reload()),
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Row(children: [
                        const Icon(Icons.refresh_rounded, size: 18, color: LrColors.verified),
                        const SizedBox(width: 10),
                        Expanded(child: Text(tr('pclib.newer', {'pc': widget.desktop.name}), style: theme.textTheme.bodySmall)),
                      ]),
                    ),
                  ),
                ),
              ),
            ),
          // Selecting, but this PC doesn't let this phone delete: say where
          // that is turned on (people looked for a delete button).
          if (_selected.isNotEmpty && !lib.canDelete)
            SliverToBoxAdapter(
              child: Container(
                margin: const EdgeInsets.fromLTRB(12, 10, 12, 0),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: LrColors.raised,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: LrColors.safelight.withValues(alpha: 0.5)),
                ),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Icon(Icons.info_outline_rounded, size: 18, color: LrColors.safelight),
                  const SizedBox(width: 10),
                  Expanded(child: Text(tr('pclib.delete_hint', {'pc': widget.desktop.name}), style: theme.textTheme.bodySmall)),
                ]),
              ),
            ),
          for (final e in days.entries) ...[
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                child: Text(loc.formatFullDate(e.key), style: theme.textTheme.titleSmall),
              ),
            ),
            SliverPadding(
              padding: const EdgeInsets.symmetric(horizontal: 2),
              sliver: SliverGrid(
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 4, mainAxisSpacing: 2, crossAxisSpacing: 2),
                delegate: SliverChildBuilderDelegate(
                  (context, n) => _tile(e.value[n]),
                  childCount: e.value.length,
                ),
              ),
            ),
          ],
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Center(
                child: lib.loading
                    ? const CircularProgressIndicator()
                    : lib.error != null
                        ? TextButton(onPressed: lib.loadMore, child: Text(tr('common.retry')))
                        : const SizedBox.shrink(),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _tile(int index) {
    final item = lib.items[index];
    final selected = _selected.contains(item.path);
    return GestureDetector(
      onTap: () {
        if (_selected.isNotEmpty) {
          setState(() => selected ? _selected.remove(item.path) : _selected.add(item.path));
        } else if (item.file) {
          unawaited(_openFile(item));
        } else {
          unawaited(_openViewer(index));
        }
      },
      onLongPress: () => setState(() => _selected.add(item.path)),
      child: Stack(fit: StackFit.expand, children: [
        if (item.file) _FileThumb(lib: lib, item: item) else _Thumb(lib: lib, path: item.path),
        if (item.kind == MediaKind.video)
          const Positioned(right: 4, bottom: 4, child: Icon(Icons.play_circle_fill_rounded, color: Colors.white, size: 20)),
        if (item.live != null)
          const Positioned(left: 4, top: 4, child: Icon(Icons.motion_photos_on_rounded, color: Colors.white, size: 18)),
        if (item.private)
          const Positioned(right: 4, top: 4, child: Icon(Icons.lock_rounded, color: Colors.white, size: 16)),
        if (selected) ...[
          Container(color: Colors.black38),
          const Positioned(left: 4, bottom: 4, child: Icon(Icons.check_circle_rounded, color: LrColors.verified)),
        ],
      ]),
    );
  }
}

class _Thumb extends StatelessWidget {
  const _Thumb({required this.lib, required this.path});

  final PcLibrary lib;
  final String path;

  @override
  Widget build(BuildContext context) => FutureBuilder<Uint8List?>(
        future: lib.thumb(path),
        builder: (context, snap) {
          final b = snap.data;
          if (b == null) {
            return Container(
              color: LrColors.raised,
              child: snap.connectionState == ConnectionState.done
                  ? const Icon(Icons.broken_image_outlined, color: LrColors.muted)
                  : null,
            );
          }
          return Image.memory(b, fit: BoxFit.cover, gaplessPlayback: true, cacheWidth: 300);
        },
      );
}

/// One item at a time, swipe for the next.
class _Viewer extends StatefulWidget {
  const _Viewer({
    required this.lib,
    required this.start,
    required this.onSave,
    required this.onDelete,
    required this.onVisibility,
    required this.onOpenFile,
  });

  final PcLibrary lib;
  final int start;
  final Future<void> Function(List<String>) onSave;
  final Future<void> Function(List<String>) onDelete;
  final Future<void> Function(List<String>, bool) onVisibility;
  final Future<void> Function(RemoteItem) onOpenFile;

  @override
  State<_Viewer> createState() => _ViewerState();
}

class _ViewerState extends State<_Viewer> {
  late final PageController _pages = PageController(initialPage: widget.start);
  late int _at = widget.start;

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.lib,
      builder: (context, _) {
        final items = widget.lib.items;
        if (items.isEmpty) return const Scaffold();
        if (_at >= items.length) _at = items.length - 1;
        final item = items[_at];
        final taken = DateTime.fromMillisecondsSinceEpoch(item.takenMs);
        final arrived = item.receivedMs > 0 && item.receivedMs != item.takenMs
            ? DateTime.fromMillisecondsSinceEpoch(item.receivedMs)
            : null;
        final loc = MaterialLocalizations.of(context);
        return Scaffold(
          backgroundColor: Colors.black,
          appBar: AppBar(
            backgroundColor: Colors.black,
            title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('${loc.formatMediumDate(taken)} ${TimeOfDay.fromDateTime(taken).format(context)}',
                  style: const TextStyle(fontSize: 15)),
              Text(
                  [
                    item.name,
                    if (item.from != null) tr('pclib.from', {'name': item.from}),
                    if (arrived != null) tr('pclib.arrived', {'when': loc.formatShortDate(arrived)}),
                  ].join(' · '),
                  style: const TextStyle(fontSize: 12, color: LrColors.muted), overflow: TextOverflow.ellipsis),
            ]),
            actions: [
              IconButton(
                tooltip: tr('pclib.save'),
                onPressed: () => widget.onSave([item.path]),
                icon: const Icon(Icons.download_rounded),
              ),
              if (item.mine)
                IconButton(
                  tooltip: tr(item.private ? 'pclib.make_shared' : 'pclib.make_private'),
                  onPressed: () => widget.onVisibility([item.path], !item.private),
                  icon: Icon(item.private ? Icons.lock_rounded : Icons.lock_open_rounded),
                ),
              if (widget.lib.canDelete)
                IconButton(
                  tooltip: tr('pclib.delete'),
                  onPressed: () => widget.onDelete([item.path]),
                  icon: const Icon(Icons.delete_outline_rounded),
                ),
            ],
          ),
          body: PageView.builder(
            controller: _pages,
            itemCount: items.length,
            onPageChanged: (i) {
              setState(() => _at = i);
              if (i > items.length - 10) unawaited(widget.lib.loadMore());
            },
            itemBuilder: (context, i) {
              final it = items[i];
              if (it.file) {
                return _FilePage(key: ValueKey(it.path), lib: widget.lib, item: it, onOpen: () => widget.onOpenFile(it));
              }
              return it.kind == MediaKind.video
                  ? _VideoView(key: ValueKey(it.path), lib: widget.lib, path: it.path, onSave: () => widget.onSave([it.path]))
                  : _PhotoView(key: ValueKey(it.path), lib: widget.lib, item: it);
            },
          ),
        );
      },
    );
  }
}

class _PhotoView extends StatefulWidget {
  const _PhotoView({super.key, required this.lib, required this.item});

  final PcLibrary lib;
  final RemoteItem item;

  @override
  State<_PhotoView> createState() => _PhotoViewState();
}

class _PhotoViewState extends State<_PhotoView> {
  late final Future<Uint8List> _picture = widget.lib.view(widget.item.path);
  bool _live = false;

  @override
  Widget build(BuildContext context) {
    final live = widget.item.live;
    if (_live && live != null) {
      return GestureDetector(
        onTap: () => setState(() => _live = false),
        child: _VideoView(lib: widget.lib, path: live, loop: false, onEnd: () => setState(() => _live = false)),
      );
    }
    return Stack(children: [
      Positioned.fill(
        child: FutureBuilder<Uint8List>(
          future: _picture,
          builder: (context, snap) {
            if (snap.hasError) {
              return Center(child: Text(widget.lib.describe(snap.error!), style: const TextStyle(color: LrColors.muted)));
            }
            final b = snap.data;
            if (b == null) {
              // The small one meanwhile.
              return Stack(fit: StackFit.expand, children: [
                _Thumb(lib: widget.lib, path: widget.item.path),
                const Center(child: CircularProgressIndicator()),
              ]);
            }
            return InteractiveViewer(maxScale: 6, child: Center(child: Image.memory(b, gaplessPlayback: true)));
          },
        ),
      ),
      if (live != null)
        Positioned(
          left: 12,
          top: 12,
          child: ActionChip(
            avatar: const Icon(Icons.motion_photos_on_rounded, size: 18),
            label: Text(tr('pclib.live')),
            onPressed: () => setState(() => _live = true),
          ),
        ),
    ]);
  }
}

class _VideoView extends StatefulWidget {
  const _VideoView({super.key, required this.lib, required this.path, this.loop = false, this.onEnd, this.onSave});

  final PcLibrary lib;
  final String path;
  final bool loop;
  final VoidCallback? onEnd;

  /// "Save to this phone" (the PC converts what the phone can't play).
  final VoidCallback? onSave;

  @override
  State<_VideoView> createState() => _VideoViewState();
}

class _VideoViewState extends State<_VideoView> {
  VideoPlayerController? _c;
  Object? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_open());
  }

  Future<void> _open() async {
    try {
      final uri = await widget.lib.playable(widget.path);
      final c = VideoPlayerController.networkUrl(uri);
      await c.initialize();
      await c.setLooping(widget.loop);
      if (!mounted) {
        await c.dispose();
        return;
      }
      c.addListener(_tick);
      setState(() => _c = c);
      await c.play();
    } catch (e) {
      // Which file and why, for the log (a format the phone can't play,
      // the PC not answering…).
      final dot = widget.path.lastIndexOf('.');
      DiagLog.log('pclib', 'video failed (${dot < 0 ? '?' : widget.path.substring(dot + 1)}): $e');
      if (mounted) setState(() => _error = e);
    }
  }

  bool _ended = false;

  void _tick() {
    final c = _c;
    if (c == null || _ended || widget.onEnd == null) return;
    final v = c.value;
    if (v.isInitialized && !v.isPlaying && v.position >= v.duration && v.duration > Duration.zero) {
      _ended = true;
      widget.onEnd!();
    }
  }

  @override
  void dispose() {
    final c = _c;
    if (c != null) {
      c.removeListener(_tick);
      unawaited(c.dispose());
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.videocam_off_outlined, size: 44, color: LrColors.muted),
            const SizedBox(height: 10),
            Text(tr('pclib.cant_play'), style: const TextStyle(color: Colors.white, fontSize: 16)),
            const SizedBox(height: 6),
            Text(tr('pclib.cant_play_hint'), textAlign: TextAlign.center, style: const TextStyle(color: LrColors.muted)),
            if (widget.onSave != null) ...[
              const SizedBox(height: 14),
              FilledButton.icon(
                onPressed: widget.onSave,
                icon: const Icon(Icons.download_rounded),
                label: Text(tr('pclib.save')),
              ),
            ],
          ]),
        ),
      );
    }
    final c = _c;
    if (c == null) return const Center(child: CircularProgressIndicator());
    return GestureDetector(
      onTap: () => unawaited(c.value.isPlaying ? c.pause() : c.play()),
      child: Stack(alignment: Alignment.bottomCenter, children: [
        Center(child: AspectRatio(aspectRatio: c.value.aspectRatio, child: VideoPlayer(c))),
        VideoProgressIndicator(c, allowScrubbing: true, padding: const EdgeInsets.fromLTRB(12, 12, 12, 24)),
        ValueListenableBuilder(
          valueListenable: c,
          builder: (_, v, _) => v.isPlaying
              ? const SizedBox.shrink()
              : const Center(child: Icon(Icons.play_circle_outline_rounded, color: Colors.white70, size: 72)),
        ),
      ]),
    );
  }
}

/// A received file's first page, drawn on this phone from a copy of the
/// file (PDF: its first page; iPhone: the system's picture; Office / text:
/// drawn from its contents). Its kind and name until then, or if it can't.
class _FileThumb extends StatelessWidget {
  const _FileThumb({required this.lib, required this.item});

  final PcLibrary lib;
  final RemoteItem item;

  /// Per file version; a failure is tried again later, not kept for good.
  static final SoftCache<Object> _cache = SoftCache(max: 300);
  static int _running = 0;
  static final Queue<Completer<void>> _waiting = Queue();

  /// Three files fetched at a time.
  static Future<T?> _limited<T>(Future<T?> Function() task) async {
    while (_running >= 3) {
      final c = Completer<void>();
      _waiting.add(c);
      await c.future;
    }
    _running++;
    try {
      return await task();
    } finally {
      _running--;
      if (_waiting.isNotEmpty) _waiting.removeFirst().complete();
    }
  }

  static bool _picture(String name) => MediaKind.fromName(name.toLowerCase()) == MediaKind.image;

  Future<Object?> _load() {
    final n = item.name.toLowerCase();
    return _cache.get('${lib.desktop.id}|${item.path}|${item.size}|${item.receivedMs}', () => _limited<Object>(() async {
          // The PC's picture first (PDF first page, photo, video frame):
          // small, nothing to download.
          final pc = await lib.thumb(item.path);
          if (pc != null) return pc;
          // Office / text files: drawn here from a copy of the file.
          final drawable = n.endsWith('.pdf') || _picture(n) || FirstPage.canDraw(n) || Platform.isIOS;
          if (!drawable || item.size > PcLibrary.maxThumbFile) return null;
          final String path;
          try {
            path = await lib.fetch(item);
          } catch (e) {
            DiagLog.log('pclib', 'file not fetched (${_ext(n)}): $e');
            return null;
          }
          Object? page;
          if (n.endsWith('.pdf')) {
            page = await PdfPages.thumb(path);
          } else if (_picture(n)) {
            page = File(path);
          } else {
            page = await FileOpener.thumbnail(path) ?? await FirstPages.of(path, name: item.name);
          }
          if (page == null) DiagLog.log('pclib', 'no first page (${_ext(n)})');
          return page;
        }));
  }

  static String _ext(String n) {
    final i = n.lastIndexOf('.');
    return i < 0 ? '?' : n.substring(i + 1);
  }

  static IconData iconFor(String name) {
    final n = name.toLowerCase();
    if (n.endsWith('.pdf')) return Icons.picture_as_pdf_rounded;
    if (n.endsWith('.doc') || n.endsWith('.docx') || n.endsWith('.txt') || n.endsWith('.rtf')) return Icons.description_rounded;
    if (n.endsWith('.xls') || n.endsWith('.xlsx') || n.endsWith('.csv')) return Icons.table_chart_rounded;
    if (n.endsWith('.ppt') || n.endsWith('.pptx')) return Icons.slideshow_rounded;
    if (n.endsWith('.zip') || n.endsWith('.rar') || n.endsWith('.7z')) return Icons.folder_zip_rounded;
    if (MediaKind.fromName(n) == MediaKind.video) return Icons.movie_rounded;
    if (MediaKind.fromName(n) == MediaKind.image) return Icons.image_rounded;
    return Icons.insert_drive_file_rounded;
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<Object?>(
        future: _load(),
        builder: (context, s) {
          final d = s.data;
          final Widget page;
          if (d is Uint8List) {
            page = Container(
              color: Colors.white,
              child: Image.memory(d, fit: BoxFit.cover, alignment: Alignment.topCenter, gaplessPlayback: true, cacheWidth: 300),
            );
          } else if (d is File) {
            page = Image.file(d, fit: BoxFit.cover, gaplessPlayback: true, cacheWidth: 300,
                errorBuilder: (_, _, _) => _plain());
          } else if (d is FirstPage) {
            page = FirstPageView(page: d);
          } else {
            return _plain();
          }
          return Stack(fit: StackFit.expand, children: [page, _label()]);
        },
      );

  Widget _label() => Positioned(
        left: 0,
        right: 0,
        bottom: 0,
        child: Container(
          color: Colors.black54,
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
          child: Row(children: [
            Icon(iconFor(item.name), size: 11, color: Colors.white),
            const SizedBox(width: 3),
            Expanded(
              child: Text(item.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 10, color: Colors.white)),
            ),
          ]),
        ),
      );

  Widget _plain() => Container(
        color: LrColors.surface,
        padding: const EdgeInsets.all(6),
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          Icon(iconFor(item.name), size: 30, color: LrColors.safelight),
          const SizedBox(height: 6),
          Text(item.name, maxLines: 2, textAlign: TextAlign.center, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 10)),
        ]),
      );
}

/// A received file in the full-screen view: its first page and "Open".
class _FilePage extends StatelessWidget {
  const _FilePage({super.key, required this.lib, required this.item, required this.onOpen});

  final PcLibrary lib;
  final RemoteItem item;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 240, maxHeight: 320),
              child: AspectRatio(aspectRatio: 210 / 297, child: _FileThumb(lib: lib, item: item)),
            ),
            const SizedBox(height: 16),
            Text(item.name, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white, fontSize: 15)),
            const SizedBox(height: 4),
            Text(formatSize(item.size), style: const TextStyle(color: LrColors.muted, fontSize: 12)),
            const SizedBox(height: 16),
            FilledButton.icon(onPressed: onOpen, icon: const Icon(Icons.open_in_new_rounded), label: Text(tr('pclib.open'))),
          ]),
        ),
      );
}
