// apps/desktop/lib/ui/pc_files_page.dart
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../app_services.dart';
import '../l10n/l10n.dart';
import '../services/pc_files.dart';
import '../services/network.dart';
import '../services/win_dialogs.dart';
import 'copy_in_ui.dart';
import 'files_view.dart';
import 'format.dart';
import 'lr_dialog.dart';
import 'send_paths.dart';
import 'theme.dart';

enum _When { all, week, month, year, lastYear, range }

enum _Size { all, small, medium, big, huge }

enum _Sort { newest, oldest, name, biggest }

/// "Other files on this PC": photos, videos, PDF, Office and text files
/// outside the library, to find one again. Filtered by kind, time, place,
/// size and name (or the words inside, when Windows Search is on); open,
/// show in its folder, copy into the library, send.
class PcFilesPage extends StatefulWidget {
  const PcFilesPage({super.key, required this.services});

  final AppServices services;

  @override
  State<PcFilesPage> createState() => _PcFilesPageState();
}

class _PcFilesPageState extends State<PcFilesPage> {
  AppServices get s => widget.services;
  PcFiles get pc => s.pcFiles;

  bool _loading = true;
  final Set<PcKind> _kinds = {};
  _When _when = _When.all;
  DateTimeRange? _range;
  String _place = ''; // a folder; '': everywhere
  _Size _size = _Size.all;
  _Sort _sort = _Sort.newest;
  final TextEditingController _name = TextEditingController();
  Timer? _typing;
  bool _inside = false;
  List<PcFile>? _found; // words inside (Windows Search)
  final Set<String> _selected = {};

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _name.dispose();
    _typing?.cancel();
    super.dispose();
  }

  Future<void> _load({bool fresh = false}) async {
    setState(() => _loading = true);
    await pc.list(fresh: fresh);
    if (!mounted) return;
    setState(() => _loading = false);
    if (_inside) await _searchInside();
  }

  Future<void> _searchInside() async {
    final w = _name.text.trim();
    if (!_inside || w.isEmpty) {
      setState(() => _found = null);
      return;
    }
    setState(() => _loading = true);
    final got = await pc.searchInside(w);
    if (!mounted) return;
    setState(() {
      _found = got;
      _loading = false;
    });
  }

  // --- the filters ---

  bool _whenOk(PcFile f) {
    final now = DateTime.now();
    final t = f.when;
    return switch (_when) {
      _When.all => true,
      _When.week => now.difference(t).inDays < 7,
      _When.month => t.year == now.year && t.month == now.month,
      _When.year => t.year == now.year,
      _When.lastYear => t.year == now.year - 1,
      _When.range => _range == null || (!t.isBefore(_range!.start) && t.isBefore(_range!.end.add(const Duration(days: 1)))),
    };
  }

  bool _sizeOk(PcFile f) {
    const mb = 1024 * 1024;
    return switch (_size) {
      _Size.all => true,
      _Size.small => f.size < mb,
      _Size.medium => f.size >= mb && f.size < 100 * mb,
      _Size.big => f.size >= 100 * mb && f.size < 1024 * mb,
      _Size.huge => f.size >= 1024 * mb,
    };
  }

  List<PcFile> _shown() {
    final words = _name.text.trim().toLowerCase();
    final base = _inside && _found != null ? _found! : pc.files;
    final place = _place.isEmpty ? null : _place.toLowerCase();
    final out = [
      for (final f in base)
        if ((_kinds.isEmpty || _kinds.contains(f.kind)) &&
            _whenOk(f) &&
            _sizeOk(f) &&
            (place == null || f.path.toLowerCase().startsWith('$place\\')) &&
            (_inside || words.isEmpty || f.name.toLowerCase().contains(words)))
          f,
    ];
    switch (_sort) {
      case _Sort.newest:
        out.sort((a, b) => b.when.compareTo(a.when));
      case _Sort.oldest:
        out.sort((a, b) => a.when.compareTo(b.when));
      case _Sort.name:
        out.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
      case _Sort.biggest:
        out.sort((a, b) => b.size.compareTo(a.size));
    }
    return out;
  }

  List<String> _places() => [...PcFiles.usualFolders(), ...s.settings.pcFilesExtra];

  static String _placeName(String p) => p.split(Platform.pathSeparator).last;

  // --- actions ---

  Future<void> _open(PcFile f) async {
    if (!File(f.path).existsSync()) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('pcfiles.gone'))));
      pc.files.remove(f);
      setState(() {});
      return;
    }
    await openFromOutside(context, s, [f.path]);
  }

  void _act(String what, List<PcFile> list) {
    final paths = [for (final f in list) f.path];
    switch (what) {
      case 'open':
        if (list.isNotEmpty) unawaited(_open(list.first));
      case 'folder':
        if (list.isNotEmpty) unawaited(revealInExplorer(list.first.path));
      case 'copy':
        unawaited(copyIntoLibrary(s, paths));
        setState(_selected.clear);
      case 'send':
        sendFromExplorer(s, paths);
        setState(_selected.clear);
    }
  }

  Future<void> _placesDialog() async {
    await showLrDialog<void>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, set) {
          Widget list(String title, List<String> items, void Function(List<String>) save) => Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    Expanded(child: Text(title, style: const TextStyle(fontWeight: FontWeight.w600))),
                    TextButton.icon(
                      onPressed: () async {
                        final p = await WinDialogs.pickFolder(title: title);
                        if (p == null || items.contains(p)) return;
                        set(() => items.add(p));
                        save(items);
                      },
                      icon: const Icon(Icons.add_rounded, size: 18),
                      label: Text(tr('pcfiles.add')),
                    ),
                  ]),
                  if (items.isEmpty) Text(tr('pcfiles.none'), style: const TextStyle(fontSize: 12, color: LrColors.muted)),
                  for (final p in items)
                    Row(children: [
                      Expanded(child: Text(p, style: const TextStyle(fontSize: 12), overflow: TextOverflow.ellipsis)),
                      IconButton(
                        iconSize: 18,
                        onPressed: () {
                          set(() => items.remove(p));
                          save(items);
                        },
                        icon: const Icon(Icons.close_rounded),
                      ),
                    ]),
                ],
              );
          return AlertDialog(
            title: Text(tr('pcfiles.places_title')),
            content: SizedBox(
              width: 520,
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(tr('pcfiles.places_body'), style: const TextStyle(fontSize: 13)),
                const SizedBox(height: 14),
                list(tr('pcfiles.extra'), [...s.settings.pcFilesExtra], (v) => unawaited(s.settings.update((x) => x.pcFilesExtra = [...v]))),
                const SizedBox(height: 12),
                list(tr('pcfiles.skip'), [...s.settings.pcFilesSkip], (v) => unawaited(s.settings.update((x) => x.pcFilesSkip = [...v]))),
              ]),
            ),
            actions: [FilledButton(onPressed: () => Navigator.pop(c), child: Text(tr('common.ok')))],
          );
        },
      ),
    );
    if (mounted) await _load(fresh: true);
  }

  // --- the page ---

  Widget _drop<T>(String label, T value, List<(T, String)> items, void Function(T) pick) => PopupMenuButton<T>(
        tooltip: '',
        initialValue: value,
        onSelected: pick,
        itemBuilder: (_) => [for (final (v, t) in items) CheckedPopupMenuItem(value: v, checked: v == value, child: Text(t))],
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          decoration: BoxDecoration(border: Border.all(color: const Color(0xFFD8E0EE)), borderRadius: BorderRadius.circular(18)),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Text('$label：', style: const TextStyle(fontSize: 13, color: LrColors.muted)),
            Text(items.firstWhere((e) => e.$1 == value, orElse: () => items.first).$2, style: const TextStyle(fontSize: 13)),
            const Icon(Icons.arrow_drop_down_rounded, size: 18),
          ]),
        ),
      );

  static IconData _icon(PcKind? k) => switch (k) {
        PcKind.photo => Icons.image_outlined,
        PcKind.video => Icons.movie_outlined,
        PcKind.pdf => Icons.picture_as_pdf_outlined,
        PcKind.word => Icons.description_outlined,
        PcKind.excel => Icons.table_chart_outlined,
        PcKind.ppt => Icons.slideshow_outlined,
        _ => Icons.article_outlined,
      };

  Widget _thumb(PcFile f) {
    const box = 44.0;
    final e = f.name.toLowerCase();
    if (f.kind == PcKind.photo && (e.endsWith('.jpg') || e.endsWith('.jpeg') || e.endsWith('.png') || e.endsWith('.webp') || e.endsWith('.gif') || e.endsWith('.bmp'))) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: Image.file(File(f.path),
            width: box, height: box, fit: BoxFit.cover, cacheWidth: 96, errorBuilder: (_, _, _) => Icon(_icon(f.kind), size: 28)),
      );
    }
    return SizedBox(width: box, height: box, child: Icon(_icon(f.kind), size: 28, color: const Color(0xFF5A6B8C)));
  }

  @override
  Widget build(BuildContext context) {
    final list = _loading && pc.files.isEmpty ? const <PcFile>[] : _shown();
    final chosen = [for (final f in list) if (_selected.contains(f.path)) f];
    final kinds = [
      (PcKind.photo, tr('pcfiles.k_photo')),
      (PcKind.video, tr('pcfiles.k_video')),
      (PcKind.pdf, 'PDF'),
      (PcKind.word, 'Word'),
      (PcKind.excel, 'Excel'),
      (PcKind.ppt, 'PowerPoint'),
      (PcKind.text, tr('pcfiles.k_text')),
    ];
    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false,
        title: Text(_selected.isEmpty ? tr('pcfiles.title') : tr('pcfiles.selected', {'count': _selected.length})),
        actions: [
          if (_selected.isNotEmpty) ...[
            TextButton.icon(onPressed: () => _act('copy', chosen), icon: const Icon(Icons.library_add_rounded), label: Text(tr('copyin.do'))),
            TextButton.icon(onPressed: () => _act('send', chosen), icon: const Icon(Icons.send_rounded), label: Text(tr('pcfiles.send'))),
            IconButton(tooltip: tr('common.cancel'), onPressed: () => setState(_selected.clear), icon: const Icon(Icons.close_rounded)),
          ] else ...[
            IconButton(tooltip: tr('pcfiles.places_title'), onPressed: _placesDialog, icon: const Icon(Icons.tune_rounded)),
            IconButton(tooltip: tr('pcfiles.refresh'), onPressed: _loading ? null : () => _load(fresh: true), icon: const Icon(Icons.refresh_rounded)),
          ],
          const SizedBox(width: 8),
        ],
      ),
      body: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 4),
          child: Row(children: [
            Expanded(
              child: TextField(
                controller: _name,
                decoration: InputDecoration(
                  isDense: true,
                  prefixIcon: const Icon(Icons.search_rounded),
                  hintText: _inside ? tr('pcfiles.search_inside_hint') : tr('pcfiles.search_hint'),
                  border: const OutlineInputBorder(),
                ),
                onChanged: (_) {
                  _typing?.cancel();
                  _typing = Timer(const Duration(milliseconds: 450), () {
                    if (_inside) {
                      unawaited(_searchInside());
                    } else {
                      setState(() {});
                    }
                  });
                },
              ),
            ),
            const SizedBox(width: 10),
            if (pc.source == PcSource.windowsSearch)
              Row(children: [
                Checkbox(
                  value: _inside,
                  onChanged: (v) {
                    setState(() => _inside = v ?? false);
                    unawaited(_searchInside());
                  },
                ),
                Text(tr('pcfiles.inside')),
              ]),
          ]),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 6, 20, 4),
          child: Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
            for (final (k, t) in kinds)
              FilterChip(
                label: Text(t),
                selected: _kinds.contains(k),
                onSelected: (on) => setState(() => on ? _kinds.add(k) : _kinds.remove(k)),
              ),
          ]),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
          child: Wrap(spacing: 8, runSpacing: 8, children: [
            _drop<_When>(tr('pcfiles.when'), _when, [
              (_When.all, tr('pcfiles.all')),
              (_When.week, tr('pcfiles.week')),
              (_When.month, tr('pcfiles.month')),
              (_When.year, tr('pcfiles.year')),
              (_When.lastYear, tr('pcfiles.last_year')),
              (_When.range,
                  _range == null ? tr('pcfiles.range') : '${formatDate(_range!.start).split(' ').first} – ${formatDate(_range!.end).split(' ').first}'),
            ], (v) async {
              if (v == _When.range) {
                final now = DateTime.now();
                final r = await showDateRangePicker(context: context, firstDate: DateTime(1990), lastDate: now, initialDateRange: _range);
                if (r == null) return;
                setState(() {
                  _range = r;
                  _when = v;
                });
              } else {
                setState(() => _when = v);
              }
            }),
            _drop<String>(tr('pcfiles.where'), _place, [
              ('', tr('pcfiles.everywhere')),
              for (final p in _places()) (p, _placeName(p)),
            ], (v) => setState(() => _place = v)),
            _drop<_Size>(tr('pcfiles.size'), _size, [
              (_Size.all, tr('pcfiles.all')),
              (_Size.small, '< 1 MB'),
              (_Size.medium, '1 – 100 MB'),
              (_Size.big, '100 MB – 1 GB'),
              (_Size.huge, '> 1 GB'),
            ], (v) => setState(() => _size = v)),
            _drop<_Sort>(tr('pcfiles.sort'), _sort, [
              (_Sort.newest, tr('pcfiles.newest')),
              (_Sort.oldest, tr('pcfiles.oldest')),
              (_Sort.name, tr('pcfiles.by_name')),
              (_Sort.biggest, tr('pcfiles.biggest')),
            ], (v) => setState(() => _sort = v)),
          ]),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 6),
          child: Row(children: [
            if (_loading) const Padding(padding: EdgeInsets.only(right: 8), child: SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))),
            Expanded(
              child: Text(
                _loading && pc.files.isEmpty
                    ? tr('pcfiles.loading')
                    : tr(pc.source == PcSource.windowsSearch ? 'pcfiles.count_search' : 'pcfiles.count_scan', {'count': list.length}),
                style: const TextStyle(fontSize: 12, color: LrColors.muted),
              ),
            ),
            if (list.isNotEmpty)
              TextButton(
                onPressed: () => setState(() => list.length == chosen.length ? _selected.clear() : _selected.addAll(list.map((f) => f.path))),
                child: Text(list.length == chosen.length ? tr('pcfiles.select_none') : tr('pcfiles.select_all')),
              ),
          ]),
        ),
        const Divider(height: 1),
        Expanded(
          child: list.isEmpty && !_loading
              ? Center(child: Text(tr('pcfiles.empty'), style: const TextStyle(color: LrColors.muted)))
              : ListView.builder(
                  itemCount: list.length,
                  itemExtent: 60,
                  itemBuilder: (context, i) {
                    final f = list[i];
                    final on = _selected.contains(f.path);
                    return InkWell(
                      onTap: () => _selected.isNotEmpty ? setState(() => on ? _selected.remove(f.path) : _selected.add(f.path)) : _open(f),
                      onSecondaryTapUp: (d) async {
                        final v = await showMenu<String>(
                          context: context,
                          position: RelativeRect.fromLTRB(d.globalPosition.dx, d.globalPosition.dy, d.globalPosition.dx, d.globalPosition.dy),
                          items: [
                            PopupMenuItem(value: 'open', child: Text(tr('lib.open'))),
                            PopupMenuItem(value: 'folder', child: Text(tr('copyin.show'))),
                            PopupMenuItem(value: 'copy', child: Text(tr('copyin.do'))),
                            PopupMenuItem(value: 'send', child: Text(tr('pcfiles.send'))),
                          ],
                        );
                        if (v != null) _act(v, on && chosen.isNotEmpty ? chosen : [f]);
                      },
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        child: Row(children: [
                          Checkbox(value: on, onChanged: (v) => setState(() => v == true ? _selected.add(f.path) : _selected.remove(f.path))),
                          _thumb(f),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
                              Text(f.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                              Text(f.folder, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11, color: LrColors.muted)),
                            ]),
                          ),
                          const SizedBox(width: 12),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(color: const Color(0xFFEFF3FA), borderRadius: BorderRadius.circular(4)),
                            child: Text(tr('pcfiles.not_in_lib'), style: const TextStyle(fontSize: 10, color: LrColors.muted)),
                          ),
                          const SizedBox(width: 12),
                          SizedBox(width: 140, child: Text(formatDate(f.when), style: const TextStyle(fontSize: 12, color: LrColors.muted))),
                          SizedBox(width: 80, child: Text(formatBytes(f.size), textAlign: TextAlign.right, style: const TextStyle(fontSize: 12, color: LrColors.muted))),
                        ]),
                      ),
                    );
                  },
                ),
        ),
      ]),
    );
  }
}
