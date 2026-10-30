// apps/desktop/lib/ui/screen/recordings_view.dart
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:localroll_core/localroll_core.dart';

import '../../app_services.dart';
import '../../l10n/l10n.dart';
import '../../services/library_index.dart';
import '../../services/network.dart';
import '../../services/peers.dart';
import '../../services/recordings.dart';
import '../app_nav.dart';
import '../convert_dialog.dart';
import '../files_view.dart';
import '../format.dart';
import '../player/narration.dart';
import '../player/player_entry.dart';
import '../player/player_page.dart';
import '../send_page.dart';
import '../theme.dart';
import '../trash_actions.dart';

String _len(int ms) {
  final d = Duration(milliseconds: ms);
  final s = (d.inSeconds % 60).toString().padLeft(2, '0');
  return d.inHours > 0 ? '${d.inHours}:${(d.inMinutes % 60).toString().padLeft(2, '0')}:$s' : '${d.inMinutes}:$s';
}

String _when(int ms) {
  final d = DateTime.fromMillisecondsSinceEpoch(ms);
  String two(int v) => v.toString().padLeft(2, '0');
  return '${d.year}-${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}';
}

IconData kindIcon(RecKind k) => switch (k) {
      RecKind.screen => Icons.desktop_windows_rounded,
      RecKind.narration => Icons.record_voice_over_rounded,
      RecKind.clip => Icons.content_cut_rounded,
      RecKind.shot => Icons.photo_camera_rounded,
    };

/// The group a recording is shown in: screen recordings by what was
/// recorded ("Screen · Chrome"), the rest by the original's name.
String groupOf(Recording r) => r.kind == RecKind.screen ? tr('recs.group_screen', {'name': r.source}) : r.source;

/// Opens recordings in the player ([list]: what the arrows go through).
Future<void> openRecordings(BuildContext context, AppServices s, List<Recording> list, Recording r) {
  final entries = <PlayerEntry>[];
  var at = 0;
  for (final x in list) {
    final e = PlayerEntry.fromPath(x.path, library: s.library);
    if (e == null) continue;
    if (x.id == r.id) at = entries.length;
    entries.add(e);
  }
  if (entries.isEmpty) return Future.value();
  return openPlayer(context, s, entries, at, source: tr('recs.title'));
}

/// The menu's actions for one recording. [onPlay]: play it (else it opens
/// in the player); [onRemake]: make an explanation again in this player.
Future<void> recordingAction(
  BuildContext context,
  AppServices s,
  Recording r,
  String action, {
  VoidCallback? onPlay,
  Future<void> Function(Recording r)? onRemake,
}) async {
  final recs = s.recordings;
  switch (action) {
    case 'play':
      if (onPlay != null) {
        onPlay();
      } else {
        await openRecordings(context, s, [r], r);
      }
    case 'send':
      await sendRecordings(context, s, [r]);
    case 'rename':
      final c = TextEditingController(text: stemOf(r.name));
      final name = await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(tr('recs.rename')),
          content: SizedBox(
            width: 420,
            child: TextField(controller: c, autofocus: true, onSubmitted: (v) => Navigator.pop(ctx, v)),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: Text(tr('common.cancel'))),
            FilledButton(onPressed: () => Navigator.pop(ctx, c.text), child: Text(tr('common.ok'))),
          ],
        ),
      );
      c.dispose();
      if (name == null || name.trim().isEmpty) return;
      final ok = await recs.rename(r, name);
      if (!ok && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('recs.rename_failed'))));
      }
    case 'convert':
      final item = recs.itemOf(r);
      await convertWithDialog(context, s, items: [?item], path: item == null ? r.path : null, video: r.video);
    case 'remake':
      if (onRemake != null) {
        await onRemake(r);
        return;
      }
      final src = r.sourcePath;
      if (src == null || !File(src).existsSync()) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('recs.source_gone'))));
        return;
      }
      await openInPlayer(context, s, [src], remake: r.narrationId);
    case 'delete':
      await deleteRecordings(context, s, [r]);
    case 'reveal':
      await revealInExplorer(r.path);
  }
}

