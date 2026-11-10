// apps/mobile/lib/ui/tools_page.dart
import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:localroll_core/localroll_core.dart';
import 'package:localroll_ink/localroll_ink.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:path_provider/path_provider.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:share_plus/share_plus.dart';
import 'package:video_player/video_player.dart';

import '../l10n/l10n.dart';
import '../services/clip_maker.dart';
import '../services/desktop_client.dart';
import '../services/discovery.dart';
import '../services/file_sender.dart';
import '../services/media_saver.dart';
import '../services/mobile_settings.dart';
import '../services/my_library.dart';
import '../services/pdf_pages.dart';
import '../services/scan_pdf.dart';
import 'cleanup_page.dart' show formatSize;
import 'home_look.dart';
import 'open_file.dart';
import 'send_files_page.dart';

// The everyday tools on the phone (Home): photos, videos, PDFs, QR codes;
// Office → PDF goes through the PC. Originals are never changed.

/// A photo (HEIC too) as an upright JPEG, by the phone's own decoder.
Future<Uint8List?> phoneJpeg(String path, {int maxSide = 0, int quality = 92}) async {
  try {
    return await const MethodChannel('localroll/files')
        .invokeMethod<Uint8List>('toJpeg', {'path': path, 'maxSide': maxSide, 'quality': quality});
  } catch (e) {
    DiagLog.log('tools', 'jpeg failed: $e');
    return null;
  }
}

enum PhoneTool {
  heicJpg(Icons.image_rounded, Color(0xFF2F6BFF)),
  compressVideo(Icons.movie_filter_rounded, Color(0xFFE8740C)),
  cutVideo(Icons.content_cut_rounded, Color(0xFFC98A00)),
  photosPdf(Icons.picture_as_pdf_rounded, Color(0xFF16A36A)),
  pdfTools(Icons.draw_rounded, Color(0xFF7B4DEB)),
  editImage(Icons.auto_fix_high_rounded, Color(0xFFD64545)),
  compressPhoto(Icons.photo_size_select_small_rounded, Color(0xFF1F5FD6)),
  qr(Icons.qr_code_2_rounded, Color(0xFF3C4A63)),
  officePdf(Icons.slideshow_rounded, Color(0xFFD9541E));

  const PhoneTool(this.icon, this.color);

  final IconData icon;
  final Color color;

  String get title => tr('ptool.$name');
  String get sub => tr('ptool.${name}_sub');
}

/// Home's "Tools" tiles.
class PhoneToolsGrid extends StatelessWidget {
  const PhoneToolsGrid({super.key, required this.settings, required this.discovery});

  final MobileSettings settings;
  final DesktopDiscovery discovery;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 18),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Icon(Icons.handyman_rounded, color: HomeColors.blue, size: 22),
            const SizedBox(width: 8),
            Text(tr('ptool.section'), style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 17, color: HomeColors.ink)),
          ]),
          const SizedBox(height: 10),
          GridView.count(
            crossAxisCount: 3,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            mainAxisSpacing: 10,
            crossAxisSpacing: 10,
            childAspectRatio: 1.05,
            children: [
              for (final t in PhoneTool.values)
                Material(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(16),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(16),
                    onTap: () => unawaited(openPhoneTool(context, settings, discovery, t)),
                    child: Padding(
                      padding: const EdgeInsets.all(10),
                      child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                        Container(
                          width: 40,
                          height: 40,
                          decoration: BoxDecoration(color: t.color.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(12)),
                          child: Icon(t.icon, color: t.color, size: 22),
                        ),
                        const SizedBox(height: 6),
                        Text(t.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            textAlign: TextAlign.center,
                            style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12.5, color: HomeColors.ink)),
                        Text(t.sub,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            textAlign: TextAlign.center,
                            style: const TextStyle(fontSize: 10.5, color: Color(0xFF6B7A99))),
                      ]),
                    ),
                  ),
                ),
            ],
          ),
        ]),
      );
}

