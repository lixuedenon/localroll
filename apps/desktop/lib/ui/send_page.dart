// apps/desktop/lib/ui/send_page.dart
import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:localroll_core/localroll_core.dart';

import '../app_services.dart';
import '../l10n/l10n.dart';
import '../services/peers.dart';
import '../services/phone_formats.dart';
import '../services/settings.dart';
import 'app_nav.dart';
import 'breathing.dart';
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

  static bool _autoScanned = false;

  /// Look for PCs only while this page is shown.
  void _onNav() {
    final show = AppNav.instance.tab == AppNav.send;
    if (show == _looking) return;
    _looking = show;
    if (show) {
      widget.services.peers.acquire();
      // Scanning the whole network is noisy: only by itself when there is
      // nothing paired yet (once per run); otherwise on "Search".
      final p = widget.services.peers;
      if (!_autoScanned && widget.services.settings.peers.isEmpty && p.found.isEmpty) {
        _autoScanned = true;
        unawaited(p.scan());
      }
    } else {
      widget.services.peers.release();
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.services;
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: Listenable.merge([s.peers, s.sender, s.settings, s.server]),
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

              const SizedBox(height: 20),
              _section(theme, tr('send.paired')),
              if (paired.isEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Text(tr('send.no_paired'), style: const TextStyle(color: LrColors.muted)),
                ),
              for (final p in paired) _pairedCard(context, p),
              // Phones: they receive while LocalRoll is open on them.
              if (s.phones.isNotEmpty) ...[
                const SizedBox(height: 20),
                _section(theme, tr('send.phones')),
                for (final t in s.phones) _phoneCard(context, t),
              ],
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
                for (final j in s.sender.jobs) _JobTile(job: j, onCancel: () => s.sender.cancel(j), onResend: () => s.sender.resend(j)),
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

  Widget _pairedCard(BuildContext context, PeerPc p) {
    final s = widget.services;
    final online = s.isOnline(p.id);
    final family = s.settings.trusted[p.id]?.familyMember ?? true;
    // The card itself breathes while that PC is online.
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Breathing(
        online: online,
        child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(children: [
          DeviceBadge(icon: p.icon, color: p.color, size: 48),
          const SizedBox(width: 16),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(p.name, style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 4),
              Text(
                online ? tr('send.online') : tr('send.offline'),
                style: TextStyle(color: online ? onlineGlow : LrColors.muted, fontSize: 13),
              ),
              const SizedBox(height: 2),
              // How each side treats the other: family = straight in, guest = "Accept" first.
              Text(tr(family ? 'send.in_my_family' : 'send.my_guest'),
                  style: const TextStyle(color: LrColors.muted, fontSize: 12)),
              if (s.peers.familyAt[p.id] case final there?)
                Text(tr(there ? 'send.me_family_there' : 'send.me_guest_there'),
                    style: TextStyle(color: there ? LrColors.muted : LrColors.safelight, fontSize: 12)),
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
            onSelected: (v) {
              if (v == 'family' || v == 'guest') {
                unawaited(s.server.setFamily(p.id, v == 'family'));
              } else if (v == 'ask_family' || v == 'leave_family') {
                unawaited(_membership(p, family: v == 'ask_family'));
              } else {
                _unpair(p, forget: v == 'forget');
              }
            },
            itemBuilder: (_) => [
              // What it sends here: straight in (family) or after "Accept" (guest).
              if (family)
                PopupMenuItem(value: 'guest', child: Text(tr('family.make_guest')))
              else
                PopupMenuItem(value: 'family', child: Text(tr('family.make_family'))),
              // Our place in its family group (it decides; leaving is up to us).
              if (s.peers.familyAt[p.id] == true)
                PopupMenuItem(value: 'leave_family', child: Text(tr('send.leave_family_there')))
              else
                PopupMenuItem(value: 'ask_family', child: Text(tr('send.ask_family_there'))),
              PopupMenuItem(value: 'disconnect', child: Text(tr('send.disconnect'))),
              PopupMenuItem(value: 'forget', child: Text(tr('send.forget'))),
            ],
          ),
        ]),
        ),
      ),
    );
  }

  /// A paired phone: breathes while it can receive (LocalRoll open on it).
  Widget _phoneCard(BuildContext context, TrustedDevice t) {
    final s = widget.services;
    final target = s.phoneTarget(t.id);
    final ready = target != null;
    // Online (checking in) but not telling where it receives: an older
    // LocalRoll on the phone, or its receiver is still starting.
    final onlineOnly = !ready && s.isOnline(t.id);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Breathing(
        online: ready,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(children: [
            CircleAvatar(
              radius: 24,
              backgroundColor: LrColors.raised,
              child: Icon(t.platform == 'ios' ? Icons.phone_iphone_rounded : Icons.phone_android_rounded,
                  color: ready ? onlineGlow : LrColors.muted),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(t.name, style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 4),
                Text(tr(ready ? 'send.phone_ready' : (onlineOnly ? 'send.phone_online_not_ready' : 'send.phone_closed_hint')),
                    style: TextStyle(color: ready ? onlineGlow : (onlineOnly ? LrColors.safelight : LrColors.muted), fontSize: 13)),
              ]),
            ),
            FilledButton.icon(
              onPressed: target == null ? null : () => _sendFiles(target, toPhone: true),
              icon: const Icon(Icons.description_outlined),
              label: Text(tr('send.files')),
            ),
            const SizedBox(width: 8),
            OutlinedButton.icon(
              onPressed: target == null ? null : () => _sendFolder(target, toPhone: true),
              icon: const Icon(Icons.folder_outlined),
              label: Text(tr('send.folder')),
            ),
          ]),
        ),
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

  /// Ask PC [p] to make this PC a family member there, or leave its family.
  Future<void> _membership(PeerPc p, {required bool family}) async {
    final m = ScaffoldMessenger.of(context);
    if (family) m.showSnackBar(SnackBar(content: Text(tr('send.ask_family_waiting', {'name': p.name}))));
    try {
      final now = await widget.services.peers.requestMembership(p.id, family: family);
      if (!mounted) return;
      m.hideCurrentSnackBar();
      m.showSnackBar(SnackBar(
        content: Text(tr(now ? 'send.now_family_there' : (family ? 'send.family_denied' : 'send.now_guest_there'), {'name': p.name})),
      ));
    } on PeerError catch (e) {
      if (!mounted) return;
      m.hideCurrentSnackBar();
      m.showSnackBar(SnackBar(content: Text(peerErrorText(e.code))));
    }
  }

  Future<void> _sendFiles(PeerPc p, {bool toPhone = false}) async {
    final picked = await openFiles(confirmButtonText: tr('send.files'));
    if (picked.isEmpty) return;
    final files = [
      // Photos and videos go into the other PC's library; other files into
      // its "Received files" folder.
      for (final x in picked)
        ?SendFile.plain(File(x.path), x.name, toLibrary: MediaKind.fromName(x.name) != MediaKind.other),
    ];
    if (files.isEmpty) return;
    final title = files.length == 1 ? files.first.name : tr('send.n_files', {'count': files.length});
    if (!mounted) return;
    if (toPhone) {
      await queueForPhone(context, widget.services, p, files, title);
    } else {
      widget.services.sender.add(p, files, title);
    }
  }

  Future<void> _sendFolder(PeerPc p, {bool toPhone = false}) async {
    final dir = await getDirectoryPath(confirmButtonText: tr('send.folder'));
    if (dir == null) return;
    final files = await filesInFolder(dir);
    if (!mounted) return;
    if (files.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('send.empty_folder'))));
      return;
    }
    final name = dir.replaceAll(RegExp(r'[\\/]+$'), '').split(RegExp(r'[\\/]')).last;
    if (toPhone) {
      await queueForPhone(context, widget.services, p, files, name);
    } else {
      widget.services.sender.add(p, files, name);
    }
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
  const _JobTile({required this.job, required this.onCancel, this.onResend});

  final SendJob job;
  final VoidCallback onCancel;

  /// Failed / cancelled: send it again (finished files are skipped).
  final VoidCallback? onResend;

  @override
  Widget build(BuildContext context) {
    final j = job;
    final (String status, Color color) = switch (j.state) {
      SendJobState.waiting => (tr('send.waiting'), LrColors.muted),
      SendJobState.converting => (
          tr('send.converting', {'done': min(j.convertDone + 1, j.convertTotal), 'total': j.convertTotal}),
          LrColors.safelight
        ),
      SendJobState.connecting => (tr('send.connecting'), LrColors.safelight),
      SendJobState.sending => (tr('send.sending'), LrColors.safelight),
      SendJobState.done => (tr('send.done'), LrColors.verified),
      SendJobState.failed => (
          [peerErrorText(j.error), if (j.reason?.isNotEmpty ?? false) tr('send.their_reason', {'reason': j.reason!})].join(' — '),
          LrColors.danger
        ),
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
            if (onResend != null && (j.state == SendJobState.failed || j.state == SendJobState.cancelled))
              TextButton.icon(
                onPressed: onResend,
                icon: const Icon(Icons.refresh_rounded, size: 18),
                label: Text(tr('send.resend')),
              ),
          ]),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: j.state == SendJobState.connecting
                  ? null
                  : j.state == SendJobState.converting
                      ? (j.convertTotal == 0 ? null : ((j.convertDone + j.convertProgress) / j.convertTotal).clamp(0.0, 1.0))
                      : j.fraction,
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
  final phones = [for (final t in s.phones) ?s.phoneTarget(t.id)];
  if (peers.isEmpty && phones.isEmpty) {
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
        // Phones with LocalRoll open (they ask their owner first).
        for (final p in phones)
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, p),
            child: Row(children: [
              const CircleAvatar(radius: 16, backgroundColor: LrColors.raised, child: Icon(Icons.smartphone_rounded, size: 18)),
              const SizedBox(width: 12),
              Expanded(child: Text(p.name)),
              const Icon(Icons.circle, size: 10, color: onlineGlow),
            ]),
          ),
        for (final p in peers)
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, p),
            child: Row(children: [
              DeviceBadge(icon: p.icon, color: p.color, size: 32),
              const SizedBox(width: 12),
              Expanded(child: Text(p.name)),
              if (s.isOnline(p.id)) const Icon(Icons.circle, size: 10, color: onlineGlow),
            ]),
          ),
      ],
    ),
  );
  if (p == null || !context.mounted) return;
  if (phones.contains(p)) {
    await queueForPhone(context, s, p, files, title);
    return;
  }
  s.sender.add(p, files, title);
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
    content: Text(tr('send.queued', {'name': p.name})),
    action: SnackBarAction(label: tr('send.title'), onPressed: () => AppNav.instance.selectTab(AppNav.send)),
  ));
}

