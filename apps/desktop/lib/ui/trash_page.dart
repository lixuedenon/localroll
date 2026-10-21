// apps/desktop/lib/ui/trash_page.dart
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_services.dart';
import '../l10n/l10n.dart';
import '../services/library_trash.dart';
import 'files_view.dart';
import 'format.dart';
import 'theme.dart';

/// LocalRoll's "Recently deleted": what was deleted in the last 30 days,
/// newest first. Select (click, Ctrl+A), then restore or delete for good.
class TrashPage extends StatefulWidget {
  const TrashPage({super.key, required this.services});

  final AppServices services;

  @override
  State<TrashPage> createState() => _TrashPageState();
}

class _TrashPageState extends State<TrashPage> {
  final Set<String> _selected = {};
  bool _busy = false;
  final FocusNode _focus = FocusNode();

  LibraryTrash get _trash => widget.services.server.trash;

  @override
  void initState() {
    super.initState();
    unawaited(_trash.load());
  }

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  List<TrashEntry> _chosen() => [for (final e in _trash.entries) if (_selected.contains(e.id)) e];

  Future<void> _restore(List<TrashEntry> list) async {
    if (list.isEmpty) return;
    setState(() => _busy = true);
    final n = await _trash.restore(list);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _selected.clear();
    });
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('trash.restored', {'count': n}))));
  }

  Future<void> _forever(List<TrashEntry> list) async {
    if (list.isEmpty) return;
    final size = list.fold(0, (a, e) => a + _trash.sizeOf(e));
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        icon: const Icon(Icons.delete_forever_rounded, size: 32),
        title: Text(tr('trash.forever_title', {'count': list.length, 'size': formatBytes(size)})),
        content: Text(tr('trash.forever_body')),
        actions: [
          OutlinedButton(onPressed: () => Navigator.pop(c, false), child: Text(tr('common.cancel'))),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Theme.of(c).colorScheme.error),
            onPressed: () => Navigator.pop(c, true),
            child: Text(tr('trash.delete_forever')),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _busy = true);
    final n = await _trash.purge(list);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _selected.clear();
    });
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('trash.removed', {'count': n}))));
  }

  KeyEventResult _onKey(FocusNode _, KeyEvent e) {
    if (e is! KeyDownEvent) return KeyEventResult.ignored;
    final ctrl = HardwareKeyboard.instance.isControlPressed;
    if (ctrl && e.logicalKey == LogicalKeyboardKey.keyA) {
      setState(() => _selected.addAll(_trash.entries.map((x) => x.id)));
      return KeyEventResult.handled;
    }
    if (e.logicalKey == LogicalKeyboardKey.escape && _selected.isNotEmpty) {
      setState(_selected.clear);
      return KeyEventResult.handled;
    }
    if (e.logicalKey == LogicalKeyboardKey.delete && _selected.isNotEmpty) {
      unawaited(_forever(_chosen()));
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: _trash,
      builder: (context, _) {
        final list = _trash.entries;
        _selected.removeWhere((id) => !list.any((e) => e.id == id));
        final chosen = _chosen();
        return Focus(
          focusNode: _focus,
          autofocus: true,
          onKeyEvent: _onKey,
          child: Scaffold(
            appBar: AppBar(
              title: Text(_selected.isEmpty
                  ? tr('trash.title')
                  : tr('lib.selected_size', {
                      'count': _selected.length,
                      'size': formatBytes(chosen.fold(0, (a, e) => a + _trash.sizeOf(e))),
                    })),
              actions: [
                if (_busy)
                  const Padding(
                    padding: EdgeInsets.all(16),
                    child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
                  ),
                if (_selected.isNotEmpty) ...[
                  TextButton.icon(
                    onPressed: _busy ? null : () => _restore(chosen),
                    icon: const Icon(Icons.restore_rounded),
                    label: Text(tr('trash.restore')),
                  ),
                  TextButton.icon(
                    onPressed: _busy ? null : () => _forever(chosen),
                    icon: Icon(Icons.delete_forever_rounded, color: theme.colorScheme.error),
                    label: Text(tr('trash.delete_forever'), style: TextStyle(color: theme.colorScheme.error)),
                  ),
                  IconButton(
                    tooltip: tr('common.cancel'),
                    onPressed: () => setState(_selected.clear),
                    icon: const Icon(Icons.close_rounded),
                  ),
                ] else if (list.isNotEmpty) ...[
                  TextButton(
                    onPressed: () => setState(() => _selected.addAll(list.map((e) => e.id))),
                    child: Text(tr('trash.select_all')),
                  ),
                  TextButton(
                    onPressed: _busy ? null : () => _forever(list),
                    child: Text(tr('trash.empty_all'), style: TextStyle(color: theme.colorScheme.error)),
                  ),
                ],
                const SizedBox(width: 8),
              ],
            ),
            body: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
                child: Text(
                  tr('trash.info', {'count': list.length, 'size': formatBytes(_trash.totalSize)}),
                  style: theme.textTheme.bodySmall?.copyWith(color: LrColors.muted),
                ),
              ),
              Expanded(
                child: list.isEmpty
                    ? Center(
                        child: Column(mainAxisSize: MainAxisSize.min, children: [
                          Icon(Icons.delete_outline_rounded, size: 56, color: theme.colorScheme.outline),
                          const SizedBox(height: 10),
                          Text(tr('trash.empty')),
                        ]),
                      )
                    : GridView.builder(
                        padding: const EdgeInsets.fromLTRB(12, 4, 12, 24),
                        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                          maxCrossAxisExtent: 170,
                          mainAxisSpacing: 6,
                          crossAxisSpacing: 6,
                          childAspectRatio: 0.82,
                        ),
                        itemCount: list.length,
                        itemBuilder: (context, i) => _tile(context, list[i]),
                      ),
              ),
            ]),
          ),
        );
      },
    );
  }

  Widget _tile(BuildContext context, TrashEntry e) {
    final theme = Theme.of(context);
    final selected = _selected.contains(e.id);
    final left = _trash.daysLeft(e);
    return GestureDetector(
      onTap: () {
        _focus.requestFocus();
        setState(() => selected ? _selected.remove(e.id) : _selected.add(e.id));
      },
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Expanded(
          child: Stack(fit: StackFit.expand, children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: FileThumb(
                key: ValueKey(e.id),
                path: _trash.storedPath(e),
                size: e.size,
                modified: e.deleted,
                services: widget.services,
                icon: Container(
                  color: LrColors.raised,
                  alignment: Alignment.center,
                  child: const Icon(Icons.insert_drive_file_rounded, size: 36, color: LrColors.muted),
                ),
              ),
            ),
            Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(4),
                border: selected ? Border.all(color: theme.colorScheme.primary, width: 3) : null,
                color: selected ? Colors.black26 : null,
              ),
              alignment: Alignment.topLeft,
              padding: const EdgeInsets.all(4),
              child: Icon(
                selected ? Icons.check_circle : Icons.radio_button_unchecked_rounded,
                color: selected ? theme.colorScheme.primary : Colors.white70,
                size: 20,
              ),
            ),
          ]),
        ),
        const SizedBox(height: 4),
        Text(e.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodySmall),
        Text(
          tr('trash.days_left', {'count': left}),
          style: theme.textTheme.bodySmall?.copyWith(color: left <= 3 ? theme.colorScheme.error : LrColors.muted, fontSize: 11),
        ),
      ]),
    );
  }
}
