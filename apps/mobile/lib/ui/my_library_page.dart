// apps/mobile/lib/ui/my_library_page.dart
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:localroll_core/localroll_core.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:share_plus/share_plus.dart';
import 'package:video_player/video_player.dart';

import '../l10n/l10n.dart';
import '../services/discovery.dart';
import '../services/mobile_settings.dart';
import '../services/my_library.dart';
import '../services/pdf_pages.dart';
import 'cleanup_page.dart' show formatSize;
import 'first_page_view.dart';
import 'open_file.dart';
import 'send_files_page.dart';
import 'theme.dart';

/// "My files": everything that arrived on this phone and its own scans,
/// like the PC's library — by day, filtered by kind and by who sent it,
/// searchable; open, share, send, rename, delete.
class MyLibraryPage extends StatefulWidget {
  const MyLibraryPage({super.key, required this.settings, required this.discovery});

  final MobileSettings settings;
  final DesktopDiscovery discovery;

  @override
  State<MyLibraryPage> createState() => _MyLibraryPageState();
}

/// Filter tabs.
enum _Tab { all, photo, video, document, scan, other }

class _MyLibraryPageState extends State<MyLibraryPage> {
  final MyLibrary lib = MyLibrary.instance;
  _Tab _tab = _Tab.all;
  String? _source; // sender id, null = everyone
  String _query = '';
  bool _searching = false;
  final Set<String> _selected = {};
  bool _busy = true;

  @override
  void initState() {
    super.initState();
    lib.addListener(_changed);
    unawaited(_start());
  }

  Future<void> _start() async {
    await lib.load();
    await lib.importOld(unknownName: tr('mylib.unknown'));
    await lib.reconcile();
    if (mounted) setState(() => _busy = false);
  }