/// To a phone: say what will be converted so its photo app can show it, and
/// let the user choose (convert — recommended — or send everything as it is).
Future<void> queueForPhone(BuildContext context, AppServices s, PeerPc phone, List<SendFile> files, String title) async {
  final platform = s.settings.trusted[phone.id]?.platform ?? '';
  final fmt = s.sender.formatter;
  if (fmt == null) {
    s.sender.add(phone, files, title, toPhone: true, platform: platform);
    return;
  }
  final plan = PhonePlan([for (final f in files) await fmt.decide(f, platform)]);
  if (!context.mounted) return;
  var convert = false;
  if (plan.anyConversion) {
    final choice = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        icon: const Icon(Icons.auto_fix_high_rounded, size: 32),
        title: Text(tr('phonefmt.title', {'count': plan.actions.where((a) => a != PhoneAction.asIs).length, 'name': phone.name})),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (plan.count(PhoneAction.toJpeg) > 0) Text('• ${tr('phonefmt.jpeg', {'count': plan.count(PhoneAction.toJpeg)})}'),
            if (plan.count(PhoneAction.remux) > 0) Text('• ${tr('phonefmt.remux', {'count': plan.count(PhoneAction.remux)})}'),
            if (plan.count(PhoneAction.toH264) > 0) Text('• ${tr('phonefmt.h264', {'count': plan.count(PhoneAction.toH264)})}'),
            const SizedBox(height: 10),
            Text(tr('phonefmt.note'), style: const TextStyle(color: LrColors.muted, fontSize: 13)),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: Text(tr('common.cancel'))),
          OutlinedButton(onPressed: () => Navigator.pop(c, 'asis'), child: Text(tr('phonefmt.as_is'))),
          FilledButton(onPressed: () => Navigator.pop(c, 'convert'), child: Text(tr('phonefmt.convert'))),
        ],
      ),
    );
    if (choice == null) return;
    convert = choice == 'convert';
  }
  s.sender.add(phone, files, title, toPhone: true, convert: convert, platform: platform);
  if (context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(tr('send.queued', {'name': phone.name})),
      action: SnackBarAction(label: tr('send.title'), onPressed: () => AppNav.instance.selectTab(AppNav.send)),
    ));
  }
}