/// Sends recordings to a phone or PC (from the library when they are in it).
Future<void> sendRecordings(BuildContext context, AppServices s, List<Recording> list) async {
  final files = <SendFile>[];
  for (final r in list) {
    final item = s.recordings.itemOf(r);
    final f = item != null ? SendFile.fromLibrary(s.library, item) : SendFile.plain(File(r.path), r.name);
    if (f != null) files.add(f);
  }
  if (files.isEmpty || !context.mounted) return;
  await sendToPc(context, s, files, list.length == 1 ? list.first.name : tr('send.n_items', {'count': list.length}));
}

/// Deleted into "Recently deleted"; an explanation's recording (voice,
/// marks) too if the person says so (then it can't be made again).
Future<void> deleteRecordings(BuildContext context, AppServices s, List<Recording> list) async {
  final media = <MediaItem>[];
  final files = <String>[];
  for (final r in list) {
    final item = s.recordings.itemOf(r);
    if (item != null) {
      media.add(item);
    } else {
      files.add(r.path);
    }
  }
  final n = await deleteToTrash(context, s, media: media, files: files);
  if (n == 0 || !context.mounted) return;
  final raw = [for (final r in list) ?r.narrationId];
  if (raw.isEmpty) return;
  final also = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(tr('recs.raw_title')),
      content: SizedBox(width: 440, child: Text(tr('recs.raw_text'), style: const TextStyle(height: 1.5))),
      actions: [
        FilledButton(autofocus: true, onPressed: () => Navigator.pop(ctx, false), child: Text(tr('recs.raw_keep'))),
        TextButton(
          onPressed: () => Navigator.pop(ctx, true),
          style: TextButton.styleFrom(foregroundColor: LrColors.danger),
          child: Text(tr('recs.raw_delete')),
        ),
      ],
    ),
  );
  if (also != true) return;
  for (final id in raw) {
    try {
      await NarrationSession.folderOf(s.settings.dataDir, id).delete(recursive: true);
    } catch (_) {}
  }
  s.recordings.forget([for (final r in list) if (r.narrationId != null && !r.exists) r]);
}

/// "Who can see my recordings": the phones allowed to (others don't see
/// them when they look at this library).
Future<void> pickSeenBy(BuildContext context, AppServices s) async {
  final phones = [for (final t in s.settings.trusted.values) if (!isDesktopPlatform(t.platform)) t];
  final chosen = Set<String>.of(s.recordings.seenBy);
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, set) => AlertDialog(
        title: Text(tr('recs.seen_title')),
        content: SizedBox(
          width: 440,
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(tr('recs.seen_text'), style: const TextStyle(color: LrColors.muted, height: 1.5)),
            const SizedBox(height: 10),
            if (phones.isEmpty) Text(tr('recs.seen_none'), style: const TextStyle(color: LrColors.muted)),
            for (final p in phones)
              CheckboxListTile(
                value: chosen.contains(p.id),
                onChanged: (v) => set(() => v == true ? chosen.add(p.id) : chosen.remove(p.id)),
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                title: Text(p.family.member == p.name ? p.name : '${p.family.member} · ${p.name}'),
              ),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('common.cancel'))),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(tr('common.ok'))),
        ],
      ),
    ),
  );
  if (ok == true) s.recordings.setSeenBy(chosen);
}

