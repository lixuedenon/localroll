// packages/ink/lib/src/stamp.dart
import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

/// One piece of a stamp's picture, in the stamp's own box (0–1 across and
/// down): filled outlines, lines, or a word.
class StampPart {
  const StampPart({this.polys = const [], this.fill = true, this.w = 0.06, this.color, this.role, this.text, this.at = const Offset(0.5, 0.5), this.size = 0.5});

  /// Outlines / lines (several: holes, or separate strokes).
  final List<List<Offset>> polys;
  final bool fill;

  /// Line width, part of the box's height.
  final double w;

  /// Its own colour (null: the colour chosen when drawing).
  final int? color;

  /// 'u' rising / 'd' falling colour (candles), set when it is placed.
  final String? role;

  /// A word drawn at [at] (its middle), [size] high (part of the box).
  final String? text;
  final Offset at;
  final double size;

  StampPart withColor(int c) => StampPart(polys: polys, fill: fill, w: w, color: c, text: text, at: at, size: size);

  Map<String, dynamic> toJson() => {
        if (polys.isNotEmpty) 'd': [for (final p in polys) [for (final o in p) ...[_r(o.dx), _r(o.dy)]]],
        if (!fill) 'f': 0,
        if (!fill) 'w': _r(w),
        'c': ?color,
        'ro': ?role,
        if (text != null) ...{'t': text, 'x': _r(at.dx), 'y': _r(at.dy), 's': _r(size)},
      };

  static StampPart fromJson(Map<String, dynamic> j) => StampPart(
        polys: [
          for (final p in (j['d'] as List?) ?? const [])
            [for (var i = 0; i + 1 < (p as List).length; i += 2) Offset((p[i] as num).toDouble(), (p[i + 1] as num).toDouble())],
        ],
        fill: j['f'] != 0,
        w: (j['w'] as num?)?.toDouble() ?? 0.06,
        color: (j['c'] as num?)?.toInt(),
        role: j['ro'] as String?,
        text: j['t'] as String?,
        at: Offset((j['x'] as num?)?.toDouble() ?? 0.5, (j['y'] as num?)?.toDouble() ?? 0.5),
        size: (j['s'] as num?)?.toDouble() ?? 0.5,
      );

  static double _r(double v) => (v * 1000).roundToDouble() / 1000;
}

/// A stamp's whole picture: parts in a box [aspect] wide for 1 high, or a
/// picture ([png], base64) for stamps made from an image.
class StampShape {
  const StampShape({required this.aspect, this.parts = const [], this.png});

  final double aspect;
  final List<StampPart> parts;
  final String? png;

  /// Rising / falling parts get their colours (when placed).
  StampShape resolved(int up, int down) => StampShape(
        aspect: aspect,
        png: png,
        parts: [for (final p in parts) p.role == null ? p : p.withColor(p.role == 'u' ? up : down)],
      );

  Map<String, dynamic> toJson() => {
        'a': (aspect * 1000).roundToDouble() / 1000,
        if (parts.isNotEmpty) 'p': [for (final p in parts) p.toJson()],
        'png': ?png,
      };

  static StampShape fromJson(Map<String, dynamic> j) => StampShape(
        aspect: (j['a'] as num?)?.toDouble() ?? 1,
        parts: [for (final p in (j['p'] as List?) ?? const []) StampPart.fromJson((p as Map).cast<String, dynamic>())],
        png: j['png'] as String?,
      );

  /// Where it sits in [box]: as large as fits, its own proportions, in the middle.
  Rect fit(Rect box) {
    if (box.isEmpty) return box;
    final w = math.min(box.width, box.height * aspect);
    final h = w / aspect;
    return Rect.fromCenter(center: box.center, width: w, height: h);
  }

  /// Draws it in [box] ([color]: for the parts without their own).
  void paint(Canvas c, Rect box, int color) {
    final r = fit(box);
    if (r.isEmpty) return;
    final b64 = png;
    if (b64 != null) {
      final img = StampImages.get(b64);
      if (img != null) {
        c.drawImageRect(img, Rect.fromLTWH(0, 0, img.width.toDouble(), img.height.toDouble()), r,
            Paint()..filterQuality = FilterQuality.medium);
      }
    }
    Offset at(Offset o) => Offset(r.left + o.dx * r.width, r.top + o.dy * r.height);
    for (final p in parts) {
      final col = Color(p.color ?? color);
      if (p.text != null) {
        final tp = TextPainter(
          text: TextSpan(text: p.text, style: TextStyle(color: col, fontSize: math.max(4.0, p.size * r.height), fontWeight: FontWeight.w800, height: 1)),
          textDirection: TextDirection.ltr,
        )..layout();
        tp.paint(c, at(p.at) - Offset(tp.width / 2, tp.height / 2));
        continue;
      }
      final path = Path();
      for (final poly in p.polys) {
        if (poly.isEmpty) continue;
        path.addPolygon([for (final o in poly) at(o)], p.fill);
      }
      if (p.fill) {
        c.drawPath(path, Paint()..color = col);
      } else {
        c.drawPath(
            path,
            Paint()
              ..color = col
              ..style = PaintingStyle.stroke
              ..strokeWidth = math.max(1.0, p.w * r.height)
              ..strokeCap = StrokeCap.round
              ..strokeJoin = StrokeJoin.round);
      }
    }
  }

  /// As a picture, [px] on its long side (for the screen pen), PNG.
  Future<Uint8List?> toPng(int color, {int px = 512}) async {
    if (png != null) await StampImages.load(png!);
    final w = aspect >= 1 ? px : math.max(8, (px * aspect).round());
    final h = aspect >= 1 ? math.max(8, (px / aspect).round()) : px;
    final rec = ui.PictureRecorder();
    paint(Canvas(rec), Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()), color);
    final img = await rec.endRecording().toImage(w, h);
    final data = await img.toByteData(format: ui.ImageByteFormat.png);
    img.dispose();
    return data?.buffer.asUint8List();
  }
}

/// Stamps made from pictures: decoded once, kept while LocalRoll runs.
class StampImages {
  static final Map<String, ui.Image> _done = {};
  static final Map<String, Future<void>> _loading = {};

  /// Ticks when one more is ready (painters repaint).
  static final ValueNotifier<int> loaded = ValueNotifier(0);

  /// Ready now, or null (then it is decoded and [loaded] ticks).
  static ui.Image? get(String b64) {
    final img = _done[b64];
    if (img == null) unawaited(load(b64));
    return img;
  }

  static Future<void> load(String b64) => _done.containsKey(b64)
      ? Future.value()
      : _loading.putIfAbsent(b64, () async {
          try {
            final codec = await ui.instantiateImageCodec(base64Decode(b64));
            final f = await codec.getNextFrame();
            _done[b64] = f.image;
            loaded.value++;
          } catch (_) {}
        });
}
