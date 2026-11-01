// apps/desktop/lib/ui/library_picker.dart
import 'package:flutter/material.dart';
import 'package:localroll_core/localroll_core.dart';

import '../app_services.dart';
import '../l10n/l10n.dart';
import '../services/library_index.dart';
import 'media_thumb.dart';
import 'theme.dart';

/// Pick photos / videos from the library (newest first; all, videos or
/// photos; by name). Returns their paths on this PC, or null.
Future<List<String>?> pickFromLibrary(BuildContext context, AppServices s, {bool multiple = true}) {
  if (s.library.rootPath.isEmpty || s.library.offline) {
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(tr('pick.no_library'))));
    return Future.value(null);
  }
  return showDialog<List<String>>(context: context, builder: (_) => _LibraryPicker(services: s, multiple: multiple));
}

class _LibraryPicker extends StatefulWidget {
  const _LibraryPicker({required this.services, required this.multiple});

  final AppServices services;
  final bool multiple;

  @override
  State<_LibraryPicker> createState() => _LibraryPickerState();
}

class _LibraryPickerState extends State<_LibraryPicker> {
  final TextEditingController _q = TextEditingController();
  MediaKind? _kind;
  final List<MediaItem> _picked = [];

  @override
  void dispose() {
    _q.dispose();
    super.dispose();
  }

  List<MediaItem> _shown() {
    final q = _q.text.trim().toLowerCase();
    final all = [
      for (final i in widget.services.library.items)
        if ((i.kind == MediaKind.image || i.kind == MediaKind.video) &&
            (_kind == null || i.kind == _kind) &&
            (q.isEmpty || i.name.toLowerCase().contains(q) || i.relPath.toLowerCase().contains(q)))
          i,
    ]..sort((a, b) => b.captureMs.compareTo(a.captureMs));
    return all;
  }

  void _done([MediaItem? one]) {
    final lib = widget.services.library;
    final list = one != null ? [one] : _picked;
    Navigator.pop(context, [for (final i in list) lib.absPath(i)]);
  }

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
                onChanged: (_) => setState(() {}),
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
                      final at = _picked.indexOf(i);
                      return Tooltip(
                        message: i.name,
                        waitDuration: const Duration(milliseconds: 600),
                        child: GestureDetector(
                          onTap: () {
                            if (!widget.multiple) return _done(i);
                            setState(() => at >= 0 ? _picked.removeAt(at) : _picked.add(i));
                          },
                          onDoubleTap: () => _done(i),
                          child: Stack(fit: StackFit.expand, children: [
                            ClipRRect(
                              borderRadius: BorderRadius.circular(6),
                              child: MediaThumb(key: ValueKey(i.relPath), item: i, library: s.library, ffmpeg: s.ffmpeg),
                            ),
                            if (i.kind == MediaKind.video)
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
          Text(tr(widget.multiple ? 'pick.tip_multi' : 'pick.tip_one'), style: const TextStyle(color: LrColors.muted, fontSize: 12)),
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
