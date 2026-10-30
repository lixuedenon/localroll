// apps/desktop/lib/ui/player/player_side.dart
part of 'player_page.dart';

/// What the list on the right shows.
enum _Kind { all, video, photo }

/// The files of this list (what the arrows go through): thumbnails, the
/// one shown highlighted; all, only videos or only photos.
class _EntryList extends StatefulWidget {
  const _EntryList({super.key, required this.services, required this.entries, required this.index, required this.onPick, this.source});

  final AppServices services;
  final List<PlayerEntry> entries;
  final int index;

  /// Where the list came from.
  final String? source;
  final ValueChanged<int> onPick;

  @override
  State<_EntryList> createState() => _EntryListState();
}

class _EntryListState extends State<_EntryList> {
  static const double _row = 68;
  final ScrollController _scroll = ScrollController();
  _Kind _kind = _Kind.all;

  List<int> get _shown => [
        for (var i = 0; i < widget.entries.length; i++)
          if (_kind == _Kind.all || (widget.entries[i].video == (_kind == _Kind.video))) i,
      ];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _reveal(jump: true));
  }

  @override
  void didUpdateWidget(_EntryList old) {
    super.didUpdateWidget(old);
    if (old.index != widget.index) WidgetsBinding.instance.addPostFrameCallback((_) => _reveal());
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  /// Keeps the one shown in view.
  void _reveal({bool jump = false}) {
    if (!mounted || !_scroll.hasClients) return;
    final at = _shown.indexOf(widget.index);
    if (at < 0) return;
    final view = _scroll.position.viewportDimension;
    final top = at * _row;
    final now = _scroll.offset;
    if (top >= now && top + _row <= now + view) return;
    final to = (top - view / 2 + _row / 2).clamp(0.0, _scroll.position.maxScrollExtent);
    if (jump) {
      _scroll.jumpTo(to);
    } else {
      unawaited(_scroll.animateTo(to, duration: const Duration(milliseconds: 200), curve: Curves.easeOut));
    }
  }

  Widget _thumb(PlayerEntry e) {
    final s = widget.services;
    final item = e.item;
    if (item != null) return MediaThumb(key: ValueKey(item.relPath), item: item, library: s.library, ffmpeg: s.ffmpeg);
    return FileThumb(
      key: ValueKey(e.path),
      path: e.path,
      size: e.size,
      modified: DateTime.fromMillisecondsSinceEpoch(e.modifiedMs),
      services: s,
      box: 96,
      icon: Container(
        color: LrColors.raised,
        alignment: Alignment.center,
        child: Icon(e.video ? Icons.movie_rounded : Icons.image_rounded, color: LrColors.muted, size: 20),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final shown = _shown;
    final videos = widget.entries.where((e) => e.video).length;
    final photos = widget.entries.length - videos;
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 2),
        child: Row(children: [
          Expanded(
            child: Text(
              tr('player.from_list', {'where': widget.source ?? tr('player.src_files'), 'n': widget.entries.length}),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12, color: LrColors.muted),
            ),
          ),
          Tooltip(
            message: tr('player.list_marks'),
            child: const Icon(Icons.info_outline_rounded, size: 16, color: LrColors.muted),
          ),
        ]),
      ),
      if (videos > 0 && photos > 0)
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 8, 10, 4),
          child: SegmentedButton<_Kind>(
            showSelectedIcon: false,
            style: const ButtonStyle(visualDensity: VisualDensity.compact),
            segments: [
              ButtonSegment(value: _Kind.all, label: Text('${tr('player.kind_all')} ${widget.entries.length}', style: const TextStyle(fontSize: 12))),
              ButtonSegment(value: _Kind.video, label: Text('${tr('player.kind_video')} $videos', style: const TextStyle(fontSize: 12))),
              ButtonSegment(value: _Kind.photo, label: Text('${tr('player.kind_photo')} $photos', style: const TextStyle(fontSize: 12))),
            ],
            selected: {_kind},
            onSelectionChanged: (v) {
              setState(() => _kind = v.first);
              WidgetsBinding.instance.addPostFrameCallback((_) => _reveal(jump: true));
            },
          ),
        ),
      Expanded(
        child: ListenableBuilder(
          listenable: Listenable.merge([widget.services.notes, widget.services.recordings]),
          builder: (context, _) => ListView.builder(
            controller: _scroll,
            itemExtent: _row,
            padding: const EdgeInsets.symmetric(vertical: 4),
            itemCount: shown.length,
            itemBuilder: (context, k) {
              final i = shown[k];
              final e = widget.entries[i];
              final on = i == widget.index;
              final notes = e.item == null ? 0 : widget.services.notes.countFor(e.item!);
              final made = widget.services.recordings.madeFrom(e.path).length;
              return Material(
                color: on ? LrColors.safelight.withValues(alpha: 0.16) : Colors.transparent,
                child: InkWell(
                  onTap: () => widget.onPick(i),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    child: Row(children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(5),
                        child: SizedBox(
                          width: 96,
                          height: 54,
                          child: Stack(fit: StackFit.expand, children: [
                            _thumb(e),
                            if (e.video)
                              const Positioned(
                                right: 3,
                                bottom: 3,
                                child: Icon(Icons.play_circle_fill_rounded, size: 16, color: Colors.white70),
                              ),
                          ]),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(e.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(fontSize: 13, color: on ? LrColors.safelight : LrColors.text, fontWeight: on ? FontWeight.w600 : FontWeight.w400)),
                          const SizedBox(height: 2),
                          Row(children: [
                            Expanded(
                              child: Text('${formatDate(e.time)} · ${formatBytes(e.size)}',
                                  maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11.5, color: LrColors.muted)),
                            ),
                            if (notes > 0) ...[
                              const Icon(Icons.brush_rounded, size: 12, color: LrColors.safelight),
                              const SizedBox(width: 2),
                              Text('$notes', style: const TextStyle(fontSize: 11.5, color: LrColors.safelight)),
                            ],
                            if (made > 0) ...[
                              const SizedBox(width: 6),
                              const Icon(Icons.mic_rounded, size: 12, color: LrColors.safelight),
                              const SizedBox(width: 2),
                              Text('$made', style: const TextStyle(fontSize: 11.5, color: LrColors.safelight)),
                            ],
                          ]),
                        ]),
                      ),
                    ]),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    ]);
  }
}

