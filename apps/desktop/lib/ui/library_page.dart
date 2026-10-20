// apps/desktop/lib/ui/library_page.dart
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:localroll_core/localroll_core.dart';

import '../app_services.dart';
import '../l10n/l10n.dart';
import '../services/converter.dart';
import '../services/file_actions.dart';
import '../services/library_index.dart';
import '../services/network.dart';
import '../services/peers.dart';
import '../services/win_dialogs.dart';
import 'files_view.dart';
import 'library_recovery.dart';
import 'media_thumb.dart';
import 'send_page.dart';
import 'theme.dart';
import 'viewer_page.dart';

enum _Filter { all, photos, videos, docs, other }

/// One square on the "All" timeline: a library photo / video, or a received
/// file (Documents / Other).
class _Cell {
  _Cell.media(MediaItem this.media, this.day) : file = null;
  _Cell.file(ReceivedFile this.file) : media = null, day = file.arrived;

  final MediaItem? media;
  final ReceivedFile? file;
  final DateTime day;
}

/// Received media grouped by capture day, newest first; All / Photos / Videos.
class LibraryPage extends StatefulWidget {
  const LibraryPage({super.key, required this.services});

  final AppServices services;

  @override
  State<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends State<LibraryPage> {
  _Filter _filter = _Filter.all;
  final Set<String> _selected = {};

  /// Family group: show one member only (null = everyone).
  String? _member;

  /// "Only me" items are hidden until this is switched on.
  bool _showPrivate = false;

  bool get _selecting => _selected.isNotEmpty;

  /// Received files (Documents / Other), shown on the "All" timeline by the
  /// day they arrived.
  List<ReceivedFile> _files = const [];
  int _seenSaved = -1;
  final List<StreamSubscription<FileSystemEvent>> _watches = [];
  Timer? _filesSoon;

  @override
  void initState() {
    super.initState();
    widget.services.hub.addListener(_onHub);
    unawaited(_loadFiles());
    unawaited(_watchFiles());
  }

  @override
  void dispose() {
    widget.services.hub.removeListener(_onHub);
    for (final w in _watches) {
      unawaited(w.cancel());
    }
    _filesSoon?.cancel();
    super.dispose();
  }

  /// A file arrived: show it.
  void _onHub() {
    final n = widget.services.hub.savedFiles.length;
    if (n != _seenSaved) {
      _seenSaved = n;
      _reloadFilesSoon();
    }
  }

  void _reloadFilesSoon() {
    _filesSoon?.cancel();
    _filesSoon = Timer(const Duration(milliseconds: 800), () => unawaited(_loadFiles()));
  }

  Future<void> _loadFiles() async {
    final f = await ReceivedFile.scan(widget.services);
    if (mounted) setState(() => _files = f);
  }

  /// Changes made in Explorer (deleted, renamed, copied in) show up too.
  Future<void> _watchFiles() async {
    for (final doc in [true, false]) {
      try {
        final dir = await widget.services.server.folderPath(document: doc);
        _watches.add(Directory(dir).watch(recursive: true).listen((_) => _reloadFilesSoon(), onError: (_) {}));
      } catch (_) {}
    }
  }

  /// Received files that belong on the "All" timeline now.
  List<ReceivedFile> _visibleFiles() {
    // Files carry no sender: hidden while one person is picked.
    if (_filter != _Filter.all || _member != null) return const [];
    if (!_onlyRecent) return _files;
    final since = DateTime.now().subtract(const Duration(hours: 24));
    return [for (final f in _files) if (f.arrived.isAfter(since)) f];
  }

  /// Photos / videos and received files, newest first, in one list.
  List<_Cell> _cells(List<MediaItem> items) {
    final out = [
      for (final i in items) _Cell.media(i, _dayOf(i)),
      for (final f in _visibleFiles()) _Cell.file(f),
    ]..sort((a, b) => b.day.compareTo(a.day));
    return out;
  }

  /// Who sent [i]: the family member of its phone, or the phone's name if it
  /// is no longer paired.
  String _memberOf(FamilyDirectory family, MediaItem i) =>
      (i.deviceId == null ? null : family.memberOf(i.deviceId!)) ?? i.deviceName ?? '?';

  bool get _filesTab => _filter == _Filter.docs || _filter == _Filter.other;

  /// Order by when it was taken (default) or when it arrived here.
  bool _byReceived = false;

  /// Only what arrived recently ("Just received"), still ordered by date.
  bool _onlyRecent = false;

  /// Arrivals of the last 24 hours not yet looked at: old photos sent today
  /// sit far down the timeline, so they are offered at the top as well.
  List<MediaItem> _recent(List<MediaItem> all) {
    final since = DateTime.now().subtract(const Duration(hours: 24)).millisecondsSinceEpoch;
    final from = since > widget.services.settings.recentSeenMs ? since : widget.services.settings.recentSeenMs;
    return [for (final i in all) if (i.receivedMs > from) i];
  }

  DateTime _dayOf(MediaItem i) => _byReceived ? DateTime.fromMillisecondsSinceEpoch(i.receivedMs) : i.captureTime;

  List<MediaItem> _visible(List<MediaItem> all, FamilyDirectory family) {
    var list = _filtered(all, family);
    if (_onlyRecent) {
      final since = DateTime.now().subtract(const Duration(hours: 24)).millisecondsSinceEpoch;
      list = [for (final i in list) if (i.receivedMs > since) i];
    }
    if (_byReceived) list.sort((a, b) => b.receivedMs.compareTo(a.receivedMs));
    return list;
  }

  List<MediaItem> _filtered(List<MediaItem> all, FamilyDirectory family) => [
        for (final i in all)
          if ((_filter == _Filter.all ||
                  (_filter == _Filter.photos && i.kind == MediaKind.image) ||
                  (_filter == _Filter.videos && i.kind == MediaKind.video)) &&
              (_showPrivate || !i.private) &&
              (_member == null || FamilyDirectory.keyOf(_memberOf(family, i)) == FamilyDirectory.keyOf(_member!)))
            i,
      ];

  /// Member chips + "show only-me items", shown once there is a family.
  /// "Everyone ▾": whose items to show (one entry per person / phone /
  /// other PC, with how many), and whether to show "only me" items.
  Widget? _personMenu(List<MediaItem> all, FamilyDirectory family) {
    final counts = <String, int>{};
    final pcs = <String>{};
    final st = widget.services.settings;
    for (final i in all) {
      if (i.private && !_showPrivate) continue;
      final m = _memberOf(family, i);
      counts[m] = (counts[m] ?? 0) + 1;
      final t = i.deviceId == null ? null : st.trusted[i.deviceId!];
      if (t != null && isDesktopPlatform(t.platform)) pcs.add(m);
    }
    final members = counts.keys.toList();
    final privateCount = all.where((i) => i.private).length;
    if (members.length < 2 && privateCount == 0) return null;
    return PopupMenuButton<String>(
      tooltip: tr('family.everyone'),
      onSelected: (v) => setState(() {
        if (v == '\u0000private') {
          _showPrivate = !_showPrivate;
        } else if (v.isEmpty) {
          _member = null;
        } else {
          _member = v;
        }
      }),
      itemBuilder: (_) => [
        CheckedPopupMenuItem(value: '', checked: _member == null, child: Text(tr('family.everyone'))),
        for (final m in members)
          CheckedPopupMenuItem(
            value: m,
            checked: _member != null && FamilyDirectory.keyOf(_member!) == FamilyDirectory.keyOf(m),
            child: Row(children: [
              if (pcs.contains(m)) const Padding(padding: EdgeInsets.only(right: 6), child: Icon(Icons.computer_rounded, size: 16)),
              Text('$m · ${counts[m]}'),
            ]),
          ),
        if (privateCount > 0) ...[
          const PopupMenuDivider(),
          CheckedPopupMenuItem(
            value: '\u0000private',
            checked: _showPrivate,
            child: Text(tr('family.show_private', {'count': privateCount})),
          ),
        ],
      ],
      child: _toolChip(Icons.groups_rounded, _member ?? tr('family.everyone')),
    );
  }

  /// A labelled dropdown-looking button for the toolbar.
  Widget _toolChip(IconData icon, String label) => Container(
        height: 36,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(borderRadius: BorderRadius.circular(10), border: Border.all(color: LrColors.line)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 18, color: LrColors.muted),
          const SizedBox(width: 6),
          Text(label, style: const TextStyle(fontSize: 13.5)),
          const Icon(Icons.arrow_drop_down_rounded, color: LrColors.muted),
        ]),
      );

  @override
  Widget build(BuildContext context) {
    final s = widget.services;
    return ListenableBuilder(
      listenable: Listenable.merge([s.library, s.settings]),
      builder: (context, _) {
        final family = s.settings.family;
        final all = s.library.items;
        final items = _visible(all, family);
        _selected.removeWhere((p) => !items.any((i) => i.relPath == p));
        return Scaffold(
          appBar: AppBar(
            title: _selecting
                ? Text(tr('library.selected', {'count': _selected.length}))
                : Row(children: [
                    Text(tr('nav.library')),
                    const SizedBox(width: 12),
                    Flexible(
                      child: Text(tr('library.hover_hint'),
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(color: LrColors.muted, fontSize: 13, fontWeight: FontWeight.w400)),
                    ),
                    if (!_onlyRecent && _recent(all).isNotEmpty) ...[
                      const SizedBox(width: 12),
                      ActionChip(
                        avatar: const Icon(Icons.fiber_new_rounded, size: 18, color: LrColors.safelight),
                        label: Text(tr('lib.recent_chip', {'count': _recent(all).length})),
                        onPressed: () => setState(() => _onlyRecent = true),
                      ),
                      IconButton(
                        tooltip: tr('lib.recent_dismiss'),
                        iconSize: 16,
                        onPressed: () => s.settings.update((x) => x.recentSeenMs = DateTime.now().millisecondsSinceEpoch),
                        icon: const Icon(Icons.close_rounded),
                      ),
                    ],
                  ]),
            leading: _selecting
                ? IconButton(icon: const Icon(Icons.close), onPressed: () => setState(_selected.clear))
                : null,
            actions: [
              if (_selecting) ...[
                IconButton(
                  tooltip: tr('lib.export'),
                  icon: const Icon(Icons.drive_file_move_rounded),
                  onPressed: () => _export(items.where((i) => _selected.contains(i.relPath)).toList()),
                ),
                IconButton(
                  tooltip: tr('send.to_pc'),
                  icon: const Icon(Icons.send_rounded),
                  onPressed: () => _sendToPc(items.where((i) => _selected.contains(i.relPath)).toList()),
                ),
                IconButton(
                  tooltip: tr('lib.delete'),
                  icon: const Icon(Icons.delete_outline_rounded),
                  onPressed: () => _delete(items.where((i) => _selected.contains(i.relPath)).toList()),
                ),
                PopupMenuButton<ConvertPreset>(
                  tooltip: tr('convert.selected_tooltip'),
                  icon: const Icon(Icons.auto_fix_high),
                  onSelected: (p) {
                    s.converter.enqueue(items.where((i) => _selected.contains(i.relPath)), p);
                    setState(_selected.clear);
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text(tr('convert.queued', {'preset': p.label}))),
                    );
                  },
                  itemBuilder: (_) => [
                    for (final p in ConvertPreset.values) PopupMenuItem(value: p, child: Text(tr('convert.to', {'preset': p.label}))),
                  ],
                ),
              ] else ...[
                SegmentedButton<_Filter>(
                  segments: [
                    ButtonSegment(value: _Filter.all, label: Text(tr('library.filter_all'))),
                    ButtonSegment(value: _Filter.photos, label: Text(tr('library.filter_photos'))),
                    ButtonSegment(value: _Filter.videos, label: Text(tr('library.filter_videos'))),
                    ButtonSegment(value: _Filter.docs, label: Text(tr('library.filter_docs'))),
                    ButtonSegment(value: _Filter.other, label: Text(tr('library.filter_other'))),
                  ],
                  selected: {_filter},
                  onSelectionChanged: (v) => setState(() => _filter = v.first),
                ),
                const SizedBox(width: 8),
                // New arrivals from a phone or PC can have old capture dates
                // and land far down the list; "by arrival" puts them on top.
                if (!_filesTab) ?_personMenu(all, family),
                const SizedBox(width: 8),
                PopupMenuButton<bool>(
                  tooltip: tr('library.sort'),
                  initialValue: _byReceived,
                  onSelected: (v) => setState(() => _byReceived = v),
                  itemBuilder: (_) => [
                    CheckedPopupMenuItem(value: false, checked: !_byReceived, child: Text(tr('library.sort_taken'))),
                    CheckedPopupMenuItem(value: true, checked: _byReceived, child: Text(tr('library.sort_received'))),
                  ],
                  child: _toolChip(Icons.sort_rounded, tr(_byReceived ? 'library.sort_received' : 'library.sort_taken')),
                ),
                if (!_filesTab)
                  PopupMenuButton<int>(
                    tooltip: tr('library.size'),
                    initialValue: s.settings.thumbSize,
                    onSelected: (v) => s.settings.update((x) => x.thumbSize = v),
                    itemBuilder: (_) => [
                      for (final (v, k) in [(0, 'library.size_s'), (1, 'library.size_m'), (2, 'library.size_l')])
                        CheckedPopupMenuItem(value: v, checked: s.settings.thumbSize == v, child: Text(tr(k))),
                    ],
                    icon: const Icon(Icons.photo_size_select_large_rounded),
                  ),
                IconButton(
                  tooltip: tr('library.open_folder'),
                  onPressed: () => revealInExplorer(s.library.rootPath),
                  icon: const Icon(Icons.folder_open),
                ),
              ],
              const SizedBox(width: 8),
            ],
          ),
          body: Column(
            children: [
              ..._banners(context),
              Expanded(
                child: _filesTab
                    // Documents / other files from PCs: a file list, not photos.
                    ? FilesView(services: s, document: _filter == _Filter.docs)
                    : items.isEmpty && _visibleFiles().isEmpty
                        ? _empty(context)
                        : _grid(context, items),
              ),
            ],
          ),
        );
      },
    );
  }

  /// Library folder unreachable, or many files vanished at once.
  List<Widget> _banners(BuildContext context) {
    final lib = widget.services.library;
    final theme = Theme.of(context);
    Widget banner(IconData icon, Color color, String text, List<Widget> actions) => Container(
          margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: color.withValues(alpha: 0.6)),
          ),
          child: Row(children: [
            Icon(icon, color: color),
            const SizedBox(width: 12),
            Expanded(child: Text(text, style: theme.textTheme.bodyMedium)),
            ...actions,
          ]),
        );
    return [
      if (_onlyRecent)
        banner(Icons.schedule_rounded, LrColors.safelight, tr('lib.recent_only'), [
          TextButton(onPressed: () => setState(() => _onlyRecent = false), child: Text(tr('lib.recent_all'))),
        ]),
      // Unplugged drive / deleted or moved folder: what can be done.
      if (lib.offline) LibraryRecovery(services: widget.services),
      if (!lib.offline && lib.pendingMissing.isNotEmpty)
        banner(Icons.help_outline_rounded, Colors.amber, tr('lib.missing_ask', {'count': lib.pendingMissing.length}), [
          TextButton(onPressed: lib.retry, child: Text(tr('lib.missing_rescan'))),
          const SizedBox(width: 4),
          FilledButton(onPressed: lib.confirmMissing, child: Text(tr('lib.missing_confirm'))),
        ]),
    ];
  }

  /// Delete = move to the Windows Recycle Bin. Phones are told next time.
  Future<void> _delete(List<MediaItem> items) async {
    if (items.isEmpty) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.delete_outline_rounded, size: 32),
        title: Text(tr('lib.delete_title', {'count': items.length})),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Text(tr('lib.delete_body')),
        ),
        actions: [
          OutlinedButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('exit.stay'))),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(tr('lib.delete'))),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    // Big deletions: show progress (thousands of files take a little while).
    final progress = ValueNotifier<(int, int)>((0, items.length));
    final showProgress = items.length >= 50;
    if (showProgress) {
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => PopScope(
          canPop: false,
          child: AlertDialog(
            content: ValueListenableBuilder<(int, int)>(
              valueListenable: progress,
              builder: (_, v, _) => Column(mainAxisSize: MainAxisSize.min, children: [
                Text(tr('lib.deleting', {'done': v.$1, 'total': v.$2})),
                const SizedBox(height: 12),
                LinearProgressIndicator(value: v.$2 == 0 ? null : v.$1 / v.$2),
              ]),
            ),
          ),
        ),
      );
    }
    final n = await deleteItems(
      widget.services.library,
      items,
      onProgress: (done, total) => progress.value = (done, total),
    );
    if (showProgress && mounted) Navigator.of(context).pop();
    progress.dispose();
    if (!mounted) return;
    setState(_selected.clear);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('lib.deleted', {'count': n}))));
  }

  /// Send originals (with their Live Photo videos) to another PC's library.
  Future<void> _sendToPc(List<MediaItem> items) async {
    if (items.isEmpty) return;
    final lib = widget.services.library;
    final files = [for (final i in lib.withLive(items)) ?SendFile.fromLibrary(lib, i)];
    if (files.isEmpty) return;
    setState(_selected.clear);
    await sendToPc(context, widget.services, files,
        items.length == 1 ? items.first.name : tr('send.n_items', {'count': items.length}));
  }

  /// Copy the originals into a folder of your choice.
  Future<void> _export(List<MediaItem> items) async {
    if (items.isEmpty) return;
    final folder = await WinDialogs.pickFolder(title: tr('lib.export'));
    if (folder == null) return;
    final n = await exportItems(widget.services.library, items, folder);
    if (!mounted) return;
    setState(_selected.clear);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(tr('lib.exported', {'count': n})),
      action: SnackBarAction(label: tr('common.open'), onPressed: () => revealInExplorer(folder)),
    ));
  }

  /// Right-click menu: acts on the selection if the item is part of it.
  Future<void> _contextMenu(BuildContext context, List<MediaItem> items, int index, Offset at) async {
    final item = items[index];
    final targets = _selected.contains(item.relPath)
        ? items.where((i) => _selected.contains(i.relPath)).toList()
        : [item];
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final choice = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(at & const Size(1, 1), Offset.zero & overlay.size),
      items: [
        if (targets.length == 1) PopupMenuItem(value: 'open', child: _menuRow(Icons.open_in_full_rounded, tr('lib.open'))),
        PopupMenuItem(
          value: 'select',
          child: _menuRow(Icons.check_circle_outline_rounded,
              _selected.contains(item.relPath) ? tr('lib.unselect') : tr('lib.select')),
        ),
        const PopupMenuDivider(),
        for (final p in ConvertPreset.values)
          PopupMenuItem(value: 'convert:${p.name}', child: _menuRow(Icons.auto_fix_high_rounded, tr('convert.to', {'preset': p.label}))),
        PopupMenuItem(value: 'export', child: _menuRow(Icons.drive_file_move_rounded, tr('lib.export'))),
        PopupMenuItem(value: 'send', child: _menuRow(Icons.send_rounded, tr('send.to_pc'))),
        if (targets.length == 1)
          PopupMenuItem(value: 'reveal', child: _menuRow(Icons.folder_open_rounded, tr('common.show_in_folder'))),
        // Family group: who may see it.
        if (targets.any((i) => !i.private))
          PopupMenuItem(value: 'private', child: _menuRow(Icons.lock_rounded, tr('family.make_private'))),
        if (targets.any((i) => i.private))
          PopupMenuItem(value: 'shared', child: _menuRow(Icons.groups_rounded, tr('family.make_shared'))),
        const PopupMenuDivider(),
        PopupMenuItem(
          value: 'delete',
          child: _menuRow(Icons.delete_outline_rounded,
              targets.length == 1 ? tr('lib.delete') : tr('lib.delete_n', {'count': targets.length}),
              danger: true),
        ),
      ],
    );
    if (!mounted || choice == null) return;
    final s = widget.services;
    switch (choice) {
      case 'open':
        await Navigator.of(this.context).push(MaterialPageRoute(
          builder: (_) => ViewerPage(services: s, items: items, initialIndex: index),
        ));
      case 'select':
        setState(() => _selected.contains(item.relPath) ? _selected.remove(item.relPath) : _selected.add(item.relPath));
      case 'export':
        await _export(targets);
      case 'send':
        await _sendToPc(targets);
      case 'reveal':
        revealInExplorer(s.library.absPath(item));
      case 'private' || 'shared':
        s.library.setPrivate(targets, choice == 'private');
        setState(_selected.clear);
      case 'delete':
        await _delete(targets);
      default:
        if (choice.startsWith('convert:')) {
          final p = ConvertPreset.values.firstWhere((x) => 'convert:${x.name}' == choice);
          s.converter.enqueue(targets, p);
          setState(_selected.clear);
          ScaffoldMessenger.of(this.context).showSnackBar(
            SnackBar(content: Text(tr('convert.queued', {'preset': p.label}))),
          );
        }
    }
  }

  Widget _menuRow(IconData icon, String text, {bool danger = false}) {
    final color = danger ? Theme.of(context).colorScheme.error : null;
    return Row(children: [
      Icon(icon, size: 18, color: color),
      const SizedBox(width: 12),
      Text(text, style: TextStyle(color: color)),
    ]);
  }

  Widget _empty(BuildContext context) => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.photo_library_outlined, size: 64, color: Theme.of(context).colorScheme.outline),
            const SizedBox(height: 12),
            Text(tr('library.empty')),
            const SizedBox(height: 4),
            Text(tr('library.empty_hint'), textAlign: TextAlign.center),
          ],
        ),
      );

  Widget _grid(BuildContext context, List<MediaItem> items) {
    // Group into days; photos / videos keep their index in [items] for the
    // viewer (it pages through photos and videos only).
    final cells = _cells(items);
    final indexOf = {for (var k = 0; k < items.length; k++) items[k].relPath: k};
    final slivers = <Widget>[];
    var start = 0;
    while (start < cells.length) {
      final t = cells[start].day;
      var end = start;
      while (end < cells.length && cells[end].day.year == t.year && cells[end].day.month == t.month && cells[end].day.day == t.day) {
        end++;
      }
      final day = cells.sublist(start, end);
      final photos = day.where((c) => c.media?.kind == MediaKind.image).length;
      final videos = day.where((c) => c.media?.kind == MediaKind.video).length;
      final files = day.where((c) => c.file != null).length;
      final theme = Theme.of(context);
      slivers
        ..add(SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 24, 16, 10),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Text(formatDayFull(t), style: theme.textTheme.titleMedium),
                const SizedBox(width: 12),
                Text(
                  [
                    if (photos > 0) tr('library.n_photos', {'count': photos}),
                    if (videos > 0) tr('library.n_videos', {'count': videos}),
                    if (files > 0) tr('library.n_files', {'count': files}),
                  ].join('   '),
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
          ),
        ))
        ..add(SliverPadding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          sliver: SliverGrid.builder(
            gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: const [120.0, 180.0, 260.0][widget.services.settings.thumbSize],
              mainAxisSpacing: 4,
              crossAxisSpacing: 4,
            ),
            itemCount: day.length,
            itemBuilder: (context, i) {
              final c = day[i];
              final m = c.media;
              return m != null ? _cell(context, items, indexOf[m.relPath]!) : _fileCell(context, c.file!);
            },
          ),
        ));
      start = end;
    }
    slivers.add(const SliverToBoxAdapter(child: SizedBox(height: 24)));
    return CustomScrollView(slivers: slivers);
  }

  /// A received file on the timeline: its first page and name; opens the
  /// way it does under Documents / Other.
  Widget _fileCell(BuildContext context, ReceivedFile f) {
    final s = widget.services;
    return Tooltip(
      message: f.name,
      waitDuration: const Duration(milliseconds: 600),
      child: GestureDetector(
        onTap: _selecting ? null : () => openReceivedFile(context, s, f.path),
        onSecondaryTapUp: (d) => _fileMenu(context, f, d.globalPosition),
        child: Stack(fit: StackFit.expand, children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: FileThumb(
              key: ValueKey(f.path),
              path: f.path,
              size: f.size,
              modified: f.modified,
              services: s,
              icon: Container(
                color: LrColors.raised,
                alignment: Alignment.center,
                child: Icon(_iconFor(f.name), size: 40, color: LrColors.muted),
              ),
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: Container(
              decoration: const BoxDecoration(
                color: Colors.black54,
                borderRadius: BorderRadius.vertical(bottom: Radius.circular(4)),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
              child: Row(children: [
                Icon(_iconFor(f.name), size: 13, color: Colors.white),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(f.name,
                      maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11, color: Colors.white)),
                ),
              ]),
            ),
          ),
        ]),
      ),
    );
  }

  static IconData _iconFor(String name) {
    final ext = extensionOf(name);
    if (ext == 'pdf') return Icons.picture_as_pdf_rounded;
    if (const {'doc', 'docx', 'odt', 'rtf', 'pages', 'wps', 'txt', 'md'}.contains(ext)) return Icons.description_rounded;
    if (const {'xls', 'xlsx', 'ods', 'csv', 'numbers', 'et'}.contains(ext)) return Icons.table_chart_rounded;
    if (const {'ppt', 'pptx', 'odp', 'key', 'dps'}.contains(ext)) return Icons.slideshow_rounded;
    if (const {'zip', 'rar', '7z', 'tar', 'gz'}.contains(ext)) return Icons.folder_zip_rounded;
    if (const {'mp3', 'm4a', 'wav', 'flac', 'aac', 'ogg'}.contains(ext)) return Icons.audio_file_rounded;
    if (MediaKind.fromName(name) == MediaKind.image) return Icons.image_rounded;
    if (MediaKind.fromName(name) == MediaKind.video) return Icons.movie_rounded;
    return Icons.insert_drive_file_rounded;
  }

  /// Right-click on a received file: open, show in its folder, delete.
  Future<void> _fileMenu(BuildContext context, ReceivedFile f, Offset at) async {
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final choice = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(at & const Size(1, 1), Offset.zero & overlay.size),
      items: [
        PopupMenuItem(value: 'open', child: _menuRow(Icons.open_in_full_rounded, tr('lib.open'))),
        PopupMenuItem(value: 'reveal', child: _menuRow(Icons.folder_open_rounded, tr('common.show_in_folder'))),
        const PopupMenuDivider(),
        PopupMenuItem(value: 'delete', child: _menuRow(Icons.delete_outline_rounded, tr('lib.delete'), danger: true)),
      ],
    );
    if (!mounted || choice == null) return;
    switch (choice) {
      case 'open':
        await openReceivedFile(this.context, widget.services, f.path);
      case 'reveal':
        revealInExplorer(f.path);
      case 'delete':
        final ok = await showDialog<bool>(
          context: this.context,
          builder: (c) => AlertDialog(
            title: Text(tr('files.delete_title', {'name': f.name})),
            content: Text(tr('files.delete_body')),
            actions: [
              TextButton(onPressed: () => Navigator.pop(c, false), child: Text(tr('common.cancel'))),
              FilledButton(onPressed: () => Navigator.pop(c, true), child: Text(tr('lib.delete'))),
            ],
          ),
        );
        if (ok != true) return;
        await moveToRecycleBin([f.path]);
        await _loadFiles();
    }
  }

  Widget _cell(BuildContext context, List<MediaItem> items, int index) {
    final s = widget.services;
    final item = items[index];
    final selected = _selected.contains(item.relPath);
    return GestureDetector(
      onTap: () {
        if (_selecting) {
          setState(() => selected ? _selected.remove(item.relPath) : _selected.add(item.relPath));
        } else {
          Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => ViewerPage(services: s, items: items, initialIndex: index),
          ));
        }
      },
      onLongPress: () => setState(() => _selected.add(item.relPath)),
      onSecondaryTapUp: (d) => _contextMenu(context, items, index, d.globalPosition),
      child: Stack(
        fit: StackFit.expand,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: MediaThumb(
              key: ValueKey(item.relPath),
              item: item,
              library: s.library,
              ffmpeg: s.ffmpeg,
            ),
          ),
          if (selected)
            Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(4),
                border: Border.all(color: Theme.of(context).colorScheme.primary, width: 3),
                color: Colors.black26,
              ),
              alignment: Alignment.topRight,
              padding: const EdgeInsets.all(4),
              child: Icon(Icons.check_circle, color: Theme.of(context).colorScheme.primary),
            ),
        ],
      ),
    );
  }
}
