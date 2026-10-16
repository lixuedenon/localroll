// apps/desktop/lib/ui/devices_page.dart
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:localroll_core/localroll_core.dart';

import '../app_services.dart';
import '../l10n/l10n.dart';
import '../services/peers.dart';
import '../services/settings.dart';
import '../services/win_dialogs.dart';
import 'add_device_dialog.dart';
import 'app_nav.dart';
import 'breathing.dart';
import 'device_badge.dart';
import 'format.dart';
import 'receive_page.dart' show NetworkCheck;
import 'send_page.dart';
import 'text_window.dart';
import 'theme.dart';

/// One paired device as the Devices page shows it (a phone or a PC; a PC
/// can be both trusted here and a send target there).
class _Dev {
  _Dev({required this.id, required this.name, required this.isPc, required this.online, this.trusted, this.peer, this.phone});

  final String id;
  final String name;
  final bool isPc;
  final bool online;
  final TrustedDevice? trusted;
  final PeerPc? peer;

  /// A phone with LocalRoll open: where to send to it.
  final PeerPc? phone;

  bool get family => trusted?.familyMember ?? true;

  /// Where "Send" goes (null: can't send now).
  PeerPc? get target => isPc ? peer : phone;
}

/// Devices: everything paired (family / guests), sending to them, what each
/// may do, adding new ones — receiving, sending and the family group in one
/// place. Click a device for its details on the right.
class DevicesPage extends StatefulWidget {
  const DevicesPage({super.key, required this.services});

  final AppServices services;

  @override
  State<DevicesPage> createState() => _DevicesPageState();
}

class _DevicesPageState extends State<DevicesPage> {
  bool _looking = false;
  bool _showHidden = false;
  String? _selected;

  // "Online" turns off by itself after a while: look again now and then.
  late final Timer _tick = Timer.periodic(const Duration(seconds: 15), (_) {
    if (mounted) setState(() {});
  });

  @override
  void initState() {
    super.initState();
    _tick;
    AppNav.instance.addListener(_onNav);
    AppNav.instance.deviceFocus.addListener(_onFocus);
    _onNav();
    _onFocus();
  }

  @override
  void dispose() {
    _tick.cancel();
    AppNav.instance.removeListener(_onNav);
    AppNav.instance.deviceFocus.removeListener(_onFocus);
    if (_looking) widget.services.peers.release();
    super.dispose();
  }

  void _onFocus() {
    final id = AppNav.instance.deviceFocus.value;
    if (id == null) return;
    AppNav.instance.deviceFocus.value = null;
    setState(() => _selected = id);
  }

  static bool _autoScanned = false;

  /// Look for PCs nearby only while this page is shown.
  void _onNav() {
    final show = AppNav.instance.tab == AppNav.devices;
    if (show == _looking) return;
    _looking = show;
    final p = widget.services.peers;
    if (show) {
      p.acquire();
      if (!_autoScanned && widget.services.settings.peers.isEmpty && p.found.isEmpty) {
        _autoScanned = true;
        unawaited(p.scan());
      }
    } else {
      p.release();
    }
  }