  @override
  void dispose() {
    lib.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  bool _matches(MyItem i) {
    final kindOk = switch (_tab) {
      _Tab.all => true,
      _Tab.photo => i.kind == MyKind.photo,
      _Tab.video => i.kind == MyKind.video,
      _Tab.document => i.kind == MyKind.document,
      _Tab.scan => i.kind == MyKind.scan,
      _Tab.other => i.kind == MyKind.other,
    };
    if (!kindOk) return false;
    if (_source != null && i.fromId != _source) return false;
    final q = _query.trim().toLowerCase();
    if (q.isNotEmpty && !i.name.toLowerCase().contains(q) && !i.fromName.toLowerCase().contains(q)) return false;
    return true;
  }

  List<MyItem> get _shown => lib.items.where(_matches).toList();

  List<MyItem> get _selection => lib.items.where((i) => _selected.contains(i.id)).toList();

  // ------------------------------------------------------------- actions

  void _toast(String t) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(t)));
  }

  Future<void> _open(MyItem i) async {
    if (i.kind.isMedia) {
      final media = _shown.where((x) => x.kind.isMedia).toList();
      await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => _MediaViewer(items: media, start: media.indexOf(i).clamp(0, media.length - 1)),
      ));
      return;
    }
    final path = await lib.pathOf(i);
    if (path == null || !await File(path).exists()) {
      _toast(tr('mylib.cannot_open'));
      return;
    }
    if (!mounted) return;
    // Shown inside LocalRoll wherever the phone can (see open_file.dart).
    await openDocument(context, path, name: i.name, onSend: () => _sendFiles([File(path)]));
  }

  Future<void> _shareFiles(List<File> files) async {
    final box = context.findRenderObject() as RenderBox?;
    await SharePlus.instance.share(ShareParams(
      files: [for (final f in files) XFile(f.path)],
      sharePositionOrigin: box == null ? null : box.localToGlobal(Offset.zero) & box.size,
    ));
  }

  Future<List<File>> _filesOf(List<MyItem> items) async {
    final out = <File>[];
    for (final i in items) {
      final f = await lib.fileOf(i);
      if (f != null && await f.exists()) out.add(f);
    }
    return out;
  }

  Future<void> _share() async {
    final files = await _filesOf(_selection);
    if (files.isEmpty) return _toast(tr('mylib.cannot_open'));
    await _shareFiles(files);
  }

  Future<void> _send() async {
    final files = await _filesOf(_selection);
    if (files.isEmpty) return _toast(tr('mylib.cannot_open'));
    if (!mounted) return;
    await _sendFiles(files, clearSelection: true);
  }

  Future<void> _sendFiles(List<File> files, {bool clearSelection = false}) async {
    final sender = await pickFileTarget(context, widget.settings, widget.discovery, files);
    if (sender == null || !mounted) return;
    if (clearSelection) setState(_selected.clear);
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => SendFilesPage(sender: sender)));
  }

  Future<void> _delete() async {
    final list = _selection;
    if (list.isEmpty) return;
    final files = list.where((i) => !i.isAsset).length;
    // Photos and videos: the system asks itself. Files: we ask.
    if (files > 0) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: Text(tr('mylib.delete_title', {'count': list.length})),
          content: Text(tr('mylib.delete_body')),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: Text(tr('common.cancel'))),
            FilledButton(onPressed: () => Navigator.pop(c, true), child: Text(tr('mylib.delete'))),
          ],
        ),
      );
      if (ok != true) return;
    }
    final n = await lib.delete(list);
    if (!mounted) return;
    setState(_selected.clear);
    _toast(tr('mylib.deleted', {'count': n}));
  }

  Future<void> _rename() async {
    final list = _selection;
    if (list.length != 1 || list.first.isAsset) return;
    final i = list.first;
    final dot = i.name.lastIndexOf('.');
    final c = TextEditingController(text: dot > 0 ? i.name.substring(0, dot) : i.name);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('mylib.rename')),
        content: TextField(controller: c, autofocus: true, onSubmitted: (v) => Navigator.pop(ctx, v)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(tr('common.cancel'))),
          FilledButton(onPressed: () => Navigator.pop(ctx, c.text), child: Text(tr('common.ok'))),
        ],
      ),
    );
    c.dispose();
    if (name == null || name.trim().isEmpty) return;
    if (!await lib.rename(i, name)) _toast(tr('mylib.rename_failed'));
    if (mounted) setState(_selected.clear);
  }

  // ------------------------------------------------------------------ UI

  String _tabLabel(_Tab t) => switch (t) {
        _Tab.all => tr('mylib.all'),
        _Tab.photo => tr('mylib.photos'),
        _Tab.video => tr('mylib.videos'),
        _Tab.document => tr('mylib.docs'),
        _Tab.scan => tr('mylib.scans'),
        _Tab.other => tr('mylib.other'),
      };

  static String _day(int ms) {
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    return '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final shown = _shown;
    final selecting = _selected.isNotEmpty;
    final sources = lib.sources;
    // Group by day (newest first).
    final days = <String, List<MyItem>>{};
    for (final i in shown) {
      (days[_day(i.addedMs)] ??= []).add(i);
    }
    return PopScope(
      canPop: !selecting,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && selecting) setState(_selected.clear);
      },
      child: Scaffold(
        appBar: AppBar(
          title: selecting
              ? Text(tr('mylib.selected', {'count': _selected.length}))
              : _searching
                  ? TextField(
                      autofocus: true,
                      decoration: InputDecoration(hintText: tr('mylib.search'), border: InputBorder.none),
                      onChanged: (v) => setState(() => _query = v),
                    )
                  : Text(tr('mylib.title')),
          actions: selecting
              ? [
                  IconButton(
                    tooltip: tr('mylib.select_all'),
                    onPressed: () => setState(() => _selected.addAll(shown.map((i) => i.id))),
                    icon: const Icon(Icons.select_all_rounded),
                  ),
                ]
              : [
                  IconButton(
                    tooltip: tr('mylib.search'),
                    onPressed: () => setState(() {
                      _searching = !_searching;
                      if (!_searching) _query = '';
                    }),
                    icon: Icon(_searching ? Icons.close_rounded : Icons.search_rounded),
                  ),
                  IconButton(
                    tooltip: tr('mylib.trash'),
                    onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const _TrashPage())),
                    icon: const Icon(Icons.delete_outline_rounded),
                  ),
                ],
        ),
        body: Column(children: [
          SizedBox(
            height: 48,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              children: [
                for (final t in _Tab.values)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      label: Text(_tabLabel(t)),
                      selected: _tab == t,
                      onSelected: (_) => setState(() => _tab = t),
                    ),
                  ),
              ],
            ),
          ),
          if (sources.length > 1)
            SizedBox(
              height: 44,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
                children: [
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: FilterChip(
                      label: Text(tr('mylib.all_sources')),
                      selected: _source == null,
                      onSelected: (_) => setState(() => _source = null),
                    ),
                  ),
                  for (final (id, name) in sources)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: FilterChip(
                        avatar: const Icon(Icons.devices_rounded, size: 16),
                        label: Text(name),
                        selected: _source == id,
                        onSelected: (_) => setState(() => _source = _source == id ? null : id),
                      ),
                    ),
                ],
              ),
            ),
          Expanded(
            child: _busy && shown.isEmpty
                ? const Center(child: CircularProgressIndicator())
                : shown.isEmpty
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(32),
                          child: Text(tr('mylib.empty'), textAlign: TextAlign.center, style: const TextStyle(color: LrColors.muted)),
                        ),
                      )
                    : RefreshIndicator(
                        onRefresh: lib.reconcile,
                        child: CustomScrollView(slivers: [
                          for (final e in days.entries) ...[
                            SliverToBoxAdapter(
                              child: Padding(
                                padding: const EdgeInsets.fromLTRB(14, 14, 14, 6),
                                child: Text(e.key, style: const TextStyle(fontWeight: FontWeight.w700, color: LrColors.muted)),
                              ),
                            ),
                            SliverPadding(
                              padding: const EdgeInsets.symmetric(horizontal: 4),
                              sliver: SliverGrid(
                                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                                  crossAxisCount: 4,
                                  mainAxisSpacing: 3,
                                  crossAxisSpacing: 3,
                                ),
                                delegate: SliverChildBuilderDelegate(
                                  (context, k) => _tile(e.value[k]),
                                  childCount: e.value.length,
                                ),
                              ),
                            ),
                          ],
                          const SliverToBoxAdapter(child: SizedBox(height: 90)),
                        ]),
                      ),
          ),
        ]),
        bottomNavigationBar: selecting ? _actions() : null,
      ),
    );
  }

  Widget _actions() {
    final sel = _selection;
    final canRename = sel.length == 1 && !sel.first.isAsset;
    Widget b(IconData icon, String label, VoidCallback? onTap) => Expanded(
          child: InkWell(
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Icon(icon, color: onTap == null ? LrColors.line : null),
                const SizedBox(height: 4),
                Text(label, style: TextStyle(fontSize: 12, color: onTap == null ? LrColors.line : null)),
              ]),
            ),
          ),
        );
    return SafeArea(
      child: Material(
        color: LrColors.raised,
        child: Row(children: [
          b(Icons.ios_share_rounded, tr('mylib.share'), _share),
          b(Icons.send_rounded, tr('mylib.send'), _send),
          b(Icons.drive_file_rename_outline_rounded, tr('mylib.rename'), canRename ? _rename : null),
          b(Icons.delete_outline_rounded, tr('mylib.delete'), _delete),
        ]),
      ),
    );
  }

  Widget _tile(MyItem i) {
    final selected = _selected.contains(i.id);
    return GestureDetector(
      onTap: () {
        if (_selected.isNotEmpty) {
          setState(() => selected ? _selected.remove(i.id) : _selected.add(i.id));
        } else {
          unawaited(_open(i));
        }
      },
      onLongPress: () => setState(() => _selected.add(i.id)),
      child: Stack(fit: StackFit.expand, children: [
        // Same pictures as on the home screen (PDFs: their first page).
        MyItemThumb(item: i),
        if (selected) Container(color: LrColors.safelight.withValues(alpha: 0.35)),
        if (selected) const Positioned(right: 4, top: 4, child: Icon(Icons.check_circle_rounded, color: LrColors.safelight)),
      ]),
    );
  }
}

