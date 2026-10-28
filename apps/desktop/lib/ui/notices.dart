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
import 'presence_toasts.dart';
import 'reasons.dart';
import 'send_page.dart' show peerErrorText;
import 'theme.dart';

/// The dialogs that tell the user something finished or needs an answer:
///  * "X wants to send files" (auto-receive off) — Accept / Decline;
///  * "Received everything from X" once incoming files stop arriving;
///  * "Sent everything to X" when a PC → PC job ends.
class Notices {
  Notices(this.s) {
    // Who is online: one note per change.
    _presence = s.presenceEvents.listen(_onPresence);
    s.server.incomingAsks.addListener(_onAsks);
    s.server.membershipAsks.addListener(_onMembership);
    s.hub.addListener(_onHub);
    s.sender.addListener(_onSender);
    for (final j in s.sender.jobs) {
      if (j.over) _announced.add(j.id);
    }
  }

  final AppServices s;

  void dispose() {
    _presence?.cancel();
    s.server.incomingAsks.removeListener(_onAsks);
    s.server.membershipAsks.removeListener(_onMembership);
    s.hub.removeListener(_onHub);
    s.sender.removeListener(_onSender);
    _quiet?.cancel();
    _doneTimer?.cancel();
    _doneNote?.remove();
  }

  BuildContext? get _ctx => AppNav.instance.navigatorKey.currentContext;

  // ------------------------------------------------------- online / offline

  StreamSubscription<PresenceEvent>? _presence;

