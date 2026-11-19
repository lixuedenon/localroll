// packages/ink/lib/src/tools/photo_edit.dart
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;

/// What was asked of a photo; done on the full picture when saving.
class PhotoEdit {
  /// Quarter turns clockwise.
  int turns = 0;

  /// The part kept, 0–1 of the turned picture.
  Rect crop = const Rect.fromLTWH(0, 0, 1, 1);

  /// −0.5…0.5 (0: as it is).
  double brightness = 0, contrast = 0, saturation = 0;

  /// Blurred-into-squares parts, 0–1 of the turned picture.
  final List<Rect> mosaic = [];

  /// The longest side at most this (0: as it is).
  int maxSide = 0;

  int quality = 88;

  /// Exactly this many pixels (an ID photo); 0: as cropped.
  int outW = 0, outH = 0;

  bool get changed =>
      turns % 4 != 0 ||
      crop != const Rect.fromLTWH(0, 0, 1, 1) ||
      brightness != 0 ||
      contrast != 0 ||
      saturation != 0 ||
      mosaic.isNotEmpty ||
      maxSide > 0 ||
      outW > 0;
}

/// An ID photo's shape: its size on paper, the pixels saved, and how much
/// of its height the head (top of the head to the chin) should fill.
class IdPhoto {
  const IdPhoto(this.key, this.w, this.h, this.headFrom, this.headTo);

  /// Its name in the texts ("id_us"…).
  final String key;

  /// Pixels saved.
  final int w, h;

  /// Head height, part of the photo's height.
  final double headFrom, headTo;

  double get ratio => w / h;

  /// US passport / visa / green card: 2×2 in, head 1–1⅜ in. Schengen, UK,
  /// most of Europe: 35×45 mm, head 32–36 mm. China passport / visa:
  /// 33×48 mm, head 28–33 mm. Pixels at 300 dpi (the US: 1200, the most
  /// its online forms take).
  static const all = [
    IdPhoto('id_us', 1200, 1200, 0.50, 0.69),
    IdPhoto('id_eu', 413, 531, 0.71, 0.80),
    IdPhoto('id_cn', 390, 567, 0.58, 0.69),
  ];
}

/// The photo with [edit] done, as a JPEG (in the background: big photos take
/// a moment).
Future<Uint8List?> renderPhotoEdit(Uint8List source, PhotoEdit edit) => compute(
    _render, (source, edit.turns, edit.crop, edit.brightness, edit.contrast, edit.saturation, List<Rect>.of(edit.mosaic), edit.maxSide, edit.quality, edit.outW, edit.outH));

/// The colour change, the same sums as the screen's [photoEditFilter], each
/// value kept within 0–255 (bright parts stay white instead of wrapping
/// round to black).
img.Image _colour(img.Image src, double br, double co, double sa) {
  final m = _colourMatrix(br, co, sa);
  final im = src.format == img.Format.uint8 && src.numChannels >= 3 ? src : src.convert(format: img.Format.uint8, numChannels: 3);
  final d = im.data!.toUint8List();
  final n = im.numChannels;
  int c(double v) => v < 0 ? 0 : (v > 255 ? 255 : v.round());
  for (var i = 0; i + 2 < d.length; i += n) {
    final r = d[i].toDouble(), g = d[i + 1].toDouble(), b = d[i + 2].toDouble();
    d[i] = c(m[0] * r + m[1] * g + m[2] * b + m[4]);
    d[i + 1] = c(m[5] * r + m[6] * g + m[7] * b + m[9]);
    d[i + 2] = c(m[10] * r + m[11] * g + m[12] * b + m[14]);
  }
  return img.Image.fromBytes(
      width: im.width, height: im.height, bytes: d.buffer, bytesOffset: d.offsetInBytes, numChannels: n, rowStride: im.width * n);
}

