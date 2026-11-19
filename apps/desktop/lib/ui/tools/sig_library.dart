// apps/desktop/lib/ui/tools/sig_library.dart
import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:localroll_core/localroll_core.dart' show DiagLog;
import 'package:localroll_ink/localroll_ink.dart' show Signature, showSignaturePad;
import 'package:pdfrx/pdfrx.dart';

import '../../app_services.dart';
import '../../l10n/l10n.dart';
import '../../services/file_tools.dart' show uprightJpeg;
import '../../services/win_dialogs.dart';
import '../library_picker.dart';
import '../light_dialog.dart';
import '../light_look.dart';
import '../lr_dialog.dart';

/// "My signatures": saved as see-through PNGs in Keepnear's data folder.
class SigStore {
  SigStore(this.s);
  final AppServices s;

  Directory get dir => Directory('${s.settings.dataDir.path}${Platform.pathSeparator}signatures');

  Future<List<File>> list() async {
    try {
      if (!await dir.exists()) return [];
      final out = [
        await for (final e in dir.list())
          if (e is File && e.path.toLowerCase().endsWith('.png')) e,
      ]..sort((a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()));
      return out;
    } catch (_) {
      return [];
    }
  }

  Future<void> add(Uint8List png) async {
    await dir.create(recursive: true);
    await File('${dir.path}${Platform.pathSeparator}${DateTime.now().millisecondsSinceEpoch}.png').writeAsBytes(png, flush: true);
  }
}

Future<Signature> signatureFromPng(Uint8List png) async {
  final codec = await ui.instantiateImageCodec(png);
  final f = await codec.getNextFrame();
  return Signature(f.image, png);
}

/// Picks a signature: a saved one, a new one drawn, or one from a file (a
/// photo or a PDF of a signature on paper, its background taken away). New
/// ones are saved.
Future<Signature?> pickSignature(BuildContext context, AppServices s) async {
  final store = SigStore(s);
  var files = await store.list();
  if (!context.mounted) return null;
  final pick = await showLrDialog<Object>(
    context: context,
    builder: (c) => StatefulBuilder(
      builder: (c, set) => LightDialog(
        icon: Icons.draw_rounded,
        title: tr('sig.mine'),
        subtitle: tr('sig.mine_sub'),
        actions: [
          OutlinedButton.icon(onPressed: () => Navigator.pop(c, 'draw'), icon: const Icon(Icons.gesture_rounded, size: 18), label: Text(tr('sig.add_draw'))),
          OutlinedButton.icon(onPressed: () => Navigator.pop(c, 'photo'), icon: const Icon(Icons.upload_file_rounded, size: 18), label: Text(tr('sig.add_file'))),
          TextButton(onPressed: () => Navigator.pop(c), child: Text(tr('common.cancel'))),
        ],
        child: files.isEmpty
            ? Text(tr('sig.none'), style: const TextStyle(color: LightLook.muted))
            : Wrap(spacing: 10, runSpacing: 10, children: [
                for (final f in files)
                  Stack(clipBehavior: Clip.none, children: [
                    InkWell(
                      borderRadius: BorderRadius.circular(10),
                      onTap: () => Navigator.pop(c, f),
                      child: Container(
                        width: 150,
                        height: 70,
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: const Color(0xFFFAFBFE),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: const Color(0xFFE3E8F2)),
                        ),
                        child: Image.file(f, fit: BoxFit.contain),
                      ),
                    ),
                    Positioned(
                      right: -8,
                      top: -8,
                      child: IconButton(
                        tooltip: tr('lib.delete'),
                        visualDensity: VisualDensity.compact,
                        iconSize: 16,
                        style: IconButton.styleFrom(backgroundColor: Colors.white),
                        onPressed: () async {
                          try {
                            await f.delete();
                          } catch (_) {}
                          files = await store.list();
                          set(() {});
                        },
                        icon: const Icon(Icons.close_rounded, color: LightLook.muted),
                      ),
                    ),
                  ]),
              ]),
      ),
    ),
  );
  if (!context.mounted || pick == null) return null;
  if (pick is File) return signatureFromPng(await pick.readAsBytes());
  Signature? sig;
  if (pick == 'draw') {
    sig = await showSignaturePad(context, (k) => tr('sig.$k'));
  } else {
    sig = await pictureCutout(context, s, signature: true);
  }
  if (sig != null) await store.add(sig.png);
  return sig;
}

