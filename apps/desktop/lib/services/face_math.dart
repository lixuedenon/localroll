// apps/desktop/lib/services/face_math.dart
import 'dart:math' as math;
import 'dart:typed_data';

/// The arithmetic around the two face models, kept apart (no model needed)
/// so it can be checked: the picture made ready for the face finder (YuNet,
/// 640×640), what it answers turned into faces, and each face turned
/// upright to 112×112 for the face reader (SFace), the way OpenCV does.

/// A face found: how sure (0–1), where (pixels of the picture given), and
/// the five points: eyes, nose tip, mouth corners (left to right as seen).
class FoundFace {
  const FoundFace(this.score, this.x, this.y, this.w, this.h, this.points);

  final double score;
  final double x, y, w, h;

  /// x0, y0, x1, y1 … (10 numbers).
  final List<double> points;

  FoundFace scaled(double s) => FoundFace(score, x * s, y * s, w * s, h * s, [for (final p in points) p * s]);
}

class FaceMath {
  static const int detectSize = 640;
  static const int faceSize = 112;

  /// Where the five points sit in a 112×112 upright face (the reader was
  /// trained on faces placed like this).
  static const List<double> template = [
    38.2946, 51.6963, 73.5318, 51.5014, 56.0252, 71.7366, 41.5493, 92.3655, 70.7299, 92.2041, //
  ];

  /// RGB bytes ([w]×[h]) → the finder's input: fitted into 640×640 (the
  /// rest black, at the right / bottom), blue-green-red, channels first,
  /// 0–255. Returns it and the scale used.
  static (Float32List, double) detectInput(Uint8List rgb, int w, int h) {
    const n = detectSize;
    final s = n / math.max(w, h);
    final nw = math.min(n, (w * s).round());
    final nh = math.min(n, (h * s).round());
    final out = Float32List(3 * n * n);
    const plane = n * n;
    // Bilinear, pixel centres lined up (like OpenCV's resize).
    final sx = w / nw, sy = h / nh;
    for (var y = 0; y < nh; y++) {
      final fy = math.max(0.0, (y + 0.5) * sy - 0.5);
      final y0 = math.min(fy.floor(), h - 1);
      final y1 = math.min(y0 + 1, h - 1);
      final dy = fy - y0;
      for (var x = 0; x < nw; x++) {
        final fx = math.max(0.0, (x + 0.5) * sx - 0.5);
        final x0 = math.min(fx.floor(), w - 1);
        final x1 = math.min(x0 + 1, w - 1);
        final dx = fx - x0;
        final a = (y0 * w + x0) * 3, b = (y0 * w + x1) * 3, c = (y1 * w + x0) * 3, d = (y1 * w + x1) * 3;
        final o = y * n + x;
        for (var ch = 0; ch < 3; ch++) {
          final v = (rgb[a + ch] * (1 - dx) + rgb[b + ch] * dx) * (1 - dy) + (rgb[c + ch] * (1 - dx) + rgb[d + ch] * dx) * dy;
          // Blue first.
          out[(2 - ch) * plane + o] = v;
        }
      }
    }
    return (out, s);
  }

  /// The finder's answers (per step 8 / 16 / 32: cls, obj, bbox ×4, kps
  /// ×10, flat) → faces at least [minScore] sure, overlaps removed, in the
  /// 640×640 picture's pixels, surest first.
  static List<FoundFace> decode(Map<String, Float32List> out, {double minScore = 0.8, double overlap = 0.3}) {
    final faces = <FoundFace>[];
    for (final st in const [8, 16, 32]) {
      final cols = detectSize ~/ st;
      final cls = out['cls_$st'], obj = out['obj_$st'], bb = out['bbox_$st'], kp = out['kps_$st'];
      if (cls == null || obj == null || bb == null || kp == null) continue;
      for (var i = 0; i < cls.length; i++) {
        final score = math.sqrt(cls[i].clamp(0.0, 1.0) * obj[i].clamp(0.0, 1.0));
        if (score < minScore) continue;
        final r = i ~/ cols, c = i % cols;
        final cx = (c + bb[i * 4]) * st, cy = (r + bb[i * 4 + 1]) * st;
        final w = math.exp(bb[i * 4 + 2]) * st, h = math.exp(bb[i * 4 + 3]) * st;
        faces.add(FoundFace(score, cx - w / 2, cy - h / 2, w, h, [
          for (var k = 0; k < 5; k++) ...[(c + kp[i * 10 + 2 * k]) * st, (r + kp[i * 10 + 2 * k + 1]) * st],
        ]));
      }
    }
    faces.sort((a, b) => b.score.compareTo(a.score));
    final kept = <FoundFace>[];
    for (final f in faces) {
      if (kept.every((k) => _iou(f, k) < overlap)) kept.add(f);
    }
    return kept;
  }