  /// "X is online" / "X went offline" for every paired phone and PC; a
  /// newer note about the same device replaces the older one.
  void _onPresence(PresenceEvent e) {
    final overlay = AppNav.instance.navigatorKey.currentState?.overlay;
    if (overlay == null) return;
    final pc = s.settings.peers.containsKey(e.id) || isDesktopPlatform(s.settings.trusted[e.id]?.platform ?? '');
    PresenceToasts.show(
      overlay,
      key: e.id,
      text: tr(e.online ? 'presence.online' : 'presence.offline', {'name': s.deviceName(e.id)}),
      icon: pc ? Icons.computer_rounded : Icons.phone_iphone_rounded,
      online: e.online,
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
    var quiet = false;
    AppNav.instance.needAttention(true);
    final AskAnswer? answer;
    try {
      answer = await showDialog<AskAnswer>(
      context: ctx,
      barrierDismissible: false,
      builder: (c) => StatefulBuilder(
        builder: (c, setLocal) => AlertDialog(
          title: Row(children: [
            DeviceBadge(icon: isDesktopPlatform(a.device.platform) ? 'desktop' : 'phone', size: 40),
            const SizedBox(width: 12),
            Expanded(child: Text(tr('incoming.title', {'name': a.device.name}))),
          ]),
          content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (a.bytes > 0) Text(tr('incoming.first', {'count': a.count, 'size': formatBytes(a.bytes)})),
            const SizedBox(height: 8),
            Text(tr('incoming.guest_hint'), style: Theme.of(c).textTheme.bodySmall?.copyWith(color: LrColors.muted)),
            const SizedBox(height: 4),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              controlAffinity: ListTileControlAffinity.leading,
              value: quiet,
              onChanged: (v) => setLocal(() => quiet = v ?? false),
              title: Text(tr('incoming.quiet')),
            ),
          ]),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c, const AskAnswer(accept: false)),
              child: Text(tr('incoming.decline')),
            ),
            OutlinedButton(
              onPressed: () async {
                final reason = await askDeclineReason(c);
                if (reason != null && c.mounted) Navigator.pop(c, AskAnswer(accept: false, reason: reason));
              },
              child: Text(tr('incoming.decline_reason')),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(c, AskAnswer(accept: true, quiet: quiet)),
              child: Text(tr('incoming.accept')),
            ),
          ],
        ),
      ),
    );
    } finally {
      AppNav.instance.needAttention(false);
    }
    if (_openAsk == a) _openAsk = null;
    s.server.answerIncoming(a, answer ?? const AskAnswer(accept: false));
  }

  // ------------------------------------------------------ join the family?

  final Set<MembershipAsk> _shownMember = {};

  void _onMembership() {
    for (final a in s.server.membershipAsks.value) {
      if (_shownMember.add(a)) unawaited(_askMember(a));
    }
  }

  Future<void> _askMember(MembershipAsk a) async {
    await _toFront();
    final ctx = _ctx;
    if (ctx == null || !ctx.mounted) return;
    var open = true;
    unawaited(a.answer.future.then((_) {
      final c = _ctx;
      if (open && c != null && c.mounted) Navigator.of(c).pop();
    }));
    final yes = await showDialog<bool>(
      context: ctx,
      barrierDismissible: false,
      builder: (c) => AlertDialog(
        title: Text(tr('family.join_title', {'name': a.device.name})),
        content: Text(tr('family.join_body')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: Text(tr('pair.deny'))),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: Text(tr('family.join_allow'))),
        ],
      ),
    );
    open = false;
    s.server.answerMembership(a, allow: yes == true);
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
    // Offers that were all "already here" start a burst too (nothing was
    // received, but the sender should not look like it went nowhere).
    if (_burstStart == null) {
      final recent = s.hub.transfers.where((t) => DateTime.now().difference(t.updated) < const Duration(seconds: 10));
      if (recent.isEmpty) return;
      _burstStart = recent.map((t) => t.updated).reduce((a, b) => a.isBefore(b) ? a : b).subtract(const Duration(seconds: 1));
    }
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

  /// Every sender in [batch] is in the family group (backups): no dialog to
  /// click away, a note that goes by itself.
  bool _allFamily(Iterable<String> names) => names.every((n) =>
      s.settings.trusted.values.any((t) => t.name == n && t.familyMember));

  OverlayEntry? _doneNote;
  Timer? _doneTimer;

  Future<void> _received(List<TransferProgress> batch) async {
    final byDevice = <String, List<TransferProgress>>{};
    for (final t in batch) {
      (byDevice[t.deviceName] ??= []).add(t);
    }
    final lines = <String>[];
    var failed = 0;
    var media = 0;
    var had = 0;
    for (final e in byDevice.entries) {
      final ok = e.value.where((t) => t.state == TransferState.saved).toList();
      failed += e.value.where((t) => t.state == TransferState.failed).length;
      had += e.value.where((t) => t.state == TransferState.alreadyHad).length;
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
      lines.add(tr('done.from', {'name': e.key, 'what': parts.join(tr('done.sep')), 'size': formatBytes(size)}));
    }
    if (had > 0) lines.add(tr('done.already_had', {'count': had}));
    if (lines.isEmpty && failed == 0) return;
    // A document or other file: offer to show it in its folder.
    final file = batch.lastWhere(
      (t) => t.state == TransferState.saved && t.savedPath != null && MediaKind.fromName(t.fileName) == MediaKind.other,
      orElse: () => batch.first,
    );
    final reveal = file.state == TransferState.saved && file.savedPath != null && MediaKind.fromName(file.fileName) == MediaKind.other
        ? file.savedPath
        : null;
    final title = failed == 0 ? tr('done.received_title') : tr('done.received_partly');

    // Family group (backups): a note in the corner that goes by itself.
    if (failed == 0 && _allFamily(byDevice.keys)) {
      final overlay = AppNav.instance.navigatorKey.currentState?.overlay;
      if (overlay == null) return;
      _doneTimer?.cancel();
      _doneNote?.remove();
      void close() {
        _doneTimer?.cancel();
        _doneNote?.remove();
        _doneNote = null;
      }

      _doneNote = OverlayEntry(
        builder: (c) => Positioned(
          right: 20,
          bottom: 24,
          width: 400,
          child: Material(
            color: LrColors.raised,
            elevation: 8,
            borderRadius: BorderRadius.circular(14),
            child: Container(
              padding: const EdgeInsets.fromLTRB(16, 12, 6, 8),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: LrColors.verified.withValues(alpha: 0.7)),
              ),
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  const Icon(Icons.check_circle_rounded, color: LrColors.verified, size: 22),
                  const SizedBox(width: 10),
                  Expanded(child: Text(title, style: const TextStyle(fontWeight: FontWeight.w700))),
                  IconButton(visualDensity: VisualDensity.compact, onPressed: close, icon: const Icon(Icons.close_rounded, size: 18)),
                ]),
                for (final l in lines)
                  Padding(padding: const EdgeInsets.only(left: 32, bottom: 4), child: Text(l, style: const TextStyle(fontSize: 13))),
                Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                  if (reveal != null)
                    TextButton(
                      onPressed: () {
                        close();
                        revealInExplorer(reveal);
                      },
                      child: Text(tr('common.show_in_folder')),
                    ),
                  if (media > 0)
                    TextButton(
                      onPressed: () {
                        close();
                        AppNav.instance.selectTab(AppNav.library);
                      },
                      child: Text(tr('done.view')),
                    ),
                ]),
              ]),
            ),
          ),
        ),
      );
      overlay.insert(_doneNote!);
      _doneTimer = Timer(const Duration(seconds: 10), close);
      return;
    }

    final ctx = _ctx;
    if (ctx == null || !ctx.mounted) return;
    await showDialog<void>(
      context: ctx,
      builder: (c) => AlertDialog(
        icon: Icon(failed == 0 ? Icons.check_circle_rounded : Icons.error_outline_rounded,
            color: failed == 0 ? LrColors.verified : LrColors.danger, size: 48),
        title: Text(title),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          for (final l in lines) Padding(padding: const EdgeInsets.only(bottom: 6), child: Text(l)),
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
        title: Text(!ok
            ? tr('done.sent_failed', {'name': j.peer.name})
            : (j.sentFiles == 0 && j.skippedFiles > 0
                ? tr('done.sent_nothing_new', {'name': j.peer.name})
                : tr('done.sent_title', {'name': j.peer.name}))),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(j.title, style: const TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          Text(tr('done.sent_body', {'sent': j.sentFiles, 'size': formatBytes(j.totalBytes)})),
          if (j.skippedFiles > 0) Text(tr('send.skipped', {'count': j.skippedFiles})),
          if (j.failedFiles > 0 || !ok)
            Text(
              [if (j.failedFiles > 0) tr('done.failed', {'count': j.failedFiles}), if (j.error != null) peerErrorText(j.error), if (j.reason?.isNotEmpty ?? false) tr('send.their_reason', {'reason': j.reason!})]
                  .join(' · '),
              style: const TextStyle(color: LrColors.danger),
            ),
        ]),
        actions: [FilledButton(onPressed: () => Navigator.pop(c), child: Text(tr('done.ok')))],
      ),
    );
  }
}
