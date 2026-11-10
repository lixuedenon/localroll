// apps/desktop/lib/ui/tools/qr_tool.dart
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'package:localroll_core/localroll_core.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:zxing2/qrcode.dart';

import '../../app_services.dart';
import '../../l10n/l10n.dart';
import '../../services/file_tools.dart';
import '../../services/win_dialogs.dart';
import '../light_dialog.dart';
import '../light_look.dart';

/// QR codes: make one (a link, text, a Wi-Fi network) and save / copy it;
/// read one from a picture.
Future<void> showQrTool(BuildContext context, AppServices s) => showDialog<void>(context: context, builder: (_) => _QrTool(s: s));

class _QrTool extends StatefulWidget {
  const _QrTool({required this.s});

  final AppServices s;

  @override
  State<_QrTool> createState() => _QrToolState();
}

class _QrToolState extends State<_QrTool> {
  bool _read = false;
  bool _wifi = false;
  final TextEditingController _text = TextEditingController(), _ssid = TextEditingController(), _pass = TextEditingController();
  String? _found;
  bool _busy = false;

  @override
  void dispose() {
    _text.dispose();
    _ssid.dispose();
    _pass.dispose();
    super.dispose();
  }

  String get _data {
    if (!_wifi) return _text.text;
    String esc(String v) => v.replaceAllMapped(RegExp(r'([\\;,:"])'), (m) => '\\${m[1]}');
    return 'WIFI:T:WPA;S:${esc(_ssid.text)};P:${esc(_pass.text)};;';
  }

  Future<Uint8List?> _png() async {
    final p = QrPainter(data: _data, version: QrVersions.auto, gapless: true, eyeStyle: const QrEyeStyle(color: Colors.black), dataModuleStyle: const QrDataModuleStyle(color: Colors.black));
    final pic = await p.toImageData(1024, format: ui.ImageByteFormat.png);
    return pic?.buffer.asUint8List();
  }

  Future<void> _save() async {
    final png = await _png();
    if (png == null) return;
    final out = await WinDialogs.saveFile(suggestedName: 'QR.png', extensions: const ['png']);
    if (out == null) return;
    // White around it, so phones read it on any background.
    final im = img.decodePng(png);
    if (im == null) return;
    final framed = img.Image(width: im.width + 96, height: im.height + 96);
    img.fill(framed, color: img.ColorRgb8(255, 255, 255));
    img.compositeImage(framed, im, dstX: 48, dstY: 48);
    await File(out.toLowerCase().endsWith('.png') ? out : '$out.png').writeAsBytes(img.encodePng(framed));
  }

