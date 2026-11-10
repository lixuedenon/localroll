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

  bool get changed =>
      turns % 4 != 0 || crop != const Rect.fromLTWH(0, 0, 1, 1) || brightness != 0 || contrast != 0 || saturation != 0 || mosaic.isNotEmpty || maxSide > 0;
}

/// The photo with [edit] done, as a JPEG (in the background: big photos take
/// a moment).
Future<Uint8List?> renderPhotoEdit(Uint8List source, PhotoEdit edit) => compute(_render, (source, edit.turns, edit.crop, edit.brightness, edit.contrast, edit.saturation, List<Rect>.of(edit.mosaic), edit.maxSide, edit.quality));

Uint8List? _render((Uint8List, int, Rect, double, double, double, List<Rect>, int, int) a) {
  final (bytes, turns, crop, br, co, sa, mosaic, maxSide, quality) = a;
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
    im = img.adjustColor(im, brightness: 1 + br, contrast: 1 + co, saturation: 1 + sa);
  }
  if (maxSide > 0 && math.max(im.width, im.height) > maxSide) {
    im = im.width >= im.height
        ? img.copyResize(im, width: maxSide, interpolation: img.Interpolation.average)
        : img.copyResize(im, height: maxSide, interpolation: img.Interpolation.average);
  }
  return img.encodeJpg(im, quality: quality);
}

/// The colour change as the screen shows it meanwhile (close to the saved one).
ColorFilter photoEditFilter(PhotoEdit e) {
  final b = e.brightness * 255 * 0.6;
  final c = 1 + e.contrast;
  final s = 1 + e.saturation;
  const lr = 0.2126, lg = 0.7152, lb = 0.0722;
  final sr = (1 - s) * lr, sg = (1 - s) * lg, sb = (1 - s) * lb;
  final t = (1 - c) * 128 + b;
  return ColorFilter.matrix([
    c * (sr + s), c * sg, c * sb, 0, t, //
    c * sr, c * (sg + s), c * sb, 0, t,
    c * sr, c * sg, c * (sb + s), 0, t,
    0, 0, 0, 1, 0,
  ]);
}

enum _Mode { crop, adjust, mosaic, size }

/// The photo editor: crop (with set shapes), turn, colour, squares over
/// what should not be seen, smaller. Saving is the app's ([onSave] gets the
/// JPEG). [texts] keys: crop, turn, adjust, mosaic, size, brightness,
/// contrast, saturation, free, square, original, undo, reset, save, saving,
/// mosaic_hint, size_hint, cancel.
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

  void _setRatio(double? r) {
    setState(() {
      _ratio = r;
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
                  ..maxSide = 0;
                _e.mosaic.clear();
                _ratio = null;
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
        return ListView(children: [
          Text(t('crop'), style: const TextStyle(fontWeight: FontWeight.w700)),
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
              ChoiceChip(selected: _ratio == r, onSelected: (_) => _setRatio(r), label: Text(label)),
          ]),
          const SizedBox(height: 12),
          Text('${(_e.crop.width * s.width).round()} × ${(_e.crop.height * s.height).round()}', style: TextStyle(color: fg.withValues(alpha: 0.7))),
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
                if (_mode == _Mode.crop) _dragStart = norm(d.localPosition);
              },
              onPanUpdate: (d) {
                final p = norm(d.localPosition), a = _dragStart;
                if (a == null) return;
                if (_mode == _Mode.mosaic) setState(() => _drawing = Rect.fromPoints(a, p));
                if (_mode == _Mode.crop) {
                  // Move the box when dragging inside it, else draw a new one.
                  final r = _e.crop;
                  if (r.contains(a) && _drawing == null) {
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
                      final w = box.width, h = w / want;
                      box = Rect.fromLTWH(box.left, box.top, w, math.min(h, 1 - box.top));
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
                });
              },
              child: Stack(children: [
                Positioned.fill(child: pic),
                for (final m in [..._e.mosaic, if (_mode == _Mode.mosaic && _drawing != null) _drawing!])
                  Positioned.fromRect(rect: toPx(m), child: const _Squares()),
                if (_mode == _Mode.crop) Positioned.fill(child: CustomPaint(painter: _CropShade(toPx(_e.crop)))),
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
  _CropShade(this.box);

  final Rect box;

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
  }

  @override
  bool shouldRepaint(_CropShade old) => old.box != box;
}
