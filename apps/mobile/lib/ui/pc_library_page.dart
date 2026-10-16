// apps/mobile/lib/ui/pc_library_page.dart
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:localroll_core/localroll_core.dart';
import 'package:video_player/video_player.dart';

import '../l10n/l10n.dart';
import '../services/discovery.dart';
import '../services/mobile_settings.dart';
import '../services/pc_library.dart';
import '../services/phone_server.dart';
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

  @override
  void initState() {
    super.initState();
    unawaited(lib.loadMore());
  }

  @override
  void dispose() {
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
              preferredSize: const Size.fromHeight(52),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                child: SegmentedButton<MediaKind?>(
                  segments: [
                    ButtonSegment(value: null, label: Text(tr('pclib.all'))),
                    ButtonSegment(value: MediaKind.image, label: Text(tr('pclib.photos'))),
                    ButtonSegment(value: MediaKind.video, label: Text(tr('pclib.videos'))),
                  ],
                  selected: {lib.kind},
                  onSelectionChanged: (v) {
                    lib.kind = v.first;
                    _selected.clear();
                    unawaited(lib.refresh());
                  },
                ),
              ),
            ),
          ),
          body: RefreshIndicator(onRefresh: lib.refresh, child: _body(context)),
        );
      },
    );
  }

  Widget _body(BuildContext context) {
    final theme = Theme.of(context);
    if (lib.items.isEmpty) {
      return ListView(children: [
        const SizedBox(height: 120),
        if (lib.loading)
          const Center(child: CircularProgressIndicator())
        else
          Padding(
            padding: const EdgeInsets.all(32),
            child: Column(children: [
              Icon(lib.error == null ? Icons.photo_library_outlined : Icons.cloud_off_rounded, size: 48, color: LrColors.muted),
              const SizedBox(height: 12),
              Text(lib.error ?? tr('pclib.empty'), textAlign: TextAlign.center),
              if (lib.error != null) ...[
                const SizedBox(height: 16),
                FilledButton(onPressed: lib.refresh, child: Text(tr('common.retry'))),
              ],
            ]),
          ),
      ]);
    }
    // By day, newest first (the PC sends them in that order).
    final days = <DateTime, List<int>>{};
    for (var k = 0; k < lib.items.length; k++) {
      final t = DateTime.fromMillisecondsSinceEpoch(lib.items[k].takenMs);
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
              child: Text(tr('pclib.count', {'count': lib.total}), style: theme.textTheme.bodySmall?.copyWith(color: LrColors.muted)),
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
        } else {
          Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => _Viewer(lib: lib, start: index, onSave: _save, onDelete: _delete, onVisibility: _visibility),
          ));
        }
      },
      onLongPress: () => setState(() => _selected.add(item.path)),
      child: Stack(fit: StackFit.expand, children: [
        _Thumb(lib: lib, path: item.path),
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
  const _Viewer({required this.lib, required this.start, required this.onSave, required this.onDelete, required this.onVisibility});

  final PcLibrary lib;
  final int start;
  final Future<void> Function(List<String>) onSave;
  final Future<void> Function(List<String>) onDelete;
  final Future<void> Function(List<String>, bool) onVisibility;

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
        final loc = MaterialLocalizations.of(context);
        return Scaffold(
          backgroundColor: Colors.black,
          appBar: AppBar(
            backgroundColor: Colors.black,
            title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('${loc.formatMediumDate(taken)} ${TimeOfDay.fromDateTime(taken).format(context)}',
                  style: const TextStyle(fontSize: 15)),
              Text([item.name, if (item.from != null) tr('pclib.from', {'name': item.from})].join(' · '),
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
              return it.kind == MediaKind.video
                  ? _VideoView(key: ValueKey(it.path), lib: widget.lib, path: it.path)
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
  const _VideoView({super.key, required this.lib, required this.path, this.loop = false, this.onEnd});

  final PcLibrary lib;
  final String path;
  final bool loop;
  final VoidCallback? onEnd;

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
      return Center(child: Text(tr('pclib.cant_play'), style: const TextStyle(color: LrColors.muted)));
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