/// Photos and PDFs a picture / signature can come from.
const _pictureExts = {'jpg', 'jpeg', 'png', 'heic', 'heif', 'webp', 'bmp', 'gif', 'tif', 'tiff', 'pdf'};

/// A picture to put on a page: a photo or a PDF page (from the library or
/// this PC), cropped, its plain background (paper, white) made see-through
/// if asked. [signature]: set for a signature (background off by default for
/// other pictures).
Future<Signature?> pictureCutout(BuildContext context, AppServices s, {bool signature = false}) async {
  final where = await showLrDialog<String>(
    context: context,
    builder: (c) => SimpleDialog(title: Text(tr(signature ? 'sig.add_file' : 'pdf.add_picture')), children: [
      SimpleDialogOption(onPressed: () => Navigator.pop(c, 'lib'), child: Text(tr('tool.from_library'))),
      SimpleDialogOption(onPressed: () => Navigator.pop(c, 'pc'), child: Text(tr('tool.from_folder'))),
    ]),
  );
  if (where == null || !context.mounted) return null;
  final List<String> paths = where == 'lib'
      ? (await pickFromLibrary(context, s, multiple: false, exts: _pictureExts) ?? const [])
      : await WinDialogs.pickFiles(title: tr(signature ? 'sig.add_file' : 'pdf.add_picture'), extensions: _pictureExts.toList());
  if (paths.isEmpty || !context.mounted) return null;
  Uint8List? bytes;
  final p = paths.first;
  final ext = p.toLowerCase().split('.').last;
  try {
    if (ext == 'pdf') {
      bytes = await _pdfPagePicture(context, p);
    } else if (ext == 'png' || ext == 'jpg' || ext == 'jpeg') {
      bytes = await File(p).readAsBytes();
    } else {
      final j = await uprightJpeg(s, p, max: 2400);
      if (j != null) bytes = await File(j.$1).readAsBytes();
    }
  } catch (e) {
    DiagLog.log('tools', 'picture for pdf: $e');
  }
  if (bytes == null || !context.mounted) return null;
  return showLrDialog<Signature>(
    context: context,
    builder: (_) => _Cutout(src: bytes!, signature: signature, maxSide: ext == 'pdf' ? 3600 : 2400),
  );
}

/// A page of the PDF [path] as a sharp picture (300 dpi): the page is
/// picked first when there are several.
Future<Uint8List?> _pdfPagePicture(BuildContext context, String path) async {
  final doc = await PdfDocument.openFile(path);
  try {
    var at = 0;
    if (doc.pages.length > 1) {
      if (!context.mounted) return null;
      final pick = await showLrDialog<int>(
        context: context,
        builder: (c) => LightDialog(
          icon: Icons.picture_as_pdf_outlined,
          title: tr('sig.pick_page'),
          subtitle: tr('sig.pick_page_sub'),
          actions: [TextButton(onPressed: () => Navigator.pop(c), child: Text(tr('common.cancel')))],
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 440),
            child: SingleChildScrollView(
              child: Wrap(spacing: 12, runSpacing: 12, children: [
                for (var i = 0; i < doc.pages.length; i++)
                  InkWell(
                    borderRadius: BorderRadius.circular(8),
                    onTap: () => Navigator.pop(c, i),
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      Container(
                        width: 120,
                        height: 120 * doc.pages[i].height / doc.pages[i].width,
                        decoration: BoxDecoration(
                          color: Colors.white,
                          border: Border.all(color: const Color(0xFFDDE3EC)),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: PdfPageView(document: doc, pageNumber: i + 1, maximumDpi: 72),
                      ),
                      const SizedBox(height: 4),
                      Text('${i + 1}', style: const TextStyle(color: LightLook.muted, fontSize: 12)),
                    ]),
                  ),
              ]),
            ),
          ),
        ),
      );
      if (pick == null) return null;
      at = pick;
    }
    final page = doc.pages[at];
    final k = math.min(300 / 72, 3600 / math.max(page.width, page.height));
    final w = (page.width * k).round(), h = (page.height * k).round();
    final pic = await page.render(width: w, height: h, fullWidth: w.toDouble(), fullHeight: h.toDouble(), backgroundColor: Colors.white);
    if (pic == null) return null;
    final im = await pic.createImage();
    pic.dispose();
    final png = await im.toByteData(format: ui.ImageByteFormat.png);
    im.dispose();
    DiagLog.log('tools', 'picture from pdf page ${at + 1}: ${w}x$h');
    return png?.buffer.asUint8List();
  } finally {
    await doc.dispose();
  }
}

