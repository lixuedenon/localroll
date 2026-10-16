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

/// Library → another PC: choose which one, then queue the items.
Future<void> sendToPc(BuildContext context, AppServices s, List<SendFile> files, String title) async {
  final peers = s.settings.peers.values.toList();
  final phones = [for (final t in s.phones) ?s.phoneTarget(t.id)];
  if (peers.isEmpty && phones.isEmpty) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(tr('send.no_paired')),
      action: SnackBarAction(label: tr('nav.devices'), onPressed: () => AppNav.instance.selectTab(AppNav.devices)),
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
    action: SnackBarAction(label: tr('xfer.title'), onPressed: () => showTransfers(context, s)),
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
      action: SnackBarAction(label: tr('xfer.title'), onPressed: () => showTransfers(context, s)),
    ));
  }
}

/// File name of [path] (either slash).
String baseNameOf(String path) => path.split(RegExp(r'[\\/]')).last;