Uint8List? _render((Uint8List, int, Rect, double, double, double, List<Rect>, int, int, int, int) a) {
  final (bytes, turns, crop, br, co, sa, mosaic, maxSide, quality, outW, outH) = a;
  var im = img.decodeImage(bytes);
  if (im == null) return null;
  im = img.bakeOrientation(im);
  if (turns % 4 != 0) im = img.copyRotate(im, angle: (turns % 4) * 90);
  final w = im.width, h = im.height;
  for (final r in mosaic) {
    final x = (r.left * w).round().clamp(0, w - 1), y = (r.top * h).round().clamp(0, h - 1);
    final rw = (r.width * w).round().clamp(1, w - x), rh = (r.height * h).round().clamp(1, h - y);
    final part = img.pixelate(img.copyCrop(im, x: x, y: y, width: rw, height: rh), size: math.max(8, math.max(w, h) ~/ 60));
    img.compositeImage(im, part, dstX: x, dstY: y);
  }
  if (crop != const Rect.fromLTWH(0, 0, 1, 1)) {
    final x = (crop.left * w).round().clamp(0, w - 1), y = (crop.top * h).round().clamp(0, h - 1);
    im = img.copyCrop(im, x: x, y: y, width: (crop.width * w).round().clamp(1, w - x), height: (crop.height * h).round().clamp(1, h - y));
  }
  if (br != 0 || co != 0 || sa != 0) {
    im = _colour(im, br, co, sa);
  }
  if (outW > 0 && outH > 0) {
    im = img.copyResize(im, width: outW, height: outH, interpolation: img.Interpolation.cubic);
  } else if (maxSide > 0 && math.max(im.width, im.height) > maxSide) {
    im = im.width >= im.height
        ? img.copyResize(im, width: maxSide, interpolation: img.Interpolation.average)
        : img.copyResize(im, height: maxSide, interpolation: img.Interpolation.average);
  }
  return img.encodeJpg(im, quality: quality);
}

/// The colour change as the screen shows it meanwhile (close to the saved one).
ColorFilter photoEditFilter(PhotoEdit e) => ColorFilter.matrix(_colourMatrix(e.brightness, e.contrast, e.saturation));

List<double> _colourMatrix(double brightness, double contrast, double saturation) {
  final b = brightness * 255 * 0.6;
  final c = 1 + contrast;
  final s = 1 + saturation;
  const lr = 0.2126, lg = 0.7152, lb = 0.0722;
  final sr = (1 - s) * lr, sg = (1 - s) * lg, sb = (1 - s) * lb;
  final t = (1 - c) * 128 + b;
  return [
    c * (sr + s), c * sg, c * sb, 0, t, //
    c * sr, c * (sg + s), c * sb, 0, t,
    c * sr, c * sg, c * (sb + s), 0, t,
    0, 0, 0, 1, 0,
  ];
}

enum _Mode { crop, adjust, mosaic, size }

/// The photo editor: crop (with set shapes), turn, colour, squares over
/// what should not be seen, smaller. Saving is the app's ([onSave] gets the
/// JPEG). [texts] keys: crop, turn, adjust, mosaic, size, brightness,
/// contrast, saturation, free, square, original, undo, reset, save, saving,
/// mosaic_hint, size_hint, cancel, crop_hint, id_photos, id_us, id_eu,
/// id_cn, id_hint, out_size.
class PhotoEditor extends StatefulWidget {
  const PhotoEditor({super.key, required this.bytes, required this.texts, required this.onSave, this.dark = true, this.extraActions = const []});

  final Uint8List bytes;
  final String Function(String key) texts;
  final Future<void> Function(Uint8List jpeg, PhotoEdit edit) onSave;
  final bool dark;

  /// More buttons next to "Save" (e.g. "Send to phone"), given the JPEG.
  final List<(String, IconData, Future<void> Function(Uint8List jpeg))> extraActions;

  @override
  State<PhotoEditor> createState() => _PhotoEditorState();
}

class _PhotoEditorState extends State<PhotoEditor> {
  final PhotoEdit _e = PhotoEdit();
  _Mode _mode = _Mode.crop;
  double? _ratio; // crop shape (w / h), null: free
  IdPhoto? _id; // an ID photo's shape and size, if chosen