/// After saving: play it, send it, or go to "My recordings".
void showSavedBar(BuildContext context, AppServices s, File f) {
  final messenger = ScaffoldMessenger.maybeOf(context);
  if (messenger == null) return;
  final r = s.recordings.byPath(f.path);
  messenger.showSnackBar(SnackBar(
    duration: const Duration(seconds: 10),
    content: Row(children: [
      Expanded(child: Text(tr('recs.saved', {'name': f.path.split(Platform.pathSeparator).last}), maxLines: 2, overflow: TextOverflow.ellipsis)),
      TextButton(
        onPressed: () {
          messenger.hideCurrentSnackBar();
          if (r != null) {
            unawaited(openRecordings(context, s, [r], r));
          } else {
            unawaited(openInPlayer(context, s, [f.path]));
          }
        },
        child: Text(tr('recs.play')),
      ),
      TextButton(
        onPressed: () {
          messenger.hideCurrentSnackBar();
          final nav = AppNav.instance.navigatorKey.currentState;
          nav?.popUntil((route) => route.isFirst);
          AppNav.instance.selectTab(AppNav.screen);
        },
        child: Text(tr('recs.go')),
      ),
      const SizedBox(width: 4),
      FilledButton.icon(
        onPressed: () {
          messenger.hideCurrentSnackBar();
          if (r != null) {
            unawaited(sendRecordings(context, s, [r]));
          } else {
            final file = SendFile.plain(f, f.path.split(Platform.pathSeparator).last);
            if (file != null) unawaited(sendToPc(context, s, [file], f.path.split(Platform.pathSeparator).last));
          }
        },
        icon: const Icon(Icons.send_rounded, size: 16),
        label: Text(tr('player.send')),
      ),
    ]),
  ));
}

/// "My recordings": search, kinds, grouped by what they came from (the
/// latest first). [compact]: the player's side list.
class RecordingsView extends StatefulWidget {
  const RecordingsView({
    super.key,
    required this.services,
    this.compact = false,
    this.current,
    this.query = '',
    this.onOpen,
    this.onRemake,
    this.footer,
  });

  final AppServices services;
  final bool compact;

  /// Shown now (highlighted).
  final String? current;
  final String query;

  /// Play [r] ([shown]: the list as it is now). Null: in the player.
  final void Function(List<Recording> shown, Recording r)? onOpen;
  final Future<void> Function(Recording r)? onRemake;

  /// More at the end (explanations not made into a video yet).
  final Widget? footer;

  @override
  State<RecordingsView> createState() => _RecordingsViewState();
}

class _RecordingsViewState extends State<RecordingsView> {
  late final TextEditingController _q = TextEditingController(text: widget.query);
  RecKind? _kind;
  final Set<String> _picked = {};

  AppServices get s => widget.services;

  @override
  void didUpdateWidget(RecordingsView old) {
    super.didUpdateWidget(old);
    if (old.query != widget.query) _q.text = widget.query;
  }

  @override
  void dispose() {
    _q.dispose();
    super.dispose();
  }

  List<Recording> _shown() {
    final q = _q.text.trim().toLowerCase();
    return [
      for (final r in s.recordings.items)
        if ((_kind == null || r.kind == _kind) &&
            (q.isEmpty || r.name.toLowerCase().contains(q) || r.source.toLowerCase().contains(q) || (r.sourcePath?.toLowerCase().contains(q) ?? false)))
          r,
    ];
  }

  void _open(List<Recording> shown, Recording r) {
    final on = widget.onOpen;
    if (on != null) {
      on(shown, r);
    } else {
      unawaited(openRecordings(context, s, shown, r));
    }
  }

  Widget _chips() => Wrap(spacing: 6, runSpacing: 6, children: [
        for (final k in [null, ...RecKind.values])
          ChoiceChip(
            visualDensity: VisualDensity.compact,
            label: Text(tr(k == null ? 'recs.all' : 'recs.kind_${k.name}'), style: const TextStyle(fontSize: 12)),
            selected: _kind == k,
            onSelected: (_) => setState(() => _kind = k),
          ),
      ]);