/// The picture's pixels, its size, and how to treat them.
class _Job {
  _Job(this.rgba, this.w, this.h, this.crop, this.strength, this.ink, this.opacity, this.turns);
  final Uint8List rgba;
  final int w, h;
  final Rect crop; // 0–1
  final double strength; // 0: keep background, 1: take away a lot
  final int? ink; // ARGB to recolour the lines, or null
  final double opacity;
  final int turns;
}

/// Crops, makes the background see-through (colours near the border's
/// colour), recolours, cuts to what is left. Returns rgba, w, h.
(Uint8List, int, int) _cutOut(_Job j) {
  final x0 = (j.crop.left * j.w).floor().clamp(0, j.w - 1), y0 = (j.crop.top * j.h).floor().clamp(0, j.h - 1);
  final x1 = (j.crop.right * j.w).ceil().clamp(x0 + 1, j.w), y1 = (j.crop.bottom * j.h).ceil().clamp(y0 + 1, j.h);
  final cw = x1 - x0, ch = y1 - y0;
  var px = Uint8List(cw * ch * 4);
  for (var y = 0; y < ch; y++) {
    px.setRange(y * cw * 4, (y + 1) * cw * 4, j.rgba, ((y0 + y) * j.w + x0) * 4);
  }
  // The background: the middle colour along the edges.
  if (j.strength > 0) {
    final rs = <int>[], gs = <int>[], bs = <int>[];
    void take(int x, int y) {
      final i = (y * cw + x) * 4;
      rs.add(px[i]);
      gs.add(px[i + 1]);
      bs.add(px[i + 2]);
    }

    for (var x = 0; x < cw; x += math.max(1, cw ~/ 200)) {
      take(x, 0);
      take(x, ch - 1);
    }
    for (var y = 0; y < ch; y += math.max(1, ch ~/ 200)) {
      take(0, y);
      take(cw - 1, y);
    }
    int mid(List<int> v) => (v..sort())[v.length ~/ 2];
    final br = mid(rs), bg = mid(gs), bb = mid(bs);
    // Near the background: gone; far: kept; between: part see-through.
    final lo = 12 + j.strength * 70, hi = lo + 30 + j.strength * 40;
    for (var i = 0; i < px.length; i += 4) {
      final dr = px[i] - br, dg = px[i + 1] - bg, db = px[i + 2] - bb;
      final d = math.sqrt(dr * dr + dg * dg + db * db);
      final a = d <= lo ? 0.0 : (d >= hi ? 1.0 : (d - lo) / (hi - lo));
      px[i + 3] = (px[i + 3] * a).round();
    }
  }
  final ink = j.ink;
  for (var i = 0; i < px.length; i += 4) {
    if (ink != null) {
      px[i] = (ink >> 16) & 0xFF;
      px[i + 1] = (ink >> 8) & 0xFF;
      px[i + 2] = ink & 0xFF;
    }
    if (j.opacity < 1) px[i + 3] = (px[i + 3] * j.opacity).round();
  }
  var w = cw, h = ch;
  // Cut to what is left (a see-through picture: no empty margins).
  if (j.strength > 0) {
    var l = w, t = h, r = -1, b = -1;
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        if (px[(y * w + x) * 4 + 3] > 24) {
          if (x < l) l = x;
          if (x > r) r = x;
          if (y < t) t = y;
          if (y > b) b = y;
        }
      }
    }
    if (r >= l && b >= t) {
      const pad = 4;
      l = math.max(0, l - pad);
      t = math.max(0, t - pad);
      r = math.min(w - 1, r + pad);
      b = math.min(h - 1, b + pad);
      final nw = r - l + 1, nh = b - t + 1;
      final out = Uint8List(nw * nh * 4);
      for (var y = 0; y < nh; y++) {
        out.setRange(y * nw * 4, (y + 1) * nw * 4, px, ((t + y) * w + l) * 4);
      }
      px = out;
      w = nw;
      h = nh;
    }
  }
  // Turned a quarter at a time.
  for (var k = 0; k < j.turns % 4; k++) {
    final out = Uint8List(px.length);
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        final si = (y * w + x) * 4, di = (x * h + (h - 1 - y)) * 4;
        out[di] = px[si];
        out[di + 1] = px[si + 1];
        out[di + 2] = px[si + 2];
        out[di + 3] = px[si + 3];
      }
    }
    px = out;
    final t = w;
    w = h;
    h = t;
  }
  return (px, w, h);
}

