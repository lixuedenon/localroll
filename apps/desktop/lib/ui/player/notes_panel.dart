// apps/desktop/lib/ui/player/notes_panel.dart
import 'dart:io';

import 'package:flutter/material.dart';

import '../../app_services.dart';
import '../../l10n/l10n.dart';
import '../../services/annotations.dart';
import '../../services/text_index.dart';
import '../theme.dart';
import 'ink_paint.dart';
import 'narration.dart';
import 'player_entry.dart';

/// What was chosen on an annotation in the list.
enum NoteAction { jump, edit, rename, shot, send, clip, sendClip, delete }

/// The annotations of what is shown: jump to one, edit, rename,
/// screenshot, send, delete. Settings: how far before to start, stop at
/// each annotation, show / hide the drawings.
class NotesPanel extends StatefulWidget {
  const NotesPanel({
    super.key,
    required this.services,
    required this.entry,
    required this.set,
    required this.aspect,
    required this.showInk,
    required this.onShowInk,
    required this.onAction,
    required this.onHold,
    required this.onClipAround,
    this.leading,
    this.narrations = const [],
    this.onNarration,
  });

  /// Explanations recorded with this file (to make again or delete).
  final List<NarrationSession> narrations;
  final void Function(NarrationSession n, String action)? onNarration;

  /// Shown at the top left instead of the title.
  final Widget? leading;

  final AppServices services;
  final PlayerEntry entry;
  final NoteSet? set;

  /// Width / height of the picture (thumbnails are drawn to match).
  final double aspect;
  final bool showInk;
  final ValueChanged<bool> onShowInk;
  final void Function(Note note, NoteAction action) onAction;
  final void Function(Note note, int holdMs) onHold;

  /// Change the seconds a note's clip takes before / after it.
  final VoidCallback onClipAround;

  @override
  State<NotesPanel> createState() => _NotesPanelState();
}

class _NotesPanelState extends State<NotesPanel> {
  final TextEditingController _q = TextEditingController();

  @override
  void dispose() {
    _q.dispose();
    super.dispose();
  }

  String _time(int ms) {
    final d = Duration(milliseconds: ms);
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    return d.inHours > 0 ? '${d.inHours}:${(d.inMinutes % 60).toString().padLeft(2, '0')}:$s' : '${d.inMinutes}:$s';
  }

  bool _matches(Note n) {
    final q = SearchQuery(_q.text);
    if (q.isEmpty) return true;
    final text = TextIndex.normalize([
      n.words,
      for (final t in {for (final i in n.inks) i.tool}) tr('ink.tool_${t.name}'),
    ].join(' '));
    return q.words.every(text.contains);
  }

  Future<void> _menu(BuildContext context, Note n, Offset at) async {
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    Widget row(IconData i, String t, {bool danger = false}) => Row(children: [
          Icon(i, size: 18, color: danger ? LrColors.danger : null),
          const SizedBox(width: 12),
          Text(t, style: TextStyle(color: danger ? LrColors.danger : null)),
        ]);
    final video = widget.entry.video;
    final choice = await showMenu<Object>(
      context: context,
      position: RelativeRect.fromRect(at & const Size(1, 1), Offset.zero & overlay.size),
      items: [
        if (video) PopupMenuItem(value: NoteAction.jump, child: row(Icons.play_arrow_rounded, tr('ink.jump'))),
        PopupMenuItem(value: NoteAction.edit, child: row(Icons.brush_rounded, tr('ink.edit'))),
        PopupMenuItem(value: NoteAction.rename, child: row(Icons.drive_file_rename_outline_rounded, tr('ink.rename'))),
        PopupMenuItem(value: NoteAction.shot, child: row(Icons.camera_alt_rounded, tr('ink.shot'))),
        PopupMenuItem(value: NoteAction.send, child: row(Icons.send_rounded, tr('ink.send_shot'))),
        if (video) ...[
          PopupMenuItem(value: NoteAction.clip, child: row(Icons.movie_creation_rounded, tr('clip.of_note'))),
          PopupMenuItem(value: NoteAction.sendClip, child: row(Icons.send_rounded, tr('clip.send_of_note'))),
        ],
        if (video) ...[
          const PopupMenuDivider(),
          PopupMenuItem(enabled: false, child: Text(tr('ink.hold'))),
          for (final s in const [1, 3, 5, 10])
            CheckedPopupMenuItem<Object>(value: s * 1000, checked: n.holdMs == s * 1000, child: Text(tr('ink.seconds', {'n': s}))),
        ],
        const PopupMenuDivider(),
        PopupMenuItem(value: NoteAction.delete, child: row(Icons.delete_outline_rounded, tr('ink.delete'), danger: true)),
      ],
    );
    if (choice is NoteAction) widget.onAction(n, choice);
    if (choice is int) widget.onHold(n, choice);
  }

