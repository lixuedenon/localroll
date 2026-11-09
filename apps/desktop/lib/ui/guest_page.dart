// apps/desktop/lib/ui/guest_page.dart
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../app_services.dart';
import '../l10n/l10n.dart';
import '../services/network.dart' show revealInExplorer;
import '../services/guest_server.dart';
import '../services/win_dialogs.dart';
import 'app_nav.dart';
import 'format.dart';
import 'library_picker.dart';
import 'theme.dart';

/// Guests without LocalRoll: a QR code / short address + code for their
/// browser; what they send (accepted here first), what is shared with them.
Future<void> showGuestTransfer(BuildContext context, AppServices s) async {
  final g = s.guest;
  g.ask = (offer) => _askGuest(offer);
  if (!await g.start()) {
    if (context.mounted) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(tr('guest.no_port'))));
    }
    return;
  }
  // The firewall may block the page's port: allowed once (asks for admin).
  unawaited(allowGuestPort(g.port));
  if (!context.mounted) return;
  await showDialog<void>(context: context, builder: (_) => _GuestDialog(s: s));
  await g.stop();
}

Future<bool> _askGuest(GuestOffer offer) async {
  final ctx = AppNav.instance.navigatorKey.currentContext;
  if (ctx == null) return false;
  final total = offer.files.fold<int>(0, (n, f) => n + f.size);
  final r = await showDialog<bool>(
    context: ctx,
    builder: (c) => AlertDialog(
      title: Text(tr('guest.ask_title', {'name': offer.guest})),
      content: SizedBox(
        width: 420,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(tr('guest.ask_body', {'count': offer.files.length, 'size': formatBytes(total)})),
          const SizedBox(height: 8),
          for (final f in offer.files.take(6))
            Text('· ${f.name}', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: LrColors.muted, fontSize: 13)),
          if (offer.files.length > 6) Text('…', style: const TextStyle(color: LrColors.muted)),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c, false), child: Text(tr('guest.decline'))),
        FilledButton(onPressed: () => Navigator.pop(c, true), child: Text(tr('guest.accept'))),
      ],
    ),
  );
  return r ?? false;
}

class _GuestDialog extends StatefulWidget {
  const _GuestDialog({required this.s});

  final AppServices s;

  @override
  State<_GuestDialog> createState() => _GuestDialogState();
}

class _GuestDialogState extends State<_GuestDialog> {
  Timer? _tick;
  final TextEditingController _ssid = TextEditingController(), _pass = TextEditingController();
  bool _hotspot = false;

