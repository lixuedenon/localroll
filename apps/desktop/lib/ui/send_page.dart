// apps/desktop/lib/ui/send_page.dart
import 'dart:async';
import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:localroll_core/localroll_core.dart';

import '../app_services.dart';
import '../l10n/l10n.dart';
import '../services/peers.dart';
import '../services/settings.dart';
import 'app_nav.dart';
import 'device_badge.dart';
import 'format.dart';
import 'text_window.dart';
import 'theme.dart';

/// Error code from sending / pairing, in the user's language.
String peerErrorText(String? code) {
  if (code == null) return '';
  final key = 'send.err_$code';
  return translator.has(key) ? tr(key) : tr('send.err_other', {'code': code});
}

/// PC → PC: pair with other LocalRoll PCs and send them files, folders or
/// photos from the library.
class SendPage extends StatefulWidget {
  const SendPage({super.key, required this.services});

  final AppServices services;

  @override
  State<SendPage> createState() => _SendPageState();
}

class _SendPageState extends State<SendPage> {
  bool _looking = false;
  bool _showHidden = false;

  @override
  void initState() {
    super.initState();
    AppNav.instance.addListener(_onNav);
    _onNav();
  }

  @override
  void dispose() {
    AppNav.instance.removeListener(_onNav);
    if (_looking) widget.services.peers.release();
    super.dispose();
  }

