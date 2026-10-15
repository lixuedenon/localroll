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
      final ws = await link(phone, extra: {'rport': '53317', 'rfp': 'cd' * 32});
      await eventually(() => pc.server.phoneEndpoint(phone.id) != null);
      final ep = pc.server.phoneEndpoint(phone.id)!;
      expect(ep.port, 53317);
      expect(ep.fingerprint, 'cd' * 32);
      await ws.close();
      await eventually(() => pc.server.phoneEndpoint(phone.id) == null);
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
}