  /// Changing the crop box: 'move', 'new', or the edges held ('l', 't',
  /// 'r', 'b' — a corner is two).
  String? _grab;
  Rect _grabFrom = Rect.zero;
  Size? _natural;
  bool _busy = false;
  Offset? _dragStart;
  Rect? _drawing;

  @override
  void initState() {
    super.initState();
    decodeImageFromList(widget.bytes).then((i) {
      if (mounted) setState(() => _natural = Size(i.width.toDouble(), i.height.toDouble()));
      i.dispose();
    });
  }

  String t(String k) => widget.texts(k);

  Size get _turned {
    final n = _natural ?? const Size(1, 1);
    return _e.turns.isOdd ? Size(n.height, n.width) : n;
  }

  void _setRatio(double? r, {IdPhoto? id}) {
    setState(() {
      _ratio = r;
      _id = id;
      _e
        ..outW = id?.w ?? 0
        ..outH = id?.h ?? 0;
      if (r == null) return;
      final s = _turned;
      // The biggest box of that shape in the middle.
      final want = r * s.height / s.width; // width / height in 0–1 units
      final w = want <= 1 ? want : 1.0, h = want <= 1 ? 1.0 : 1 / want;
      _e.crop = Rect.fromLTWH((1 - w) / 2, (1 - h) / 2, w, h);
    });
  }

  Future<Uint8List?> _jpeg() async {
    setState(() => _busy = true);
    try {
      return await renderPhotoEdit(widget.bytes, _e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final fg = widget.dark ? Colors.white : const Color(0xFF16213E);
    final panel = widget.dark ? const Color(0xFF1D2633) : const Color(0xFFF1F4FA);
    Widget modeBtn(_Mode m, IconData icon, String label) => Padding(
          padding: const EdgeInsets.only(right: 6),
          child: ChoiceChip(
            selected: _mode == m,
            onSelected: (_) => setState(() => _mode = m),
            avatar: Icon(icon, size: 16),
            label: Text(label),
          ),
        );
    return Column(children: [
      Container(
        color: panel,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(children: [
            modeBtn(_Mode.crop, Icons.crop_rounded, t('crop')),
            modeBtn(_Mode.adjust, Icons.tune_rounded, t('adjust')),
            modeBtn(_Mode.mosaic, Icons.blur_on_rounded, t('mosaic')),
            modeBtn(_Mode.size, Icons.photo_size_select_large_rounded, t('size')),
            const SizedBox(width: 8),
            IconButton(
              tooltip: t('turn'),
              onPressed: () => setState(() {
                _e.turns = (_e.turns + 1) % 4;
                _e.crop = const Rect.fromLTWH(0, 0, 1, 1);
                _e.mosaic.clear();
                _ratio = null;
                _id = null;
                _e
                  ..outW = 0
                  ..outH = 0;
              }),
              icon: Icon(Icons.rotate_right_rounded, color: fg),
            ),
            IconButton(
              tooltip: t('reset'),
              onPressed: () => setState(() {
                _e
                  ..turns = 0
                  ..crop = const Rect.fromLTWH(0, 0, 1, 1)
                  ..brightness = 0
                  ..contrast = 0
                  ..saturation = 0
                  ..maxSide = 0
                  ..outW = 0
                  ..outH = 0;
                _e.mosaic.clear();
                _ratio = null;
                _id = null;
              }),
              icon: Icon(Icons.restart_alt_rounded, color: fg),
            ),
          ]),
        ),
      ),
      Expanded(
        child: LayoutBuilder(builder: (context, c) {
          final picture = _natural == null ? const Center(child: CircularProgressIndicator()) : _canvas();
          final side = Container(
            width: c.maxWidth < 640 ? double.infinity : 230,
            height: c.maxWidth < 640 ? 170 : double.infinity,
            color: panel,
            padding: const EdgeInsets.all(14),
            child: DefaultTextStyle(style: TextStyle(color: fg, fontSize: 13), child: _side(fg)),
          );
          // Narrow (a phone): the settings under the picture.
          return c.maxWidth < 640
              ? Column(children: [Expanded(child: picture), side])
              : Row(children: [Expanded(child: picture), side]);
        }),
      ),
      Container(
        color: panel,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Row(children: [
          if (_busy) ...[
            const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
            const SizedBox(width: 8),
            Text(t('saving'), style: TextStyle(color: fg)),
          ],
          const Spacer(),
          for (final (label, icon, run) in widget.extraActions)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: OutlinedButton.icon(
                onPressed: _busy
                    ? null
                    : () async {
                        final j = await _jpeg();
                        if (j != null) await run(j);
                      },
                icon: Icon(icon, size: 18),
                label: Text(label),
              ),
            ),
          FilledButton.icon(
            onPressed: _busy
                ? null
                : () async {
                    final j = await _jpeg();
                    if (j != null) await widget.onSave(j, _e);
                  },
            icon: const Icon(Icons.save_alt_rounded, size: 18),
            label: Text(t('save')),
          ),
        ]),
      ),
    ]);
  }