Future<ui.Image> _toImage(Uint8List rgba, int w, int h) {
  final c = Completer<ui.Image>();
  ui.decodeImageFromPixels(rgba, w, h, ui.PixelFormat.rgba8888, c.complete);
  return c.future;
}

class _Cutout extends StatefulWidget {
  const _Cutout({required this.src, required this.signature, this.maxSide = 2400});

  final Uint8List src;
  final bool signature;

  /// The longest side kept (a PDF page is cut from a larger picture).
  final int maxSide;

  @override
  State<_Cutout> createState() => _CutoutState();
}

class _CutoutState extends State<_Cutout> {
  ui.Image? _orig;
  Uint8List? _rgba, _small;
  int _w = 0, _h = 0, _sw = 0, _sh = 0;
  ui.Image? _preview;
  Rect _crop = const Rect.fromLTWH(0, 0, 1, 1);
  late bool _cut = widget.signature;
  double _strength = 0.45;
  int? _ink;
  double _opacity = 1;
  int _turns = 0;
  Timer? _soon;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    // At most 2400 px on the long side (sharp enough on a page).
    final codec = await ui.instantiateImageCodec(widget.src);
    final f = await codec.getNextFrame();
    var im = f.image;
    final k = math.min(1.0, widget.maxSide / math.max(im.width, im.height));
    if (k < 1) {
      final rec = ui.PictureRecorder();
      Canvas(rec).drawImageRect(im, Rect.fromLTWH(0, 0, im.width.toDouble(), im.height.toDouble()),
          Rect.fromLTWH(0, 0, im.width * k, im.height * k), Paint()..filterQuality = FilterQuality.high);
      im = await rec.endRecording().toImage((im.width * k).round(), (im.height * k).round());
    }
    final d = await im.toByteData(format: ui.ImageByteFormat.rawStraightRgba);
    // A small copy for the live preview.
    final ks = math.min(1.0, 700 / math.max(im.width, im.height));
    final rec = ui.PictureRecorder();
    Canvas(rec).drawImageRect(im, Rect.fromLTWH(0, 0, im.width.toDouble(), im.height.toDouble()),
        Rect.fromLTWH(0, 0, im.width * ks, im.height * ks), Paint()..filterQuality = FilterQuality.medium);
    final small = await rec.endRecording().toImage(math.max(1, (im.width * ks).round()), math.max(1, (im.height * ks).round()));
    final sd = await small.toByteData(format: ui.ImageByteFormat.rawStraightRgba);
    if (!mounted || d == null || sd == null) return;
    setState(() {
      _orig = im;
      _rgba = d.buffer.asUint8List();
      _w = im.width;
      _h = im.height;
      _small = sd.buffer.asUint8List();
      _sw = small.width;
      _sh = small.height;
    });
    _refresh();
  }

  _Job _job(bool full) => _Job(full ? _rgba! : _small!, full ? _w : _sw, full ? _h : _sh, _crop, _cut ? _strength : 0, _ink,
      widget.signature ? 1 : _opacity, _turns);

  void _refresh() {
    _soon?.cancel();
    _soon = Timer(const Duration(milliseconds: 120), () async {
      if (_small == null) return;
      final (px, w, h) = await compute(_cutOut, _job(false));
      final im = await _toImage(px, w, h);
      if (mounted) setState(() => _preview = im);
    });
  }

  Future<void> _done() async {
    setState(() => _saving = true);
    final (px, w, h) = await compute(_cutOut, _job(true));
    final im = await _toImage(px, w, h);
    final png = (await im.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List();
    if (mounted) Navigator.pop(context, Signature(im, png));
  }

  @override
  void dispose() {
    _soon?.cancel();
    super.dispose();
  }

  Widget _chip(String label, bool on, VoidCallback tap) => Padding(
        padding: const EdgeInsets.only(right: 6),
        child: ChoiceChip(label: Text(label), selected: on, onSelected: (_) => tap()),
      );

  @override
  Widget build(BuildContext context) {
    final orig = _orig;
    return LightDialog(
      icon: widget.signature ? Icons.draw_rounded : Icons.image_outlined,
      title: tr(widget.signature ? 'sig.add_file' : 'pdf.add_picture'),
      subtitle: tr('sig.cut_sub'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(tr('common.cancel'))),
        FilledButton(onPressed: orig == null || _saving ? null : _done, child: Text(tr(widget.signature ? 'sig.save' : 'common.ok'))),
      ],
      child: orig == null
          ? const Padding(padding: EdgeInsets.all(40), child: Center(child: CircularProgressIndicator()))
          : Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(tr('sig.original'), style: const TextStyle(color: LightLook.muted, fontSize: 12.5)),
                    const SizedBox(height: 4),
                    SizedBox(height: 240, child: _CropBox(image: orig, crop: _crop, onCrop: (r) {
                      setState(() => _crop = r);
                      _refresh();
                    })),
                  ]),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(tr('sig.result'), style: const TextStyle(color: LightLook.muted, fontSize: 12.5)),
                    const SizedBox(height: 4),
                    Container(
                      height: 240,
                      decoration: BoxDecoration(borderRadius: BorderRadius.circular(8), border: Border.all(color: const Color(0xFFE3E8F2))),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: CustomPaint(
                          painter: const _Checks(),
                          child: Center(child: _preview == null ? null : RawImage(image: _preview, fit: BoxFit.contain)),
                        ),
                      ),
                    ),
                  ]),
                ),
              ]),
              const SizedBox(height: 10),
              Row(children: [
                if (!widget.signature)
                  Padding(
                    padding: const EdgeInsets.only(right: 10),
                    child: FilterChip(
                      label: Text(tr('sig.cut_bg')),
                      selected: _cut,
                      onSelected: (v) {
                        setState(() => _cut = v);
                        _refresh();
                      },
                    ),
                  ),
                if (_cut) ...[
                  Text(tr('sig.strength'), style: const TextStyle(color: LightLook.text)),
                  Expanded(
                    child: Slider(
                      value: _strength,
                      onChanged: (v) {
                        setState(() => _strength = v);
                        _refresh();
                      },
                    ),
                  ),
                ] else
                  const Spacer(),
                IconButton(
                  tooltip: tr('pdf.turn'),
                  onPressed: () {
                    setState(() => _turns = (_turns + 1) % 4);
                    _refresh();
                  },
                  icon: const Icon(Icons.rotate_right_rounded),
                ),
              ]),
              if (widget.signature)
                Row(children: [
                  Text('${tr('sig.ink')}  ', style: const TextStyle(color: LightLook.text)),
                  _chip(tr('sig.ink_orig'), _ink == null, () {
                    setState(() => _ink = null);
                    _refresh();
                  }),
                  _chip(tr('sig.ink_blue'), _ink == 0xFF1D3FA0, () {
                    setState(() => _ink = 0xFF1D3FA0);
                    _refresh();
                  }),
                  _chip(tr('sig.ink_black'), _ink == 0xFF111111, () {
                    setState(() => _ink = 0xFF111111);
                    _refresh();
                  }),
                ])
              else
                Row(children: [
                  Text(tr('sig.opacity'), style: const TextStyle(color: LightLook.text)),
                  Expanded(
                    child: Slider(
                      value: _opacity,
                      min: 0.2,
                      onChanged: (v) {
                        setState(() => _opacity = v);
                        _refresh();
                      },
                    ),
                  ),
                  Text('${(_opacity * 100).round()}%'),
                ]),
              Text(tr('sig.crop_hint'), style: const TextStyle(color: LightLook.muted, fontSize: 12)),
            ]),
    );
  }
}