  static double _iou(FoundFace a, FoundFace b) {
    final x1 = math.max(a.x, b.x), y1 = math.max(a.y, b.y);
    final x2 = math.min(a.x + a.w, b.x + b.w), y2 = math.min(a.y + a.h, b.y + b.h);
    final i = math.max(0.0, x2 - x1) * math.max(0.0, y2 - y1);
    final u = a.w * a.h + b.w * b.h - i;
    return u <= 0 ? 0 : i / u;
  }

  /// The turn + size + shift that best puts [points] onto [template]
  /// (no mirroring): x' = a·x − b·y + tx, y' = b·x + a·y + ty.
  static List<double> similarity(List<double> points, [List<double> to = template]) {
    const n = 5;
    var msx = 0.0, msy = 0.0, mdx = 0.0, mdy = 0.0;
    for (var i = 0; i < n; i++) {
      msx += points[2 * i];
      msy += points[2 * i + 1];
      mdx += to[2 * i];
      mdy += to[2 * i + 1];
    }
    msx /= n;
    msy /= n;
    mdx /= n;
    mdy /= n;
    var v = 0.0, c00 = 0.0, c11 = 0.0, c10 = 0.0, c01 = 0.0;
    for (var i = 0; i < n; i++) {
      final sx = points[2 * i] - msx, sy = points[2 * i + 1] - msy;
      final dx = to[2 * i] - mdx, dy = to[2 * i + 1] - mdy;
      v += sx * sx + sy * sy;
      c00 += dx * sx;
      c11 += dy * sy;
      c10 += dy * sx;
      c01 += dx * sy;
    }
    final p = c00 + c11, q = c10 - c01;
    final norm = math.sqrt(p * p + q * q);
    if (v == 0 || norm == 0) return const [1, 0, 0, 0];
    final scale = norm / v;
    final a = p / norm * scale, b = q / norm * scale;
    return [a, b, mdx - (a * msx - b * msy), mdy - (b * msx + a * msy)];
  }

  /// The face turned upright: 112×112, red-green-blue, channels first,
  /// 0–255 (what the reader takes). Outside the picture: black.
  static Float32List upright(Uint8List rgb, int w, int h, List<double> m) {
    const n = faceSize;
    final a = m[0], b = m[1], tx = m[2], ty = m[3];
    // Inverse of [[a, −b], [b, a]].
    final det = a * a + b * b;
    final ia = a / det, ib = b / det;
    final out = Float32List(3 * n * n);
    const plane = n * n;
    for (var y = 0; y < n; y++) {
      for (var x = 0; x < n; x++) {
        final u = x - tx, v = y - ty;
        final sx = ia * u + ib * v, sy = -ib * u + ia * v;
        final x0 = sx.floor(), y0 = sy.floor();
        final fx = sx - x0, fy = sy - y0;
        final o = y * n + x;
        for (var ch = 0; ch < 3; ch++) {
          double px(int xx, int yy) => xx < 0 || yy < 0 || xx >= w || yy >= h ? 0 : rgb[(yy * w + xx) * 3 + ch].toDouble();
          out[ch * plane + o] = px(x0, y0) * (1 - fx) * (1 - fy) +
              px(x0 + 1, y0) * fx * (1 - fy) +
              px(x0, y0 + 1) * (1 - fx) * fy +
              px(x0 + 1, y0 + 1) * fx * fy;
        }
      }
    }
    return out;
  }

  /// Length 1.
  static Float32List unit(Float32List v) {
    var s = 0.0;
    for (final x in v) {
      s += x * x;
    }
    s = math.sqrt(s);
    if (s == 0) return v;
    return Float32List.fromList([for (final x in v) x / s]);
  }

  /// A PPM picture (P6, 8 bits) → its size and RGB bytes.
  static (int, int, Uint8List)? readPpm(Uint8List b) {
    var at = 0;
    String token() {
      // Spaces and # comments between header fields.
      while (at < b.length) {
        if (b[at] == 0x23) {
          while (at < b.length && b[at] != 0x0A) {
            at++;
          }
        } else if (b[at] <= 0x20) {
          at++;
        } else {
          break;
        }
      }
      final start = at;
      while (at < b.length && b[at] > 0x20) {
        at++;
      }
      return String.fromCharCodes(b.sublist(start, at));
    }

    if (token() != 'P6') return null;
    final w = int.tryParse(token()), h = int.tryParse(token()), max = int.tryParse(token());
    if (w == null || h == null || max != 255 || w <= 0 || h <= 0) return null;
    at++; // the one space after the header
    if (b.length - at < w * h * 3) return null;
    return (w, h, Uint8List.sublistView(b, at, at + w * h * 3));
  }
}