/// The annotations of every file in this list, by file.
class _AllNotes extends StatelessWidget {
  const _AllNotes({
    required this.services,
    required this.entries,
    required this.notes,
    required this.current,
    required this.header,
    required this.onPick,
  });

  final AppServices services;
  final List<PlayerEntry> entries;
  final List<(int, Note)> notes;
  final int current;
  final Widget header;
  final void Function(int index, Note note) onPick;

  @override
  Widget build(BuildContext context) {
    final rows = <Widget>[];
    int? last;
    for (final (i, n) in notes) {
      if (i != last) {
        last = i;
        rows.add(Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 4),
          child: Text(entries[i].name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: i == current ? LrColors.safelight : LrColors.muted)),
        ));
      }
      rows.add(ListTile(
        dense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 14),
        leading: Icon(entries[i].video ? Icons.movie_rounded : Icons.image_rounded, size: 18, color: LrColors.muted),
        title: Text(n.name, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Text(
          [
            if (entries[i].video) playerTime(Duration(milliseconds: n.startMs)),
            tr('ink.n_marks', {'n': n.inks.length}),
          ].join(' · '),
          style: const TextStyle(color: LrColors.muted, fontSize: 12),
        ),
        onTap: () => onPick(i, n),
      ));
    }
    return Material(
      color: Colors.transparent,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(padding: const EdgeInsets.fromLTRB(14, 12, 14, 4), child: Align(alignment: Alignment.centerLeft, child: header)),
        Expanded(
          child: rows.isEmpty
              ? Padding(
                  padding: const EdgeInsets.all(20),
                  child: Text(tr('player.notes_none_in_list'), style: const TextStyle(color: LrColors.muted)),
                )
              : ListView(padding: const EdgeInsets.only(bottom: 12), children: rows),
        ),
      ]),
    );
  }
}
