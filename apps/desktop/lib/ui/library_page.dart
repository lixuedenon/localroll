// apps/desktop/lib/ui/library_page.dart
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
                    : items.isEmpty
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
    // Group into days while keeping the flat index for the viewer.
    final slivers = <Widget>[];
    var start = 0;
    while (start < items.length) {
      final t = _dayOf(items[start]);
      var end = start;
      while (end < items.length &&
          _dayOf(items[end]).year == t.year &&
          _dayOf(items[end]).month == t.month &&
          _dayOf(items[end]).day == t.day) {
        end++;
      }
      final groupStart = start;
      final count = end - start;
      final day = items.sublist(start, end);
      final photos = day.where((i) => i.kind == MediaKind.image).length;
      final videos = day.where((i) => i.kind == MediaKind.video).length;
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
            itemCount: count,
            itemBuilder: (context, i) => _cell(context, items, groupStart + i),
          ),
        ));
      start = end;
    }
    slivers.add(const SliverToBoxAdapter(child: SizedBox(height: 24)));
    return CustomScrollView(slivers: slivers);
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
