// apps/desktop/lib/ui/library_page.dart
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:localroll_core/localroll_core.dart';

import '../app_services.dart';
import '../l10n/l10n.dart';
import '../services/converter.dart';
import '../services/file_actions.dart';
import '../services/library_index.dart';
import '../services/network.dart';
import 'media_thumb.dart';
import 'viewer_page.dart';

enum _Filter { all, photos, videos }

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

  List<MediaItem> _visible(List<MediaItem> all, FamilyDirectory family) => [
        for (final i in all)
          if ((_filter == _Filter.all ||
                  (_filter == _Filter.photos && i.kind == MediaKind.image) ||
                  (_filter == _Filter.videos && i.kind == MediaKind.video)) &&
              (_showPrivate || !i.private) &&
              (_member == null || FamilyDirectory.keyOf(_memberOf(family, i)) == FamilyDirectory.keyOf(_member!)))
            i,
      ];

  /// Member chips + "show only-me items", shown once there is a family.
  PreferredSizeWidget? _familyBar(List<MediaItem> all, FamilyDirectory family) {
    final members = {for (final i in all) _memberOf(family, i)}.toList();
    final privateCount = all.where((i) => i.private).length;
    if (members.length < 2 && privateCount == 0) return null;
    return PreferredSize(
      preferredSize: const Size.fromHeight(52),
      child: SizedBox(
        height: 52,
        child: ListView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          children: [
            if (members.length >= 2) ...[
              ChoiceChip(
                avatar: const Icon(Icons.groups_rounded, size: 18),
                label: Text(tr('family.everyone')),
                selected: _member == null,
                onSelected: (_) => setState(() => _member = null),
              ),
              for (final m in members) ...[
                const SizedBox(width: 8),
                ChoiceChip(
                  label: Text(m),
                  selected: _member != null && FamilyDirectory.keyOf(_member!) == FamilyDirectory.keyOf(m),
                  onSelected: (_) => setState(() => _member = m),
                ),
              ],
              const SizedBox(width: 16),
            ],
            if (privateCount > 0)
              FilterChip(
                avatar: Icon(_showPrivate ? Icons.lock_open_rounded : Icons.lock_rounded, size: 18),
                label: Text(tr('family.show_private', {'count': privateCount})),
                selected: _showPrivate,
                onSelected: (v) => setState(() => _showPrivate = v),
              ),
          ],
        ),
      ),
    );
  }

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
            title: Text(_selecting ? tr('library.selected', {'count': _selected.length}) : tr('nav.library')),
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
                  ],
                  selected: {_filter},
                  onSelectionChanged: (v) => setState(() => _filter = v.first),
                ),
                const SizedBox(width: 8),
                IconButton(
                  tooltip: tr('library.open_folder'),
                  onPressed: () => revealInExplorer(s.library.rootPath),
                  icon: const Icon(Icons.folder_open),
                ),
              ],
              const SizedBox(width: 8),
            ],
            bottom: _familyBar(all, family),
          ),
          body: items.isEmpty ? _empty(context) : _grid(context, items),
        );
      },
    );
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
    if (ok != true) return;
    final n = await deleteItems(widget.services.library, items);
    if (!mounted) return;
    setState(_selected.clear);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('lib.deleted', {'count': n}))));
  }

  /// Copy the originals into a folder of your choice.
  Future<void> _export(List<MediaItem> items) async {
    if (items.isEmpty) return;
    final folder = await getDirectoryPath(confirmButtonText: tr('lib.export'));
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
      final t = items[start].captureTime;
      var end = start;
      while (end < items.length &&
          items[end].captureTime.year == t.year &&
          items[end].captureTime.month == t.month &&
          items[end].captureTime.day == t.day) {
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
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 180,
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