  Widget _settings() {
    final m = widget.services.player;
    return PopupMenuButton<String>(
      tooltip: tr('ink.settings'),
      icon: const Icon(Icons.tune_rounded, size: 20),
      onSelected: (v) {
        if (v == 'pause') m.setPauseAtNotes(!m.pauseAtNotes);
        if (v == 'around') widget.onClipAround();
        if (v.startsWith('lead:')) m.setLead(int.parse(v.substring(5)));
        setState(() {});
      },
      itemBuilder: (_) => [
        CheckedPopupMenuItem(value: 'pause', checked: m.pauseAtNotes, child: Text(tr('ink.pause_at_notes'))),
        PopupMenuItem(value: 'around', child: Text(tr('clip.around_now', {'before': m.clipBefore, 'after': m.clipAfter}))),
        const PopupMenuDivider(),
        PopupMenuItem(enabled: false, child: Text(tr('ink.lead'))),
        for (final s in const [0, 1, 2, 3, 5])
          CheckedPopupMenuItem(value: 'lead:$s', checked: m.leadSec == s, child: Text(tr('ink.seconds', {'n': s}))),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final all = widget.set?.sorted ?? const <Note>[];
    final shown = all.where(_matches).toList();
    return Material(
      color: Colors.transparent,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 6, 4),
          child: Row(children: [
            Expanded(
              child: widget.leading ??
                  Text('${tr('ink.notes')}${all.isEmpty ? '' : ' (${all.length})'}', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            ),
            IconButton(
              tooltip: tr(widget.showInk ? 'ink.hide' : 'ink.show'),
              onPressed: () => widget.onShowInk(!widget.showInk),
              icon: Icon(widget.showInk ? Icons.visibility_rounded : Icons.visibility_off_rounded, size: 20),
            ),
            if (widget.entry.video) _settings(),
          ]),
        ),
        if (all.length > 3)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            child: TextField(
              controller: _q,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                isDense: true,
                prefixIcon: const Icon(Icons.search_rounded, size: 18),
                hintText: tr('ink.search'),
                border: const OutlineInputBorder(),
              ),
            ),
          ),
        Expanded(
          child: all.isEmpty
              ? Padding(
                  padding: const EdgeInsets.all(20),
                  child: Text(tr('ink.empty'), style: const TextStyle(color: LrColors.muted, height: 1.5)),
                )
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(8, 0, 8, 12),
                  itemCount: shown.length,
                  itemBuilder: (context, k) {
                    final n = shown[k];
                    return Material(
                      color: Colors.transparent,
                      child: InkWell(
                        borderRadius: BorderRadius.circular(8),
                        onTap: () => widget.onAction(n, widget.entry.video ? NoteAction.jump : NoteAction.edit),
                        onSecondaryTapUp: (d) => _menu(context, n, d.globalPosition),
                        child: Padding(
                          padding: const EdgeInsets.all(6),
                          child: Row(children: [
                            ClipRRect(
                              borderRadius: BorderRadius.circular(6),
                              child: SizedBox(
                                width: 104,
                                height: 64,
                                child: _NoteThumb(key: ValueKey('${n.id}|${n.modifiedMs}'), services: widget.services, entry: widget.entry, note: n, aspect: widget.aspect),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                Text(n.name, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13.5)),
                                const SizedBox(height: 3),
                                Text(
                                  [
                                    if (widget.entry.video) _time(n.startMs),
                                    tr('ink.n_marks', {'n': n.inks.length}),
                                    if (n.narration) tr('ink.from_narration'),
                                  ].join(' · '),
                                  style: const TextStyle(fontSize: 12, color: LrColors.muted),
                                ),
                              ]),
                            ),
                            Builder(
                              builder: (bc) => IconButton(
                                tooltip: tr('ink.more'),
                                onPressed: () {
                                  final ro = bc.findRenderObject();
                                  final box = ro is RenderBox ? ro : null;
                                  final at = box == null ? Offset.zero : box.localToGlobal(box.size.bottomLeft(Offset.zero));
                                  _menu(context, n, at);
                                },
                                icon: const Icon(Icons.more_vert_rounded, size: 18),
                              ),
                            ),
                          ]),
                        ),
                      ),
                    );
                  },
                ),
        ),
        if (widget.narrations.isNotEmpty) ...[
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 2),
            child: Text(tr('rec.records'), style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: LrColors.muted)),
          ),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 180),
            child: ListView(shrinkWrap: true, padding: const EdgeInsets.only(bottom: 8), children: [
              for (final n in widget.narrations)
                ListTile(
                  dense: true,
                  leading: const Icon(Icons.mic_rounded, size: 18, color: LrColors.danger),
                  title: Text(tr('rec.record_name', {'time': _time(n.lengthMs)})),
                  subtitle: Text(() {
                    final d = DateTime.fromMillisecondsSinceEpoch(n.createdMs);
                    String two(int v) => v.toString().padLeft(2, '0');
                    return '${d.month}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}'
                        '${n.files.length > 1 ? ' · ${tr('rec.n_files', {'n': n.files.length})}' : ''}';
                  }(), style: const TextStyle(fontSize: 12, color: LrColors.muted)),
                  trailing: PopupMenuButton<String>(
                    tooltip: tr('ink.more'),
                    icon: const Icon(Icons.more_vert_rounded, size: 18),
                    onSelected: (a) => widget.onNarration?.call(n, a),
                    itemBuilder: (_) => [
                      PopupMenuItem(value: 'remake', child: Text(tr('rec.remake'))),
                      PopupMenuItem(value: 'delete', child: Text(tr('rec.delete_record'), style: const TextStyle(color: LrColors.danger))),
                    ],
                  ),
                  onTap: () => widget.onNarration?.call(n, 'remake'),
                ),
            ]),
          ),
        ],
      ]),
    );
  }
}