/// An item's small picture: a thumbnail, or the file's kind and name.
class MyItemThumb extends StatelessWidget {
  const MyItemThumb({super.key, required this.item});

  final MyItem item;

  @override
  Widget build(BuildContext context) => Stack(fit: StackFit.expand, children: [
        item.kind.isMedia
            ? _Thumb(item: item)
            : item.name.toLowerCase().endsWith('.pdf')
                ? _PdfTile(item: item)
                : _DocTile(item: item),
        if (item.kind == MyKind.video)
          const Positioned(right: 4, bottom: 4, child: Icon(Icons.play_circle_fill_rounded, size: 18, color: Colors.white)),
      ]);
}

/// A photo / video thumbnail (from the photo library).
class _Thumb extends StatelessWidget {
  const _Thumb({required this.item});

  final MyItem item;

  static final Map<String, Future<Uint8List?>> _cache = {};

  Future<Uint8List?> _load(String assetId) => _cache.putIfAbsent(assetId, () async {
        final a = await AssetEntity.fromId(assetId);
        return a?.thumbnailDataWithSize(const ThumbnailSize.square(240), quality: 80);
      });

  @override
  Widget build(BuildContext context) {
    final id = item.assetId;
    // Kept as a file (the photo library would not take it, or no access):
    // a photo is drawn from the file; anything else shows its kind.
    if (id == null) return item.kind == MyKind.photo ? _FilePhoto(item: item, size: 240) : _DocTile(item: item);
    return FutureBuilder<Uint8List?>(
      future: _load(id),
      builder: (context, s) {
        final b = s.data;
        if (b == null) return Container(color: LrColors.surface);
        return Image.memory(b, fit: BoxFit.cover, gaplessPlayback: true);
      },
    );
  }
}

