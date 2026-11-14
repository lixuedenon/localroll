// apps/desktop/lib/ui/library_picker.dart
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:localroll_core/localroll_core.dart';

import '../app_services.dart';
import '../l10n/l10n.dart';
import '../services/library_index.dart';
import '../services/received_files.dart';
import '../services/text_index.dart';
import 'files_view.dart';
import 'media_thumb.dart';
import 'theme.dart';
import 'lr_dialog.dart';

/// Pick photos / videos from the library (newest first; all, videos or
/// photos; by name) — with [files], also its documents and other files.
/// Returns their paths on this PC, or null.
Future<List<String>?> pickFromLibrary(BuildContext context, AppServices s, {bool multiple = true, bool files = false}) {
  if (s.library.rootPath.isEmpty || s.library.offline) {
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(tr('pick.no_library'))));
    return Future.value(null);
  }
  return showLrDialog<List<String>>(context: context, builder: (_) => _LibraryPicker(services: s, multiple: multiple, files: files));
}

/// One thing to pick: a library photo / video, or a received file.
class _Pick {
  _Pick.media(MediaItem this.item, this.path)
      : file = null,
        ms = item.captureMs;
  _Pick.file(ReceivedFile this.file)
      : item = null,
        path = file.path,
        ms = file.arrived.millisecondsSinceEpoch;

  final MediaItem? item;
  final ReceivedFile? file;
  final String path;
  final int ms;

  String get name => item?.name ?? file!.name;
}

class _LibraryPicker extends StatefulWidget {
  const _LibraryPicker({required this.services, required this.multiple, required this.files});

  final AppServices services;
  final bool multiple;
  final bool files;

  @override
  State<_LibraryPicker> createState() => _LibraryPickerState();
}

class _LibraryPickerState extends State<_LibraryPicker> {
  final TextEditingController _q = TextEditingController();

  /// null: all; image / video; other: documents and other files.
  MediaKind? _kind;
  final List<String> _picked = [];
  List<ReceivedFile> _files = const [];

  @override
  void initState() {
    super.initState();
    if (widget.files) {
      unawaited(widget.services.server.files.list().then((v) {
        if (mounted) setState(() => _files = v);
      }));
    }
  }

  /// The same search as the library: name, words in the picture, notes,
  /// what it looks like ("dog"), who is in it.
  SearchQuery _search = SearchQuery('');
  Set<String>? _who;
  Map<String, double> _picHits = const {};
  Timer? _picSoon;
  String _picQuery = '';

  @override
  void dispose() {
    _picSoon?.cancel();
    _q.dispose();
    super.dispose();
  }

  void _onSearch(String v) {
    final s = widget.services;
    unawaited(s.server.textIndex.load());
    var words = v;
    _who = null;
    if (s.settings.faces) {
      final split = s.server.people.split(v);
      if (split != null) {
        _who = split.$1;
        words = split.$2;
      }
    }
    _search = SearchQuery(words);
    _picSoon?.cancel();
    _picQuery = words;
    final ix = s.pictureIndexer;
    if (words.trim().isEmpty || !ix.ready) {
      _picHits = const {};
    } else {
      _picSoon = Timer(const Duration(milliseconds: 400), () async {
        final hits = await ix.find(words);
        if (!mounted || _picQuery != words) return;
        setState(() => _picHits = {for (final (k, sc) in hits) k: sc});
      });
    }
    setState(() {});
  }

  List<_Pick> _shown() {
    final s = widget.services;
    final idx = s.server.textIndex;
    final all = [
      if (_kind != MediaKind.other)
        for (final i in s.library.items)
          if ((i.kind == MediaKind.image || i.kind == MediaKind.video) &&
              (_kind == null || i.kind == _kind) &&
              (_search.isEmpty || idx.matches(TextIndex.mediaKey(i), i.name, _search) || _picHits.containsKey(TextIndex.mediaKey(i))) &&
              (_who == null || _who!.contains(TextIndex.mediaKey(i))))
            _Pick.media(i, s.library.absPath(i)),
      if (widget.files && (_kind == null || _kind == MediaKind.other) && _who == null)
        for (final f in _files)
          if (_search.isEmpty ||
              idx.matches(TextIndex.fileKey(s.server.files.relOf(f.path) ?? f.path, f.size), f.name, _search))
            _Pick.file(f),
    ]..sort((a, b) => b.ms.compareTo(a.ms));
    return all;
  }

  /// "Pictures 63 % searched": still being looked through.
  String? _note() {
    final s = widget.services;
    final pic = s.pictureIndexer.progress.value;
    if (s.settings.pictureSearch && pic.total > 0 && pic.done < pic.total) {
      return tr('pick.indexed', {'n': (pic.done * 100 / pic.total).floor()});
    }
    return null;
  }

