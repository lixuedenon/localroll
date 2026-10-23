// apps/desktop/test/face_math_test.dart
//
// The arithmetic around the face models gives what the Python reference
// gives (which matched OpenCV's own face finder / reader: same boxes, and
// 0.99+ alike face numbers on test photos).
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:localroll_desktop/services/face_math.dart';

void main() {
  final fx = jsonDecode(File('test/fixtures/face_math.json').readAsStringSync()) as Map<String, dynamic>;
  final w = fx['w'] as int, h = fx['h'] as int;
  final rgb = Uint8List.fromList((fx['rgb'] as List).cast<int>());

  test('picture made ready for the face finder', () {
    final (input, scale) = FaceMath.detectInput(rgb, w, h);
    expect(scale, closeTo((fx['scale'] as num).toDouble(), 1e-9));
    for (final s in (fx['detect'] as List).cast<List>()) {
      expect(input[s[0] as int], closeTo((s[1] as num).toDouble(), 0.01), reason: 'at ${s[0]}');
    }
    var sum = 0.0;
    for (final v in input) {
      sum += v;
    }
    expect(sum, closeTo((fx['detectSum'] as num).toDouble(), 5));
  });

  test('a face turned upright', () {
    final pts = (fx['points'] as List).map((e) => (e as num).toDouble()).toList();
    final m = FaceMath.similarity(pts);
    final want = (fx['m'] as List).map((e) => (e as num).toDouble()).toList();
    for (var i = 0; i < 4; i++) {
      expect(m[i], closeTo(want[i], 1e-6));
    }
    final up = FaceMath.upright(rgb, w, h, m);
    for (final s in (fx['upright'] as List).cast<List>()) {
      expect(up[s[0] as int], closeTo((s[1] as num).toDouble(), 0.01), reason: 'at ${s[0]}');
    }
  });

  test('the template put onto itself: no change', () {
    final m = FaceMath.similarity(FaceMath.template);
    expect(m[0], closeTo(1, 1e-9));
    expect(m[1], closeTo(0, 1e-9));
    expect(m[2], closeTo(0, 1e-6));
    expect(m[3], closeTo(0, 1e-6));
  });

  test('the finder\'s answers become faces; overlaps go', () {
    Map<String, Float32List> empty() => {
          for (final st in [8, 16, 32]) ...{
            'cls_$st': Float32List((640 ~/ st) * (640 ~/ st)),
            'obj_$st': Float32List((640 ~/ st) * (640 ~/ st)),
            'bbox_$st': Float32List((640 ~/ st) * (640 ~/ st) * 4),
            'kps_$st': Float32List((640 ~/ st) * (640 ~/ st) * 10),
          },
        };
    final out = empty();
    // Step 32, row 3, column 5: a 64×96 face centred at (5.5·32, 3.25·32).
    const i = 3 * 20 + 5;
    out['cls_32']![i] = 0.95;
    out['obj_32']![i] = 0.95;
    out['bbox_32']!.setAll(i * 4, [0.5, 0.25, math.log(2), math.log(3)]);
    out['kps_32']!.setAll(i * 10, [0.2, 0.1, 0.8, 0.1, 0.5, 0.4, 0.3, 0.7, 0.7, 0.7]);
    // The same face seen at step 16, a little less sure: removed.
    const j = 6 * 40 + 11;
    out['cls_16']![j] = 0.9;
    out['obj_16']![j] = 0.9;
    out['bbox_16']!.setAll(j * 4, [0.0, 0.5, math.log(4), math.log(6)]);
    // Unsure: left out.
    out['cls_8']![10] = 0.5;
    out['obj_8']![10] = 0.5;
    final faces = FaceMath.decode(out);
    expect(faces, hasLength(1));
    final f = faces.single;
    expect(f.score, closeTo(0.95, 1e-6));
    expect(f.x, closeTo(5.5 * 32 - 32, 1e-3));
    expect(f.y, closeTo(3.25 * 32 - 48, 1e-3));
    expect(f.w, closeTo(64, 1e-3));
    expect(f.h, closeTo(96, 1e-3));
    expect(f.points[0], closeTo(5.2 * 32, 1e-3));
    expect(f.points[1], closeTo(3.1 * 32, 1e-3));
  });

  test('PPM pictures from ffmpeg', () {
    final b = BytesBuilder()
      ..add(ascii.encode('P6\n# made by ffmpeg\n2 1\n255\n'))
      ..add([1, 2, 3, 4, 5, 6]);
    final (pw, ph, px) = FaceMath.readPpm(b.toBytes())!;
    expect((pw, ph), (2, 1));
    expect(px, [1, 2, 3, 4, 5, 6]);
    expect(FaceMath.readPpm(Uint8List.fromList(ascii.encode('P6\n2 2\n255\n'))), isNull);
  });
}