/// A photo kept as a file in LocalRoll's folder (not in the photo
/// library): drawn straight from the file; its name if it can't be.
class _FilePhoto extends StatelessWidget {
  const _FilePhoto({required this.item, this.size, this.fit = BoxFit.cover});

  final MyItem item;

  /// Decoded at about this width (thumbnails); null = full size.
  final int? size;
  final BoxFit fit;

  static final Map<String, Future<String?>> _paths = {};

  @override
  Widget build(BuildContext context) => FutureBuilder<String?>(
        future: _paths.putIfAbsent('${item.id}|${item.name}', () => MyLibrary.instance.pathOf(item)),
        builder: (context, s) {
          final path = s.data;
          if (path == null) {
            return s.connectionState == ConnectionState.done ? _FileTile(item: item) : Container(color: LrColors.surface);
          }
          return Image.file(
            File(path),
            fit: fit,
            cacheWidth: size,
            gaplessPlayback: true,
            errorBuilder: (_, _, _) => _FileTile(item: item),
          );
        },
      );
}

/// A PDF: its first page, its name below (the icon until the page is drawn).
class _PdfTile extends StatelessWidget {
  const _PdfTile({required this.item});

  final MyItem item;

  /// Per item and name (a renamed file is drawn again): the same future on
  /// every rebuild, so the page doesn't flicker back to the icon.
  static final Map<String, Future<Uint8List?>> _cache = {};

  Future<Uint8List?> _load() => _cache.putIfAbsent('${item.id}|${item.name}', () async {
        final path = await MyLibrary.instance.pathOf(item);
        if (path == null) return null;
        return PdfPages.thumb(path);
      });

  @override
  Widget build(BuildContext context) => FutureBuilder<Uint8List?>(
        future: _load(),
        builder: (context, s) {
          final b = s.data;
          if (b == null) return _FileTile(item: item);
          return Stack(fit: StackFit.expand, children: [
            Container(
              color: Colors.white,
              child: Image.memory(b, fit: BoxFit.cover, alignment: Alignment.topCenter, gaplessPlayback: true),
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: Container(
                color: Colors.black54,
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                child: Text(item.name,
                    maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 10, color: Colors.white)),
              ),
            ),
          ]);
        },
      );
}

