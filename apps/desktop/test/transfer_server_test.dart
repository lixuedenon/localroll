// apps/desktop/test/transfer_server_test.dart
//
// End-to-end tests of the PC's receiver: a real server on a free port, real
// HTTPS with the pinned certificate, real files on disk. Each test gets a
// fresh PC (settings, certificate, library) in a temporary folder.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:localroll_core/localroll_core.dart';
import 'package:localroll_desktop/server/transfer_server.dart';

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

  group('signing in', () {
    test('info is public; everything else needs a paired device', () async {
      final info = await LrClient(host: '127.0.0.1', port: pc.port, secure: true, pin: pc.tls.fingerprint).info();
      expect(info.id, pc.settings.deviceId);
      expect(info.fingerprint, pc.tls.fingerprint);

      var (status, body) = await pc.call('GET', LrProtocol.pathChanges);
      expect(status, 401);
      expect(body['error'], 'not_paired');
      (status, body) = await pc.call('GET', LrProtocol.pathChanges, id: 'nobody', token: 'guess');
      expect(status, 401);
    });

    test('wrong PIN is refused; after 5 wrong guesses the PIN changes', () async {
      final shown = pc.server.pin.value;
      for (var i = 0; i < 5; i++) {
        final (status, body) = await pc.call('POST', LrProtocol.pathPair,
            json: PairRequest(device: const DeviceInfo(id: 'x', name: 'x', platform: 'ios'), pin: '000000').toJson());
        expect(status, 403);
        expect(body['error'], 'wrong_pin');
      }
      final (status, _) = await pc.call('POST', LrProtocol.pathPair,
          json: PairRequest(device: const DeviceInfo(id: 'x', name: 'x', platform: 'ios'), pin: shown).toJson());
      expect(status, 429);
      expect(pc.server.pin.value, isNot(shown));
      expect(pc.settings.trusted, isEmpty);
    });

    test('pairing with the PIN works once; the PIN changes after it', () async {
      final shown = pc.server.pin.value;
      final phone = await pc.pairPhone();
      expect(pc.settings.trusted[phone.id]?.secure, isTrue);
      expect(pc.settings.trusted[phone.id]?.familyMember, isTrue);
      expect(pc.server.pin.value, isNot(shown));
      await phone.client.ping();
    });

    test('a device paired over HTTPS is refused over plain HTTP', () async {
      final phone = await pc.pairPhone();
      final (status, body) =
          await pc.call('GET', LrProtocol.pathChanges, id: phone.id, token: phone.token, secure: false);
      expect(status, 426);
      expect(body['error'], 'upgrade_required');
    });

    test('a pinned client refuses a different certificate', () async {
      final wrong = LrClient(host: '127.0.0.1', port: pc.port, secure: true, pin: 'ab' * 32);
      await expectLater(wrong.info(), throwsA(anything));
      wrong.close();
    });

    test('"Forget this PC" from the phone: its token stops working', () async {
      final phone = await pc.pairPhone();
      await phone.client.unpair();
      expect(pc.settings.trusted.containsKey(phone.id), isFalse);
      await expectLater(phone.client.ping(), throwsA(isA<LrHttpError>().having((e) => e.status, 'status', 401)));
    });

    test('many failed sign-ins from one address: blocked for a while', () async {
      for (var i = 0; i < 20; i++) {
        await pc.call('GET', LrProtocol.pathChanges, id: 'nobody', token: 'guess$i');
      }
      // Pairing is refused too while blocked, even with the right PIN.
      var (status, _) = await pc.call('POST', LrProtocol.pathPair,
          json: PairRequest(device: const DeviceInfo(id: 'x', name: 'x', platform: 'ios'), pin: pc.server.pin.value).toJson());
      expect(status, 429);
      (status, _) = await pc.call('GET', LrProtocol.pathChanges, id: 'nobody', token: 'x');
      expect(status, 429);
      expect(pc.settings.trusted, isEmpty);
    });
  });

  group('upload', () {
    test('a photo arrives intact, in <year>/<month>, dated as taken', () async {
      final phone = await pc.pairPhone();
      final data = bytesOf(300 * 1024);
      final taken = DateTime(2024, 5, 17, 10, 30);
      final r = await phone.upload('A1', data, name: 'IMG_0001.JPG', captured: taken);
      expect(r.saved, isTrue);
      expect(r.path, '2024/05/IMG_0001.JPG');
      final f = File(pc.abs(r.path!));
      expect(await f.readAsBytes(), data);
      expect((await f.lastModified()).millisecondsSinceEpoch ~/ 1000, taken.millisecondsSinceEpoch ~/ 1000);
      final item = pc.library.findByAsset(phone.id, 'A1');
      expect(item, isNotNull);
      expect(item!.sha256, await sha(data));
      expect(item.deviceId, phone.id);
    });

    test('sent again: "already have it", nothing transferred', () async {
      final phone = await pc.pairPhone();
      await phone.upload('A1', bytesOf(1000));
      final s = await phone.client.createSession(SessionRequest(files: [
        FileOffer(id: 'f1', assetId: 'A1', name: 'IMG_0001.JPG', kind: MediaKind.image, createdMs: 1, modifiedMs: 1, size: 1000),
      ]));
      expect(s.results['f1']!.status, OfferStatus.duplicate);
      expect(pc.library.items.length, 1);
    });

    test('interrupted: a new session resumes at the right offset', () async {
      final phone = await pc.pairPhone();
      final data = bytesOf(100000, 7);
      final offer = FileOffer(
          id: 'f1', assetId: 'V1', name: 'MOV_1.MOV', kind: MediaKind.video, createdMs: 5, modifiedMs: 5, size: data.length);
      final s1 = await phone.client.createSession(SessionRequest(files: [offer]));
      await phone.client.putChunk(s1.sessionId, 'f1', 0, data.length, data.sublist(0, 40000));
      // Connection lost; later, a new session for the same file.
      final s2 = await phone.client.createSession(SessionRequest(files: [offer]));
      expect(s2.results['f1']!.offset, 40000);
      expect(await phone.client.status(s2.sessionId, 'f1'), 40000);
      // A chunk at the wrong place is refused with where to continue.
      await expectLater(
        phone.client.putChunk(s2.sessionId, 'f1', 30000, data.length, data.sublist(30000)),
        throwsA(isA<LrHttpError>().having((e) => e.status, 'status', 409)),
      );
      await phone.client.putChunk(s2.sessionId, 'f1', 40000, data.length, data.sublist(40000));
      final r = await phone.client.complete(s2.sessionId, 'f1', CompleteRequest(size: data.length, sha256: await sha(data)));
      expect(r.saved, isTrue);
      expect(await File(pc.abs(r.path!)).readAsBytes(), data);
    });

    test('damaged on the way (hash differs): refused, nothing kept, starts over', () async {
      final phone = await pc.pairPhone();
      final data = bytesOf(5000);
      final offer =
          FileOffer(id: 'f1', assetId: 'B1', name: 'b.jpg', kind: MediaKind.image, createdMs: 5, modifiedMs: 5, size: data.length);
      final s = await phone.client.createSession(SessionRequest(files: [offer]));
      await phone.client.putChunk(s.sessionId, 'f1', 0, data.length, data);
      await expectLater(
        phone.client.complete(s.sessionId, 'f1', CompleteRequest(size: data.length, sha256: '0' * 64)),
        throwsA(isA<LrHttpError>().having((e) => e.status, 'status', 422).having((e) => e.code, 'code', 'sha256_mismatch')),
      );
      expect(pc.library.items, isEmpty);
      final again = await phone.client.createSession(SessionRequest(files: [offer]));
      expect(again.results['f1']!.offset, 0);
    });

    test('"complete" with fewer bytes than said: refused', () async {
      final phone = await pc.pairPhone();
      final data = bytesOf(5000);
      final offer =
          FileOffer(id: 'f1', assetId: 'C1', name: 'c.jpg', kind: MediaKind.image, createdMs: 5, modifiedMs: 5, size: data.length);
      final s = await phone.client.createSession(SessionRequest(files: [offer]));
      await phone.client.putChunk(s.sessionId, 'f1', 0, data.length, data.sublist(0, 3000));
      await expectLater(
        phone.client.complete(s.sessionId, 'f1', CompleteRequest(size: data.length, sha256: await sha(data))),
        throwsA(isA<LrHttpError>().having((e) => e.status, 'status', 409)),
      );
      expect(pc.library.items, isEmpty);
    });

    test('"complete" repeated after success (answer lost): still "saved"', () async {
      final phone = await pc.pairPhone();
      final data = bytesOf(2000);
      final offer =
          FileOffer(id: 'f1', assetId: 'D1', name: 'd.jpg', kind: MediaKind.image, createdMs: 5, modifiedMs: 5, size: data.length);
      final s = await phone.client.createSession(SessionRequest(files: [offer]));
      await phone.client.putChunk(s.sessionId, 'f1', 0, data.length, data);
      final req = CompleteRequest(size: data.length, sha256: await sha(data));
      final first = await phone.client.complete(s.sessionId, 'f1', req);
      final second = await phone.client.complete(s.sessionId, 'f1', req);
      expect(first.saved, isTrue);
      expect(second.saved, isTrue);
      expect(pc.library.items.length, 1);
    });

    test('more bytes than the file said: refused, the disk is not filled', () async {
      final phone = await pc.pairPhone();
      final offer =
          FileOffer(id: 'f1', assetId: 'E1', name: 'e.jpg', kind: MediaKind.image, createdMs: 5, modifiedMs: 5, size: 1000);
      final s = await phone.client.createSession(SessionRequest(files: [offer]));
      await expectLater(
        phone.client.putChunk(s.sessionId, 'f1', 0, 1000, bytesOf(50000)),
        throwsA(isA<LrHttpError>().having((e) => e.status, 'status', 413)),
      );
      expect(await phone.client.status(s.sessionId, 'f1'), lessThanOrEqualTo(1000));
    });

    test('a chunk cut off by a lost Wi-Fi leaves nothing; the resumed send arrives intact', () async {
      final phone = await pc.pairPhone();
      final data = bytesOf(300000, 9);
      final offer = FileOffer(
          id: 'f1', assetId: 'W1', name: 'w.jpg', kind: MediaKind.image, createdMs: 5, modifiedMs: 5, size: data.length);
      final s = await phone.client.createSession(SessionRequest(files: [offer]));
      // Half a chunk, then the connection is gone.
      final http = lrHttpClient(pin: pc.tls.fingerprint);
      final uri = Uri(
        scheme: 'https',
        host: '127.0.0.1',
        port: pc.port,
        path: LrProtocol.filePath(s.sessionId, 'f1'),
        queryParameters: {'offset': '0', 'total': '${data.length}'},
      );
      final req = await http.openUrl('PUT', uri);
      req.headers.set(LrProtocol.headerDeviceId, phone.id);
      req.headers.set(LrProtocol.headerToken, phone.token);
      req.contentLength = data.length;
      req.add(data.sublist(0, 120000));
      await req.flush();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      req.abort();
      http.close(force: true);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(await phone.client.status(s.sessionId, 'f1'), 0);
      // Resumed on a new connection: the whole file, nothing mixed in.
      expect(await phone.client.putChunk(s.sessionId, 'f1', 0, data.length, data), data.length);
      final r = await phone.client.complete(s.sessionId, 'f1', CompleteRequest(size: data.length, sha256: await sha(data)));
      expect(r.saved, isTrue);
      expect(await File(pc.library.absPath(pc.library.items.single)).readAsBytes(), data);
    });

    test('photos deleted on the PC: linked phones are told at once', () async {
      final phone = await pc.pairPhone();
      expect((await phone.upload('D1', bytesOf(100))).saved, isTrue);
      final link = await phone.live();
      await eventually(() => link.messages.any((m) => m.type == 'hello'));
      pc.library.removeItems(pc.library.items.toList());
      await eventually(() => link.messages.any((m) => m.type == 'changed'));
      await link.close();
    });

    test('library access changed on the PC: the phone is told at once', () async {
      final phone = await pc.pairPhone();
      final link = await phone.live();
      await eventually(() => link.messages.any((m) => m.type == 'hello'));
      await pc.server.setAccess(phone.id, LibraryAccess.manage);
      await eventually(() => link.messages.any((m) => m.type == 'you' && m.access == LibraryAccess.manage));
      await link.close();
    });

    test('family → guest: library access drops to "can\'t look"', () async {
      final phone = await pc.pairPhone();
      await pc.server.setFamily(phone.id, true);
      await pc.server.setAccess(phone.id, LibraryAccess.manage);
      final link = await phone.live();
      await eventually(() => link.messages.any((m) => m.type == 'hello'));
      await pc.server.setFamily(phone.id, false);
      expect(pc.settings.trusted[phone.id]!.libraryAccess, LibraryAccess.none);
      await eventually(() => link.messages.any((m) => m.type == 'you' && m.access == LibraryAccess.none));
      await link.close();
    });

    test('another device\'s session can\'t be used', () async {
      final a = await pc.pairPhone(id: 'phoneA');
      final b = await pc.pairPhone(id: 'phoneB');
      final s = await a.client.createSession(SessionRequest(files: [
        const FileOffer(id: 'f1', assetId: 'X', name: 'x.jpg', kind: MediaKind.image, createdMs: 1, modifiedMs: 1, size: 10),
      ]));
      await expectLater(
        b.client.putChunk(s.sessionId, 'f1', 0, 10, bytesOf(10)),
        throwsA(isA<LrHttpError>().having((e) => e.status, 'status', 404)),
      );
    });

    test('Live Photo: the video lands next to its photo with the same name', () async {
      final phone = await pc.pairPhone();
      final photo = await phone.upload('L1', bytesOf(4000), name: 'IMG_0042.HEIC');
      final video = await phone.upload(liveCompanionId('L1'), bytesOf(9000, 3), name: 'IMG_0042.MOV', kind: MediaKind.video);
      expect(photo.path, '2024/05/IMG_0042.HEIC');
      expect(video.path, '2024/05/IMG_0042.MOV');
    });

    test('same file name from two phones: both kept', () async {
      final a = await pc.pairPhone(id: 'phoneA');
      final b = await pc.pairPhone(id: 'phoneB');
      final ra = await a.upload('S', bytesOf(100, 1), name: 'IMG_1.JPG');
      final rb = await b.upload('S', bytesOf(100, 2), name: 'IMG_1.JPG');
      expect(ra.path, isNot(rb.path));
      expect(pc.library.items.length, 2);
    });
  });

  group('same photo sent again (by content)', () {
    test('a new iPhone sends the same photos: one file kept, the new phone sees them backed up', () async {
      final old = await pc.pairPhone(id: 'oldPhone');
      final fresh = await pc.pairPhone(id: 'newPhone');
      final data = bytesOf(5000, 4);
      final first = await old.upload('OLD-ID', data, name: 'IMG_0100.HEIC');
      // Restored from iCloud on the new phone: other id, same bytes.
      final again = await fresh.upload('NEW-ID', data, name: 'IMG_0100.HEIC');
      expect(again.saved, isTrue);
      expect(again.path, first.path);
      expect(pc.library.items, hasLength(1));
      expect(Directory(pc.abs('2024/05')).listSync(), hasLength(1));
      // Next time: "already have it" straight away; cleanup checks the one file.
      final s = await fresh.client.createSession(SessionRequest(files: [
        const FileOffer(id: 'f1', assetId: 'NEW-ID', name: 'IMG_0100.HEIC', kind: MediaKind.image, createdMs: 1, modifiedMs: 1, size: 5000),
      ]));
      expect(s.results['f1']!.status, OfferStatus.duplicate);
      final (_, body) = await fresh.call('POST', LrProtocol.pathVerify, json: const VerifyRequest(assetIds: ['NEW-ID']).toJson());
      expect(VerifyResponse.fromJson(body).items.single.ok, isTrue);
      // Kept over a restart.
      await pc.library.flush();
      await pc.library.load();
      expect(pc.library.findByAsset('newPhone', 'NEW-ID')?.relPath, first.path);
      // Deleted on the PC: both phones are told.
      pc.library.removeItems([pc.library.findByAsset('oldPhone', 'OLD-ID')!]);
      expect(pc.library.deletedSince('oldPhone', 0), contains('OLD-ID'));
      expect(pc.library.deletedSince('newPhone', 0), contains('NEW-ID'));
    });

    test('a Live Photo sent again: no new files, the photo still finds its video', () async {
      final old = await pc.pairPhone(id: 'oldPhone');
      final fresh = await pc.pairPhone(id: 'newPhone');
      final still = bytesOf(4000, 5), motion = bytesOf(9000, 6);
      await old.upload('L1', still, name: 'IMG_0042.HEIC');
      await old.upload(liveCompanionId('L1'), motion, name: 'IMG_0042.MOV', kind: MediaKind.video);
      await fresh.upload('L2', still, name: 'IMG_0042.HEIC');
      await fresh.upload(liveCompanionId('L2'), motion, name: 'IMG_0042.MOV', kind: MediaKind.video);
      expect(Directory(pc.abs('2024/05')).listSync(), hasLength(2));
      final photo = pc.library.findByAsset('newPhone', 'L2')!;
      expect(pc.library.liveFor(photo)?.name, 'IMG_0042.MOV');
    });

    test('different bytes: kept as two', () async {
      final phone = await pc.pairPhone();
      await phone.upload('A', bytesOf(100, 1), name: 'a.jpg');
      await phone.upload('B', bytesOf(100, 2), name: 'b.jpg');
      expect(pc.library.items, hasLength(2));
    });
  });

  test('a scan (PDF) from a phone lands in the Documents folder, by its name', () async {
    final phone = await pc.pairPhone();
    final data = [...'%PDF-1.7'.codeUnits, ...bytesOf(4000)];
    final offer = FileOffer(
      id: 'f1',
      assetId: 'file:scan1',
      name: 'scan_2026-10-15_0930.pdf',
      kind: MediaKind.other,
      createdMs: 1,
      modifiedMs: 1,
      size: data.length,
      target: LrProtocol.targetFiles,
      relPath: 'scan_2026-10-15_0930.pdf',
    );
    final s = await phone.client.createSession(SessionRequest(files: [offer]));
    await phone.client.putChunk(s.sessionId, 'f1', 0, data.length, data);
    final r = await phone.client.complete(s.sessionId, 'f1', CompleteRequest(size: data.length, sha256: await sha(data)));
    expect(r.saved, isTrue);
    final docs = await pc.server.folderPath(document: true);
    expect(File('$docs${Platform.pathSeparator}scan_2026-10-15_0930.pdf').readAsBytesSync(), data);
    expect(pc.library.items, isEmpty); // not a photo
  });

  group('limits', () {
    test('not enough space on the PC: refused before sending', () async {
      final phone = await pc.pairPhone();
      TestPc.free = 300 * 1024 * 1024; // keepFree is 256 MB
      await expectLater(
        phone.client.createSession(SessionRequest(files: [
          const FileOffer(
              id: 'f1', assetId: 'BIG', name: 'big.mov', kind: MediaKind.video, createdMs: 1, modifiedMs: 1, size: 100 * 1024 * 1024),
        ])),
        throwsA(isA<LrHttpError>().having((e) => e.status, 'status', 507).having((e) => e.code, 'code', 'disk_full')),
      );
      // Small enough still goes.
      expect((await phone.upload('SMALL', bytesOf(1000))).saved, isTrue);
    });

    test('a phone photo with only an expected size: still refused up front; the hint is no limit', () async {
      final phone = await pc.pairPhone();
      TestPc.free = 300 * 1024 * 1024;
      await expectLater(
        phone.client.createSession(SessionRequest(files: [
          const FileOffer(
              id: 'f1', assetId: 'BIG', name: 'IMG_9.HEIC', kind: MediaKind.image, createdMs: 1, modifiedMs: 1, sizeHint: 100 * 1024 * 1024),
        ])),
        throwsA(isA<LrHttpError>().having((e) => e.status, 'status', 507).having((e) => e.code, 'code', 'disk_full')),
      );
      // An estimate a little short of the real file: the file still goes in whole.
      TestPc.free = 100 * 1024 * 1024 * 1024;
      final data = bytesOf(5000, 3);
      final s = await phone.client.createSession(SessionRequest(files: [
        const FileOffer(id: 'f1', assetId: 'H1', name: 'IMG_1.HEIC', kind: MediaKind.image, createdMs: 1, modifiedMs: 1, sizeHint: 4000),
      ]));
      final off = await phone.client.putChunk(s.sessionId, 'f1', 0, data.length, data);
      expect(off, data.length);
      final r = await phone.client.complete(s.sessionId, 'f1', CompleteRequest(size: data.length, sha256: await sha(data)));
      expect(r.saved, isTrue);
    });

    test('"disk full" errors are recognised (Windows and POSIX)', () async {
      expect(TransferServer.isDiskFull(const FileSystemException('x', 'p', OSError('full', 112))), isTrue);
      expect(TransferServer.isDiskFull(const FileSystemException('x', 'p', OSError('full', 28))), isTrue);
      expect(TransferServer.isDiskFull(const FileSystemException('x', 'p', OSError('denied', 5))), isFalse);
    });

    test('a huge request body is refused', () async {
      final phone = await pc.pairPhone();
      final (status, body) = await phone.call('POST', LrProtocol.pathSessions,
          bytes: utf8.encode('{"files":[${List.filled(300000, '"xxxxxxxxxxxxxxxx"').join(',')}]}'));
      expect(status, 413);
      expect(body['error'], 'too_large');
    });

    test('a malformed request is refused, the server keeps working', () async {
      final phone = await pc.pairPhone();
      var (status, _) = await phone.call('POST', LrProtocol.pathSessions, bytes: utf8.encode('{not json'));
      expect(status, 400);
      (status, _) = await phone.call('POST', LrProtocol.pathSessions, json: {'files': 'nope'});
      expect(status, 400);
      expect((await phone.upload('OK', bytesOf(10))).saved, isTrue);
    });

    test('a file from another PC can\'t be written outside the library', () async {
      final pcB = await pc.pairPhone(id: 'otherPc', name: 'Other PC', platform: 'windows');
      final data = bytesOf(100);
      final offer = FileOffer(
        id: 'f1',
        assetId: 'file:1',
        name: 'evil.txt',
        kind: MediaKind.other,
        createdMs: 1,
        modifiedMs: 1,
        size: data.length,
        target: LrProtocol.targetFiles,
        relPath: '../../../escaped/evil.txt',
      );
      final s = await pcB.client.createSession(SessionRequest(files: [offer]));
      await pcB.client.putChunk(s.sessionId, 'f1', 0, data.length, data);
      final r = await pcB.client.complete(s.sessionId, 'f1', CompleteRequest(size: data.length, sha256: await sha(data)));
      expect(r.saved, isTrue);
      expect(Directory('${pc.tmp.path}${Platform.pathSeparator}escaped').existsSync(), isFalse);
      final found = Directory(pc.library.rootPath)
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('evil.txt'))
          .toList();
      expect(found, hasLength(1));
      expect(found.single.absolute.path.startsWith(Directory(pc.library.rootPath).absolute.path), isTrue);
    });
  });

  group('safe cleanup', () {
    test('verify: intact / changed / missing', () async {
      final phone = await pc.pairPhone();
      final ok = await phone.upload('OK', bytesOf(1000, 1), name: 'ok.jpg');
      final changed = await phone.upload('CH', bytesOf(1000, 2), name: 'ch.jpg');
      final gone = await phone.upload('GO', bytesOf(1000, 3), name: 'go.jpg');
      expect([ok.saved, changed.saved, gone.saved], everyElement(isTrue));
      await File(pc.abs(changed.path!)).writeAsBytes(bytesOf(1000, 9));
      await File(pc.abs(gone.path!)).delete();

      final (status, body) =
          await phone.call('POST', LrProtocol.pathVerify, json: const VerifyRequest(assetIds: ['OK', 'CH', 'GO', 'NEVER']).toJson());
      expect(status, 200);
      final items = {for (final v in VerifyResponse.fromJson(body).items) v.assetId: v};
      expect(items['OK']!.ok, isTrue);
      expect(items['CH']!.ok, isFalse);
      expect(items['CH']!.reason, 'changed');
      expect(items['GO']!.ok, isFalse);
      expect(items['GO']!.reason, 'missing');
      expect(items['NEVER']!.ok, isFalse);
    });

    test('deleted on the PC: the phone learns it from "changes"', () async {
      final phone = await pc.pairPhone();
      final r = await phone.upload('DEL', bytesOf(500));
      await File(pc.abs(r.path!)).delete();
      await pc.library.reconcile();
      final (status, body) = await phone.call('GET', LrProtocol.pathChanges, query: {'since': '0'});
      expect(status, 200);
      final changes = ChangesResponse.fromJson(body);
      expect(changes.deleted, contains('DEL'));
      expect(changes.library, pc.library.libraryId);
    });

    test('only the sender\'s own items are reported and verified', () async {
      final a = await pc.pairPhone(id: 'phoneA');
      final b = await pc.pairPhone(id: 'phoneB');
      await a.upload('SAME', bytesOf(100));
      final (_, body) = await b.call('POST', LrProtocol.pathVerify, json: const VerifyRequest(assetIds: ['SAME']).toJson());
      expect(VerifyResponse.fromJson(body).items.single.ok, isFalse);
    });

    test('library drive unplugged: nothing is accepted, nothing reads as "not backed up"', () async {
      final phone = await pc.pairPhone();
      await phone.upload('K1', bytesOf(100));
      await pc.library.flush();
      await Directory(pc.library.rootPath).delete(recursive: true);
      await pc.library.load();
      expect(pc.library.offline, isTrue);

      await expectLater(
        phone.client.createSession(SessionRequest(files: [
          const FileOffer(id: 'f1', assetId: 'K2', name: 'k.jpg', kind: MediaKind.image, createdMs: 1, modifiedMs: 1, size: 10),
        ])),
        throwsA(isA<LrHttpError>().having((e) => e.code, 'code', 'library_offline')),
      );
      final (status, body) = await phone.call('POST', LrProtocol.pathVerify, json: const VerifyRequest(assetIds: ['K1']).toJson());
      expect(status, 503);
      expect(body['error'], 'library_offline');
      // And nothing was turned into "deleted".
      final (_, ch) = await phone.call('GET', LrProtocol.pathChanges, query: {'since': '0'});
      expect(ChangesResponse.fromJson(ch).deleted, isEmpty);
    });
  });

  group('family group', () {
    test('"only me" can be set by the phone on its own photos', () async {
      final phone = await pc.pairPhone();
      await phone.upload('P1', bytesOf(100));
      final (status, body) =
          await phone.call('POST', LrProtocol.pathVisibility, json: const VisibilityRequest(assetIds: ['P1'], private: true).toJson());
      expect(status, 200);
      expect(body['updated'], 1);
      expect(pc.library.findByAsset(phone.id, 'P1')!.private, isTrue);
    });

    test('a guest waits for "Accept"; accepted, it goes in', () async {
      final phone = await pc.pairPhone();
      await pc.server.setFamily(phone.id, false);
      final asked = Completer<IncomingAsk>();
      void listen() {
        final a = pc.server.incomingAsks.value;
        if (a.isNotEmpty && !asked.isCompleted) asked.complete(a.first);
      }

      pc.server.incomingAsks.addListener(listen);
      final upload = phone.upload('G1', bytesOf(100));
      final ask = await asked.future.timeout(const Duration(seconds: 5));
      expect(ask.device.id, phone.id);
      pc.server.answerIncoming(ask, const AskAnswer(accept: true));
      expect((await upload).saved, isTrue);
      pc.server.incomingAsks.removeListener(listen);
    });

    test('a guest declined with a reason: the phone gets the reason; it can\'t ask again at once', () async {
      final phone = await pc.pairPhone();
      await pc.server.setFamily(phone.id, false);
      void listen() {
        for (final a in pc.server.incomingAsks.value) {
          pc.server.answerIncoming(a, const AskAnswer(accept: false, reason: 'Not now, please'));
        }
      }

      pc.server.incomingAsks.addListener(listen);
      await expectLater(
        phone.upload('G2', bytesOf(100)),
        throwsA(isA<LrHttpError>()
            .having((e) => e.status, 'status', 403)
            .having((e) => e.code, 'code', 'declined')
            .having((e) => e.body['reason'], 'reason', 'Not now, please')),
      );
      pc.server.incomingAsks.removeListener(listen);
      // Within a minute: refused straight away, no new question.
      final before = DateTime.now();
      await expectLater(phone.upload('G3', bytesOf(100)), throwsA(isA<LrHttpError>()));
      expect(DateTime.now().difference(before), lessThan(const Duration(seconds: 3)));
      expect(pc.library.items, isEmpty);
    });

    test('family members are not asked', () async {
      final phone = await pc.pairPhone();
      var asked = false;
      void listen() => asked = asked || pc.server.incomingAsks.value.isNotEmpty;
      pc.server.incomingAsks.addListener(listen);
      expect((await phone.upload('F1', bytesOf(100))).saved, isTrue);
      expect(asked, isFalse);
      pc.server.incomingAsks.removeListener(listen);
    });

    test('a guest asks to join; the owner agrees', () async {
      final phone = await pc.pairPhone();
      await pc.server.setFamily(phone.id, false);
      void listen() {
        for (final a in pc.server.membershipAsks.value) {
          pc.server.answerMembership(a, allow: true);
        }
      }

      pc.server.membershipAsks.addListener(listen);
      expect(await phone.client.membership(family: true), isTrue);
      expect(pc.settings.trusted[phone.id]!.familyMember, isTrue);
      pc.server.membershipAsks.removeListener(listen);
      // Leaving needs nobody's agreement.
      expect(await phone.client.membership(family: false), isFalse);
      expect(pc.settings.trusted[phone.id]!.familyMember, isFalse);
    });
  });

  group('online / offline', () {
    Future<WebSocket> link(TestPhone p, {Map<String, String> extra = const {}}) => WebSocket.connect(
          Uri(
            scheme: 'wss',
            host: '127.0.0.1',
            port: pc.port,
            path: LrProtocol.pathLive,
            queryParameters: {'session': 's1', ...extra},
          ).toString(),
          headers: {LrProtocol.headerDeviceId: p.id, LrProtocol.headerToken: p.token},
          customClient: lrHttpClient(pin: pc.tls.fingerprint),
        );

    test('live link: online at once, offline the moment it closes', () async {
      final phone = await pc.pairPhone();
      expect(pc.server.isOnline(phone.id), isFalse);
      final ws = await link(phone);
      final first = Completer<LiveMessage>();
      ws.listen((d) {
        final m = LiveMessage.parse(d);
        if (m != null && !first.isCompleted) first.complete(m);
      });
      expect((await first.future.timeout(const Duration(seconds: 5))).type, 'hello');
      expect(pc.server.isOnline(phone.id), isTrue);
      await ws.close();
      await eventually(() => !pc.server.isOnline(phone.id));
    });

    test('others hear when a device comes and goes', () async {
      final a = await pc.pairPhone(id: 'phoneA', name: 'A');
      final b = await pc.pairPhone(id: 'phoneB', name: 'B');
      final heard = <String>[];
      final wsA = await link(a);
      wsA.listen((d) {
        final m = LiveMessage.parse(d);
        if (m != null && (m.type == 'up' || m.type == 'down')) heard.add('${m.type}:${m.device?.id ?? m.id}');
      });
      await eventually(() => pc.server.isOnline(a.id));
      final wsB = await link(b);
      await eventually(() => heard.contains('up:phoneB'));
      await wsB.close();
      await eventually(() => heard.contains('down:phoneB'));
      await wsA.close();
    });

    test('a phone\'s live link tells where it receives', () async {
      final phone = await pc.pairPhone();
      final ws = await link(phone, extra: {'rport': '53317', 'rfp': 'cd' * 32, 'rtk': 'secret-for-this-pc'});
      await eventually(() => pc.server.phoneEndpoint(phone.id) != null);
      final ep = pc.server.phoneEndpoint(phone.id)!;
      expect(ep.port, 53317);
      expect(ep.fingerprint, 'cd' * 32);
      // The secret to show when sending there (it proves the files are from us).
      expect(ep.token, 'secret-for-this-pc');
      await ws.close();
      await eventually(() => pc.server.phoneEndpoint(phone.id) == null);
    });

    test('a phone learns where another phone receives (from the PC, with its certificate)', () async {
      final a = await pc.pairPhone(id: 'phoneA', name: 'A');
      final b = await pc.pairPhone(id: 'phoneB', name: 'B');
      final wsA = await link(a, extra: {'rport': '53317', 'rfp': 'ab' * 32});
      await eventually(() => pc.server.phoneEndpoint(a.id) != null);
      final wsB = await link(b);
      final hello = Completer<LiveMessage>();
      wsB.listen((d) {
        final m = LiveMessage.parse(d);
        if (m != null && m.type == 'hello' && !hello.isCompleted) hello.complete(m);
      });
      final seen = (await hello.future.timeout(const Duration(seconds: 5))).online.firstWhere((o) => o.id == 'phoneA');
      expect(seen.port, 53317);
      expect(seen.fingerprint, 'ab' * 32);
      expect(seen.host, isNotNull);
      await wsA.close();
      await wsB.close();
    });

    test('a live link needs a valid token', () async {
      final phone = await pc.pairPhone();
      await expectLater(link(TestPhone(pc, phone.id, 'wrong')), throwsA(anything));
    });

    test('"I\'m leaving" without a live link: offline at once', () async {
      final phone = await pc.pairPhone();
      await phone.client.presence(online: true);
      expect(pc.server.isOnline(phone.id), isTrue);
      await phone.client.presence(online: false);
      expect(pc.server.isOnline(phone.id), isFalse);
    });
  });

  group('browsing from a phone', () {
    late List<List<String>> sentToPhone;

    setUp(() {
      sentToPhone = [];
      pc.server.thumbnail = (item) async {
        final f = File('${pc.tmp.path}${Platform.pathSeparator}thumb_${item.name}.jpg');
        await f.writeAsBytes([0xFF, 0xD8, 0xFF, 1, 2, 3]);
        return f;
      };
      pc.server.display = pc.server.thumbnail;
      pc.server.deleter = (items) async {
        final all = pc.library.withLive(items);
        for (final i in all) {
          await File(pc.library.absPath(i)).delete();
        }
        pc.library.removeItems(all);
        return items.length;
      };
      pc.server.sendToPhone = (d, items) async {
        sentToPhone.add([for (final i in items) i.relPath]);
        return items.length;
      };
    });

    Future<void> fill(TestPhone phone) async {
      await phone.upload('P1', bytesOf(1000, 1), name: 'old.jpg', captured: DateTime(2023, 1, 1));
      await phone.upload('P2', bytesOf(1000, 2), name: 'new.jpg', captured: DateTime(2025, 6, 1));
      await phone.upload('V1', bytesOf(3000, 3), name: 'clip.mp4', kind: MediaKind.video, captured: DateTime(2024, 3, 1));
    }

    test('family member: the library, newest first, by kind, in pages', () async {
      final phone = await pc.pairPhone();
      await fill(phone);
      final page = await phone.client.library();
      expect(page.access, LibraryAccess.view);
      expect(page.items.map((i) => i.name), ['new.jpg', 'clip.mp4', 'old.jpg']);
      expect(page.items.first.mine, isTrue);
      expect(page.total, 3);
      expect(page.next, isNull);
      expect((await phone.client.library(kind: MediaKind.video)).items.single.name, 'clip.mp4');
      final first = await phone.client.library(limit: 2);
      expect(first.items, hasLength(2));
      expect(first.next, 2);
      final rest = await phone.client.library(offset: first.next!, limit: 2);
      expect(rest.items.single.name, 'old.jpg');
      expect(rest.next, isNull);
    });

    test('a guest can\'t browse unless the PC allows it', () async {
      final phone = await pc.pairPhone();
      await pc.server.setFamily(phone.id, false);
      await expectLater(phone.client.library(),
          throwsA(isA<LrHttpError>().having((e) => e.status, 'status', 403).having((e) => e.code, 'code', 'no_access')));
      await pc.settings.update((s) => s.trusted[phone.id]!.access = LibraryAccess.view);
      expect((await phone.client.library()).access, LibraryAccess.view);
    });

    test('a family member can be kept out too', () async {
      final phone = await pc.pairPhone();
      await pc.settings.update((s) => s.trusted[phone.id]!.access = LibraryAccess.none);
      await expectLater(phone.client.library(), throwsA(isA<LrHttpError>().having((e) => e.status, 'status', 403)));
    });

    test('someone else\'s "only me" stays hidden — in the list and by path', () async {
      final mum = await pc.pairPhone(id: 'mum', name: 'Mum');
      final dad = await pc.pairPhone(id: 'dad', name: 'Dad');
      final secret = await mum.upload('S1', bytesOf(500), name: 'secret.jpg', private: true);
      await mum.upload('S2', bytesOf(500, 2), name: 'shared.jpg');
      expect((await dad.client.library()).items.map((i) => i.name), ['shared.jpg']);
      await expectLater(dad.client.libraryThumb(secret.path!), throwsA(isA<LrHttpError>().having((e) => e.status, 'status', 404)));
      final res = await dad.client.open(dad.client.libraryFileUri(secret.path!));
      expect(res.statusCode, 404);
      await res.drain<void>();
      // Mum sees her own, marked as hers and private.
      final own = (await mum.client.library()).items.firstWhere((i) => i.name == 'secret.jpg');
      expect(own.private, isTrue);
      expect(own.mine, isTrue);
    });

    test('only files in the library can be asked for', () async {
      final phone = await pc.pairPhone();
      await fill(phone);
      for (final bad in ['../data/settings.json', '.localroll/index.json', '/etc/passwd', '']) {
        final res = await phone.client.open(phone.client.libraryFileUri(bad));
        expect(res.statusCode, 404, reason: bad);
        await res.drain<void>();
      }
    });

    test('originals: whole, or the asked-for part (video players)', () async {
      final phone = await pc.pairPhone();
      final data = bytesOf(3000, 9);
      final r = await phone.upload('V9', data, name: 'v.mp4', kind: MediaKind.video);
      final uri = phone.client.libraryFileUri(r.path!);
      final whole = await phone.client.open(uri);
      expect(whole.statusCode, 200);
      expect(whole.headers.contentType?.mimeType, 'video/mp4');
      expect(await whole.fold<List<int>>([], (a, b) => a..addAll(b)), data);

      final part = await phone.client.open(uri, range: 'bytes=100-199');
      expect(part.statusCode, 206);
      expect(part.headers.value(HttpHeaders.contentRangeHeader), 'bytes 100-199/3000');
      expect(await part.fold<List<int>>([], (a, b) => a..addAll(b)), data.sublist(100, 200));

      final tail = await phone.client.open(uri, range: 'bytes=-50');
      expect(tail.statusCode, 206);
      expect(await tail.fold<List<int>>([], (a, b) => a..addAll(b)), data.sublist(2950));

      final past = await phone.client.open(uri, range: 'bytes=5000-');
      expect(past.statusCode, 416);
      await past.drain<void>();
    });

    test('pictures for the grid and the screen', () async {
      final phone = await pc.pairPhone();
      final r = await phone.upload('T1', bytesOf(100), name: 't.heic');
      expect(await phone.client.libraryThumb(r.path!), [0xFF, 0xD8, 0xFF, 1, 2, 3]);
      expect(await phone.client.libraryView(r.path!), [0xFF, 0xD8, 0xFF, 1, 2, 3]);
    });

    test('a Live Photo is one item that knows its video', () async {
      final phone = await pc.pairPhone();
      final photo = await phone.upload('L1', bytesOf(400), name: 'IMG_7.HEIC');
      final video = await phone.upload(liveCompanionId('L1'), bytesOf(900, 2), name: 'IMG_7.MOV', kind: MediaKind.video);
      final items = (await phone.client.library()).items;
      expect(items, hasLength(1));
      expect(items.single.path, photo.path);
      expect(items.single.live, video.path);
    });

    test('delete needs "manage"; then it goes, and the phone that sent it is told', () async {
      final mum = await pc.pairPhone(id: 'mum');
      final dad = await pc.pairPhone(id: 'dad');
      final r = await mum.upload('D1', bytesOf(100), name: 'd.jpg');
      await expectLater(dad.client.libraryDelete([r.path!]),
          throwsA(isA<LrHttpError>().having((e) => e.status, 'status', 403)));
      expect(File(pc.abs(r.path!)).existsSync(), isTrue);

      await pc.settings.update((s) => s.trusted['dad']!.access = LibraryAccess.manage);
      expect(await dad.client.libraryDelete([r.path!, 'not/there.jpg']), 1);
      expect(File(pc.abs(r.path!)).existsSync(), isFalse);
      expect((await dad.client.library()).items, isEmpty);
      final (_, ch) = await mum.call('GET', LrProtocol.pathChanges, query: {'since': '0'});
      expect(ChangesResponse.fromJson(ch).deleted, contains('D1'));
    });

    test('visibility: only of one\'s own items', () async {
      final mum = await pc.pairPhone(id: 'mum');
      final dad = await pc.pairPhone(id: 'dad');
      final m = await mum.upload('M1', bytesOf(100), name: 'm.jpg');
      final d = await dad.upload('D1', bytesOf(100, 2), name: 'd.jpg');
      expect(await dad.client.libraryVisibility([m.path!, d.path!], private: true), 1);
      expect(pc.library.findByAsset('mum', 'M1')!.private, isFalse);
      expect(pc.library.findByAsset('dad', 'D1')!.private, isTrue);
    });

    test('"save to my phone": the PC queues them for that phone', () async {
      final phone = await pc.pairPhone();
      await fill(phone);
      final items = (await phone.client.library()).items;
      expect(await phone.client.librarySend([items.first.path, 'nope.jpg']), 1);
      expect(sentToPhone.single, [items.first.path]);
      pc.server.sendToPhone = (d, items) async => throw StateError('closed');
      await expectLater(phone.client.librarySend([items.first.path]),
          throwsA(isA<LrHttpError>().having((e) => e.code, 'code', 'phone_closed')));
    });
  });
}
