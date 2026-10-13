// apps/desktop/lib/ui/notices.dart
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:localroll_core/localroll_core.dart';
import 'package:window_manager/window_manager.dart';

import '../app_services.dart';
import '../l10n/l10n.dart';
import '../server/transfer_server.dart';
import '../services/network.dart';
import '../services/peers.dart';
import '../services/receive_hub.dart';
import 'app_nav.dart';
import 'device_badge.dart';
import 'format.dart';
import 'send_page.dart' show peerErrorText;
import 'theme.dart';

/// The dialogs that tell the user something finished or needs an answer:
///  * "X wants to send files" (auto-receive off) — Accept / Decline;
///  * "Received everything from X" once incoming files stop arriving;
///  * "Sent everything to X" when a PC → PC job ends.
class Notices {
  Notices(this.s) {
    // Who is online: checked every few seconds and on any news.
    _presence = Timer.periodic(const Duration(seconds: 8), (_) => _checkPresence());
    s.server.addListener(_checkPresence);
    s.peers.addListener(_checkPresence);
    _online = s.onlineDevices;
    s.server.incomingAsks.addListener(_onAsks);
    s.hub.addListener(_onHub);
    s.sender.addListener(_onSender);
    for (final j in s.sender.jobs) {
      if (j.over) _announced.add(j.id);
    }
  }

  final AppServices s;

  void dispose() {
    _presence?.cancel();
    s.server.removeListener(_checkPresence);
    s.peers.removeListener(_checkPresence);
    s.server.incomingAsks.removeListener(_onAsks);
    s.hub.removeListener(_onHub);
    s.sender.removeListener(_onSender);
    _quiet?.cancel();
  }

  BuildContext? get _ctx => AppNav.instance.navigatorKey.currentContext;

  // ------------------------------------------------------- online / offline

  Timer? _presence;
  Set<String> _online = {};

  /// "X is online" / "X went offline" for every paired phone and PC.
  void _checkPresence() {
    final now = s.onlineDevices;
    final came = now.difference(_online);
    final left = _online.difference(now);
    _online = now;
    final ctx = _ctx;
    if (ctx == null || (came.isEmpty && left.isEmpty)) return;
    final m = ScaffoldMessenger.maybeOf(ctx);
    for (final id in came) {
      m?.showSnackBar(_presenceBar(id, online: true));
    }
    for (final id in left) {
      m?.showSnackBar(_presenceBar(id, online: false));
    }
  }

  SnackBar _presenceBar(String id, {required bool online}) {
    final pc = s.settings.peers.containsKey(id) || isDesktopPlatform(s.settings.trusted[id]?.platform ?? '');
    return SnackBar(
      duration: const Duration(seconds: 4),
      behavior: SnackBarBehavior.floating,
      width: 420,
      content: Row(children: [
        Icon(pc ? Icons.computer_rounded : Icons.phone_iphone_rounded,
            color: online ? LrColors.verified : LrColors.muted, size: 20),
        const SizedBox(width: 10),
        Expanded(
          child: Text(tr(online ? 'presence.online' : 'presence.offline', {'name': s.deviceName(id)})),
        ),
      ]),
    );
  }

  Future<void> _toFront() async {
    try {
      if (await windowManager.isMinimized()) await windowManager.restore();
      await windowManager.show();
      await windowManager.focus();
    } catch (_) {}
  }

  // ------------------------------------------------------------ accept?

  final Set<IncomingAsk> _shownAsks = {};

  void _onAsks() {
    for (final a in s.server.incomingAsks.value) {
      if (_shownAsks.add(a)) unawaited(_ask(a));
    }
  }