/// Any other file: its first page — the iPhone's own picture of it when the
/// system has one (Office, iWork, text…), else drawn here (Word, Excel,
/// PowerPoint, text, CSV); the icon for anything else. Its name below.
class _DocTile extends StatelessWidget {
  const _DocTile({required this.item});

  final MyItem item;

  /// A PNG (from the system) or a [FirstPage], per item and name.
  static final Map<String, Future<Object?>> _cache = {};

  Future<Object?> _load() => _cache.putIfAbsent('${item.id}|${item.name}', () async {
        final path = await MyLibrary.instance.pathOf(item);
        if (path == null) return null;
        final png = await FileOpener.thumbnail(path);
        if (png != null) return png;
        return FirstPages.of(path, name: item.name);
      });

  @override
  Widget build(BuildContext context) => FutureBuilder<Object?>(
        future: _load(),
        builder: (context, s) {
          final d = s.data;
          final Widget page;
          if (d is Uint8List) {
            page = Container(
              color: Colors.white,
              child: Image.memory(d, fit: BoxFit.cover, alignment: Alignment.topCenter, gaplessPlayback: true),
            );
          } else if (d is FirstPage) {
            page = FirstPageView(page: d);
          } else {
            return _FileTile(item: item);
          }
          return Stack(fit: StackFit.expand, children: [
            page,
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: Container(
                color: Colors.black54,
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                child: Row(children: [
                  Icon(_FileTile.iconFor(item.name), size: 11, color: Colors.white),
                  const SizedBox(width: 3),
                  Expanded(
                    child: Text(item.name,
                        maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 10, color: Colors.white)),
                  ),
                ]),
              ),
            ),
          ]);
        },
      );
}

/// A file: its kind as an icon, its name below.
class _FileTile extends StatelessWidget {
  const _FileTile({required this.item});

  final MyItem item;

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
  Widget build(BuildContext context) => Container(
        color: LrColors.surface,
        padding: const EdgeInsets.all(6),
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          Icon(iconFor(item.name), size: 30, color: item.kind == MyKind.scan ? LrColors.verified : LrColors.safelight),
          const SizedBox(height: 4),
          Text(item.name, maxLines: 2, overflow: TextOverflow.ellipsis, textAlign: TextAlign.center, style: const TextStyle(fontSize: 10.5)),
        ]),
      );
}

/// "From X · date · size" under a title.
String _about(MyItem i) {
  final d = DateTime.fromMillisecondsSinceEpoch(i.addedMs);
  final when = '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')} '
      '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
  return [tr('mylib.from', {'name': i.fromName}), when, if (i.size > 0) formatSize(i.size)].join(' · ');
}

/// Photos and videos, full screen, swipe left / right.
class _MediaViewer extends StatefulWidget {
  const _MediaViewer({required this.items, required this.start});

  final List<MyItem> items;
  final int start;

  @override
  State<_MediaViewer> createState() => _MediaViewerState();
}

class _MediaViewerState extends State<_MediaViewer> {
  late final PageController _pages = PageController(initialPage: widget.start);
  late int _at = widget.start;

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final i = widget.items[_at];
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(i.name, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 15)),
          Text(_about(i), style: const TextStyle(fontSize: 12, color: LrColors.muted)),
        ]),
      ),
      body: PageView.builder(
        controller: _pages,
        itemCount: widget.items.length,
        onPageChanged: (n) => setState(() => _at = n),
        itemBuilder: (context, k) {
          final it = widget.items[k];
          return it.kind == MyKind.video ? _Video(key: ValueKey(it.id), item: it, active: k == _at) : _Photo(item: it);
        },
      ),
    );
  }
}

class _Photo extends StatelessWidget {
  const _Photo({required this.item});

  final MyItem item;

  Future<Uint8List?> _load() async {
    final a = await AssetEntity.fromId(item.assetId!);
    return a?.thumbnailDataWithSize(const ThumbnailSize(2560, 2560), quality: 90);
  }