/// The picture at the annotation (a video: the still at its last mark),
/// with its marks.
class _NoteThumb extends StatefulWidget {
  const _NoteThumb({super.key, required this.services, required this.entry, required this.note, required this.aspect});

  final AppServices services;
  final PlayerEntry entry;
  final Note note;
  final double aspect;

  @override
  State<_NoteThumb> createState() => _NoteThumbState();
}

class _NoteThumbState extends State<_NoteThumb> {
  late final Future<File?> _pic = _load();

  Future<File?> _load() {
    final e = widget.entry;
    final ff = widget.services.ffmpeg;
    if (e.video) return ff.frameAt(e.path, widget.note.lastMs, size: e.size, modifiedMs: e.modifiedMs);
    if (e.item != null) return ff.thumbnail(e.item!);
    return ff.thumbnailFile(e.path, size: e.size, modifiedMs: e.modifiedMs, video: false);
  }

  @override
  Widget build(BuildContext context) => Container(
        color: Colors.black,
        alignment: Alignment.center,
        child: AspectRatio(
          aspectRatio: widget.aspect <= 0 ? 16 / 9 : widget.aspect,
          child: Stack(fit: StackFit.expand, children: [
            FutureBuilder<File?>(
              future: _pic,
              builder: (context, s) => s.data == null ? const SizedBox.shrink() : Image.file(s.data!, fit: BoxFit.fill, gaplessPlayback: true),
            ),
            CustomPaint(painter: InkPainter(notes: [widget.note], video: false)),
          ]),
        ),
      );
}