Future<void> openPhoneTool(BuildContext context, MobileSettings settings, DesktopDiscovery discovery, PhoneTool t) async {
  DiagLog.log('tools', t.name);
  try {
    switch (t) {
      case PhoneTool.heicJpg:
      case PhoneTool.compressPhoto:
        final picked = await ImagePicker().pickMultiImage(requestFullMetadata: false);
        if (picked.isEmpty || !context.mounted) return;
        final small = t == PhoneTool.compressPhoto;
        final outs = await _busy(context, () async {
          final dir = await _outDir();
          final made = <File>[];
          for (final p in picked) {
            final j = await phoneJpeg(p.path, maxSide: small ? 2048 : 0, quality: small ? 80 : 92);
            if (j == null) continue;
            final f = File('${dir.path}/${_stem(p.name)}${small ? '-small' : ''}.jpg');
            await f.writeAsBytes(j);
            await _toAlbum(f);
            made.add(f);
          }
          return made;
        });
        if (context.mounted && outs != null) await showPhoneResult(context, settings, discovery, outs, note: tr('ptool.in_album'));
      case PhoneTool.photosPdf:
        final picked = await ImagePicker().pickMultiImage(requestFullMetadata: false);
        if (picked.isEmpty || !context.mounted) return;
        final out = await _busy(context, () async {
          final dir = await _outDir();
          final pages = <String>[];
          for (final p in picked) {
            final j = await phoneJpeg(p.path, maxSide: 3508);
            if (j == null) continue;
            final f = File('${dir.path}/p${pages.length}.jpg');
            await f.writeAsBytes(j);
            pages.add(f.path);
          }
          if (pages.isEmpty) return null;
          final pdf = await ScanPdf.build(pages, File('${dir.path}/${tr('ptool.photos_pdf_name')} ${_stamp()}.pdf'));
          return _toMyFiles(settings, pdf);
        });
        if (context.mounted && out != null) await showPhoneResult(context, settings, discovery, [out], note: tr('ptool.in_myfiles'));
      case PhoneTool.editImage:
        final x = await ImagePicker().pickImage(source: ImageSource.gallery, requestFullMetadata: false);
        if (x == null || !context.mounted) return;
        final bytes = await phoneJpeg(x.path, maxSide: 4096);
        if (bytes == null || !context.mounted) return;
        await Navigator.of(context).push(MaterialPageRoute(builder: (_) => _PhotoEditPage(settings: settings, discovery: discovery, bytes: bytes, name: x.name)));
      case PhoneTool.compressVideo:
      case PhoneTool.cutVideo:
        final v = await ImagePicker().pickVideo(source: ImageSource.gallery);
        if (v == null || !context.mounted) return;
        await Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => _VideoToolPage(settings: settings, discovery: discovery, path: v.path, name: v.name, compress: t == PhoneTool.compressVideo),
        ));
      case PhoneTool.pdfTools:
        final r = await FilePicker.platform.pickFiles(type: FileType.custom, allowedExtensions: const ['pdf'], allowMultiple: true);
        final paths = [for (final f in r?.files ?? const <PlatformFile>[]) if (f.path != null) f.path!];
        if (paths.isEmpty || !context.mounted) return;
        await Navigator.of(context).push(MaterialPageRoute(builder: (_) => _PdfToolPage(settings: settings, discovery: discovery, files: paths)));
      case PhoneTool.qr:
        await Navigator.of(context).push(MaterialPageRoute(builder: (_) => const _QrPage()));
      case PhoneTool.officePdf:
        await _officePdf(context, settings, discovery);
    }
  } catch (e) {
    DiagLog.error('tools', e);
    if (context.mounted) _toast(context, tr('ptool.failed'));
  }
}

void _toast(BuildContext context, String text) => ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(text)));

String _stem(String name) {
  final dot = name.lastIndexOf('.');
  return dot > 0 ? name.substring(0, dot) : name;
}

String _stamp() {
  final n = DateTime.now();
  String two(int v) => v.toString().padLeft(2, '0');
  return '${n.year}-${two(n.month)}-${two(n.day)} ${two(n.hour)}${two(n.minute)}';
}