  Future<void> _ask(IncomingAsk a) async {
    await _toFront();
    final ctx = _ctx;
    if (ctx == null || !ctx.mounted) return;
    // Closes by itself when the request times out on the server.
    unawaited(a.answer.future.then((_) {
      final c = _ctx;
      if (c != null && c.mounted && _openAsk == a) Navigator.of(c).pop();
    }));
    _openAsk = a;
    final yes = await showDialog<bool>(
      context: ctx,
      barrierDismissible: false,
      builder: (c) => AlertDialog(
        title: Row(children: [
          DeviceBadge(icon: isDesktopPlatform(a.device.platform) ? 'desktop' : 'phone', size: 40),
          const SizedBox(width: 12),
          Expanded(child: Text(tr('incoming.title', {'name': a.device.name}))),
        ]),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (a.bytes > 0) Text(tr('incoming.first', {'count': a.count, 'size': formatBytes(a.bytes)})),
          const SizedBox(height: 8),
          Text(tr('incoming.window'), style: Theme.of(c).textTheme.bodySmall?.copyWith(color: LrColors.muted)),
        ]),
        actions: [
          OutlinedButton(onPressed: () => Navigator.pop(c, false), child: Text(tr('incoming.decline'))),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: Text(tr('incoming.accept'))),
        ],
      ),
    );
    if (_openAsk == a) _openAsk = null;
    s.server.answerIncoming(a, accept: yes == true);
  }

  IncomingAsk? _openAsk;

  // ----------------------------------------------------- received all

  /// Start of the current burst of incoming files.
  DateTime? _burstStart;
  Timer? _quiet;

  bool get _receiving =>
      s.hub.transfers.any((t) => t.state == TransferState.receiving || t.state == TransferState.verifying);

  void _onHub() {
    if (_receiving) {
      _burstStart ??= DateTime.now().subtract(const Duration(seconds: 1));
      _quiet?.cancel();
      return;
    }
    if (_burstStart == null) return;
    // Phones send file by file: wait for a quiet moment before saying "done".
    _quiet?.cancel();
    _quiet = Timer(const Duration(seconds: 6), () {
      if (_receiving) return;
      final since = _burstStart!;
      _burstStart = null;
      final batch = s.hub.transfers.where((t) => t.updated.isAfter(since)).toList();
      if (batch.isEmpty) return;
      unawaited(_received(batch));
    });
  }

  Future<void> _received(List<TransferProgress> batch) async {
    final byDevice = <String, List<TransferProgress>>{};
    for (final t in batch) {
      (byDevice[t.deviceName] ??= []).add(t);
    }
    final lines = <Widget>[];
    var failed = 0;
    var media = 0;
    for (final e in byDevice.entries) {
      final ok = e.value.where((t) => t.state == TransferState.saved).toList();
      failed += e.value.where((t) => t.state == TransferState.failed).length;
      final photos = ok.where((t) => MediaKind.fromName(t.fileName) == MediaKind.image).length;
      final videos = ok.where((t) => MediaKind.fromName(t.fileName) == MediaKind.video).length;
      final other = ok.length - photos - videos;
      media += photos + videos;
      final size = ok.fold<int>(0, (a, t) => a + t.total);
      final parts = [
        if (photos > 0) tr('done.photos', {'count': photos}),
        if (videos > 0) tr('done.videos', {'count': videos}),
        if (other > 0) tr('done.files', {'count': other}),
      ];
      if (parts.isEmpty) continue;
      lines.add(Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Text(tr('done.from', {'name': e.key, 'what': parts.join(tr('done.sep')), 'size': formatBytes(size)})),
      ));
    }
    if (lines.isEmpty && failed == 0) return;
    // A document or other file: offer to show it in its folder.
    final file = batch.lastWhere(
      (t) => t.state == TransferState.saved && t.savedPath != null && MediaKind.fromName(t.fileName) == MediaKind.other,
      orElse: () => batch.first,
    );
    final reveal = file.state == TransferState.saved && file.savedPath != null && MediaKind.fromName(file.fileName) == MediaKind.other
        ? file.savedPath
        : null;
    final ctx = _ctx;
    if (ctx == null || !ctx.mounted) return;
    await showDialog<void>(
      context: ctx,
      builder: (c) => AlertDialog(
        icon: Icon(failed == 0 ? Icons.check_circle_rounded : Icons.error_outline_rounded,
            color: failed == 0 ? LrColors.verified : LrColors.danger, size: 48),
        title: Text(failed == 0 ? tr('done.received_title') : tr('done.received_partly')),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          ...lines,
          if (failed > 0) Text(tr('done.failed', {'count': failed}), style: const TextStyle(color: LrColors.danger)),
        ]),
        actions: [
          if (reveal != null)
            TextButton(
              onPressed: () {
                Navigator.pop(c);
                revealInExplorer(reveal);
              },
              child: Text(tr('common.show_in_folder')),
            ),
          if (media > 0)
            TextButton(
              onPressed: () {
                Navigator.pop(c);
                AppNav.instance.selectTab(AppNav.library);
              },
              child: Text(tr('done.view')),
            ),
          FilledButton(onPressed: () => Navigator.pop(c), child: Text(tr('done.ok'))),
        ],
      ),
    );
  }

  // ---------------------------------------------------------- sent all

  final Set<String> _announced = {};

  void _onSender() {
    for (final j in s.sender.jobs) {
      if (j.over && _announced.add(j.id) && j.state != SendJobState.cancelled) unawaited(_sent(j));
    }
  }

  Future<void> _sent(SendJob j) async {
    final ctx = _ctx;
    if (ctx == null || !ctx.mounted) return;
    final ok = j.state == SendJobState.done;
    await showDialog<void>(
      context: ctx,
      builder: (c) => AlertDialog(
        icon: Icon(ok ? Icons.check_circle_rounded : Icons.error_outline_rounded,
            color: ok ? LrColors.verified : LrColors.danger, size: 48),
        title: Text(ok ? tr('done.sent_title', {'name': j.peer.name}) : tr('done.sent_failed', {'name': j.peer.name})),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(j.title, style: const TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          Text(tr('done.sent_body', {'sent': j.sentFiles, 'size': formatBytes(j.totalBytes)})),
          if (j.skippedFiles > 0) Text(tr('send.skipped', {'count': j.skippedFiles})),
          if (j.failedFiles > 0 || !ok)
            Text(
              [if (j.failedFiles > 0) tr('done.failed', {'count': j.failedFiles}), if (j.error != null) peerErrorText(j.error)]
                  .join(' · '),
              style: const TextStyle(color: LrColors.danger),
            ),
        ]),
        actions: [FilledButton(onPressed: () => Navigator.pop(c), child: Text(tr('done.ok')))],
      ),
    );
  }
}
