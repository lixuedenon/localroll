// apps/desktop/test/library_index_test.dart
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:localroll_core/localroll_core.dart';
import 'package:localroll_desktop/services/library_index.dart';

/// The library must follow what happens in Explorer without ever turning
/// "can't find it" into "deleted" by mistake.
void main() {
  late Directory tmp;
  late String root;
  late File state;

  String p(String rel) => '$root${Platform.pathSeparator}${rel.replaceAll('/', Platform.pathSeparator)}';

  Future<MediaItem> put(LibraryIndex lib, String rel, {String? asset, int bytes = 10}) async {
    final f = File(p(rel));
    await f.parent.create(recursive: true);
    await f.writeAsBytes(List.filled(bytes, 7));
    final item = MediaItem(
      relPath: rel,
      name: rel.split('/').last,
      size: bytes,
      kind: MediaKind.fromName(rel),
      captureMs: 1,
      receivedMs: 1,
      deviceId: asset == null ? null : 'phone',
      assetId: asset,
    );
    lib.add(item);
    return item;
  }

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('lr_lib_test');
    root = '${tmp.path}${Platform.pathSeparator}Library';
    state = File('${tmp.path}${Platform.pathSeparator}state.json');
  });

  tearDown(() async {
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  test('a few deleted files: removed, and the phone is told', () async {
    final lib = LibraryIndex(root, stateFile: state);
    await lib.load();
    await put(lib, '2026/10/a.jpg', asset: 'A');
    await put(lib, '2026/10/b.jpg', asset: 'B');
    await File(p('2026/10/a.jpg')).delete();
    await lib.reconcile();
    expect(lib.items.map((i) => i.name), ['b.jpg']);
    expect(lib.deletedSince('phone', 0), ['A']);
    expect(lib.pendingMissing, isEmpty);
    lib.dispose();
  });

  test('many files vanish at once: ask first, phones are not told yet', () async {
    final lib = LibraryIndex(root, stateFile: state);
    await lib.load();
    for (var i = 0; i < LibraryIndex.askAbove + 5; i++) {
      await put(lib, '2026/09/p$i.jpg', asset: 'X$i');
    }
    await Directory(p('2026/09')).delete(recursive: true);
    await lib.reconcile();
    expect(lib.pendingMissing.length, LibraryIndex.askAbove + 5);
    expect(lib.items, isEmpty); // hidden meanwhile
    expect(lib.deletedSince('phone', 0), isEmpty);
    lib.confirmMissing();
    expect(lib.pendingMissing, isEmpty);
    expect(lib.deletedSince('phone', 0).length, LibraryIndex.askAbove + 5);
    lib.dispose();
  });

  test('moved inside the library: same item, new path', () async {
    final lib = LibraryIndex(root, stateFile: state);
    await lib.load();
    await put(lib, '2026/10/c.jpg', asset: 'C', bytes: 33);
    await Directory(p('Trip')).create(recursive: true);
    await File(p('2026/10/c.jpg')).rename(p('Trip/c.jpg'));
    await lib.reconcile();
    final c = lib.findByAsset('phone', 'C');
    expect(c?.relPath, 'Trip/c.jpg');
    expect(lib.deletedSince('phone', 0), isEmpty);
    lib.dispose();
  });

  test('restored from the Recycle Bin: comes back as it was', () async {
    final lib = LibraryIndex(root, stateFile: state);
    await lib.load();
    await put(lib, '2026/10/d.heic', asset: 'D', bytes: 21);
    final bytes = await File(p('2026/10/d.heic')).readAsBytes();
    await File(p('2026/10/d.heic')).delete();
    await lib.reconcile();
    expect(lib.findByAsset('phone', 'D'), isNull);
    await File(p('2026/10/d.heic')).writeAsBytes(bytes);
    await lib.reconcile();
    expect(lib.findByAsset('phone', 'D')?.relPath, '2026/10/d.heic');
    expect(lib.deletedSince('phone', 0), isEmpty);
    lib.dispose();
  });

  test('copied in from elsewhere: added; our own folders ignored', () async {
    final lib = LibraryIndex(root, stateFile: state);
    await lib.load();
    await File(p('Old/e.mp4')).create(recursive: true);
    await File(p('_converted/compatible/x.jpg')).create(recursive: true);
    await File(p('notes.txt')).create(recursive: true);
    await lib.reconcile();
    expect(lib.items.map((i) => i.relPath), ['Old/e.mp4']);
    lib.dispose();
  });

  test('unplugged drive: offline, nothing marked deleted, nothing re-created', () async {
    final lib = LibraryIndex(root, stateFile: state);
    await lib.load();
    await put(lib, '2026/10/f.jpg', asset: 'F');
    await lib.flush();
    lib.dispose();
    await Directory(root).rename('$root-unplugged');

    final again = LibraryIndex(root, stateFile: state);
    await again.load();
    expect(again.offline, isTrue);
    expect(Directory(root).existsSync(), isFalse);
    expect(again.deletedSince('phone', 0), isEmpty);
    again.dispose();

    await Directory('$root-unplugged').rename(root);
    final back = LibraryIndex(root, stateFile: state);
    await back.load();
    expect(back.offline, isFalse);
    expect(back.findByAsset('phone', 'F'), isNotNull);
    back.dispose();
  });

  test('first run: a missing folder that never had anything is created', () async {
    final lib = LibraryIndex(root, stateFile: state);
    await lib.load();
    expect(lib.offline, isFalse);
    expect(Directory(root).existsSync(), isTrue);
    lib.dispose();
  });
}