Future<Directory> _outDir() async {
  final d = Directory('${(await getTemporaryDirectory()).path}/lr_tools_${DateTime.now().microsecondsSinceEpoch}');
  await d.create(recursive: true);
  return d;
}

Future<void> _toAlbum(File f) async {
  await PhotoManager.editor.saveImageWithPath(f.path, title: f.uri.pathSegments.last, relativePath: Platform.isAndroid ? 'Pictures/Keepnear' : null);
}

/// Into "My files" (Keepnear's folder › Documents › this phone).
Future<File> _toMyFiles(MobileSettings settings, File f) async {
  final me = Sender(settings.deviceId, tr('mylib.this_phone'));
  final dir = await MediaSaver.folderFor(MyKind.document, me);
  final target = await MediaSaver.freeFile(dir, FileSender.nameOfPath(f.path));
  await f.copy(target.path);
  await MyLibrary.instance.addFile(target.path, MyKind.document, fromId: me.id, fromName: me.name);
  return target;
}

/// A moment's work with a turning circle (the screen can't be used meanwhile).
Future<T?> _busy<T>(BuildContext context, Future<T> Function() job) async {
  final nav = Navigator.of(context);
  unawaited(showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => PopScope(
      canPop: false,
      child: AlertDialog(
        content: Row(children: [
          const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 3)),
          const SizedBox(width: 16),
          Flexible(child: Text(tr('ptool.working'))),
        ]),
      ),
    ),
  ));
  try {
    return await job();
  } finally {
    nav.pop();
  }
}

/// Done: where it went; share it, send it to a computer / phone, open it.
Future<void> showPhoneResult(BuildContext context, MobileSettings settings, DesktopDiscovery discovery, List<File> outs, {String? note}) {
  if (outs.isEmpty) {
    _toast(context, tr('ptool.failed'));
    return Future.value();
  }
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (c) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Icon(Icons.check_circle_rounded, color: Color(0xFF12A35F), size: 28),
            const SizedBox(width: 10),
            Expanded(child: Text(tr('ptool.done', {'count': outs.length}), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800))),
          ]),
          if (note != null) Padding(padding: const EdgeInsets.only(top: 4), child: Text(note, style: const TextStyle(color: Color(0xFF6B7A99)))),
          const SizedBox(height: 8),
          for (final o in outs.take(5))
            Text('· ${o.uri.pathSegments.last}  (${formatSize(o.lengthSync())})', maxLines: 1, overflow: TextOverflow.ellipsis),
          const SizedBox(height: 14),
          Row(children: [
            if (outs.length == 1)
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => unawaited(openDocument(c, outs.first.path)),
                  icon: const Icon(Icons.open_in_new_rounded),
                  label: Text(tr('ptool.open')),
                ),
              ),
            if (outs.length == 1) const SizedBox(width: 8),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () async {
                  final box = c.findRenderObject() as RenderBox?;
                  await SharePlus.instance.share(ShareParams(
                    files: [for (final o in outs) XFile(o.path)],
                    sharePositionOrigin: box == null ? null : box.localToGlobal(Offset.zero) & box.size,
                  ));
                },
                icon: const Icon(Icons.ios_share_rounded),
                label: Text(tr('ptool.share')),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: FilledButton.icon(
                onPressed: () async {
                  Navigator.pop(c);
                  final sender = await pickFileTarget(context, settings, discovery, outs);
                  if (sender == null || !context.mounted) return;
                  await Navigator.of(context).push(MaterialPageRoute(builder: (_) => SendFilesPage(sender: sender)));
                },
                icon: const Icon(Icons.send_rounded),
                label: Text(tr('ptool.send')),
              ),
            ),
          ]),
        ]),
      ),
    ),
  );
}

// ------------------------------------------------------------- Office → PDF

