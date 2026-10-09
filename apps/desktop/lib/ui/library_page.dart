// apps/desktop/lib/ui/library_page.dart
import 'package:flutter/material.dart';
import 'package:localroll_core/localroll_core.dart';

import '../app_services.dart';
import '../l10n/l10n.dart';
import '../services/converter.dart';
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

  bool get _selecting => _selected.isNotEmpty;

  List<MediaItem> _visible(List<MediaItem> all) => switch (_filter) {
        _Filter.all => all,
        _Filter.photos => all.where((i) => i.kind == MediaKind.image).toList(),
        _Filter.videos => all.where((i) => i.kind == MediaKind.video).toList(),
      };

  @override
  Widget build(BuildContext context) {
    final s = widget.services;
    return ListenableBuilder(
      listenable: s.library,
      builder: (context, _) {
        final items = _visible(s.library.items);
        _selected.removeWhere((p) => !items.any((i) => i.relPath == p));
        return Scaffold(
          appBar: AppBar(
            title: Text(_selecting ? tr('library.selected', {'count': _selected.length}) : tr('nav.library')),
            leading: _selecting
                ? IconButton(icon: const Icon(Icons.close), onPressed: () => setState(_selected.clear))
                : null,
            actions: [
              if (_selecting)
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
                )
              else ...[
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
          ),
          body: items.isEmpty ? _empty(context) : _grid(context, items),
        );
      },
    );
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
      onSecondaryTap: () => setState(() => _selected.add(item.relPath)),
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