/// The original with a crop box: drag a corner to change it, inside to move.
class _CropBox extends StatefulWidget {
  const _CropBox({required this.image, required this.crop, required this.onCrop});

  final ui.Image image;
  final Rect crop;
  final ValueChanged<Rect> onCrop;

  @override
  State<_CropBox> createState() => _CropBoxState();
}

class _CropBoxState extends State<_CropBox> {
  String? _grab;

  /// Room around the picture, so corners and edges on its border are as
  /// easy to take hold of as the others.
  static const _m = 14.0;

  /// What a press at [p] takes hold of: a corner, an edge, the box, none.
  String? _what(Offset p, Rect box) {
    const near = 14.0;
    final l = (p.dx - box.left).abs() < near, r = (p.dx - box.right).abs() < near;
    final t = (p.dy - box.top).abs() < near, b = (p.dy - box.bottom).abs() < near;
    final inX = p.dx > box.left - near && p.dx < box.right + near, inY = p.dy > box.top - near && p.dy < box.bottom + near;
    final h = l ? 'l' : (r ? 'r' : ''), v = t ? 't' : (b ? 'b' : '');
    if (h.isNotEmpty && v.isNotEmpty) return '$h$v';
    if (h.isNotEmpty && inY) return h;
    if (v.isNotEmpty && inX) return v;
    return box.contains(p) ? 'move' : null;
  }