Future<void> _officePdf(BuildContext context, MobileSettings settings, DesktopDiscovery discovery) async {
  final d = settings.current;
  if (d == null) {
    _toast(context, tr('ptool.office_no_pc'));
    return;
  }
  final r = await FilePicker.platform.pickFiles(
    type: FileType.custom,
    allowedExtensions: const ['doc', 'docx', 'rtf', 'xls', 'xlsx', 'csv', 'ppt', 'pptx'],
  );
  final path = r?.files.single.path;
  if (path == null || !context.mounted) return;
  final name = r!.files.single.name;
  String? why;
  final out = await _busy(context, () async {
    try {
      final c = await connectToDesktop(settings, d, discovered: discovery.found);
      try {
        final bytes = await c.officeToPdf(File(path), name);
        final dir = await _outDir();
        final f = File('${dir.path}/${_stem(name)}.pdf');
        await f.writeAsBytes(bytes);
        return _toMyFiles(settings, f);
      } finally {
        c.close();
      }
    } on LrHttpException catch (e) {
      why = e.status == 409 ? tr('ptool.office_no_office', {'name': d.name}) : tr('ptool.office_failed');
      return null;
    } catch (e) {
      why = tr('ptool.office_pc_off', {'name': d.name});
      return null;
    }
  });
  if (!context.mounted) return;
  if (out == null) {
    _toast(context, why ?? tr('ptool.failed'));
    return;
  }
  await showPhoneResult(context, settings, discovery, [out], note: tr('ptool.in_myfiles'));
}

// ------------------------------------------------------------- photo edit

class _PhotoEditPage extends StatelessWidget {
  const _PhotoEditPage({required this.settings, required this.discovery, required this.bytes, required this.name});

  final MobileSettings settings;
  final DesktopDiscovery discovery;
  final Uint8List bytes;
  final String name;

  Future<File> _write(Uint8List jpeg) async {
    final dir = await _outDir();
    final f = File('${dir.path}/${_stem(name)}-edited.jpg');
    await f.writeAsBytes(jpeg);
    return f;
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: const Color(0xFF141B26),
        appBar: AppBar(title: Text(PhoneTool.editImage.title)),
        body: SafeArea(
          child: PhotoEditor(
            bytes: bytes,
            texts: (k) => tr('pe.$k'),
            onSave: (jpeg, _) async {
              final f = await _write(jpeg);
              await _toAlbum(f);
              if (context.mounted) await showPhoneResult(context, settings, discovery, [f], note: tr('ptool.in_album'));
            },
          ),
        ),
      );
}

// ------------------------------------------------------------- video

class _VideoToolPage extends StatefulWidget {
  const _VideoToolPage({required this.settings, required this.discovery, required this.path, required this.name, required this.compress});

  final MobileSettings settings;
  final DesktopDiscovery discovery;
  final String path;
  final String name;
  final bool compress;

  @override
  State<_VideoToolPage> createState() => _VideoToolPageState();
}

class _VideoToolPageState extends State<_VideoToolPage> {
  late final VideoPlayerController _v = VideoPlayerController.file(File(widget.path));
  RangeValues _keep = const RangeValues(0, 1);
  late int _side = widget.compress ? 1280 : 0;

  @override
  void initState() {
    super.initState();
    _v.initialize().then((_) {
      if (!mounted) return;
      setState(() => _keep = RangeValues(0, _v.value.duration.inMilliseconds.toDouble().clamp(1, double.infinity)));
    });
    _v.addListener(() {
      if (!mounted) return;
      if (_v.value.isPlaying && _v.value.position.inMilliseconds >= _keep.end) unawaited(_v.pause());
      setState(() {});
    });
  }

  @override
  void dispose() {
    unawaited(_v.dispose());
    super.dispose();
  }

  Future<void> _make() async {
    await _v.pause();
    if (!mounted) return;
    final size = _v.value.size;
    final out = await _busy(context, () async {
      final clip = await ClipMaker.make(
        input: widget.path,
        width: size.width.round(),
        height: size.height.round(),
        fromMs: _keep.start.round(),
        toMs: _keep.end.round(),
        notes: const [],
        maxSide: _side,
      );
      final dir = await _outDir();
      final f = await clip.copy('${dir.path}/${_stem(widget.name)}${_side > 0 ? '-small' : '-cut'}.mp4');
      await ClipMaker.saveToAlbum(f, f.uri.pathSegments.last);
      return f;
    });
    if (mounted && out != null) await showPhoneResult(context, widget.settings, widget.discovery, [out], note: tr('ptool.in_album'));
  }