  void _done([String? one]) => Navigator.pop(context, one != null ? [one] : List.of(_picked));

  @override
  Widget build(BuildContext context) {
    final s = widget.services;
    final shown = _shown();
    return AlertDialog(
      title: Text(tr('pick.title')),
      content: SizedBox(
        width: 760,
        height: 520,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Expanded(
              child: TextField(
                controller: _q,
                autofocus: true,
                onChanged: _onSearch,
                decoration: InputDecoration(
                  isDense: true,
                  prefixIcon: const Icon(Icons.search_rounded, size: 18),
                  hintText: tr('pick.search'),
                  border: const OutlineInputBorder(),
                ),
              ),
            ),
            const SizedBox(width: 10),
            SegmentedButton<MediaKind?>(
              showSelectedIcon: false,
              segments: [
                ButtonSegment(value: null, label: Text(tr('library.filter_all'))),
                ButtonSegment(value: MediaKind.video, label: Text(tr('library.filter_videos'))),
                ButtonSegment(value: MediaKind.image, label: Text(tr('library.filter_photos'))),
                if (widget.files) ButtonSegment(value: MediaKind.other, label: Text(tr('pick.files'))),
              ],
              selected: {_kind},
              onSelectionChanged: (v) => setState(() => _kind = v.first),
            ),
          ]),
          const SizedBox(height: 10),
          Expanded(
            child: shown.isEmpty
                ? Center(child: Text(tr('ink.no_hits'), style: const TextStyle(color: LrColors.muted)))
                : GridView.builder(
                    gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(maxCrossAxisExtent: 150, mainAxisSpacing: 6, crossAxisSpacing: 6),
                    itemCount: shown.length,
                    itemBuilder: (context, k) {
                      final i = shown[k];
                      final at = _picked.indexOf(i.path);
                      final item = i.item, file = i.file;
                      return Tooltip(
                        message: i.name,
                        waitDuration: const Duration(milliseconds: 600),
                        child: GestureDetector(
                          onTap: () {
                            if (!widget.multiple) return _done(i.path);
                            setState(() => at >= 0 ? _picked.removeAt(at) : _picked.add(i.path));
                          },
                          onDoubleTap: () => _done(i.path),
                          child: Stack(fit: StackFit.expand, children: [
                            ClipRRect(
                              borderRadius: BorderRadius.circular(6),
                              child: item != null
                                  ? MediaThumb(key: ValueKey(item.relPath), item: item, library: s.library, ffmpeg: s.ffmpeg)
                                  : FileThumb(
                                      key: ValueKey(file!.path),
                                      path: file.path,
                                      size: file.size,
                                      modified: file.modified,
                                      services: s,
                                      icon: Container(
                                        color: LrColors.raised,
                                        alignment: Alignment.center,
                                        child: const Icon(Icons.description_rounded, size: 40, color: LrColors.muted),
                                      ),
                                    ),
                            ),
                            if (file != null)
                              Positioned(
                                left: 0,
                                right: 0,
                                bottom: 0,
                                child: Container(
                                  color: const Color(0xAA000000),
                                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                                  child: Text(file.name,
                                      maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11, color: Colors.white)),
                                ),
                              ),
                            if (item?.kind == MediaKind.video)
                              const Positioned(left: 4, bottom: 4, child: Icon(Icons.play_circle_fill_rounded, size: 18, color: Colors.white70)),
                            if (at >= 0)
                              Container(
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(6),
                                  border: Border.all(color: LrColors.safelight, width: 3),
                                ),
                                alignment: Alignment.topRight,
                                padding: const EdgeInsets.all(4),
                                child: CircleAvatar(
                                  radius: 11,
                                  backgroundColor: LrColors.safelight,
                                  child: Text('${at + 1}', style: const TextStyle(fontSize: 11, color: Colors.black, fontWeight: FontWeight.w700)),
                                ),
                              ),
                          ]),
                        ),
                      );
                    },
                  ),
          ),
          const SizedBox(height: 6),
          Text([tr(widget.multiple ? 'pick.tip_multi' : 'pick.tip_one'), ?_note()].join('  ·  '), style: const TextStyle(color: LrColors.muted, fontSize: 12)),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(tr('common.cancel'))),
        if (widget.multiple)
          FilledButton(
            onPressed: _picked.isEmpty ? null : _done,
            child: Text(tr('pick.ok', {'n': _picked.length})),
          ),
      ],
    );
  }
}