  @override
  Widget build(BuildContext context) => item.assetId == null
      ? InteractiveViewer(maxScale: 6, child: Center(child: _FilePhoto(item: item, size: 2560, fit: BoxFit.contain)))
      : FutureBuilder<Uint8List?>(
        future: _load(),
        builder: (context, s) {
          final b = s.data;
          if (b == null) {
            return s.connectionState == ConnectionState.done
                ? Center(child: Text(tr('mylib.cannot_open'), style: const TextStyle(color: LrColors.muted)))
                : const Center(child: CircularProgressIndicator());
          }
          return InteractiveViewer(maxScale: 6, child: Center(child: Image.memory(b, fit: BoxFit.contain)));
        },
      );
}

class _Video extends StatefulWidget {
  const _Video({super.key, required this.item, required this.active});

  final MyItem item;
  final bool active;

  @override
  State<_Video> createState() => _VideoState();
}

class _VideoState extends State<_Video> {
  VideoPlayerController? _c;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    unawaited(_open());
  }

  Future<void> _open() async {
    try {
      // In the photo library, or kept as a file in LocalRoll's folder.
      final id = widget.item.assetId;
      final path = id == null ? await MyLibrary.instance.pathOf(widget.item) : null;
      final f = id != null ? await (await AssetEntity.fromId(id))?.file : (path == null ? null : File(path));
      if (f == null) throw StateError('no file');
      final c = VideoPlayerController.file(f);
      await c.initialize();
      if (!mounted) {
        await c.dispose();
        return;
      }
      setState(() => _c = c);
      if (widget.active) await c.play();
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  @override
  void didUpdateWidget(_Video old) {
    super.didUpdateWidget(old);
    if (old.active && !widget.active) unawaited(_c?.pause());
  }

  @override
  void dispose() {
    unawaited(_c?.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_failed) return Center(child: Text(tr('mylib.cannot_open'), style: const TextStyle(color: LrColors.muted)));
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

/// "Recently deleted": files kept 30 days; restore or delete for good.
class _TrashPage extends StatefulWidget {
  const _TrashPage();

  @override
  State<_TrashPage> createState() => _TrashPageState();
}

class _TrashPageState extends State<_TrashPage> {
  final MyLibrary lib = MyLibrary.instance;

  @override
  void initState() {
    super.initState();
    lib.addListener(_changed);
  }

  @override
  void dispose() {
    lib.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final list = lib.trash;
    final now = DateTime.now().millisecondsSinceEpoch;
    return Scaffold(
      appBar: AppBar(
        title: Text(tr('mylib.trash')),
        actions: [
          if (list.isNotEmpty)
            TextButton(
              onPressed: () async {
                final ok = await showDialog<bool>(
                  context: context,
                  builder: (c) => AlertDialog(
                    title: Text(tr('mylib.purge_all', {'count': list.length})),
                    actions: [
                      TextButton(onPressed: () => Navigator.pop(c, false), child: Text(tr('common.cancel'))),
                      FilledButton(onPressed: () => Navigator.pop(c, true), child: Text(tr('mylib.purge'))),
                    ],
                  ),
                );
                if (ok == true) await lib.purge(list);
              },
              child: Text(tr('mylib.purge')),
            ),
        ],
      ),
      body: list.isEmpty
          ? Center(child: Text(tr('mylib.trash_empty'), style: const TextStyle(color: LrColors.muted)))
          : ListView(children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                child: Text(tr('mylib.trash_hint'), style: const TextStyle(color: LrColors.muted, fontSize: 13)),
              ),
              for (final i in list)
                ListTile(
                  leading: Icon(_FileTile.iconFor(i.name)),
                  title: Text(i.name, overflow: TextOverflow.ellipsis),
                  subtitle: Text(tr('mylib.days_left', {
                    'days': (30 - (now - (i.deletedMs ?? now)) ~/ Duration.millisecondsPerDay).clamp(0, 30),
                  })),
                  trailing: TextButton(
                    onPressed: () async {
                      final ok = await lib.restore(i);
                      if (!context.mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text(tr(ok ? 'mylib.restored' : 'mylib.cannot_open'))));
                    },
                    child: Text(tr('mylib.restore')),
                  ),
                ),
            ]),
    );
  }
}