  static String _clock(num ms) {
    final d = Duration(milliseconds: ms.round());
    return '${d.inMinutes.toString().padLeft(2, '0')}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final ready = _v.value.isInitialized;
    final len = _v.value.duration.inMilliseconds.toDouble();
    return Scaffold(
      backgroundColor: const Color(0xFF141B26),
      appBar: AppBar(title: Text(widget.compress ? PhoneTool.compressVideo.title : PhoneTool.cutVideo.title)),
      body: SafeArea(
        child: Column(children: [
          Expanded(
            child: Center(
              child: ready ? AspectRatio(aspectRatio: _v.value.aspectRatio, child: VideoPlayer(_v)) : const CircularProgressIndicator(),
            ),
          ),
          if (ready && len > 0) ...[
            RangeSlider(
              values: _keep,
              min: 0,
              max: len,
              onChanged: (r) {
                final moved = r.start != _keep.start ? r.start : r.end;
                setState(() => _keep = r);
                unawaited(_v.seekTo(Duration(milliseconds: moved.round())));
              },
            ),
            Row(children: [
              IconButton(
                color: Colors.white,
                onPressed: () async {
                  if (_v.value.isPlaying) {
                    await _v.pause();
                  } else {
                    final p = _v.value.position.inMilliseconds;
                    if (p < _keep.start || p >= _keep.end - 100) await _v.seekTo(Duration(milliseconds: _keep.start.round()));
                    await _v.play();
                  }
                },
                icon: Icon(_v.value.isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded),
              ),
              Expanded(
                child: Text(tr('ptool.keep', {'from': _clock(_keep.start), 'to': _clock(_keep.end)}),
                    style: const TextStyle(color: Colors.white70)),
              ),
            ]),
          ],
          Container(
            color: const Color(0xFF1D2633),
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Wrap(spacing: 6, children: [
                for (final (side, label) in [(0, tr('ptool.v_original')), (1920, tr('ptool.v_1080')), (1280, tr('ptool.v_720'))])
                  ChoiceChip(selected: _side == side, onSelected: (_) => setState(() => _side = side), label: Text(label)),
              ]),
              const SizedBox(height: 8),
              FilledButton.icon(onPressed: ready ? _make : null, icon: const Icon(Icons.check_rounded), label: Text(tr('ptool.make_video'))),
            ]),
          ),
        ]),
      ),
    );
  }
}

// ------------------------------------------------------------- PDF

class _PPage {
  _PPage(this.path, this.index);

  final String path;
  final int index;
  int turns = 0;
  final List<(Signature, Rect)> signs = [];
  Uint8List? thumb;
}

/// PDF on the phone: sign, join, turn, delete, reorder. Pages are saved as
/// pictures (their text can no longer be selected — said on screen).
class _PdfToolPage extends StatefulWidget {
  const _PdfToolPage({required this.settings, required this.discovery, required this.files});

  final MobileSettings settings;
  final DesktopDiscovery discovery;
  final List<String> files;

  @override
  State<_PdfToolPage> createState() => _PdfToolPageState();
}

class _PdfToolPageState extends State<_PdfToolPage> {
  final List<_PPage> _pages = [];
  bool _loading = true;
  Signature? _sig;

  @override
  void initState() {
    super.initState();
    unawaited(_add(widget.files));
  }

  Future<void> _add(List<String> files) async {
    setState(() => _loading = true);
    for (final f in files) {
      final n = await PdfPages.count(f);
      for (var i = 0; i < n; i++) {
        final p = _PPage(f, i);
        _pages.add(p);
        unawaited(PdfPages.render(f, i, 240).then((b) {
          if (mounted) setState(() => p.thumb = b);
        }));
      }
    }
    if (mounted) setState(() => _loading = false);
  }