  /// Look for PCs only while this page is shown.
  void _onNav() {
    final show = AppNav.instance.tab == AppNav.send;
    if (show == _looking) return;
    _looking = show;
    if (show) {
      widget.services.peers.acquire();
      // A first scan so PCs whose mDNS is blocked show up too.
      if (widget.services.peers.found.isEmpty) unawaited(widget.services.peers.scan());
    } else {
      widget.services.peers.release();
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.services;
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: Listenable.merge([s.peers, s.sender, s.settings]),
      builder: (context, _) {
        final paired = s.settings.peers.values.toList()..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
        final unpaired = s.peers.found.where((f) => !s.settings.peers.containsKey(f.id)).toList();
        // "Forgotten" PCs are left out unless asked for.
        final hidden = unpaired.where((f) => s.settings.hiddenPeers.contains(f.id)).toList();
        final nearby = [
          for (final f in unpaired)
            if (_showHidden || !s.settings.hiddenPeers.contains(f.id)) f,
        ];
        return Scaffold(
          appBar: AppBar(
            title: Text(tr('send.title')),
            actions: [
              Padding(
                padding: const EdgeInsets.only(right: 16),
                child: s.peers.scanning
                    ? Row(children: [
                        const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                        const SizedBox(width: 10),
                        Text(tr('send.searching')),
                      ])
                    : TextButton.icon(
                        onPressed: s.peers.scan,
                        icon: const Icon(Icons.radar_rounded),
                        label: Text(tr('send.search')),
                      ),
              ),
            ],
          ),
          body: ListView(
            padding: const EdgeInsets.all(24),
            children: [
              Text(tr('send.hint'), style: theme.textTheme.bodyMedium?.copyWith(color: LrColors.muted)),
              const SizedBox(height: 6),
              Text(tr('send.where'), style: theme.textTheme.bodySmall?.copyWith(color: LrColors.muted)),
              const SizedBox(height: 4),
              Text(tr('send.drag_hint'), style: theme.textTheme.bodySmall?.copyWith(color: LrColors.muted)),
              const SizedBox(height: 20),
              _section(theme, tr('send.paired')),
              if (paired.isEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Text(tr('send.no_paired'), style: const TextStyle(color: LrColors.muted)),
                ),
              for (final p in paired) _pairedCard(context, p),
              const SizedBox(height: 20),
              _section(theme, tr('send.nearby')),
              if (nearby.isEmpty)
                Text(s.peers.scanning ? tr('send.searching') : tr('send.none_nearby'),
                    style: const TextStyle(color: LrColors.muted)),
              for (final f in nearby) _nearbyCard(context, f),
              if (hidden.isNotEmpty)
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton(
                    onPressed: () => setState(() => _showHidden = !_showHidden),
                    child: Text(_showHidden ? tr('send.hide_forgotten') : tr('send.show_forgotten', {'count': hidden.length})),
                  ),
                ),
              if (s.sender.jobs.isNotEmpty) ...[
                const SizedBox(height: 24),
                Row(children: [
                  Expanded(child: _section(theme, tr('send.transfers'))),
                  if (s.sender.jobs.any((j) => j.over))
                    Tooltip(
                      message: tr('common.clear_hint'),
                      child: TextButton(onPressed: s.sender.clearFinished, child: Text(tr('send.clear'))),
                    ),
                ]),
                for (final j in s.sender.jobs) _JobTile(job: j, onCancel: () => s.sender.cancel(j)),
              ],
            ],
          ),
        );
      },
    );
  }

  Widget _section(ThemeData theme, String t) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Text(t, style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
      );

  /// Drop target: files or folders dragged from Explorer onto a PC's card
  /// are sent to that PC.
  String? _dropOver;

  Future<void> _dropped(PeerPc p, List<String> paths) async {
    final files = <SendFile>[];
    var folders = 0;
    for (final path in paths) {
      if (FileSystemEntity.isDirectorySync(path)) {
        folders++;
        files.addAll(await filesInFolder(path));
      } else {
        final name = path.split(RegExp(r'[\\/]')).last;
        final f = SendFile.plain(File(path), name, toLibrary: MediaKind.fromName(name) != MediaKind.other);
        if (f != null) files.add(f);
      }
    }
    if (files.isEmpty || !mounted) return;
    final title = paths.length == 1
        ? paths.first.replaceAll(RegExp(r'[\\/]+$'), '').split(RegExp(r'[\\/]')).last
        : tr('send.n_files', {'count': files.length});
    widget.services.sender.add(p, files, folders == 0 && files.length > 1 ? tr('send.n_files', {'count': files.length}) : title);
  }

  Widget _pairedCard(BuildContext context, PeerPc p) => DropTarget(
        onDragEntered: (_) => setState(() => _dropOver = p.id),
        onDragExited: (_) => setState(() => _dropOver = null),
        onDragDone: (d) {
          setState(() => _dropOver = null);
          _dropped(p, [for (final f in d.files) f.path]);
        },
        child: _pairedCardBody(context, p),
      );

  Widget _pairedCardBody(BuildContext context, PeerPc p) {
    final s = widget.services;
    final online = s.peers.isOnline(p.id);
    final over = _dropOver == p.id;
    return Card(
      shape: over
          ? RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: const BorderSide(color: LrColors.safelight, width: 2),
            )
          : null,
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(children: [
          DeviceBadge(icon: p.icon, color: p.color, size: 48),
          const SizedBox(width: 16),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(p.name, style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 4),
              Row(children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(color: online ? LrColors.verified : LrColors.muted, shape: BoxShape.circle),
                ),
                const SizedBox(width: 6),
                Text(online ? tr('send.online') : tr('send.offline'),
                    style: TextStyle(color: online ? LrColors.verified : LrColors.muted, fontSize: 13)),
              ]),
            ]),
          ),
          FilledButton.icon(
            onPressed: () => _sendFiles(p),
            icon: const Icon(Icons.description_outlined),
            label: Text(tr('send.files')),
          ),
          const SizedBox(width: 8),
          OutlinedButton.icon(
            onPressed: () => _sendFolder(p),
            icon: const Icon(Icons.folder_outlined),
            label: Text(tr('send.folder')),
          ),
          const SizedBox(width: 8),
          OutlinedButton.icon(
            onPressed: () => showTextComposer(context, widget.services, p),
            icon: const Icon(Icons.edit_note_rounded),
            label: Text(tr('send.text')),
          ),
          PopupMenuButton<String>(
            onSelected: (v) => _unpair(p, forget: v == 'forget'),
            itemBuilder: (_) => [
              PopupMenuItem(value: 'disconnect', child: Text(tr('send.disconnect'))),
              PopupMenuItem(value: 'forget', child: Text(tr('send.forget'))),
            ],
          ),
        ]),
      ),
    );
  }

  Widget _nearbyCard(BuildContext context, FoundPc f) => Card(
        margin: const EdgeInsets.only(bottom: 10),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(children: [
            DeviceBadge(icon: f.info?.icon, color: f.info?.color, size: 40),
            const SizedBox(width: 16),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(f.name, style: Theme.of(context).textTheme.titleMedium),
                Text(f.hosts.first, style: const TextStyle(color: LrColors.muted, fontSize: 12)),
              ]),
            ),
            FilledButton.tonal(onPressed: () => _pair(f), child: Text(tr('send.pair'))),
          ]),
        ),
      );

  // ------------------------------------------------------------- actions

  Future<void> _sendFiles(PeerPc p) async {
    final picked = await openFiles(confirmButtonText: tr('send.files'));
    if (picked.isEmpty) return;
    final files = [
      // Photos and videos go into the other PC's library; other files into
      // its "Received files" folder.
      for (final x in picked)
        ?SendFile.plain(File(x.path), x.name, toLibrary: MediaKind.fromName(x.name) != MediaKind.other),
    ];
    if (files.isEmpty) return;
    widget.services.sender.add(p, files, files.length == 1 ? files.first.name : tr('send.n_files', {'count': files.length}));
  }

  Future<void> _sendFolder(PeerPc p) async {
    final dir = await getDirectoryPath(confirmButtonText: tr('send.folder'));
    if (dir == null) return;
    final files = await filesInFolder(dir);
    if (!mounted) return;
    if (files.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('send.empty_folder'))));
      return;
    }
    final name = dir.replaceAll(RegExp(r'[\\/]+$'), '').split(RegExp(r'[\\/]')).last;
    widget.services.sender.add(p, files, name);
  }

  /// Disconnect: both PCs stop sending to each other; each still sees the
  /// other under "Nearby" and can pair again with one click.
  /// Forget: the same, and this PC also stops listing the other one.
  Future<void> _unpair(PeerPc p, {required bool forget}) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr(forget ? 'send.forget_title' : 'send.disconnect_title', {'name': p.name})),
        content: Text(tr(forget ? 'send.forget_body' : 'send.disconnect_body')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('common.cancel'))),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(tr(forget ? 'send.forget' : 'send.disconnect')),
          ),
        ],
      ),
    );
    if (ok == true) await widget.services.peers.forget(p, hide: forget);
  }

  Future<void> _pair(FoundPc f) async {
    if (widget.services.settings.hiddenPeers.contains(f.id)) {
      await widget.services.settings.update((x) => x.hiddenPeers.remove(f.id));
    }
    final emoji = ValueNotifier<List<String>?>(null);
    var cancelled = false;
    final dialog = showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 380),
          child: ValueListenableBuilder<List<String>?>(
            valueListenable: emoji,
            builder: (_, e, _) => Column(mainAxisSize: MainAxisSize.min, children: [
              Text(tr('send.pair_wait', {'name': f.name}), textAlign: TextAlign.center, style: Theme.of(ctx).textTheme.titleMedium),
              const SizedBox(height: 18),
              if (e == null)
                const CircularProgressIndicator()
              else
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
                  decoration: BoxDecoration(
                    color: LrColors.ink,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: LrColors.line),
                  ),
                  child: Text(e.join('  '), style: const TextStyle(fontSize: 40)),
                ),
              const SizedBox(height: 12),
              Text(tr('send.pair_check'), textAlign: TextAlign.center, style: Theme.of(ctx).textTheme.bodySmall),
            ]),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              cancelled = true;
              Navigator.pop(ctx);
            },
            child: Text(tr('common.cancel')),
          ),
        ],
      ),
    );
    try {
      final p = await widget.services.peers.pair(f, onWaiting: (e) => emoji.value = e, cancelled: () => cancelled);
      if (!mounted || cancelled) return;
      Navigator.of(context).pop();
      if (p != null) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('send.paired_ok', {'name': p.name}))));
      }
    } on PeerError catch (e) {
      if (!mounted) return;
      if (!cancelled) Navigator.of(context).pop();
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(peerErrorText(e.code))));
    } finally {
      unawaited(dialog.whenComplete(emoji.dispose));
    }
  }
}

