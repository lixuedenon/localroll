// apps/desktop/test/annotations_test.dart
//
// Player annotations: kept and found again, shown at the right moment,
// drawing / undo, and marks found under the mouse.
import 'dart:io';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:localroll_core/localroll_core.dart';
import 'package:localroll_desktop/services/annotations.dart';
import 'package:localroll_desktop/services/library_index.dart';
import 'package:localroll_desktop/services/text_index.dart';
import 'package:localroll_desktop/ui/player/ink_editor.dart';
import 'package:localroll_desktop/ui/player/ink_paint.dart';

void main() {
  late Directory tmp;
  late LibraryIndex lib;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('lr_notes_test');
    lib = LibraryIndex('${tmp.path}${Platform.pathSeparator}Library', stateFile: File('${tmp.path}${Platform.pathSeparator}s.json'));
    await lib.load();
  });

  tearDown(() async {
    lib.dispose();
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  InkMark mark(InkTool t, List<Offset> p, {int? at, String? text}) =>
      InkMark(id: InkMark.newId(), tool: t, color: 0xFFFF0000, width: 0.01, points: p, atMs: at, text: text);

  test('a mark survives saving: points, text, moves and turns', () {
    final m = mark(InkTool.text, [const Offset(0.25, 0.5)], at: 1200, text: '注意手腕')
      ..dx = 0.1
      ..rotation = 0.5
      ..scale = 2;
    final back = InkMark.fromJson(m.toJson());
    expect(back.tool, InkTool.text);
    expect(back.text, '注意手腕');
    expect(back.points.single, const Offset(0.25, 0.5));
    expect(back.atMs, 1200);
    expect(back.dx, closeTo(0.1, 1e-6));
    expect(back.rotation, closeTo(0.5, 1e-6));
    expect(back.scale, 2);
  });

  test('on a video: marks drawn while it played appear at their time, all stay 3 s after the last', () {
    final n = Note(id: 'n', name: 'x', startMs: 10000, inks: [
      mark(InkTool.pen, [Offset.zero], at: 10000),
      mark(InkTool.arrow, [Offset.zero, const Offset(1, 1)], at: 12000),
    ]);
    expect(n.endMs, 15000);
    expect(n.shownAt(9999), isFalse);
    expect(n.shownAt(14000), isTrue);
    expect(n.shownAt(15001), isFalse);
    expect(n.inkShownAt(n.inks[1], 11000), isFalse);
    expect(n.inkShownAt(n.inks[1], 12500), isTrue);
  });

  test('kept with the library, counted, and found by name, typed words and tool names', () async {
    final rel = '2026/IMG_1.mp4';
    final file = File('${lib.rootPath}${Platform.pathSeparator}2026${Platform.pathSeparator}IMG_1.mp4');
    await file.create(recursive: true);
    await file.writeAsBytes(List.filled(100, 1));
    final item = MediaItem(relPath: rel, name: 'IMG_1.mp4', size: 100, kind: MediaKind.video, captureMs: 1, receivedMs: 1);
    lib.add(item);
    final text = TextIndex(lib);
    final store = NoteStore(library: lib, dataDir: tmp, textIndex: text)..toolName = (t) => t == InkTool.arrow ? '箭头' : t.name;
    final set = await store.open(item: item, path: file.path, name: item.name, size: 100, video: true);
    expect(set.notes, isEmpty);
    set.notes.add(Note(id: 'a', name: '反手', startMs: 5000, inks: [
      mark(InkTool.arrow, [Offset.zero, const Offset(0.5, 0.5)], at: 5000),
      mark(InkTool.text, [const Offset(0.1, 0.1)], at: 5200, text: '肘部抬高'),
    ]));
    await store.save(set);
    expect(store.countFor(item), 1);
    expect(text.matches(TextIndex.mediaKey(item), item.name, SearchQuery('肘部')), isTrue);
    expect(text.matches(TextIndex.mediaKey(item), item.name, SearchQuery('箭头')), isTrue);
    expect(store.search('反手').single.note.id, 'a');
    expect(store.search('网球'), isEmpty);

    // Read again from disk.
    final again = NoteStore(library: lib, dataDir: tmp, textIndex: TextIndex(lib));
    await again.scan();
    expect(again.countFor(item), 1);
    final read = await again.open(item: item, path: file.path, name: item.name, size: 100, video: true);
    expect(read.notes.single.inks.length, 2);
    expect(Directory('${lib.metaDir}${Platform.pathSeparator}annotations').listSync().length, 1);

    // Nothing left: the file goes.
    read.notes.clear();
    await again.save(read);
    expect(again.countFor(item), 0);
    expect(Directory('${lib.metaDir}${Platform.pathSeparator}annotations').listSync(), isEmpty);
  });

  test('files outside the library are found by their contents (renamed or moved)', () async {
    final a = File('${tmp.path}${Platform.pathSeparator}clip.mov');
    await a.writeAsBytes(List.generate(3 << 20, (i) => i % 251));
    final store = NoteStore(library: lib, dataDir: tmp, textIndex: TextIndex(lib));
    final set = await store.open(path: a.path, name: 'clip.mov', size: 3 << 20, video: true);
    set.notes.add(Note(id: 'b', name: 'serve', inks: [mark(InkTool.check, [const Offset(0.5, 0.5)], at: 0)]));
    await store.save(set);
    final moved = File('${tmp.path}${Platform.pathSeparator}renamed.mov');
    await a.rename(moved.path);
    final fresh = NoteStore(library: lib, dataDir: tmp, textIndex: TextIndex(lib));
    final found = await fresh.open(path: moved.path, name: 'renamed.mov', size: 3 << 20, video: true);
    expect(found.notes.single.name, 'serve');
    expect(await NoteStore.contentKey(moved.path), set.key);
  });

  test('drawing: a stroke, undo, redo, numbers count up, the eraser rubs out', () {
    var now = 0;
    final ed = InkEditor(video: true, clock: () => now);
    ed.setTool(EditTool.pen);
    now = 4000;
    ed.begin(const Offset(0.1, 0.1));
    ed.extend(const Offset(0.2, 0.2));
    ed.extend(const Offset(0.3, 0.3));
    ed.end();
    expect(ed.inks.single.atMs, 4000);
    ed.setTool(EditTool.number);
    ed.begin(const Offset(0.6, 0.6));
    ed.begin(const Offset(0.7, 0.7));
    expect([for (final i in ed.inks) i.number], [null, 1, 2]);
    ed.undo();
    expect(ed.inks.length, 2);
    ed.redo();
    expect(ed.inks.length, 3);
    const size = Size(1000, 500);
    ed.eraseAt(const Offset(200, 100), size, first: true);
    expect(ed.inks.length, 2);
    expect(ed.inks.every((i) => i.tool == InkTool.number), isTrue);
  });

  test('marks are found under the mouse, also after moving and turning', () {
    const size = Size(1000, 1000);
    final line = mark(InkTool.line, [const Offset(0.1, 0.5), const Offset(0.9, 0.5)]);
    expect(InkGeometry.hits(line, size, const Offset(500, 503)), isTrue);
    expect(InkGeometry.hits(line, size, const Offset(500, 560)), isFalse);
    line.dy = 0.2;
    expect(InkGeometry.hits(line, size, const Offset(500, 700)), isTrue);
    line
      ..dy = 0
      ..rotation = 1.5707963;
    // Turned upright around its middle.
    expect(InkGeometry.hits(line, size, const Offset(500, 200)), isTrue);
    expect(InkGeometry.hits(line, size, const Offset(200, 500)), isFalse);
  });
}