  /// One page as a picture: turned, signed.
  Future<String?> _pageFile(_PPage p, String dir, int k) async {
    final png = await PdfPages.render(p.path, p.index, 1654);
    if (png == null) return null;
    final codec = await ui.instantiateImageCodec(png);
    final base = (await codec.getNextFrame()).image;
    final w = base.width, h = base.height;
    final t = p.turns % 4;
    final ow = t.isOdd ? h : w, oh = t.isOdd ? w : h;
    final rec = ui.PictureRecorder();
    final c = Canvas(rec);
    c.drawColor(Colors.white, BlendMode.src);
    c.translate(ow / 2, oh / 2);
    c.rotate(t * math.pi / 2);
    c.translate(-w / 2, -h / 2);
    c.drawImage(base, Offset.zero, Paint()..filterQuality = FilterQuality.high);
    for (final (sg, r) in p.signs) {
      c.drawImageRect(sg.image, Rect.fromLTWH(0, 0, sg.width.toDouble(), sg.height.toDouble()),
          Rect.fromLTWH(r.left * w, r.top * h, r.width * w, r.height * h), Paint()..filterQuality = FilterQuality.high);
    }
    final out = await rec.endRecording().toImage(ow, oh);
    final data = await out.toByteData(format: ui.ImageByteFormat.png);
    base.dispose();
    out.dispose();
    if (data == null) return null;
    final f = File('$dir/$k.png');
    await f.writeAsBytes(data.buffer.asUint8List());
    return f.path;
  }

  Future<void> _save() async {
    final out = await _busy(context, () async {
      final dir = await _outDir();
      final files = <String>[];
      for (var k = 0; k < _pages.length; k++) {
        final f = await _pageFile(_pages[k], dir.path, k);
        if (f != null) files.add(f);
      }
      if (files.isEmpty) return null;
      final signed = _pages.any((p) => p.signs.isNotEmpty);
      final name = '${_stem(widget.files.first.split('/').last)}${signed ? '-signed' : '-edited'}.pdf';
      final pdf = await ScanPdf.build(files, File('${dir.path}/$name'));
      return _toMyFiles(widget.settings, pdf);
    });
    if (mounted && out != null) await showPhoneResult(context, widget.settings, widget.discovery, [out], note: tr('ptool.in_myfiles'));
  }

  Future<void> _sign(_PPage p) async {
    _sig ??= await showSignaturePad(context, (k) => tr('sig.$k'));
    final sig = _sig;
    if (sig == null || !mounted) return;
    final big = await PdfPages.render(p.path, p.index, 900);
    if (big == null || !mounted) return;
    final r = await Navigator.of(context).push<Rect>(MaterialPageRoute(builder: (_) => _PlaceSign(page: big, sig: sig)));
    if (r != null) setState(() => p.signs.add((sig, r)));
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          title: Text(PhoneTool.pdfTools.title),
          actions: [
            IconButton(
              tooltip: tr('ptool.pdf_add'),
              onPressed: () async {
                final r = await FilePicker.platform.pickFiles(type: FileType.custom, allowedExtensions: const ['pdf'], allowMultiple: true);
                final paths = [for (final f in r?.files ?? const <PlatformFile>[]) if (f.path != null) f.path!];
                if (paths.isNotEmpty) await _add(paths);
              },
              icon: const Icon(Icons.note_add_rounded),
            ),
            TextButton(onPressed: _pages.isEmpty ? null : _save, child: Text(tr('ptool.save'))),
          ],
        ),
        body: Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Text(tr('ptool.pdf_hint'), style: const TextStyle(color: Color(0xFF6B7A99), fontSize: 12.5)),
          ),
          Expanded(
            child: _loading && _pages.isEmpty
                ? const Center(child: CircularProgressIndicator())
                : ReorderableListView.builder(
                    itemCount: _pages.length,
                    onReorder: (a, b) => setState(() {
                      final p = _pages.removeAt(a);
                      _pages.insert(b > a ? b - 1 : b, p);
                    }),
                    itemBuilder: (context, i) {
                      final p = _pages[i];
                      return ListTile(
                        key: ObjectKey(p),
                        leading: SizedBox(
                          width: 56,
                          height: 72,
                          child: p.thumb == null
                              ? const ColoredBox(color: Color(0xFFEEF1F6))
                              : RotatedBox(quarterTurns: p.turns, child: Image.memory(p.thumb!, fit: BoxFit.contain)),
                        ),
                        title: Text(tr('ptool.page_n', {'n': i + 1})),
                        subtitle: Text([
                          if (widget.files.length > 1 || p.path != widget.files.first) p.path.split('/').last,
                          if (p.signs.isNotEmpty) tr('ptool.signed'),
                        ].join(' · ')),
                        trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                          IconButton(onPressed: () => unawaited(_sign(p)), icon: const Icon(Icons.draw_rounded, color: Color(0xFF7B4DEB))),
                          IconButton(onPressed: () => setState(() => p.turns = (p.turns + 1) % 4), icon: const Icon(Icons.rotate_right_rounded)),
                          IconButton(onPressed: () => setState(() => _pages.removeAt(i)), icon: const Icon(Icons.delete_outline_rounded)),
                        ]),
                      );
                    },
                  ),
          ),
        ]),
      );
}