class _JobTile extends StatelessWidget {
  const _JobTile({required this.job, required this.onCancel});

  final SendJob job;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final j = job;
    final (String status, Color color) = switch (j.state) {
      SendJobState.waiting => (tr('send.waiting'), LrColors.muted),
      SendJobState.connecting => (tr('send.connecting'), LrColors.safelight),
      SendJobState.sending => (tr('send.sending'), LrColors.safelight),
      SendJobState.done => (tr('send.done'), LrColors.verified),
      SendJobState.failed => (peerErrorText(j.error), LrColors.danger),
      SendJobState.cancelled => (tr('send.cancelled'), LrColors.muted),
    };
    final parts = <String>[
      tr('send.progress', {'done': j.processed, 'total': j.files.length}),
      '${formatBytes(j.sentBytes)} / ${formatBytes(j.totalBytes)}',
      if (j.active && j.speed > 0) '${formatBytes(j.speed.round())}/s',
      if (j.skippedFiles > 0) tr('send.skipped', {'count': j.skippedFiles}),
      if (j.failedFiles > 0) tr('send.failed_n', {'count': j.failedFiles}),
    ];
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Icon(Icons.north_east_rounded, size: 18, color: LrColors.muted),
            const SizedBox(width: 8),
            Expanded(
              child: Text(tr('send.job_title', {'what': j.title, 'name': j.peer.name}),
                  overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600)),
            ),
            Text(status, style: TextStyle(color: color, fontSize: 13)),
            if (!j.over) IconButton(tooltip: tr('common.cancel'), onPressed: onCancel, icon: const Icon(Icons.close_rounded)),
          ]),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: j.state == SendJobState.connecting ? null : j.fraction,
              minHeight: 6,
              color: j.state == SendJobState.failed ? LrColors.danger : LrColors.verified,
              backgroundColor: LrColors.raised,
            ),
          ),
          const SizedBox(height: 6),
          Text(parts.join(' · '), style: const TextStyle(color: LrColors.muted, fontSize: 12)),
          if (j.current != null)
            Text(j.current!, overflow: TextOverflow.ellipsis, style: const TextStyle(color: LrColors.muted, fontSize: 12)),
        ]),
      ),
    );
  }
}

/// Library → another PC: choose which one, then queue the items.
Future<void> sendToPc(BuildContext context, AppServices s, List<SendFile> files, String title) async {
  final peers = s.settings.peers.values.toList();
  if (peers.isEmpty) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(tr('send.no_paired')),
      action: SnackBarAction(label: tr('send.title'), onPressed: () => AppNav.instance.selectTab(AppNav.send)),
    ));
    return;
  }
  final p = await showDialog<PeerPc>(
    context: context,
    builder: (ctx) => SimpleDialog(
      title: Text(tr('send.choose_pc', {'what': title})),
      children: [
        for (final p in peers)
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, p),
            child: Row(children: [
              DeviceBadge(icon: p.icon, color: p.color, size: 32),
              const SizedBox(width: 12),
              Expanded(child: Text(p.name)),
              if (s.peers.isOnline(p.id)) const Icon(Icons.circle, size: 10, color: LrColors.verified),
            ]),
          ),
      ],
    ),
  );
  if (p == null || !context.mounted) return;
  s.sender.add(p, files, title);
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
    content: Text(tr('send.queued', {'name': p.name})),
    action: SnackBarAction(label: tr('send.title'), onPressed: () => AppNav.instance.selectTab(AppNav.send)),
  ));
}