  Future<void> _pick() async {
    final f = await WinDialogs.pickFiles(title: tr('qr.pick'), multiple: false, extensions: const ['png', 'jpg', 'jpeg', 'bmp', 'webp', 'heic', 'gif']);
    if (f.isEmpty) return;
    setState(() {
      _busy = true;
      _found = null;
    });
    String? text;
    try {
      var bytes = await File(f.first).readAsBytes();
      if (const {'heic', 'heif', 'webp'}.contains(extensionOf(f.first))) {
        final j = await uprightJpeg(widget.s, f.first, max: 2400);
        if (j != null) bytes = await File(j.$1).readAsBytes();
      }
      text = await compute(_decode, bytes);
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _busy = false;
      _found = text ?? '';
    });
  }

  @override
  Widget build(BuildContext context) => LightDialog(
        icon: Icons.qr_code_2_rounded,
        title: tr('tool.qr'),
        subtitle: tr('qr.sub'),
        width: 620,
        actions: [
          if (!_read) ...[
            OutlinedButton(
              onPressed: _data.isEmpty
                  ? null
                  : () {
                      unawaited(Clipboard.setData(ClipboardData(text: _data)));
                    },
              child: Text(tr('qr.copy_text')),
            ),
            FilledButton.icon(onPressed: _data.isEmpty ? null : _save, icon: const Icon(Icons.save_alt_rounded, size: 18), label: Text(tr('qr.save'))),
          ],
          TextButton(onPressed: () => Navigator.pop(context), child: Text(tr('common.done'))),
        ],
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          SegmentedButton<bool>(
            segments: [
              ButtonSegment(value: false, label: Text(tr('qr.make')), icon: const Icon(Icons.qr_code_rounded)),
              ButtonSegment(value: true, label: Text(tr('qr.read')), icon: const Icon(Icons.qr_code_scanner_rounded)),
            ],
            selected: {_read},
            onSelectionChanged: (v) => setState(() => _read = v.first),
          ),
          const SizedBox(height: 14),
          if (!_read) ...[
            Row(children: [
              ChoiceChip(selected: !_wifi, onSelected: (_) => setState(() => _wifi = false), label: Text(tr('qr.text'))),
              const SizedBox(width: 8),
              ChoiceChip(selected: _wifi, onSelected: (_) => setState(() => _wifi = true), label: Text(tr('qr.wifi'))),
            ]),
            const SizedBox(height: 10),
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(
                child: _wifi
                    ? Column(children: [
                        TextField(controller: _ssid, onChanged: (_) => setState(() {}), decoration: InputDecoration(labelText: tr('guest.ssid'))),
                        const SizedBox(height: 8),
                        TextField(controller: _pass, onChanged: (_) => setState(() {}), decoration: InputDecoration(labelText: tr('guest.password'))),
                      ])
                    : TextField(
                        controller: _text,
                        minLines: 4,
                        maxLines: 6,
                        onChanged: (_) => setState(() {}),
                        decoration: InputDecoration(hintText: tr('qr.hint'), border: const OutlineInputBorder(), filled: true, fillColor: Colors.white),
                      ),
              ),
              const SizedBox(width: 14),
              Container(
                width: 200,
                height: 200,
                color: Colors.white,
                padding: const EdgeInsets.all(8),
                child: _data.isEmpty ? const Center(child: Icon(Icons.qr_code_2_rounded, size: 80, color: Color(0xFFDDE3EC))) : QrImageView(data: _data, backgroundColor: Colors.white),
              ),
            ]),
          ] else ...[
            Center(
              child: FilledButton.tonalIcon(onPressed: _busy ? null : _pick, icon: const Icon(Icons.image_search_rounded), label: Text(tr('qr.pick'))),
            ),
            const SizedBox(height: 12),
            if (_busy) const Center(child: CircularProgressIndicator()),
            if (_found != null)
              _found!.isEmpty
                  ? Text(tr('qr.none'), textAlign: TextAlign.center, style: const TextStyle(color: LightLook.red))
                  : LightRow(
                      icon: Icons.check_rounded,
                      iconBg: const Color(0xFFE3F7EC),
                      iconColor: LightLook.green,
                      title: _found!,
                      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                        if (RegExp(r'^https?://').hasMatch(_found!))
                          IconButton(
                            tooltip: tr('xfer.open_link'),
                            onPressed: () => unawaited(Process.run('rundll32', ['url.dll,FileProtocolHandler', _found!])),
                            icon: const Icon(Icons.open_in_new_rounded),
                          ),
                        IconButton(
                          tooltip: tr('xfer.copy'),
                          onPressed: () => unawaited(Clipboard.setData(ClipboardData(text: _found!))),
                          icon: const Icon(Icons.copy_rounded),
                        ),
                      ]),
                    ),
          ],
        ]),
      );
}

/// The text of the QR code in a picture, or null.
String? _decode(Uint8List bytes) {
  final im = img.decodeImage(bytes);
  if (im == null) return null;
  // Big photos: smaller first (faster, and reads as well).
  final small = im.width > 1600 ? img.copyResize(im, width: 1600) : im;
  final px = small.convert(numChannels: 4).getBytes(order: img.ChannelOrder.abgr).buffer.asInt32List();
  final source = RGBLuminanceSource(small.width, small.height, px);
  try {
    return QRCodeReader().decode(BinaryBitmap(GlobalHistogramBinarizer(source))).text;
  } catch (_) {
    return null;
  }
}