/// Where the signature goes on the page: drag, size.
class _PlaceSign extends StatefulWidget {
  const _PlaceSign({required this.page, required this.sig});

  final Uint8List page;
  final Signature sig;

  @override
  State<_PlaceSign> createState() => _PlaceSignState();
}

class _PlaceSignState extends State<_PlaceSign> {
  Offset _at = const Offset(0.6, 0.85);
  double _w = 0.35;
  Size? _size;

  @override
  void initState() {
    super.initState();
    decodeImageFromList(widget.page).then((i) {
      if (mounted) setState(() => _size = Size(i.width.toDouble(), i.height.toDouble()));
    });
  }

  @override
  Widget build(BuildContext context) {
    final ps = _size;
    return Scaffold(
      appBar: AppBar(
        title: Text(tr('ptool.place_sign')),
        actions: [
          TextButton(
            onPressed: ps == null
                ? null
                : () {
                    final h = _w * widget.sig.height / widget.sig.width * ps.width / ps.height;
                    Navigator.pop(context, Rect.fromLTWH(_at.dx - _w / 2, _at.dy - h / 2, _w, h));
                  },
            child: Text(tr('ptool.place_ok')),
          ),
        ],
      ),
      body: ps == null
          ? const Center(child: CircularProgressIndicator())
          : Column(children: [
              Expanded(
                child: LayoutBuilder(builder: (context, c) {
                  final k = math.min(c.maxWidth / ps.width, c.maxHeight / ps.height);
                  final w = ps.width * k, h = ps.height * k;
                  final sw = _w * w, sh = sw * widget.sig.height / widget.sig.width;
                  return Center(
                    child: SizedBox(
                      width: w,
                      height: h,
                      child: GestureDetector(
                        onPanUpdate: (d) => setState(() => _at = Offset(((_at.dx * w + d.delta.dx) / w).clamp(0.0, 1.0), ((_at.dy * h + d.delta.dy) / h).clamp(0.0, 1.0))),
                        onTapDown: (d) => setState(() => _at = Offset(d.localPosition.dx / w, d.localPosition.dy / h)),
                        child: Stack(children: [
                          Positioned.fill(child: Image.memory(widget.page, fit: BoxFit.fill)),
                          Positioned(
                            left: _at.dx * w - sw / 2,
                            top: _at.dy * h - sh / 2,
                            width: sw,
                            height: sh,
                            child: DecoratedBox(
                              decoration: BoxDecoration(border: Border.all(color: const Color(0x882F6BFF))),
                              child: Image.memory(widget.sig.png, fit: BoxFit.fill),
                            ),
                          ),
                        ]),
                      ),
                    ),
                  );
                }),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(children: [
                  Text(tr('ptool.sign_size')),
                  Expanded(child: Slider(value: _w, min: 0.1, max: 0.9, onChanged: (v) => setState(() => _w = v))),
                ]),
              ),
            ]),
    );
  }
}