  List<_Dev> _devices() {
    final s = widget.services;
    final st = s.settings;
    final out = <_Dev>[];
    for (final id in {...st.trusted.keys, ...st.peers.keys}) {
      final t = st.trusted[id];
      final p = st.peers[id];
      final isPc = p != null || isDesktopPlatform(t?.platform ?? '');
      out.add(_Dev(
        id: id,
        name: s.deviceName(id),
        isPc: isPc,
        online: s.isOnline(id),
        trusted: t,
        peer: p,
        phone: isPc ? null : s.phoneTarget(id),
      ));
    }
    out.sort((a, b) {
      final on = (b.online ? 1 : 0) - (a.online ? 1 : 0);
      return on != 0 ? on : a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.services;
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: Listenable.merge([s.peers, s.sender, s.settings, s.server]),
      builder: (context, _) {
        final all = _devices();
        final family = all.where((d) => d.family).toList();
        final guests = all.where((d) => !d.family).toList();
        final unpaired = s.peers.found.where((f) => !s.settings.peers.containsKey(f.id)).toList();
        final hidden = unpaired.where((f) => s.settings.hiddenPeers.contains(f.id)).toList();
        final nearby = [
          for (final f in unpaired)
            if (_showHidden || !s.settings.hiddenPeers.contains(f.id)) f,
        ];
        final sel = all.where((d) => d.id == _selected).firstOrNull;
        return Scaffold(
          body: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(28, 22, 28, 28),
                children: [
                  Row(children: [
                    Text(tr('dev.title'), style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700)),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Text(tr('dev.hint'),
                          overflow: TextOverflow.ellipsis, style: const TextStyle(color: LrColors.muted, fontSize: 13)),
                    ),
                    if (s.peers.scanning)
                      const Padding(
                        padding: EdgeInsets.symmetric(horizontal: 12),
                        child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
                      )
                    else
                      OutlinedButton.icon(
                        onPressed: s.peers.scan,
                        icon: const Icon(Icons.radar_rounded, size: 18),
                        label: Text(tr('send.search')),
                      ),
                    const SizedBox(width: 10),
                    FilledButton.icon(
                      onPressed: () => showAddDevice(context, s),
                      icon: const Icon(Icons.add_rounded, size: 18),
                      label: Text(tr('dev.add')),
                    ),
                  ]),
                  const SizedBox(height: 16),
                  NetworkCheck(services: s),
                  _group(tr('dev.family'), tr('dev.family_hint'), family),
                  _group(tr('dev.guests'), tr('dev.guests_hint'), guests),
                  const SizedBox(height: 18),
                  Text(tr('send.nearby'), style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 8),
                  if (nearby.isEmpty)
                    Text(s.peers.scanning ? tr('send.searching') : tr('send.none_nearby'),
                        style: const TextStyle(color: LrColors.muted, fontSize: 13)),
                  for (final f in nearby) _nearbyRow(f),
                  if (hidden.isNotEmpty)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton(
                        onPressed: () => setState(() => _showHidden = !_showHidden),
                        child: Text(_showHidden ? tr('send.hide_forgotten') : tr('send.show_forgotten', {'count': hidden.length})),
                      ),
                    ),
                ],
              ),
            ),
            if (sel != null) _drawer(context, sel),
          ]),
        );
      },
    );
  }

  Widget _group(String title, String hint, List<_Dev> list) => Padding(
        padding: const EdgeInsets.only(top: 14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(crossAxisAlignment: CrossAxisAlignment.baseline, textBaseline: TextBaseline.alphabetic, children: [
            Text(title, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
            const SizedBox(width: 10),
            Expanded(child: Text(hint, style: const TextStyle(color: LrColors.muted, fontSize: 12))),
          ]),
          const SizedBox(height: 8),
          if (list.isEmpty) Text(tr('dev.none'), style: const TextStyle(color: LrColors.muted, fontSize: 13)),
          for (final d in list) _row(d),
        ]),
      );

  Widget _avatar(_Dev d, double size) {
    final p = d.peer;
    if (p != null) return DeviceBadge(icon: p.icon, color: p.color, size: size);
    return CircleAvatar(
      radius: size / 2,
      backgroundColor: LrColors.raised,
      child: Icon(
        d.isPc ? Icons.computer_rounded : (d.trusted?.platform == 'ios' ? Icons.phone_iphone_rounded : Icons.phone_android_rounded),
        size: size * 0.5,
        color: d.online ? onlineGlow : LrColors.muted,
      ),
    );
  }

  String _status(_Dev d) {
    final kind = tr(d.isPc ? 'dev.kind_pc' : 'dev.kind_phone');
    if (!d.isPc && d.online && d.phone == null) return '$kind · ${tr('dev.not_ready')}';
    return '$kind · ${tr(d.online ? 'dev.online' : 'dev.offline')}';
  }

  Widget _chip(String text, {Color? color}) => Container(
        margin: const EdgeInsets.only(left: 8),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: LrColors.raised,
          borderRadius: BorderRadius.circular(12),
          border: color == null ? null : Border.all(color: color),
        ),
        child: Text(text, style: TextStyle(fontSize: 12, color: color)),
      );

  Widget _row(_Dev d) {
    final selected = d.id == _selected;
    final job = widget.services.sender.jobs.where((j) => j.peer.id == d.id && !j.over).firstOrNull;
    final t = d.trusted;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: selected ? LrColors.raised : LrColors.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(
            color: selected ? LrColors.safelight : (d.online ? onlineGlow.withValues(alpha: 0.5) : LrColors.line),
            width: selected ? 1.5 : 1,
          ),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () => setState(() => _selected = selected ? null : d.id),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            child: Row(children: [
              _avatar(d, 40),
              const SizedBox(width: 14),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(d.name, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 2),
                  if (job == null)
                    Text(_status(d), style: TextStyle(fontSize: 12, color: d.online ? onlineGlow : LrColors.muted))
                  else
                    Text(jobStatus(job).$1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: jobStatus(job).$2)),
                ]),
              ),
              if (t != null) _chip(tr(d.family ? 'dev.role_family' : 'dev.role_guest')),
              if (t != null && !d.isPc) _chip(tr('family.access_${t.libraryAccess.name}')),
              const SizedBox(width: 12),
              _sendButton(d),
              const SizedBox(width: 4),
              const Icon(Icons.chevron_right_rounded, color: LrColors.muted),
            ]),
          ),
        ),
      ),
    );
  }

  /// "Send ▾": files / folder (/ text to a PC). Greyed while it can't receive.
  Widget _sendButton(_Dev d) {
    final target = d.target;
    if (target == null) {
      return OutlinedButton(onPressed: null, child: Text(tr('dev.send')));
    }
    return PopupMenuButton<String>(
      tooltip: tr('dev.send'),
      onSelected: (v) => _send(d, v),
      itemBuilder: (_) => [
        PopupMenuItem(value: 'files', child: Text(tr('send.files'))),
        PopupMenuItem(value: 'folder', child: Text(tr('send.folder'))),
        if (d.isPc) PopupMenuItem(value: 'text', child: Text(tr('send.text'))),
      ],
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(borderRadius: BorderRadius.circular(8), border: Border.all(color: LrColors.safelight)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Text(tr('dev.send'), style: const TextStyle(color: LrColors.safelight, fontWeight: FontWeight.w600)),
          const Icon(Icons.arrow_drop_down_rounded, color: LrColors.safelight, size: 20),
        ]),
      ),
    );
  }

  Future<void> _send(_Dev d, String what) async {
    final target = d.target;
    if (target == null) return;
    switch (what) {
      case 'files':
        await _sendFiles(target, toPhone: !d.isPc);
      case 'folder':
        await _sendFolder(target, toPhone: !d.isPc);
      case 'text':
        await showTextComposer(context, widget.services, target);
    }
  }

  Widget _nearbyRow(FoundPc f) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Material(
          color: LrColors.surface,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: const BorderSide(color: LrColors.line)),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            child: Row(children: [
              DeviceBadge(icon: f.info?.icon, color: f.info?.color, size: 40),
              const SizedBox(width: 14),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(f.name, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                  Text(f.hosts.first, style: const TextStyle(color: LrColors.muted, fontSize: 12)),
                ]),
              ),
              FilledButton.tonal(onPressed: () => _pair(f), child: Text(tr('send.pair'))),
            ]),
          ),
        ),
      );

  // ------------------------------------------------------------- details

  Widget _label(String t) => Padding(
        padding: const EdgeInsets.only(top: 18, bottom: 6),
        child: Text(t, style: const TextStyle(color: LrColors.muted, fontSize: 13)),
      );

  Widget _drawer(BuildContext context, _Dev d) {
    final s = widget.services;
    final t = d.trusted;
    final p = d.peer;
    final member = t == null ? null : s.settings.family.memberOf(d.id);
    final there = s.peers.familyAt[d.id];
    final lastJob = s.sender.jobs.where((j) => j.peer.id == d.id).lastOrNull;
    return Container(
      width: 360,
      decoration: const BoxDecoration(
        color: LrColors.surface,
        border: Border(left: BorderSide(color: LrColors.line)),
      ),
      child: ListView(padding: const EdgeInsets.all(22), children: [
        Row(children: [
          Breathing(online: d.online, radius: 999, child: Padding(padding: const EdgeInsets.all(3), child: _avatar(d, 52))),
          const SizedBox(width: 14),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(d.name, style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w700)),
              const SizedBox(height: 2),
              Text(
                [
                  _status(d),
                  if (t != null) tr('settings.paired_on', {'date': formatDate(DateTime.fromMillisecondsSinceEpoch(t.pairedMs))}),
                ].join(' · '),
                style: TextStyle(fontSize: 12.5, color: d.online ? onlineGlow : LrColors.muted),
              ),
            ]),
          ),
          IconButton(
            tooltip: tr('common.close'),
            onPressed: () => setState(() => _selected = null),
            icon: const Icon(Icons.close_rounded),
          ),
        ]),
        if (t != null) ...[
          _label(tr('dev.identity')),
          SegmentedButton<bool>(
            showSelectedIcon: false,
            segments: [
              ButtonSegment(value: true, icon: const Icon(Icons.groups_rounded, size: 18), label: Text(tr('dev.role_family'))),
              ButtonSegment(value: false, icon: const Icon(Icons.person_outline_rounded, size: 18), label: Text(tr('dev.role_guest'))),
            ],
            selected: {d.family},
            onSelectionChanged: (v) => s.server.setFamily(d.id, v.first),
          ),
          const SizedBox(height: 6),
          Text(tr(d.family ? 'dev.family_hint' : 'dev.guests_hint'), style: const TextStyle(color: LrColors.muted, fontSize: 12)),
        ],
        if (t != null && !d.isPc) ...[
          _label(tr('dev.access')),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(borderRadius: BorderRadius.circular(8), border: Border.all(color: LrColors.line)),
            child: DropdownButton<LibraryAccess>(
              value: t.libraryAccess,
              isExpanded: true,
              underline: const SizedBox.shrink(),
              items: [
                for (final a in LibraryAccess.values) DropdownMenuItem(value: a, child: Text(tr('family.access_${a.name}'))),
              ],
              onChanged: (a) {
                if (a != null) unawaited(s.server.setAccess(d.id, a));
              },
            ),
          ),
          _label(tr('dev.member')),
          OutlinedButton.icon(
            style: OutlinedButton.styleFrom(alignment: Alignment.centerLeft, minimumSize: const Size.fromHeight(44)),
            onPressed: () async {
              final name = await _askMember(member ?? d.name, s.settings.family.members);
              if (name != null) await s.settings.update((x) => x.trusted[d.id]?.memberName = name);
            },
            icon: const Icon(Icons.edit_rounded, size: 18),
            label: Text(member ?? '—'),
          ),
        ],
        if (p != null) ...[
          _label(tr('dev.me_there')),
          Text(
            there == null ? '—' : tr(there ? 'send.me_family_there' : 'send.me_guest_there'),
            style: TextStyle(fontSize: 13, color: there == false ? LrColors.safelight : null),
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: () => _membership(p, family: there != true),
              child: Text(tr(there == true ? 'send.leave_family_there' : 'send.ask_family_there')),
            ),
          ),
        ],
        _label(tr('dev.send')),
        Row(children: [
          Expanded(
            child: FilledButton(
              onPressed: d.target == null ? null : () => _send(d, 'files'),
              child: Text(tr('send.files')),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: OutlinedButton(
              onPressed: d.target == null ? null : () => _send(d, 'folder'),
              child: Text(tr('send.folder')),
            ),
          ),
          if (d.isPc) ...[
            const SizedBox(width: 8),
            Expanded(
              child: OutlinedButton(
                onPressed: d.target == null ? null : () => _send(d, 'text'),
                child: Text(tr('send.text')),
              ),
            ),
          ],
        ]),
        if (d.target == null && !d.isPc)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(tr('send.phone_closed_hint'), style: const TextStyle(color: LrColors.muted, fontSize: 12)),
          ),
        if (lastJob != null) ...[
          const SizedBox(height: 12),
          JobTile(job: lastJob, onCancel: () => s.sender.cancel(lastJob), onResend: () => s.sender.resend(lastJob)),
        ],
        const SizedBox(height: 28),
        if (p != null) ...[
          OutlinedButton(onPressed: () => _unpair(p, forget: false), child: Text(tr('send.disconnect'))),
          const SizedBox(height: 8),
          OutlinedButton(
            style: OutlinedButton.styleFrom(foregroundColor: LrColors.danger, side: const BorderSide(color: LrColors.danger)),
            onPressed: () => _unpair(p, forget: true),
            child: Text(tr('send.forget')),
          ),
        ] else if (t != null)
          OutlinedButton(
            style: OutlinedButton.styleFrom(foregroundColor: LrColors.danger, side: const BorderSide(color: LrColors.danger)),
            onPressed: () => _unpairPhone(t),
            child: Text(tr('settings.unpair')),
          ),
      ]),
    );
  }

  // ------------------------------------------------------------- actions

  Future<void> _unpairPhone(TrustedDevice t) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('dev.unpair_title', {'name': t.name})),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('common.cancel'))),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(tr('settings.unpair'))),
        ],
      ),
    );
    if (ok != true) return;
    await widget.services.settings.update((x) => x.trusted.remove(t.id));
    if (!mounted) return;
    setState(() => _selected = null);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('settings.unpaired', {'name': t.name}))));
  }

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
    final picked = await WinDialogs.pickFiles(title: tr('send.files'));
    if (picked.isEmpty) return;
    final files = [
      // Photos and videos go into the other PC's library; other files into
      // its "Received files" folder.
      for (final path in picked)
        ?SendFile.plain(File(path), baseNameOf(path), toLibrary: MediaKind.fromName(baseNameOf(path)) != MediaKind.other),
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
    final dir = await WinDialogs.pickFolder(title: tr('send.folder'));
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
  /// other under "Nearby". Forget: also stop listing it.
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
    if (ok != true) return;
    await widget.services.peers.forget(p, hide: forget);
    if (mounted) setState(() => _selected = null);
  }

  Future<void> _pair(FoundPc f) async {
    if (widget.services.settings.hiddenPeers.contains(f.id)) {
      await widget.services.settings.update((x) => x.hiddenPeers.remove(f.id));
    }
    if (!mounted) return;
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

  /// Asks for a family member's name; existing members are one tap away.
  Future<String?> _askMember(String current, List<String> members) async {
    final ctrl = TextEditingController(text: current);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('family.member_name')),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 380),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(controller: ctrl, autofocus: true, onSubmitted: (v) => Navigator.pop(ctx, v)),
              const SizedBox(height: 12),
              Wrap(spacing: 8, runSpacing: 8, children: [
                for (final m in members) ActionChip(label: Text(m), onPressed: () => Navigator.pop(ctx, m)),
              ]),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(tr('common.cancel'))),
          FilledButton(onPressed: () => Navigator.pop(ctx, ctrl.text), child: Text(tr('common.ok'))),
        ],
      ),
    );
    ctrl.dispose();
    final t = name?.trim();
    return t == null || t.isEmpty ? null : t;
  }
}