  static MouseCursor _cursor(String? g) => switch (g) {
        'lt' || 'rb' => SystemMouseCursors.resizeUpLeftDownRight,
        'rt' || 'lb' => SystemMouseCursors.resizeUpRightDownLeft,
        'l' || 'r' => SystemMouseCursors.resizeLeftRight,
        't' || 'b' => SystemMouseCursors.resizeUpDown,
        'move' => SystemMouseCursors.click,
        _ => SystemMouseCursors.basic,
      };

  MouseCursor _hover = SystemMouseCursors.basic;

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, c) {
        final iw = widget.image.width.toDouble(), ih = widget.image.height.toDouble();
        final k = math.min((c.maxWidth - 2 * _m) / iw, (c.maxHeight - 2 * _m) / ih);
        final w = iw * k, h = ih * k;
        final r = widget.crop;
        final box = Rect.fromLTRB(r.left * w, r.top * h, r.right * w, r.bottom * h);
        Offset at(Offset p) => p - const Offset(_m, _m);
        return Center(
          child: MouseRegion(
            cursor: _grab != null ? _cursor(_grab) : _hover,
            onHover: (e) {
              final cur = _cursor(_what(at(e.localPosition), box));
              if (cur != _hover) setState(() => _hover = cur);
            },
            child: GestureDetector(
              onPanStart: (d) => setState(() => _grab = _what(at(d.localPosition), box)),
              onPanUpdate: (d) {
                final g = _grab;
                if (g == null) return;
                final dx = d.delta.dx / w, dy = d.delta.dy / h;
                var n = widget.crop;
                if (g == 'move') {
                  final x = (n.left + dx).clamp(0.0, 1 - n.width), y = (n.top + dy).clamp(0.0, 1 - n.height);
                  n = Rect.fromLTWH(x, y, n.width, n.height);
                } else {
                  var l = n.left, t = n.top, rr = n.right, b = n.bottom;
                  if (g.contains('l')) l = (l + dx).clamp(0.0, rr - 0.05);
                  if (g.contains('r')) rr = (rr + dx).clamp(l + 0.05, 1.0);
                  if (g.contains('t')) t = (t + dy).clamp(0.0, b - 0.05);
                  if (g.contains('b')) b = (b + dy).clamp(t + 0.05, 1.0);
                  n = Rect.fromLTRB(l, t, rr, b);
                }
                widget.onCrop(n);
              },
              onPanEnd: (_) => setState(() => _grab = null),
              child: Container(
                color: Colors.transparent,
                padding: const EdgeInsets.all(_m),
                child: SizedBox(
                  width: w,
                  height: h,
                  child: Stack(clipBehavior: Clip.none, children: [
                    Positioned.fill(child: RawImage(image: widget.image, fit: BoxFit.fill)),
                    Positioned.fill(child: CustomPaint(painter: _Shade(box))),
                  ]),
                ),
              ),
            ),
          ),
        );
      });
}

class _Shade extends CustomPainter {
  _Shade(this.box);
  final Rect box;

  @override
  void paint(Canvas canvas, Size size) {
    final dim = Paint()..color = const Color(0x88000000);
    canvas.drawPath(Path.combine(PathOperation.difference, Path()..addRect(Offset.zero & size), Path()..addRect(box)), dim);
    canvas.drawRect(
        box,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..color = const Color(0xFF2F6BFF));
    final h = Paint()..color = Colors.white;
    for (final p in [box.topLeft, box.topRight, box.bottomLeft, box.bottomRight]) {
      canvas.drawRect(Rect.fromCenter(center: p, width: 14, height: 14), h);
      canvas.drawRect(
          Rect.fromCenter(center: p, width: 14, height: 14),
          Paint()
            ..style = PaintingStyle.stroke
            ..color = const Color(0xFF2F6BFF)
            ..strokeWidth = 2);
    }
  }

  @override
  bool shouldRepaint(_Shade old) => old.box != box;
}

/// A chessboard: what is see-through shows as checks.
class _Checks extends CustomPainter {
  const _Checks();

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = Colors.white);
    final p = Paint()..color = const Color(0xFFEFF2F8);
    const s = 12.0;
    for (var y = 0.0; y < size.height; y += s) {
      for (var x = ((y / s).round().isOdd ? s : 0.0); x < size.width; x += 2 * s) {
        canvas.drawRect(Rect.fromLTWH(x, y, s, s), p);
      }
    }
  }

  @override
  bool shouldRepaint(_Checks old) => false;
}