  GuestServer get g => widget.s.guest;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    _ssid.dispose();
    _pass.dispose();
    super.dispose();
  }

  Future<void> _share() async {
    final files = await WinDialogs.pickFiles(title: tr('guest.share'));
    g.share(files);
  }

  Future<void> _shareLibrary() async {
    final paths = await pickFromLibrary(context, widget.s);
    if (paths != null) g.share(paths);
  }

  String _left() {
    final u = g.until;
    if (u == null) return '';
    final d = u.difference(DateTime.now());
    if (d.isNegative) return '0:00';
    return '${d.inMinutes}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';
  }

  /// The Wi-Fi QR code phones join with (WIFI:… as cameras read it).
  String get _wifi {
    String esc(String v) => v.replaceAllMapped(RegExp(r'([\\;,:"])'), (m) => '\\${m[1]}');
    return 'WIFI:T:WPA;S:${esc(_ssid.text)};P:${esc(_pass.text)};;';
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: g,
        builder: (context, _) => AlertDialog(
          icon: const Icon(Icons.qr_code_2_rounded, size: 32),
          title: Text(tr('guest.title')),
          content: SizedBox(
            width: 640,
            child: SingleChildScrollView(
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(tr('guest.intro'), style: const TextStyle(color: LrColors.muted)),
                const SizedBox(height: 14),
                Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12)),
                    child: QrImageView(data: _hotspot && _ssid.text.isNotEmpty ? _wifi : g.link, size: 200, backgroundColor: Colors.white),
                  ),
                  const SizedBox(width: 20),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(tr('guest.or_type'), style: const TextStyle(color: LrColors.muted)),
                      const SizedBox(height: 4),
                      SelectableText(g.shortAddress, style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w700)),
                      const SizedBox(height: 10),
                      Text(tr('guest.code'), style: const TextStyle(color: LrColors.muted)),
                      SelectableText(g.code, style: const TextStyle(fontSize: 36, fontWeight: FontWeight.w800, letterSpacing: 6, color: LrColors.safelight)),
                      const SizedBox(height: 10),
                      Text(tr('guest.left', {'time': _left()}), style: const TextStyle(color: LrColors.muted, fontSize: 13)),
                      TextButton(onPressed: g.extend, child: Text(tr('guest.extend'))),
                      if (g.addresses.length > 1)
                        Text(tr('guest.other_ips', {'ips': g.addresses.skip(1).join('  ')}), style: const TextStyle(color: LrColors.muted, fontSize: 12)),
                    ]),
                  ),
                ]),
                const SizedBox(height: 8),
                // Not on this Wi-Fi: this PC's hotspot, joined by a second QR code.
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: _hotspot,
                  onChanged: (v) => setState(() => _hotspot = v),
                  title: Text(tr('guest.hotspot')),
                  subtitle: Text(tr('guest.hotspot_sub')),
                ),
                if (_hotspot) ...[
                  Row(children: [
                    Expanded(child: TextField(controller: _ssid, onChanged: (_) => setState(() {}), decoration: InputDecoration(labelText: tr('guest.ssid')))),
                    const SizedBox(width: 10),
                    Expanded(child: TextField(controller: _pass, onChanged: (_) => setState(() {}), decoration: InputDecoration(labelText: tr('guest.password')))),
                    const SizedBox(width: 10),
                    OutlinedButton(onPressed: () => unawaited(Process.run('cmd', ['/c', 'start', 'ms-settings:network-mobilehotspot'])), child: Text(tr('guest.open_hotspot'))),
                  ]),
                  const SizedBox(height: 6),
                  Text(tr('guest.hotspot_steps'), style: const TextStyle(color: LrColors.muted, fontSize: 12)),
                ],
                const Divider(height: 28),
                Row(children: [
                  Text(tr('guest.shared'), style: const TextStyle(fontWeight: FontWeight.w600)),
                  const Spacer(),
                  TextButton.icon(onPressed: _shareLibrary, icon: const Icon(Icons.photo_library_outlined, size: 18), label: Text(tr('guest.from_library'))),
                  TextButton.icon(onPressed: _share, icon: const Icon(Icons.folder_open_outlined, size: 18), label: Text(tr('guest.from_folder'))),
                ]),
                if (g.shared.isEmpty) Text(tr('guest.shared_none'), style: const TextStyle(color: LrColors.muted, fontSize: 13)),
                for (final f in g.shared)
                  ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.insert_drive_file_outlined),
                    title: Text(f.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                    subtitle: Text(formatBytes(f.size)),
                    trailing: IconButton(onPressed: () => g.unshare(f), icon: const Icon(Icons.close_rounded)),
                  ),
                const Divider(height: 28),
                Text(tr('guest.received', {'count': g.received.length}), style: const TextStyle(fontWeight: FontWeight.w600)),
                if (g.guests.isNotEmpty) Text(tr('guest.joined', {'names': g.guests.join('、')}), style: const TextStyle(color: LrColors.muted, fontSize: 13)),
                for (final f in g.received.take(8))
                  ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.download_done_rounded, color: LrColors.verified),
                    title: Text(f.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                    subtitle: Text(formatBytes(f.size)),
                    trailing: IconButton(onPressed: () => revealInExplorer(f.path), icon: const Icon(Icons.folder_open_rounded)),
                  ),
              ]),
            ),
          ),
          actions: [FilledButton(onPressed: () => Navigator.pop(context), child: Text(tr('guest.close')))],
        ),
      );
}