  Widget _row(List<Recording> shown, Recording r) {
    final on = widget.current != null && widget.current!.toLowerCase() == r.path.toLowerCase();
    final picked = _picked.contains(r.id);
    final w = widget.compact ? 72.0 : 128.0;
    final st = (() {
      try {
        return File(r.path).statSync();
      } catch (_) {
        return null;
      }
    })();
    final meta = [
      tr('recs.kind_${r.kind.name}'),
      if (r.lengthMs > 0) _len(r.lengthMs),
      _when(r.createdMs),
      if (!widget.compact && st != null) formatBytes(st.size),
    ].join(' · ');
    return Material(
      color: on ? LrColors.safelight.withValues(alpha: 0.16) : (picked ? LrColors.raised : Colors.transparent),
      child: InkWell(
        onTap: () {
          if (_picked.isNotEmpty) {
            setState(() => picked ? _picked.remove(r.id) : _picked.add(r.id));
          } else {
            _open(shown, r);
          }
        },
        onLongPress: widget.compact ? null : () => setState(() => _picked.add(r.id)),
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: widget.compact ? 10 : 6, vertical: 5),
          child: Row(children: [
            if (!widget.compact)
              Checkbox(value: picked, onChanged: (v) => setState(() => v == true ? _picked.add(r.id) : _picked.remove(r.id))),
            ClipRRect(
              borderRadius: BorderRadius.circular(5),
              child: SizedBox(
                width: w,
                height: w * 9 / 16,
                child: Stack(fit: StackFit.expand, children: [
                  FileThumb(
                    key: ValueKey(r.path),
                    path: r.path,
                    size: st?.size ?? 0,
                    modified: st?.modified ?? DateTime.fromMillisecondsSinceEpoch(r.createdMs),
                    services: s,
                    box: w,
                    icon: Container(color: LrColors.raised, alignment: Alignment.center, child: Icon(kindIcon(r.kind), color: LrColors.muted, size: 18)),
                  ),
                  Positioned(right: 3, bottom: 3, child: Icon(kindIcon(r.kind), size: 14, color: Colors.white70)),
                ]),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(r.name,
                    maxLines: widget.compact ? 2 : 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 13, color: on ? LrColors.safelight : LrColors.text, fontWeight: on ? FontWeight.w600 : FontWeight.w400)),
                const SizedBox(height: 2),
                Text(meta, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11.5, color: LrColors.muted)),
                if (r.sentTo.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(tr('recs.sent_to', {'names': r.sentTo.join(', ')}),
                        maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11.5, color: LrColors.verified)),
                  ),
              ]),
            ),
            PopupMenuButton<String>(
              tooltip: tr('ink.more'),
              icon: const Icon(Icons.more_vert_rounded, size: 18),
              onSelected: (a) {
                if (a == 'play') {
                  _open(shown, r);
                  return;
                }
                unawaited(recordingAction(context, s, r, a, onRemake: widget.onRemake));
              },
              itemBuilder: (_) => [
                PopupMenuItem(value: 'play', child: Text(tr('recs.play'))),
                PopupMenuItem(value: 'send', child: Text(tr('player.send'))),
                PopupMenuItem(value: 'rename', child: Text(tr('recs.rename'))),
                PopupMenuItem(value: 'convert', child: Text(tr('convert.menu'))),
                if (r.kind == RecKind.narration && r.narrationId != null) PopupMenuItem(value: 'remake', child: Text(tr('rec.remake'))),
                PopupMenuItem(value: 'delete', child: Text(tr('lib.delete'), style: const TextStyle(color: LrColors.danger))),
                const PopupMenuDivider(),
                PopupMenuItem(value: 'reveal', child: Text(tr('common.show_in_folder'))),
              ],
            ),
          ]),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: s.recordings,
        builder: (context, _) {
          final shown = _shown();
          _picked.retainWhere((id) => shown.any((r) => r.id == id));
          // By what they came from; the group with the newest first.
          final groups = <String, List<Recording>>{};
          for (final r in shown) {
            groups.putIfAbsent(groupOf(r), () => []).add(r);
          }
          final rows = <Widget>[];
          for (final g in groups.entries) {
            rows.add(Padding(
              padding: EdgeInsets.fromLTRB(widget.compact ? 12 : 8, 12, 12, 4),
              child: Row(children: [
                Expanded(
                  child: Text(g.key, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
                ),
                Text(tr('recs.n', {'n': g.value.length}), style: const TextStyle(color: LrColors.muted, fontSize: 12)),
              ]),
            ));
            for (final r in g.value) {
              rows.add(_row(shown, r));
            }
          }
          final pad = EdgeInsets.symmetric(horizontal: widget.compact ? 10 : 0);
          final header = <Widget>[
            Padding(
              padding: pad,
              child: Row(children: [
                Expanded(
                  child: TextField(
                    controller: _q,
                    onChanged: (_) => setState(() {}),
                    decoration: InputDecoration(
                      isDense: true,
                      prefixIcon: const Icon(Icons.search_rounded, size: 18),
                      hintText: tr('recs.search'),
                      border: const OutlineInputBorder(),
                      suffixIcon: _q.text.isEmpty
                          ? null
                          : IconButton(onPressed: () => setState(_q.clear), icon: const Icon(Icons.close_rounded, size: 16)),
                    ),
                  ),
                ),
                if (!widget.compact) ...[
                  const SizedBox(width: 8),
                  OutlinedButton.icon(
                    onPressed: () => unawaited(pickSeenBy(context, s)),
                    icon: const Icon(Icons.lock_outline_rounded, size: 18),
                    label: Text(tr('recs.seen_button', {'n': s.recordings.seenBy.length})),
                  ),
                ],
              ]),
            ),
            const SizedBox(height: 8),
            Padding(padding: pad, child: _chips()),
            if (_picked.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Row(children: [
                  Text(tr('recs.picked', {'n': _picked.length})),
                  const SizedBox(width: 12),
                  FilledButton.icon(
                    onPressed: () => unawaited(sendRecordings(context, s, [for (final r in shown) if (_picked.contains(r.id)) r])),
                    icon: const Icon(Icons.send_rounded, size: 16),
                    label: Text(tr('player.send')),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton.icon(
                    onPressed: () async {
                      await deleteRecordings(context, s, [for (final r in shown) if (_picked.contains(r.id)) r]);
                      if (mounted) setState(_picked.clear);
                    },
                    icon: const Icon(Icons.delete_outline_rounded, size: 16),
                    label: Text(tr('lib.delete')),
                  ),
                  TextButton(onPressed: () => setState(_picked.clear), child: Text(tr('common.cancel'))),
                ]),
              ),
            if (!widget.compact && s.recordings.outside.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Row(children: [
                  Expanded(
                    child: Text(tr('recs.outside', {'n': s.recordings.outside.length}), style: const TextStyle(color: LrColors.safelight, fontSize: 12.5)),
                  ),
                  OutlinedButton(onPressed: () => unawaited(s.recordings.moveIntoLibrary()), child: Text(tr('recs.move_in'))),
                ]),
              ),
            if (!s.recordings.inLibrary)
              Padding(
                padding: EdgeInsets.fromLTRB(widget.compact ? 12 : 0, 8, 12, 0),
                child: Text(tr('recs.offline', {'folder': s.recordings.root}), style: const TextStyle(color: LrColors.safelight, fontSize: 12)),
              ),
          ];
          final empty = Padding(
            padding: const EdgeInsets.all(16),
            child: Text(tr(s.recordings.items.isEmpty ? 'recs.empty' : 'ink.no_hits'), style: const TextStyle(color: LrColors.muted, height: 1.5)),
          );
          if (widget.compact) {
            return Material(
              color: Colors.transparent,
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                const SizedBox(height: 10),
                ...header,
                Expanded(
                  child: ListView(padding: const EdgeInsets.only(bottom: 12), children: [
                    if (rows.isEmpty) empty else ...rows,
                    ?widget.footer,
                  ]),
                ),
              ]),
            );
          }
          return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            ...header,
            const SizedBox(height: 4),
            if (rows.isEmpty) empty else ...rows,
            ?widget.footer,
          ]);
        },
      );
}
