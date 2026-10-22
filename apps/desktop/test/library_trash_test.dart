// apps/desktop/test/library_trash_test.dart
//
// "Recently deleted": deleting moves files into the library's hidden trash
// folder, restoring puts them back as they were, and after 30 days they go
// for good. Real files in a temporary library.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:localroll_core/localroll_core.dart';
import 'package:localroll_desktop/services/library_trash.dart';

import 'support/harness.dart';

void main() {
  late TestPc pc;

  setUp(() async {
    TestPc.free = 100 * 1024 * 1024 * 1024;
    pc = await TestPc.start();
  });

  tearDown(() async {
    await pc.close();
  });

  Future<void> sendFile(TestPhone phone, String name, List<int> data) async {
    final offer = FileOffer(
      id: 'f1',
      assetId: 'file:$name',
      name: name,
      kind: MediaKind.other,
      createdMs: 1,
      modifiedMs: 1,
      size: data.length,
      target: LrProtocol.targetFiles,
      relPath: name,
    );
    final s = await phone.client.createSession(SessionRequest(files: [offer]));
    await phone.client.putChunk(s.sessionId, 'f1', 0, data.length, data);
    final r = await phone.client.complete(s.sessionId, 'f1', CompleteRequest(size: data.length, sha256: await sha(data)));
    expect(r.saved, isTrue);
  }

  test('a photo and its Live Photo video: into the trash and back, as they were', () async {
    final phone = await pc.pairPhone();
    final photo = await phone.upload('L1', bytesOf(400), name: 'IMG_7.HEIC');
    final video = await phone.upload(liveCompanionId('L1'), bytesOf(900, 2), name: 'IMG_7.MOV', kind: MediaKind.video);
    final item = pc.library.findByRel(photo.path!)!;
    final trash = pc.server.trash;

    final made = await trash.putMedia([item]);
    expect(made, hasLength(1)); // one entry shown; the video goes with it
    expect(trash.entries, hasLength(1));
    expect(trash.totalSize, 1300);
    expect(File(pc.abs(photo.path!)).existsSync(), isFalse);
    expect(File(pc.abs(video.path!)).existsSync(), isFalse);
    expect(File(trash.storedPath(made.single)).readAsBytesSync(), bytesOf(400));
    expect(pc.library.items, isEmpty);
    expect(pc.library.deletedSince(phone.id, 0), contains('L1'));

    expect(await trash.restore(made), 1);
    expect(File(pc.abs(photo.path!)).readAsBytesSync(), bytesOf(400));
    expect(File(pc.abs(video.path!)).readAsBytesSync(), bytesOf(900, 2));
    final back = pc.library.findByRel(photo.path!)!;
    expect(back.deviceId, phone.id);
    expect(back.assetId, 'L1');
    expect(pc.library.liveFor(back)?.relPath, video.path);
    // Not reported to the phone as deleted any more.
    expect(pc.library.deletedSince(phone.id, 0), isEmpty);
    expect(trash.entries, isEmpty);
  });

  test('restoring where a file now has the same name keeps both', () async {
    final phone = await pc.pairPhone();
    final r = await phone.upload('A1', bytesOf(300), name: 'a.jpg');
    final trash = pc.server.trash;
    final made = await trash.putMedia([pc.library.findByRel(r.path!)!]);
    File(pc.abs(r.path!)).writeAsBytesSync(bytesOf(10, 7));
    expect(await trash.restore(made), 1);
    expect(File(pc.abs(r.path!)).readAsBytesSync(), bytesOf(10, 7));
    final dir = File(pc.abs(r.path!)).parent;
    expect(dir.listSync().map((e) => e.path.split(Platform.pathSeparator).last), containsAll(['a.jpg', 'a (1).jpg']));
  });

  test('received files: into the trash and back with who sent them', () async {
    final phone = await pc.pairPhone(id: 'mum', name: 'Mum');
    await sendFile(phone, 'scan.pdf', [...'%PDF-1.7'.codeUnits, ...bytesOf(200)]);
    final f = (await pc.server.files.list()).single;
    expect(f.owner?.deviceId, 'mum');
    expect(f.document, isTrue);
    final trash = pc.server.trash;
    final made = await trash.putFiles([f.path]);
    expect(made.single.kind.name, 'file');
    expect(File(f.path).existsSync(), isFalse);
    expect(await pc.server.files.list(), isEmpty);
    expect(await trash.restore(made), 1);
    final again = (await pc.server.files.list()).single;
    expect(again.path, f.path);
    expect(again.owner?.deviceId, 'mum');
  });

  test('after 30 days it goes for good; emptying by hand too', () async {
    final phone = await pc.pairPhone();
    final a = await phone.upload('A1', bytesOf(100), name: 'a.jpg');
    final b = await phone.upload('B1', bytesOf(100, 3), name: 'b.jpg');
    final trash = pc.server.trash;
    final first = await trash.putMedia([pc.library.findByRel(a.path!)!]);
    expect(await trash.purgeOld(), 0);
    expect(await trash.purgeOld(now: DateTime.now().add(const Duration(days: 31))), 1);
    expect(File(trash.storedPath(first.single)).existsSync(), isFalse);
    final second = await trash.putMedia([pc.library.findByRel(b.path!)!]);
    expect(trash.daysLeft(second.single), inInclusiveRange(29, 30));
    expect(await trash.purge(trash.entries), 1);
    expect(trash.entries, isEmpty);
    expect(trash.totalSize, 0);
  });

  test('the trash list survives a restart', () async {
    final phone = await pc.pairPhone();
    final a = await phone.upload('A1', bytesOf(100), name: 'a.jpg');
    await pc.server.trash.putMedia([pc.library.findByRel(a.path!)!]);
    // A fresh trash reading the same folder.
    final fresh = LibraryTrash(pc.library, pc.server.files);
    await fresh.load();
    expect(fresh.entries.single.rel, a.path);
    expect(File(fresh.storedPath(fresh.entries.single)).existsSync(), isTrue);
  });

  test('a phone allowed to manage deletes into the trash too', () async {
    final phone = await pc.pairPhone(id: 'dad');
    await pc.settings.update((s) => s.trusted['dad']!.access = LibraryAccess.manage);
    final r = await phone.upload('D1', bytesOf(100), name: 'd.jpg');
    expect(await phone.client.libraryDelete([r.path!]), 1);
    expect(File(pc.abs(r.path!)).existsSync(), isFalse);
    expect(pc.server.trash.entries.single.rel, r.path);
  });

  test('renaming a received file keeps who sent it and "only me" (here and in Explorer)', () async {
    final mum = await pc.pairPhone(id: 'mum', name: 'Mum');
    await sendFile(mum, 'scan.pdf', [...'%PDF-1.7'.codeUnits, ...bytesOf(200)]);
    final files = pc.server.files;
    final f = (await files.list()).single;
    expect(await files.setPrivate([files.relOf(f.path)!], 'mum', true), 1);

    final to = await files.rename(f.path, 'Contract 2026.pdf');
    expect(to.endsWith('Contract 2026.pdf'), isTrue);
    var again = (await files.list()).single;
    expect(again.owner?.deviceId, 'mum');
    expect(again.owner?.private, isTrue);
    await expectLater(files.rename(to, 'bad/name.pdf'), throwsArgumentError);

    // Renamed in Explorer: found again by its size.
    final sep = Platform.pathSeparator;
    final moved = '${to.substring(0, to.lastIndexOf(sep))}${sep}renamed.pdf';
    await File(to).rename(moved);
    files.forget();
    again = (await files.list()).single;
    expect(again.path, moved);
    expect(again.owner?.private, isTrue);
  });
}
