// apps/desktop/lib/ui/devices_page.dart
import 'dart:async';
import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';
import 'package:localroll_core/localroll_core.dart';

import '../app_services.dart';
import '../l10n/l10n.dart';
import '../services/clipboard_send.dart';
import '../services/peers.dart';
import '../services/received_files.dart' show ReceivedFile;
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
import 'guest_page.dart';
import 'library_picker.dart';
import 'net_check.dart';
import 'send_paths.dart';
import 'transfer_records.dart';
import 'theme.dart';

/// One paired device as the Devices page shows it (a phone or a PC; a PC
/// can be both trusted here and a send target there).
class _Dev {
  _Dev({required this.id, required this.name, required this.isPc, required this.online, this.trusted, this.peer, this.phone, this.later});

  final String id;
  final String name;
  final bool isPc;
  final bool online;
  final TrustedDevice? trusted;
  final PeerPc? peer;

  /// A phone with LocalRoll open: where to send to it.
  final PeerPc? phone;

  bool get family => trusted?.familyMember ?? true;

  /// A phone not open now: sends wait for it.
  final PeerPc? later;

  /// Where "Send" goes (a phone not open: it waits until it is).
  PeerPc? get target => isPc ? peer : (phone ?? later);

  /// It takes files right now.
  bool get ready => isPc ? online : phone != null;
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

  /// Ticking several devices to send to them together.
  bool _multi = false;
  final Set<String> _picked = {};