  Widget _side(Color fg) {
    Widget slider(String label, double v, void Function(double) set) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label),
          Slider(value: v, min: -0.5, max: 0.5, divisions: 40, onChanged: (x) => setState(() => set(x))),
        ]);
    switch (_mode) {
      case _Mode.crop:
        final s = _turned;
        final id = _id;
        return ListView(children: [
          Text(t('crop'), style: const TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 4),
          Text(t('crop_hint'), style: TextStyle(color: fg.withValues(alpha: 0.7), fontSize: 12, height: 1.45)),
          const SizedBox(height: 8),
          Wrap(spacing: 6, runSpacing: 6, children: [
            for (final (label, r) in [
              (t('free'), null),
              (t('original'), s.width / s.height),
              (t('square'), 1.0),
              ('4:3', 4 / 3),
              ('3:4', 3 / 4),
              ('16:9', 16 / 9),
              ('9:16', 9 / 16),
            ])
              ChoiceChip(selected: _id == null && _ratio == r, onSelected: (_) => _setRatio(r), label: Text(label)),
          ]),
          const SizedBox(height: 14),
          Text(t('id_photos'), style: const TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 6),
          for (final p in IdPhoto.all)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: ChoiceChip(selected: _id == p, onSelected: (_) => _setRatio(p.ratio, id: p), label: Text(t(p.key))),
            ),
          if (id != null) Text(t('id_hint'), style: TextStyle(color: fg.withValues(alpha: 0.7), fontSize: 12, height: 1.45)),
          const SizedBox(height: 12),
          Text('${(_e.crop.width * s.width).round()} × ${(_e.crop.height * s.height).round()}', style: TextStyle(color: fg.withValues(alpha: 0.7))),
          if (id != null) Text(t('out_size').replaceAll('{w}', '${id.w}').replaceAll('{h}', '${id.h}'), style: TextStyle(color: fg.withValues(alpha: 0.7))),
        ]);
      case _Mode.adjust:
        return ListView(children: [
          slider(t('brightness'), _e.brightness, (x) => _e.brightness = x),
          slider(t('contrast'), _e.contrast, (x) => _e.contrast = x),
          slider(t('saturation'), _e.saturation, (x) => _e.saturation = x),
        ]);
      case _Mode.mosaic:
        return ListView(children: [
          Text(t('mosaic_hint')),
          const SizedBox(height: 10),
          if (_e.mosaic.isNotEmpty) TextButton.icon(onPressed: () => setState(_e.mosaic.removeLast), icon: const Icon(Icons.undo_rounded), label: Text(t('undo'))),
        ]);
      case _Mode.size:
        final s = _turned;
        final long = math.max(_e.crop.width * s.width, _e.crop.height * s.height).round();
        return ListView(children: [
          Text(t('size_hint')),
          const SizedBox(height: 8),
          for (final m in [0, 4096, 2048, 1600, 1080, 800])
            if (m == 0 || m < long)
              RadioListTile<int>(
                dense: true,
                contentPadding: EdgeInsets.zero,
                value: m,
                groupValue: _e.maxSide,
                onChanged: (v) => setState(() => _e.maxSide = v ?? 0),
                title: Text(m == 0 ? '${t('original')} ($long)' : '$m', style: TextStyle(color: fg)),
              ),
          const SizedBox(height: 8),
          Text('JPEG ${_e.quality}%'),
          Slider(value: _e.quality.toDouble(), min: 50, max: 100, divisions: 10, onChanged: (v) => setState(() => _e.quality = v.round())),
        ]);
    }
  }

  String? _hoverGrab;

  static MouseCursor _cursorFor(String? g) => switch (g) {
        'move' => SystemMouseCursors.click,
        'lt' || 'rb' => SystemMouseCursors.resizeUpLeftDownRight,
        'rt' || 'lb' => SystemMouseCursors.resizeUpRightDownLeft,
        'l' || 'r' => SystemMouseCursors.resizeLeftRight,
        't' || 'b' => SystemMouseCursors.resizeUpDown,
        _ => SystemMouseCursors.precise,
      };

  /// What a press at [p] takes hold of: a corner, an edge (free shape
  /// only), the inside (move), or nothing (draw a new box).
  String _grabAt(Rect box, Offset p) {
    const near = 14.0;
    final l = (p.dx - box.left).abs() < near, r = (p.dx - box.right).abs() < near;
    final t = (p.dy - box.top).abs() < near, b = (p.dy - box.bottom).abs() < near;
    final inX = p.dx > box.left - near && p.dx < box.right + near, inY = p.dy > box.top - near && p.dy < box.bottom + near;
    if (inX && inY) {
      if ((l || r) && (t || b)) return '${l ? 'l' : 'r'}${t ? 't' : 'b'}';
      if (_ratio == null) {
        if (l || r) return l ? 'l' : 'r';
        if (t || b) return t ? 't' : 'b';
      }
      // The box is the whole picture (nothing chosen yet): a press inside
      // draws a new box; moving it could not go anywhere.
      final whole = _e.crop.width > 0.98 && _e.crop.height > 0.98;
      if (box.contains(p) && !whole) return 'move';
    }
    return 'new';
  }

  /// [from] with the [edges] moved by [d] (0–1 units), kept on the picture;
  /// a set shape keeps its shape (the corner opposite stays put).
  Rect _resized(Rect from, String edges, Offset d, Size s) {
    var l = from.left, t = from.top, r = from.right, b = from.bottom;
    if (edges.contains('l')) l = (l + d.dx).clamp(0.0, r - 0.02);
    if (edges.contains('r')) r = (r + d.dx).clamp(l + 0.02, 1.0);
    if (edges.contains('t')) t = (t + d.dy).clamp(0.0, b - 0.02);
    if (edges.contains('b')) b = (b + d.dy).clamp(t + 0.02, 1.0);
    final rt = _ratio;
    if (rt == null) return Rect.fromLTRB(l, t, r, b);
    // Width decides; the height follows; both shrink if it would not fit.
    final want = rt * s.height / s.width; // width / height in 0–1 units
    var w = r - l, h = w / want;
    final room = edges.contains('t') ? from.bottom : 1 - from.top;
    if (h > room) {
      h = room;
      w = h * want;
    }
    final left = edges.contains('l') ? from.right - w : from.left;
    final top = edges.contains('t') ? from.bottom - h : from.top;
    return Rect.fromLTWH(left, top, w, h);
  }

  Widget _canvas() => LayoutBuilder(builder: (context, c) {
        final s = _turned;
        final k = math.min((c.maxWidth - 32) / s.width, (c.maxHeight - 32) / s.height);
        final shown = Size(s.width * k, s.height * k);
        final pic = RotatedBox(
          quarterTurns: _e.turns,
          child: ColorFiltered(colorFilter: photoEditFilter(_e), child: Image.memory(widget.bytes, fit: BoxFit.fill, gaplessPlayback: true)),
        );
        Rect toPx(Rect r) => Rect.fromLTWH(r.left * shown.width, r.top * shown.height, r.width * shown.width, r.height * shown.height);
        Offset norm(Offset p) => Offset((p.dx / shown.width).clamp(0.0, 1.0), (p.dy / shown.height).clamp(0.0, 1.0));
        return Center(
          child: SizedBox(
            width: shown.width,
            height: shown.height,
            child: GestureDetector(
              onPanStart: (d) {
                if (_mode == _Mode.mosaic) setState(() => _dragStart = norm(d.localPosition));
                if (_mode == _Mode.crop) {
                  _dragStart = norm(d.localPosition);
                  _grab = _grabAt(toPx(_e.crop), d.localPosition);
                  _grabFrom = _e.crop;
                }
              },
              onPanUpdate: (d) {
                final p = norm(d.localPosition), a = _dragStart;
                if (a == null) return;
                if (_mode == _Mode.mosaic) setState(() => _drawing = Rect.fromPoints(a, p));
                if (_mode == _Mode.crop && _grab != 'move' && _grab != 'new' && _grab != null) {
                  setState(() => _e.crop = _resized(_grabFrom, _grab!, p - a, s));
                  return;
                }
                if (_mode == _Mode.crop) {
                  // Move the box when dragging inside it, else draw a new one.
                  final r = _e.crop;
                  if (_grab == 'move' && _drawing == null) {
                    final delta = p - a;
                    _dragStart = p;
                    setState(() => _e.crop = r.shift(delta).translate(
                          r.shift(delta).left < 0 ? -r.shift(delta).left : (r.shift(delta).right > 1 ? 1 - r.shift(delta).right : 0),
                          r.shift(delta).top < 0 ? -r.shift(delta).top : (r.shift(delta).bottom > 1 ? 1 - r.shift(delta).bottom : 0),
                        ));
                  } else {
                    var box = Rect.fromPoints(a, p);
                    final rt = _ratio;
                    if (rt != null) {
                      final want = rt * s.height / s.width;
                      // From where the drag began, toward the pointer; the
                      // shape kept, shrunk to stay on the picture.
                      var w = box.width, h = w / want;
                      final down = p.dy >= a.dy, right = p.dx >= a.dx;
                      final roomH = down ? 1 - a.dy : a.dy, roomW = right ? 1 - a.dx : a.dx;
                      if (h > roomH) {
                        h = roomH;
                        w = h * want;
                      }
                      if (w > roomW) {
                        w = roomW;
                        h = w / want;
                      }
                      box = Rect.fromLTWH(right ? a.dx : a.dx - w, down ? a.dy : a.dy - h, w, h);
                    }
                    _drawing = box;
                    setState(() => _e.crop = box);
                  }
                }
              },
              onPanEnd: (_) {
                final r = _drawing;
                setState(() {
                  if (_mode == _Mode.mosaic && r != null && r.width > 0.01 && r.height > 0.01) _e.mosaic.add(r);
                  if (_mode == _Mode.crop && (_e.crop.width < 0.02 || _e.crop.height < 0.02)) _e.crop = const Rect.fromLTWH(0, 0, 1, 1);
                  _drawing = null;
                  _dragStart = null;
                  _grab = null;
                });
              },
              child: Stack(children: [
                Positioned.fill(child: pic),
                for (final m in [..._e.mosaic, if (_mode == _Mode.mosaic && _drawing != null) _drawing!])
                  Positioned.fromRect(rect: toPx(m), child: const _Squares()),
                if (_mode == _Mode.crop) Positioned.fill(child: CustomPaint(painter: _CropShade(toPx(_e.crop), id: _id))),
                // Where the pointer can grab the box.
                if (_mode == _Mode.crop)
                  Positioned.fill(
                    child: MouseRegion(
                      cursor: _cursorFor(_hoverGrab),
                      onHover: (h) {
                        final g = _grabAt(toPx(_e.crop), h.localPosition);
                        if (g != _hoverGrab) setState(() => _hoverGrab = g);
                      },
                    ),
                  ),
              ]),
            ),
          ),
        );
      });
}

