// apps/desktop/test/picture_index_test.dart
//
// Picture search: the numbers are kept with the library, read back the same,
// and the closest items come first.
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:localroll_desktop/services/library_index.dart';
import 'package:localroll_desktop/services/picture_index.dart';

Float32List unit(List<double> head) {
  final v = Float32List(PictureIndex.dim);
  for (var i = 0; i < head.length; i++) {
    v[i] = head[i];
  }
  var n = 0.0;
  for (final x in v) {
    n += x * x;
  }
  n = math.sqrt(n);
  for (var i = 0; i < v.length; i++) {
    v[i] /= n == 0 ? 1 : n;
  }
  return v;
}

void main() {
  late Directory tmp;
  late LibraryIndex lib;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('lr_pic_test');
    lib = LibraryIndex('${tmp.path}${Platform.pathSeparator}Library', stateFile: File('${tmp.path}${Platform.pathSeparator}s.json'));
    await lib.load();
  });

  tearDown(() async {
    lib.dispose();
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  test('closest first; far-off ones and empty marks are left out', () async {
    final idx = PictureIndex(lib);
    await idx.load();
    idx.put('dog', unit([1, 0.1, 0]));
    idx.put('dog2', unit([0.95, 0.2, 0]));
    idx.put('car', unit([0, 0, 1]));
    idx.put('broken', Float32List(PictureIndex.dim));
    final r = idx.search(unit([1, 0, 0]));
    expect(r.map((e) => e.$1), ['dog', 'dog2']);
    expect(r.first.$2, closeTo(0.995, 0.01));
    idx.dispose();
  });

  test('kept in the library folder and read back the same', () async {
    final idx = PictureIndex(lib);
    await idx.load();
    idx.put('m:2026/10/a.jpg|10', unit([0.3, -0.7, 0.2, 0.5]));
    idx.put('f:scan.jpg|5', unit([0, 1]));
    await idx.save();
    idx.dispose();
    final again = PictureIndex(lib);
    await again.load();
    expect(again.count, 2);
    expect(again.has('m:2026/10/a.jpg|10'), isTrue);
    final r = again.search(unit([0.3, -0.7, 0.2, 0.5]));
    expect(r.first.$1, 'm:2026/10/a.jpg|10');
    expect(r.first.$2, closeTo(1, 0.01));
    again.prune({'f:scan.jpg|5'});
    expect(again.count, 1);
    again.dispose();
  });
}