  /// A device files are being dragged over.
  String? _dropOn;

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
        later: isPc ? null : sendTargetFor(s, id),
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
          backgroundColor: _Look.page,
          body: Stack(children: [
            const Positioned.fill(child: IgnorePointer(child: CustomPaint(painter: _Streaks()))),
            Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(28, 22, 28, 28),
                children: [
                  Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
                    Text(tr('dev.title'),
                        style: theme.textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w800, color: Colors.white, letterSpacing: -0.5)),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.only(bottom: 5),
                        child: Text(tr('dev.hint'), overflow: TextOverflow.ellipsis, style: const TextStyle(color: _Look.soft, fontSize: 13.5)),
                      ),
                    ),
                    if (s.peers.scanning)
                      const Padding(
                        padding: EdgeInsets.symmetric(horizontal: 18, vertical: 12),
                        child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
                      )
                    else
                      _glassButton(Icons.radar_rounded, tr('send.search'), s.peers.scan),
                    const SizedBox(width: 10),
                    _glassButton(Icons.health_and_safety_outlined, tr('net.title'), () => unawaited(showNetCheck(context, s))),
                    const SizedBox(width: 10),
                    _glassButton(Icons.qr_code_2_rounded, tr('guest.button'), () => unawaited(showGuestTransfer(context, s))),
                    const SizedBox(width: 12),
                    _addButton(() => showAddDevice(context, s)),
                  ]),
                  const SizedBox(height: 16),
                  NetworkCheck(services: s),
                  TransferRecords(services: s),
                  const SizedBox(height: 12),
                  _receiving(),
                  Row(children: [
                    const Spacer(),
                    TextButton.icon(
                      onPressed: () => setState(() {
                        _multi = !_multi;
                        _picked.clear();
                      }),
                      icon: Icon(_multi ? Icons.check_box_rounded : Icons.check_box_outline_blank_rounded, size: 18, color: _Look.soft),
                      label: Text(tr(_multi ? 'dev.multi_done' : 'dev.multi'), style: const TextStyle(color: _Look.soft)),
                    ),
                  ]),
                  _group(tr('dev.family'), tr('dev.family_hint'), family),
                  _group(tr('dev.guests'), tr('dev.guests_hint'), guests),
                  const SizedBox(height: 18),
                  Text(tr('send.nearby'), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: Colors.white)),
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
                  const SizedBox(height: 22),
                  _note(),
                  if (_multi && _picked.isNotEmpty) const SizedBox(height: 70),
                ],
              ),
            ),
            if (sel != null) _drawer(context, sel),
          ]),
            if (_multi && _picked.isNotEmpty)
              Positioned(left: 28, right: sel != null ? 464 : 28, bottom: 16, child: _multiBar(all)),
          ]),
        );
      },
    );
  }

  Widget _group(String title, String hint, List<_Dev> list) => Padding(
        padding: const EdgeInsets.only(top: 14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(crossAxisAlignment: CrossAxisAlignment.baseline, textBaseline: TextBaseline.alphabetic, children: [
            Text(title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: Colors.white)),
            const SizedBox(width: 10),
            Expanded(child: Text(hint, style: const TextStyle(color: _Look.soft, fontSize: 12.5))),
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
          color: Colors.white.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(999),
          border: color == null ? null : Border.all(color: color),
        ),
        child: Text(text, style: TextStyle(fontSize: 12.5, color: color ?? const Color(0xFFDCE6F2))),
      );

  Widget _row(_Dev d) {
    final selected = d.id == _selected;
    final job = widget.services.sender.jobs.where((j) => j.peer.id == d.id && !j.over).firstOrNull;
    final t = d.trusted;
    final drop = _dropOn == d.id;
    final rep = widget.services.transferLog.backup[d.id];
    return DropTarget(
      enable: d.target != null,
      onDragEntered: (_) => setState(() => _dropOn = d.id),
      onDragExited: (_) => setState(() => _dropOn = null),
      onDragDone: (e) {
        setState(() => _dropOn = null);
        final paths = [for (final f in e.files) f.path];
        if (paths.isNotEmpty) unawaited(sendPathsTo(context, widget.services, [d.id], paths));
      },
      child: Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: drop ? const Color(0x1AFFC94A) : (selected ? _Look.teal.withValues(alpha: 0.08) : _Look.glass),
        shadowColor: _Look.teal,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
          side: BorderSide(color: drop ? const Color(0xFFFFC94A) : (selected ? _Look.teal : _Look.edge), width: selected || drop ? 2 : 1),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: () => setState(() => _selected = selected ? null : d.id),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 13),
            child: Row(children: [
              if (_multi) ...[
                Checkbox(
                  value: _picked.contains(d.id),
                  onChanged: d.target == null ? null : (v) => setState(() => v == true ? _picked.add(d.id) : _picked.remove(d.id)),
                ),
                const SizedBox(width: 6),
              ],
              _avatar(d, 50),
              const SizedBox(width: 16),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(d.name,
                      overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: Colors.white)),
                  const SizedBox(height: 3),
                  if (job == null)
                    Row(children: [
                      Container(
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(shape: BoxShape.circle, color: d.online ? _Look.green : _Look.soft),
                      ),
                      const SizedBox(width: 6),
                      Flexible(
                        child: Text.rich(
                          TextSpan(children: [
                            TextSpan(text: _status(d)),
                            if (!d.isPc && rep != null)
                              TextSpan(
                                text: ' · ${tr(rep.pending == 0 ? 'dev.all_backed_up' : 'dev.left_to_backup', {'count': rep.pending, 'when': formatWhen(rep.when)})}',
                                style: TextStyle(color: rep.pending == 0 ? _Look.green : const Color(0xFFFFC94A)),
                              ),
                          ]),
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 13, color: d.online ? _Look.green : _Look.soft),
                        ),
                      ),
                    ])
                  else
                    Text(jobStatus(job).$1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: jobStatus(job).$2)),
                ]),
              ),
              if (t != null) _chip(tr(d.family ? 'dev.role_family' : 'dev.role_guest')),
              if (t != null && !d.isPc) _chip(tr('family.access_${t.libraryAccess.name}')),
              const SizedBox(width: 12),
              const SizedBox(width: 4),
              if (drop)
                Padding(
                  padding: const EdgeInsets.only(right: 10),
                  child: Text(tr('dev.drop_here'), style: const TextStyle(color: Color(0xFFFFC94A), fontWeight: FontWeight.w700)),
                ),
              _sendButton(d),
              const SizedBox(width: 6),
              const Icon(Icons.chevron_right_rounded, color: _Look.soft),
            ]),
          ),
        ),
      ),
    ),
    );
  }

  /// "This PC is receiving…" — receiving needs nothing to do.
  Widget _receiving() => Container(
        margin: const EdgeInsets.only(bottom: 4),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: _Look.teal.withValues(alpha: 0.07),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: _Look.teal.withValues(alpha: 0.35)),
        ),
        child: Row(children: [
          Container(width: 9, height: 9, decoration: const BoxDecoration(shape: BoxShape.circle, color: _Look.green)),
          const SizedBox(width: 10),
          Expanded(child: Text(tr('dev.receiving_note'), style: const TextStyle(color: Color(0xFFC8D6E5), fontSize: 13.5))),
        ]),
      );

  /// Several devices ticked: send to them together.
  Widget _multiBar(List<_Dev> all) {
    final names = [for (final d in all) if (_picked.contains(d.id)) d.name];
    Future<void> go(bool folder, {bool library = false}) async {
      final List<String> paths;
      if (library) {
        paths = await pickFromLibrary(context, widget.services, files: true) ?? const [];
      } else if (folder) {
        final dir = await WinDialogs.pickFolder(title: tr('send.folder'));
        paths = dir == null ? const [] : [dir];
      } else {
        paths = await WinDialogs.pickFiles(title: tr('send.files'));
      }
      if (paths.isEmpty || !mounted) return;
      final n = await sendPathsTo(context, widget.services, _picked.toList(), paths);
      if (n > 0 && mounted) {
        setState(() {
          _multi = false;
          _picked.clear();
        });
      }
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFF12305A),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0x662B8CFF)),
        boxShadow: const [BoxShadow(color: Color(0x66000000), blurRadius: 18, offset: Offset(0, 6))],
      ),
      child: Row(children: [
        Text(tr('dev.picked', {'count': names.length}), style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800)),
        const SizedBox(width: 10),
        Expanded(child: Text(names.join('、'), overflow: TextOverflow.ellipsis, style: const TextStyle(color: _Look.soft))),
        OutlinedButton(onPressed: () => go(true), child: Text(tr('send.folder'))),
        const SizedBox(width: 8),
        OutlinedButton(onPressed: () => go(false, library: true), child: Text(tr('send.files_library'))),
        const SizedBox(width: 8),
        FilledButton(onPressed: () => go(false), child: Text(tr('send.files_pc'))),
      ]),
    );
  }

  /// "Send ▾": files / folder (/ text to a PC). Greyed while it can't receive.
  Widget _sendButton(_Dev d) {
    final target = d.target;
    if (target == null) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
        decoration: BoxDecoration(borderRadius: BorderRadius.circular(12), color: Colors.white.withValues(alpha: 0.06)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Text(tr('dev.send'), style: const TextStyle(color: Color(0xFF6F8398), fontWeight: FontWeight.w700, fontSize: 15)),
          const Icon(Icons.arrow_drop_down_rounded, color: Color(0xFF6F8398), size: 20),
        ]),
      );
    }
    return PopupMenuButton<String>(
      tooltip: d.ready ? tr('dev.send') : tr('dev.send_later_tip'),
      onSelected: (v) => _send(d, v),
      itemBuilder: (_) => [
        PopupMenuItem(value: 'files', child: Text(tr('send.files_pc'))),
        PopupMenuItem(value: 'library', child: Text(tr('send.files_library'))),
        PopupMenuItem(value: 'folder', child: Text(tr('send.folder'))),
        if (d.isPc && d.ready) PopupMenuItem(value: 'text', child: Text(tr('send.text'))),
        PopupMenuItem(value: 'clipboard', child: Text(tr('send.clipboard'))),
      ],
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          color: d.ready ? null : const Color(0x402B8CFF),
          gradient: d.ready
              ? const LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Color(0xFF2B8CFF), Color(0xFF1468E0)])
              : null,
          boxShadow: d.ready ? [BoxShadow(color: const Color(0xFF2B8CFF).withValues(alpha: 0.3), blurRadius: 12, offset: const Offset(0, 4))] : null,
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Text(tr(d.ready ? 'dev.send' : 'dev.send_later'), style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 15)),
          const Icon(Icons.arrow_drop_down_rounded, color: Colors.white, size: 20),
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
      case 'pick':
        // "Files": from this PC's folders, or from the library.
        final from = await showDialog<String>(
          context: context,
          builder: (ctx) => SimpleDialog(
            title: Text(tr('send.files_from')),
            children: [
              SimpleDialogOption(
                onPressed: () => Navigator.pop(ctx, 'files'),
                child: ListTile(leading: const Icon(Icons.folder_open_rounded), title: Text(tr('send.files_pc'))),
              ),
              SimpleDialogOption(
                onPressed: () => Navigator.pop(ctx, 'library'),
                child: ListTile(leading: const Icon(Icons.photo_library_rounded), title: Text(tr('send.files_library'))),
              ),
            ],
          ),
        );
        if (from != null && mounted) await _send(d, from);
      case 'library':
        final paths = await pickFromLibrary(context, widget.services, files: true);
        if (paths != null && paths.isNotEmpty && mounted) await _sendPaths(target, paths, toPhone: !d.isPc);
      case 'folder':
        await _sendFolder(target, toPhone: !d.isPc);
      case 'text':
        await showTextComposer(context, widget.services, target);
      case 'clipboard':
        await _sendClipboard(target, toPhone: !d.isPc);
    }
  }

  /// What is on this PC's clipboard (copied files, a picture, text): shown
  /// first, then sent.
  Future<void> _sendClipboard(PeerPc p, {bool toPhone = false}) async {
    final m = ScaffoldMessenger.of(context);
    final c = await ClipboardContent.read(Directory.systemTemp.path);
    if (!mounted) return;
    if (c.isEmpty) {
      m.showSnackBar(SnackBar(content: Text(tr('send.clipboard_empty'))));
      return;
    }
    final text = c.text ?? '';
    final what = c.files.isNotEmpty
        ? tr('send.clipboard_files', {'count': c.files.length, 'names': c.files.take(3).map(baseNameOf).join('、')})
        : c.image != null
            ? tr('send.clipboard_image')
            : tr('send.clipboard_text', {'text': text.length > 80 ? '${text.substring(0, 80)}…' : text});
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('send.clipboard_title', {'name': p.name})),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(what),
            if (c.image != null)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: Image.file(File(c.image!), height: 160, fit: BoxFit.contain),
                ),
              ),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('common.cancel'))),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(tr('dev.send'))),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    if (c.files.isNotEmpty) {
      await _sendPaths(p, c.files, toPhone: toPhone);
    } else if (c.image != null) {
      await _sendPaths(p, [c.image!], toPhone: toPhone);
    } else if (!toPhone) {
      final err = await widget.services.sender.sendText(p, text);
      if (mounted) m.showSnackBar(SnackBar(content: Text(err ?? tr('send.clipboard_sent', {'name': p.name}))));
    } else {
      // Phones take files: the text as a .txt file.
      final f = File('${Directory.systemTemp.path}${Platform.pathSeparator}clipboard_${DateTime.now().millisecondsSinceEpoch}.txt');
      await f.writeAsString(text);
      if (mounted) await _sendPaths(p, [f.path], toPhone: true);
    }
  }

  Widget _nearbyRow(FoundPc f) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Material(
          color: _Look.glass,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18), side: const BorderSide(color: _Look.edge)),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 11),
            child: Row(children: [
              DeviceBadge(icon: f.info?.icon, color: f.info?.color, size: 44),
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

  Widget _head(String t) => Padding(
        padding: const EdgeInsets.only(top: 20, bottom: 6),
        child: Text(t, style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w800)),
      );

  Widget _kv(String k, String v, {Color? dot}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(children: [
          if (dot != null) ...[
            Container(width: 10, height: 10, decoration: BoxDecoration(shape: BoxShape.circle, color: dot)),
            const SizedBox(width: 8),
          ],
          SizedBox(width: 110, child: Text(k, style: const TextStyle(color: _Look.soft, fontSize: 14))),
          Expanded(
            child: Text(v, maxLines: 1, softWrap: false, overflow: TextOverflow.fade, textAlign: TextAlign.right,
                style: const TextStyle(color: Color(0xFFDCE6F2), fontSize: 14)),
          ),
        ]),
      );

  static String _dateTime(DateTime t) =>
      '${formatDate(t)} ${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  Widget _glassButton(IconData icon, String label, VoidCallback onTap) => Material(
        color: Colors.white.withValues(alpha: 0.06),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14), side: BorderSide(color: Colors.white.withValues(alpha: 0.14))),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(icon, size: 18, color: Colors.white),
              const SizedBox(width: 8),
              Text(label, style: const TextStyle(color: Colors.white, fontSize: 14)),
            ]),
          ),
        ),
      );

  Widget _addButton(VoidCallback onTap) => Material(
        color: Colors.transparent,
        child: Ink(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            gradient: const LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Color(0xFFFFC94A), Color(0xFFF7A91A)]),
            boxShadow: [BoxShadow(color: const Color(0xFFF7A91A).withValues(alpha: 0.35), blurRadius: 18, offset: const Offset(0, 5))],
          ),
          child: InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 13),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                const Icon(Icons.add_rounded, size: 20, color: Color(0xFF2A1A00)),
                const SizedBox(width: 6),
                Text(tr('dev.add'), style: const TextStyle(color: Color(0xFF2A1A00), fontWeight: FontWeight.w800, fontSize: 15)),
              ]),
            ),
          ),
        ),
      );

  /// What sending here means (the reference's "how it works" card).
  Widget _note() => Container(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
        decoration: BoxDecoration(
          color: _Look.glass,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: _Look.edge),
        ),
        child: Row(children: [
          const Icon(Icons.verified_user_rounded, size: 34, color: _Look.teal),
          const SizedBox(width: 16),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(tr('dev.note_title'), style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 15)),
              const SizedBox(height: 3),
              Text(tr('dev.note'), style: const TextStyle(color: _Look.soft, fontSize: 13)),
            ]),
          ),
          const SizedBox(width: 16),
          const Icon(Icons.laptop_rounded, size: 40, color: Color(0xFF8CC8FF)),
          const Icon(Icons.sync_alt_rounded, size: 26, color: _Look.teal),
          const Icon(Icons.smartphone_rounded, size: 40, color: Color(0xFF8CC8FF)),
        ]),
      );

  Widget _label(String t) => Padding(
        padding: const EdgeInsets.only(top: 18, bottom: 6),
        child: Text(t, style: const TextStyle(color: _Look.soft, fontSize: 13)),
      );

  Widget _drawer(BuildContext context, _Dev d) {
    final s = widget.services;
    final t = d.trusted;
    final p = d.peer;
    final member = t == null ? null : s.settings.family.memberOf(d.id);
    final there = s.peers.familyAt[d.id];
    final lastJob = s.sender.jobs.where((j) => j.peer.id == d.id).lastOrNull;
    final mine = s.library.items.where((i) => i.deviceId == d.id);
    final photos = mine.where((i) => i.kind == MediaKind.image).length;
    final videos = mine.where((i) => i.kind == MediaKind.video).length;
    final seen = s.server.lastSeen[d.id];
    return Container(
      width: 420,
      margin: const EdgeInsets.fromLTRB(0, 16, 16, 16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24),
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [const Color(0xFF2F8CC8).withValues(alpha: 0.2), Colors.white.withValues(alpha: 0.04)],
        ),
        border: Border.all(color: const Color(0x4078C8FF)),
      ),
      child: ListView(padding: const EdgeInsets.fromLTRB(22, 12, 22, 22), children: [
        Align(
          alignment: Alignment.centerRight,
          child: IconButton(
            tooltip: tr('common.close'),
            onPressed: () => setState(() => _selected = null),
            icon: const Icon(Icons.close_rounded, color: _Look.soft),
          ),
        ),
        Center(child: Breathing(online: d.online, radius: 999, child: Padding(padding: const EdgeInsets.all(4), child: _avatar(d, 84)))),
        const SizedBox(height: 12),
        Text(d.name, textAlign: TextAlign.center, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: Colors.white)),
        const SizedBox(height: 8),
        Center(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(999),
              color: d.online ? const Color(0xFF1D9A52) : Colors.white.withValues(alpha: 0.1),
            ),
            child: Text(tr(d.online ? 'dev.online' : 'dev.offline'),
                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 13)),
          ),
        ),
        _head(tr('dev.info')),
        _kv(tr('dev.type'), tr(d.isPc ? 'dev.kind_pc' : 'dev.kind_phone')),
        _kv(tr('dev.ip'), d.target?.hosts.firstOrNull ?? '—'),
        if (t != null) _kv(tr('dev.paired'), _dateTime(DateTime.fromMillisecondsSinceEpoch(t.pairedMs))),
        if (!d.online && seen != null) _kv(tr('dev.last_seen'), formatWhen(seen)),
        if (t != null) ...[
          _head(tr('dev.got_from')),
          _kv(tr('dev.photos'), '$photos', dot: const Color(0xFF8B5CF6)),
          _kv(tr('dev.videos'), '$videos', dot: const Color(0xFFEF4444)),
          FutureBuilder<List<ReceivedFile>>(
            future: s.server.files.list(),
            builder: (context, snap) => _kv(tr('dev.files'),
                snap.data == null ? '…' : '${snap.data!.where((f) => f.owner?.deviceId == d.id).length}',
                dot: const Color(0xFFF59E0B)),
          ),
          if (photos + videos > 0)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: FilledButton.icon(
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(46),
                  backgroundColor: const Color(0xFF1F6FD8),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                ),
                onPressed: () => AppNav.instance.openLibraryMember(s.settings.family.memberOf(d.id) ?? d.name),
                icon: const Icon(Icons.photo_library_rounded, size: 18),
                label: Text(tr('dev.see_library')),
              ),
            ),
        ],
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
          Text(tr(d.family ? 'dev.family_explain' : 'dev.guest_explain'), style: const TextStyle(color: LrColors.muted, fontSize: 12)),
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
          const SizedBox(height: 6),
          Text(tr('dev.access_${t.libraryAccess.name}_explain'), style: const TextStyle(color: LrColors.muted, fontSize: 12)),
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
              onPressed: d.target == null ? null : () => _send(d, 'pick'),
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
          const SizedBox(width: 8),
          Expanded(
            child: OutlinedButton(
              onPressed: d.target == null ? null : () => _send(d, 'clipboard'),
              child: Text(tr('send.clipboard')),
            ),
          ),
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
    await _sendPaths(p, picked, toPhone: toPhone);
  }

  /// Files (and whole folders) to [p].
  Future<void> _sendPaths(PeerPc p, List<String> picked, {bool toPhone = false}) async {
    final files = [
      // Photos and videos go into the other PC's library; other files into
      // its "Received files" folder.
      for (final path in picked)
        if (FileSystemEntity.isDirectorySync(path))
          ...await filesInFolder(path)
        else
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

/// The look of this page (dark blue glass, as the reference design).
abstract final class _Look {
  static const Color page = Color(0xFF081424);
  static const Color glass = Color(0x0BFFFFFF);
  static const Color edge = Color(0x17FFFFFF);
  static const Color soft = Color(0xFF8EA4BA);
  static const Color teal = Color(0xFF2FD3C2);
  static const Color green = Color(0xFF3EE08A);
}

/// Soft curved bands of light across the top right, drawn (no picture):
/// sharp at any window size.
class _Streaks extends CustomPainter {
  const _Streaks();

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    canvas.drawRect(
      Offset.zero & size,
      Paint()
        ..shader = RadialGradient(
          center: const Alignment(0.55, -1.1),
          radius: 1.1,
          colors: [const Color(0xFF0F4C6E).withValues(alpha: 0.9), const Color(0x000F4C6E)],
        ).createShader(Offset.zero & size),
    );
    void band(double x0, double y0, double x1, double y1, double cx, double cy, double width, Color c, double blur) {
      final path = Path()
        ..moveTo(w * x0, h * y0)
        ..quadraticBezierTo(w * cx, h * cy, w * x1, h * y1);
      canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = width
          ..strokeCap = StrokeCap.round
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, blur)
          ..shader = LinearGradient(colors: [c.withValues(alpha: 0), c, c.withValues(alpha: 0)])
              .createShader(Rect.fromPoints(Offset(w * x0, h * y0), Offset(w * x1, h * y1))),
      );
    }

    band(0.30, -0.05, 1.05, 0.35, 0.70, 0.02, 60, const Color(0x2A3FA9F5), 30);
    band(0.42, -0.08, 1.05, 0.22, 0.78, -0.02, 18, const Color(0x3A5CC8FF), 8);
    band(0.55, -0.05, 1.05, 0.12, 0.85, -0.03, 6, const Color(0x5590E0FF), 3);
    band(0.20, 0.02, 1.05, 0.55, 0.62, 0.12, 120, const Color(0x1A2FD3C2), 50);
  }

  @override
  bool shouldRepaint(_Streaks old) => false;
}
