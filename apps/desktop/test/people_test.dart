// apps/desktop/test/people_test.dart
//
// People: faces grouped by person, names, merging, "not this person",
// searching by name, and that it is all kept with the library.
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:localroll_desktop/services/face_engine.dart';
import 'package:localroll_desktop/services/library_index.dart';
import 'package:localroll_desktop/services/people.dart';

/// A made-up face: [who]'s direction plus a little of [noise]'s.
FaceRead face(int who, {int noise = 0, double x = 0.1}) {
  final v = Float32List(128);
  v[who] = 1;
  if (noise > 0) v[100 + noise % 20] = 0.3;
  var n = 0.0;
  for (final e in v) {
    n += e * e;
  }
  n = math.sqrt(n);
  for (var i = 0; i < v.length; i++) {
    v[i] /= n;
  }
  return FaceRead(0.9, x, 0.2, 0.2, 0.3, v);
}

void main() {
  late Directory tmp;
  late LibraryIndex lib;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('lr_people_test');
    lib = LibraryIndex('${tmp.path}${Platform.pathSeparator}Library', stateFile: File('${tmp.path}${Platform.pathSeparator}s.json'));
    await lib.load();
  });

  tearDown(() async {
    lib.dispose();
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  test('the same face in several photos is one person; two in one photo are two', () async {
    final p = PeopleIndex(lib);
    await p.load();
    p.put('m:a.jpg|1', [face(1)]);
    p.put('m:b.jpg|1', [face(1, noise: 1), face(2, x: 0.6)]);
    p.put('m:c.jpg|1', [face(2, noise: 2)]);
    p.put('m:d.jpg|1', const []);
    final people = p.people();
    expect(people, hasLength(2));
    expect(people.map((v) => v.items), containsAll([
      {'m:a.jpg|1', 'm:b.jpg|1'},
      {'m:b.jpg|1', 'm:c.jpg|1'},
    ]));
    expect(p.has('m:d.jpg|1'), isTrue);
    expect(p.photosRead, 4);
    p.dispose();
  });

  test('names, search by name, merge, "not this person", kept and read back', () async {
    final p = PeopleIndex(lib);
    await p.load();
    p.put('m:a.jpg|1', [face(1)]);
    p.put('m:b.jpg|1', [face(1, noise: 3), face(2, x: 0.6)]);
    p.put('m:c.jpg|1', [face(3)]); // really person 1, looks different
    final mum = p.people().firstWhere((v) => v.items.contains('m:a.jpg|1')).person.id;
    final dad = p.people().firstWhere((v) => v.items.length == 1 && v.items.contains('m:b.jpg|1')).person.id;
    final other = p.people().firstWhere((v) => v.items.contains('m:c.jpg|1')).person.id;
    p.rename(mum, ' 妈妈 ');
    p.rename(dad, 'Dad');
    expect(p.person(mum)!.name, '妈妈');

    var (items, rest) = p.split('妈妈 海边')!;
    expect(items, {'m:a.jpg|1', 'm:b.jpg|1'});
    expect(rest, '海边');
    (items, rest) = p.split('妈妈海边')!;
    expect(rest, '海边');
    (items, rest) = p.split('dad 妈妈')!;
    expect(items, {'m:b.jpg|1'}); // both in it
    expect(rest, '');
    expect(p.split('beach'), isNull);

    // The same person, found apart: one from now on, the name kept.
    p.merge(other, mum);
    expect(p.itemsOf(mum), {'m:a.jpg|1', 'm:b.jpg|1', 'm:c.jpg|1'});
    expect(p.person(other), isNull);

    // Not her in b: that face goes elsewhere and never back to her.
    p.notThisPerson(mum, ['m:b.jpg|1']);
    expect(p.itemsOf(mum), {'m:a.jpg|1', 'm:c.jpg|1'});
    expect(p.itemsOf(dad), {'m:b.jpg|1'});

    p.setHidden(dad, true);
    expect(p.split('Dad'), isNull);

    await p.save();
    p.dispose();
    final again = PeopleIndex(lib);
    await again.load();
    expect(again.person(mum)!.name, '妈妈');
    expect(again.person(dad)!.hidden, isTrue);
    expect(again.itemsOf(mum), {'m:a.jpg|1', 'm:c.jpg|1'});
    // A new photo of her joins her.
    again.put('m:e.jpg|1', [face(3, noise: 5)]);
    expect(again.itemsOf(mum), contains('m:e.jpg|1'));

    // A photo gone: its faces go; someone left with none goes too.
    again.prune({'m:a.jpg|1', 'm:c.jpg|1', 'm:e.jpg|1'});
    expect(again.itemsOf(dad), isEmpty);

    await again.clear();
    expect(again.people(), isEmpty);
    expect(Directory('${lib.metaDir}${Platform.pathSeparator}people').existsSync(), isFalse);
    again.dispose();
  });
}