// ------------------------------------------------------------- QR

class _QrPage extends StatefulWidget {
  const _QrPage();

  @override
  State<_QrPage> createState() => _QrPageState();
}

class _QrPageState extends State<_QrPage> {
  bool _make = false;
  String? _found;
  final TextEditingController _text = TextEditingController();
  final MobileScannerController _cam = MobileScannerController(formats: const [BarcodeFormat.qrCode]);

  @override
  void dispose() {
    _text.dispose();
    unawaited(_cam.dispose());
    super.dispose();
  }

  Future<void> _share(BuildContext c) async {
    final p = QrPainter(data: _text.text, version: QrVersions.auto, gapless: true, eyeStyle: const QrEyeStyle(color: Colors.black), dataModuleStyle: const QrDataModuleStyle(color: Colors.black));
    final d = await p.toImageData(1024, format: ui.ImageByteFormat.png);
    if (d == null) return;
    final dir = await _outDir();
    final f = File('${dir.path}/QR.png');
    await f.writeAsBytes(d.buffer.asUint8List());
    if (!c.mounted) return;
    final box = c.findRenderObject() as RenderBox?;
    await SharePlus.instance.share(ShareParams(files: [XFile(f.path)], sharePositionOrigin: box == null ? null : box.localToGlobal(Offset.zero) & box.size));
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text(PhoneTool.qr.title)),
        body: Column(children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: SegmentedButton<bool>(
              segments: [
                ButtonSegment(value: false, label: Text(tr('ptool.qr_scan')), icon: const Icon(Icons.qr_code_scanner_rounded)),
                ButtonSegment(value: true, label: Text(tr('ptool.qr_make')), icon: const Icon(Icons.qr_code_rounded)),
              ],
              selected: {_make},
              onSelectionChanged: (v) => setState(() => _make = v.first),
            ),
          ),
          Expanded(
            child: _make
                ? ListView(padding: const EdgeInsets.all(16), children: [
                    TextField(
                      controller: _text,
                      minLines: 2,
                      maxLines: 5,
                      onChanged: (_) => setState(() {}),
                      decoration: InputDecoration(hintText: tr('ptool.qr_hint'), border: const OutlineInputBorder()),
                    ),
                    const SizedBox(height: 16),
                    if (_text.text.isNotEmpty)
                      Center(child: Container(color: Colors.white, padding: const EdgeInsets.all(12), child: QrImageView(data: _text.text, size: 240))),
                    const SizedBox(height: 12),
                    Builder(
                      builder: (c) => FilledButton.icon(
                        onPressed: _text.text.isEmpty ? null : () => _share(c),
                        icon: const Icon(Icons.ios_share_rounded),
                        label: Text(tr('ptool.share')),
                      ),
                    ),
                  ])
                : Column(children: [
                    Expanded(
                      child: MobileScanner(
                        controller: _cam,
                        onDetect: (cap) {
                          final v = cap.barcodes.firstOrNull?.rawValue;
                          if (v != null && v != _found) setState(() => _found = v);
                        },
                      ),
                    ),
                    if (_found != null)
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(14),
                        color: Colors.white,
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          SelectableText(_found!, maxLines: 4),
                          Row(children: [
                            TextButton.icon(
                              onPressed: () => unawaited(Clipboard.setData(ClipboardData(text: _found!))),
                              icon: const Icon(Icons.copy_rounded),
                              label: Text(tr('ptool.copy')),
                            ),
                            if (RegExp(r'^https?://').hasMatch(_found!))
                              TextButton.icon(
                                onPressed: () => unawaited(FileOpener.openUrl(_found!)),
                                icon: const Icon(Icons.open_in_new_rounded),
                                label: Text(tr('ptool.open')),
                              ),
                          ]),
                        ]),
                      ),
                  ]),
          ),
        ]),
      );
}