class _Squares extends StatelessWidget {
  const _Squares();

  @override
  Widget build(BuildContext context) => CustomPaint(painter: _SquaresPaint());
}

class _SquaresPaint extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    const n = 10.0;
    final p = Paint();
    for (var y = 0.0; y < size.height; y += n) {
      for (var x = 0.0; x < size.width; x += n) {
        p.color = ((x + y) ~/ n).isEven ? const Color(0xFF8A8F98) : const Color(0xFFB5BAC2);
        canvas.drawRect(Rect.fromLTWH(x, y, math.min(n, size.width - x), math.min(n, size.height - y)), p);
      }
    }
  }

  @override
  bool shouldRepaint(_SquaresPaint old) => false;
}

class _CropShade extends CustomPainter {
  _CropShade(this.box, {this.id});

  final Rect box;

  /// An ID photo: where the head goes (an oval, top of head to chin).
  final IdPhoto? id;

  @override
  void paint(Canvas canvas, Size size) {
    final outside = Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(Offset.zero & size)
      ..addRect(box);
    canvas.drawPath(outside, Paint()..color = const Color(0x88000000));
    canvas.drawRect(
        box,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..color = Colors.white);
    final thirds = Paint()
      ..color = Colors.white38
      ..strokeWidth = 1;
    for (var i = 1; i < 3; i++) {
      canvas.drawLine(Offset(box.left + box.width * i / 3, box.top), Offset(box.left + box.width * i / 3, box.bottom), thirds);
      canvas.drawLine(Offset(box.left, box.top + box.height * i / 3), Offset(box.right, box.top + box.height * i / 3), thirds);
    }
    // Handles: the corners (and the middle of each side).
    final grip = Paint()
      ..color = Colors.white
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.round;
    const k = 16.0;
    for (final (x, y, dx, dy) in [
      (box.left, box.top, 1.0, 1.0),
      (box.right, box.top, -1.0, 1.0),
      (box.left, box.bottom, 1.0, -1.0),
      (box.right, box.bottom, -1.0, -1.0),
    ]) {
      canvas.drawLine(Offset(x, y), Offset(x + dx * k, y), grip);
      canvas.drawLine(Offset(x, y), Offset(x, y + dy * k), grip);
    }
    if (id == null) {
      for (final (a, b) in [
        (Offset(box.center.dx - 10, box.top), Offset(box.center.dx + 10, box.top)),
        (Offset(box.center.dx - 10, box.bottom), Offset(box.center.dx + 10, box.bottom)),
        (Offset(box.left, box.center.dy - 10), Offset(box.left, box.center.dy + 10)),
        (Offset(box.right, box.center.dy - 10), Offset(box.right, box.center.dy + 10)),
      ]) {
        canvas.drawLine(a, b, grip);
      }
    }
    final p = id;
    if (p != null) {
      // The head: as tall as the middle of what is allowed, a little above
      // the middle; the band where the chin may be.
      final hh = box.height * (p.headFrom + p.headTo) / 2;
      final top = box.top + box.height * 0.1;
      final oval = Rect.fromCenter(center: Offset(box.center.dx, top + hh / 2), width: hh * 0.74, height: hh);
      canvas.drawOval(
          oval,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2
            ..color = const Color(0xCC4ADE80));
      final band = Paint()..color = const Color(0x334ADE80);
      canvas.drawRect(Rect.fromLTRB(box.left, top + box.height * p.headFrom, box.right, top + box.height * p.headTo), band);
      canvas.drawLine(
          Offset(box.left, top),
          Offset(box.right, top),
          Paint()
            ..color = const Color(0xCC4ADE80)
            ..strokeWidth = 1);
    }
  }

  @override
  bool shouldRepaint(_CropShade old) => old.box != box || old.id != id;
}
