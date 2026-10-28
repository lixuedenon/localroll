// apps/desktop/lib/ui/send_page.dart
import 'dart:math';

import 'package:flutter/material.dart';

import '../app_services.dart';
import '../l10n/l10n.dart';
import '../services/peers.dart';
import '../services/phone_formats.dart';
import '../services/settings.dart';
import 'app_nav.dart';
import 'breathing.dart';
import 'device_badge.dart';
import 'format.dart';
import 'theme.dart';
import 'transfers_panel.dart';

/// Error code from sending / pairing, in the user's language.
String peerErrorText(String? code) {
  if (code == null) return '';
  final key = 'send.err_$code';
  return translator.has(key) ? tr(key) : tr('send.err_other', {'code': code});
}

/// What a transfer is doing now, and its colour.
(String, Color) jobStatus(SendJob j) => switch (j.state) {
      SendJobState.waiting => (tr('send.waiting'), LrColors.muted),
      SendJobState.held => (tr('send.held', {'name': j.peer.name}), LrColors.muted),
      SendJobState.converting => (
          [
            tr(j.convertHw ? 'send.converting_hw' : 'send.converting',
                {'done': min(j.convertDone + 1, j.convertTotal), 'total': j.convertTotal}),
            if (j.convertProgress > 0) '${(j.convertProgress * 100).round()}%',
          ].join(' · '),
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

/// 0…1, or null while it can't be told (connecting).
double? jobProgress(SendJob j) => j.state == SendJobState.connecting
    ? null
    : j.state == SendJobState.converting
        ? (j.convertTotal == 0 ? null : ((j.convertDone + j.convertProgress) / j.convertTotal).clamp(0.0, 1.0))
        : j.fraction;

class JobTile extends StatelessWidget {
  const JobTile({super.key, required this.job, required this.onCancel, this.onResend});

  final SendJob job;
  final VoidCallback onCancel;

  /// Failed / cancelled: send it again (finished files are skipped).
  final VoidCallback? onResend;

  @override
  Widget build(BuildContext context) {
    final j = job;
    final (String status, Color color) = jobStatus(j);
    final parts = <String>[
      tr('send.progress', {'done': j.processed, 'total': j.files.length}),
      '${formatBytes(j.sentBytes)} / ${formatBytes(j.totalBytes)}',
      if (j.active && j.speed > 0) '${formatBytes(j.speed.round())}/s',
      if (j.skippedFiles > 0) tr('send.skipped', {'count': j.skippedFiles}),
      if (j.failedFiles > 0) tr('send.failed_n', {'count': j.failedFiles}),
      if (j.goneFiles > 0) tr('send.gone_n', {'count': j.goneFiles}),
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
              value: jobProgress(j),
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

/// Library → another PC or a phone: choose which one (the list follows who
/// comes online or goes, live), then queue the items. Offline ones can be
/// chosen too: it waits for them. True when queued (false: cancelled).
Future<bool> sendToPc(BuildContext context, AppServices s, List<SendFile> files, String title) async {
  if (s.settings.peers.isEmpty && s.phones.isEmpty) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(tr('send.no_paired')),
      action: SnackBarAction(label: tr('nav.transfer'), onPressed: () => AppNav.instance.selectTab(AppNav.devices)),
    ));
    return false;
  }
  final picked = await showDialog<(String, bool)>(
    context: context,
    builder: (ctx) => ListenableBuilder(
      listenable: Listenable.merge([s.server, s.peers, s.settings]),
      builder: (ctx, _) {
        final phones = s.phones;
        final peers = s.settings.peers.values.toList()
          ..sort((a, b) => (s.isOnline(b.id) ? 1 : 0) - (s.isOnline(a.id) ? 1 : 0));
        Widget state(bool on) => on
            ? const Icon(Icons.circle, size: 10, color: onlineGlow)
            : Text(tr('send.offline'), style: const TextStyle(color: LrColors.muted, fontSize: 12));
        return SimpleDialog(
          title: Text(tr('send.choose_pc', {'what': title})),
          children: [
            // Phones: online while LocalRoll is open on them.
            for (final t in phones)
              SimpleDialogOption(
                onPressed: () => Navigator.pop(ctx, (t.id, true)),
                child: Opacity(
                  opacity: s.phoneTarget(t.id) != null ? 1 : 0.55,
                  child: Row(children: [
                    const CircleAvatar(radius: 16, backgroundColor: LrColors.raised, child: Icon(Icons.smartphone_rounded, size: 18)),
                    const SizedBox(width: 12),
                    Expanded(child: Text(t.name)),
                    state(s.phoneTarget(t.id) != null),
                  ]),
                ),
              ),
            for (final p in peers)
              SimpleDialogOption(
                onPressed: () => Navigator.pop(ctx, (p.id, false)),
                child: Opacity(
                  opacity: s.isOnline(p.id) ? 1 : 0.55,
                  child: Row(children: [
                    DeviceBadge(icon: p.icon, color: p.color, size: 32),
                    const SizedBox(width: 12),
                    Expanded(child: Text(p.name)),
                    state(s.isOnline(p.id)),
                  ]),
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 8, 24, 0),
              child: Text(tr('send.offline_hint'), style: const TextStyle(color: LrColors.muted, fontSize: 12)),
            ),
          ],
        );
      },
    ),
  );
  if (picked == null || !context.mounted) return false;
  final (id, phone) = picked;
  if (phone) {
    final t = s.settings.trusted[id];
    final target = s.phoneTarget(id) ??
        (t == null ? null : PeerPc(id: id, name: t.name, hosts: const [], port: 0, token: '', pairedMs: t.pairedMs));
    if (target == null) return false;
    return queueForPhone(context, s, target, files, title);
  }
  final p = s.settings.peers[id];
  if (p == null) return false;
  s.sender.add(p, files, title);
  _queuedNote(context, s, p);
  return true;
}

/// "Queued" — or "waits for it to come online".
void _queuedNote(BuildContext context, AppServices s, PeerPc p) {
  if (!context.mounted) return;
  final online = s.sender.isOnline?.call(p.id) ?? true;
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
    content: Text(tr(online ? 'send.queued' : 'send.queued_held', {'name': p.name})),
    action: SnackBarAction(label: tr('xfer.title'), onPressed: () => showTransfers(context, s)),
  ));
}

/// To a phone: say what will be converted so its photo app can show it, and
/// let the user choose (convert — recommended — or send everything as it is).
Future<bool> queueForPhone(BuildContext context, AppServices s, PeerPc phone, List<SendFile> files, String title) async {
  final platform = s.settings.trusted[phone.id]?.platform ?? '';
  final fmt = s.sender.formatter;
  if (fmt == null) {
    s.sender.add(phone, files, title, toPhone: true, platform: platform);
    return true;
  }
  final plan = PhonePlan([for (final f in files) await fmt.decide(f, platform)]);
  if (!context.mounted) return false;
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
    if (choice == null) return false;
    convert = choice == 'convert';
  }
  s.sender.add(phone, files, title, toPhone: true, convert: convert, platform: platform);
  if (context.mounted) _queuedNote(context, s, phone);
  return true;
}

/// File name of [path] (either slash).
String baseNameOf(String path) => path.split(RegExp(r'[\\/]')).last;
