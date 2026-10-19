// apps/mobile/test/phone_server_test.dart
//
// The phone's receiver end to end: a real HTTPS server on a free port (its
// own certificate, pinned by the sender), the "Accept / Decline" question,
// resume, checks and limits. What would go to the photo library is caught
// by a fake saver.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:localroll_core/localroll_core.dart';
import 'package:localroll_mobile/services/media_saver.dart';
import 'package:localroll_mobile/services/phone_server.dart';

class _Me implements PhoneIdentity {
  @override
  String get deviceId => 'phone-under-test';
  @override
  String get deviceName => 'Test Phone';
}

class _FakeSaver extends MediaSaver {
  final List<(FileOffer, List<int>)> saved = [];

  @override
  Future<SavedTo> save(File file, FileOffer offer, {Sender from = const Sender('', '')}) async {
    saved.add((offer, await file.readAsBytes()));
    await file.delete();
    return offer.kind == MediaKind.other ? SavedTo.files : SavedTo.album;
  }

  @override
  Future<void> flushAll() async {}
}

List<int> bytesOf(int n, [int seed = 1]) => List.generate(n, (i) => (i * 17 + seed) & 0xff);

Future<String> sha(List<int> data) async {
  final dir = await Directory.systemTemp.createTemp('lr_sha');
  try {
    final f = File('${dir.path}/x');
    await f.writeAsBytes(data);
    return await sha256OfFile(f);
  } finally {
    await dir.delete(recursive: true);
  }
}

void main() {
  late Directory tmp;
  late _FakeSaver saver;
  late PhoneServer server;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('lr_phone_test');
    saver = _FakeSaver();
    server = PhoneServer(
      _Me(),
      saver: saver,
      dataDir: () async => Directory('${tmp.path}/data')..createSync(recursive: true),
      tempDir: () async => Directory('${tmp.path}/tmp')..createSync(recursive: true),
      advertise: false,
      ports: const [0],
    );
    await server.start();
    expect(server.running, isTrue);
  });

  tearDown(() async {
    await server.stop();
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  LrClient sender(String id) =>
      LrClient(host: '127.0.0.1', port: server.port, deviceId: id, secure: true, pin: server.fingerprint);

  DeviceInfo who(String id) => DeviceInfo(id: id, name: 'Sender $id', platform: 'windows');

  /// Answers every question with [reply] (as the person on the phone would).
  void Function() answering(IncomingReply reply) {
    void listen() {
      for (final a in server.asks.value) {
        server.answer(a, reply);
      }
    }

    server.asks.addListener(listen);
    return () => server.asks.removeListener(listen);
  }

  Future<CompleteResponse> send(LrClient c, String from, String asset, List<int> data,
      {String name = 'IMG_1.JPG', MediaKind kind = MediaKind.image}) async {
    final offer =
        FileOffer(id: 'f1', assetId: asset, name: name, kind: kind, createdMs: 1, modifiedMs: 1, size: data.length);
    final s = await c.createSession(SessionRequest(files: [offer], from: who(from), batch: 1));
    var off = s.results['f1']!.offset;
    if (off < data.length) off = await c.putChunk(s.sessionId, 'f1', off, data.length, data.sublist(off));
    return c.complete(s.sessionId, 'f1', CompleteRequest(size: data.length, sha256: await sha(data)));
  }

  test('its certificate is what senders pin', () async {
    final info = await LrClient(host: '127.0.0.1', port: server.port, secure: true, pin: server.fingerprint).info();
    expect(info.id, 'phone-under-test');
    expect(info.fingerprint, server.fingerprint);
  });

  test('accepted: the file arrives intact and is saved', () async {
    final stop = answering(const IncomingReply(accept: true));
    final data = bytesOf(150 * 1024);
    final r = await send(sender('pc1'), 'pc1', 'A', data, name: 'beach.jpg');
    stop();
    expect(r.saved, isTrue);
    expect(saver.saved, hasLength(1));
    expect(saver.saved.single.$1.name, 'beach.jpg');
    expect(saver.saved.single.$2, data);
  });

  test('asked once per transfer: the next files of an accepted one go straight in', () async {
    var asked = 0;
    void listen() {
      for (final a in server.asks.value) {
        asked++;
        server.answer(a, const IncomingReply(accept: true));
      }
    }

    server.asks.addListener(listen);
    final c = sender('pc1');
    await send(c, 'pc1', 'A', bytesOf(100));
    await send(c, 'pc1', 'B', bytesOf(100, 2));
    server.asks.removeListener(listen);
    expect(asked, 1);
    expect(saver.saved, hasLength(2));
  });

  test('declined with a reason: the sender gets it; asking again at once is refused', () async {
    final stop = answering(const IncomingReply(accept: false, reason: 'Not now'));
    final c = sender('pc1');
    await expectLater(
      send(c, 'pc1', 'A', bytesOf(100)),
      throwsA(isA<LrHttpError>()
          .having((e) => e.status, 'status', 403)
          .having((e) => e.code, 'code', 'declined')
          .having((e) => e.body['reason'], 'reason', 'Not now')),
    );
    stop();
    var askedAgain = false;
    void listen() => askedAgain = askedAgain || server.asks.value.isNotEmpty;
    server.asks.addListener(listen);
    await expectLater(send(c, 'pc1', 'A', bytesOf(100)), throwsA(isA<LrHttpError>()));
    server.asks.removeListener(listen);
    expect(askedAgain, isFalse);
    expect(saver.saved, isEmpty);
  });

  test('closing the app while asked: counts as declined', () async {
    final c = sender('pc1');
    final asked = Completer<void>();
    void listen() {
      if (server.asks.value.isNotEmpty && !asked.isCompleted) asked.complete();
    }

    server.asks.addListener(listen);
    final pending = send(c, 'pc1', 'A', bytesOf(100));
    await asked.future.timeout(const Duration(seconds: 5));
    server.asks.removeListener(listen);
    unawaited(server.stop());
    await expectLater(pending, throwsA(anything));
    expect(saver.saved, isEmpty);
  });

  test('someone else can\'t use an accepted sender\'s session', () async {
    final stop = answering(const IncomingReply(accept: true));
    final a = sender('pc1');
    final s = await a.createSession(SessionRequest(files: [
      const FileOffer(id: 'f1', assetId: 'A', name: 'a.jpg', kind: MediaKind.image, createdMs: 1, modifiedMs: 1, size: 10),
    ], from: who('pc1')));
    stop();
    await expectLater(
      sender('intruder').putChunk(s.sessionId, 'f1', 0, 10, bytesOf(10)),
      throwsA(isA<LrHttpError>().having((e) => e.status, 'status', 404)),
    );
  });

  test('a sender claiming another id is refused', () async {
    await expectLater(
      sender('pc1').createSession(SessionRequest(files: const [], from: who('someone-else'))),
      throwsA(isA<LrHttpError>().having((e) => e.status, 'status', 400)),
    );
  });

  test('a paired PC proves itself with the secret it was given; a look-alike can\'t', () async {
    final secret = server.receiveTokenFor('pc1');
    final seen = <IncomingAsk>[];
    void listen() {
      for (final a in server.asks.value) {
        if (!seen.contains(a)) seen.add(a);
        server.answer(a, const IncomingReply(accept: true));
      }
    }

    server.asks.addListener(listen);
    final real = LrClient(host: '127.0.0.1', port: server.port, deviceId: 'pc1', token: secret, secure: true, pin: server.fingerprint);
    await send(real, 'pc1', 'A', bytesOf(100));
    final fake = LrClient(host: '127.0.0.1', port: server.port, deviceId: 'pc2', token: secret, secure: true, pin: server.fingerprint);
    await send(fake, 'pc2', 'B', bytesOf(100, 2)); // someone else's secret
    server.asks.removeListener(listen);
    expect(seen.map((a) => a.verified), [true, false]);
  });

  test('"save to my phone": only the real PC goes straight in; a look-alike is asked', () async {
    final secret = server.receiveTokenFor('pc1');
    server.expectFrom('pc1');
    var asked = 0;
    void listen() {
      for (final a in server.asks.value) {
        asked++;
        expect(a.verified, isFalse);
        server.answer(a, const IncomingReply(accept: false));
      }
    }

    server.asks.addListener(listen);
    final real = LrClient(host: '127.0.0.1', port: server.port, deviceId: 'pc1', token: secret, secure: true, pin: server.fingerprint);
    expect((await send(real, 'pc1', 'A', bytesOf(100))).saved, isTrue);
    // Same id, no secret (copied from the Wi‑Fi): asked, and declined here.
    await expectLater(send(sender('pc1'), 'pc1', 'B', bytesOf(100, 2)), throwsA(isA<LrHttpError>()));
    server.asks.removeListener(listen);
    expect(asked, 1);
    expect(saver.saved, hasLength(1));
  });

  test('at most $maxOpenAsks questions at once', () async {
    final pending = <Future<void>>[];
    for (var i = 0; i < maxOpenAsks; i++) {
      pending.add(send(sender('x$i'), 'x$i', 'A', bytesOf(10)).then((_) {}, onError: (_) {}));
    }
    await eventuallyAsks(server, maxOpenAsks);
    await expectLater(
      send(sender('x9'), 'x9', 'A', bytesOf(10)),
      throwsA(isA<LrHttpError>().having((e) => e.status, 'status', 429)),
    );
    for (final a in server.asks.value) {
      server.answer(a, const IncomingReply(accept: false));
    }
    await Future.wait(pending);
  });

  test('interrupted: resumes; wrong place refused; damaged data refused', () async {
    final stop = answering(const IncomingReply(accept: true));
    final c = sender('pc1');
    final data = bytesOf(80000, 4);
    final offer =
        FileOffer(id: 'f1', assetId: 'V', name: 'v.mp4', kind: MediaKind.video, createdMs: 1, modifiedMs: 1, size: data.length);
    final s1 = await c.createSession(SessionRequest(files: [offer], from: who('pc1')));
    await c.putChunk(s1.sessionId, 'f1', 0, data.length, data.sublist(0, 30000));
    final s2 = await c.createSession(SessionRequest(files: [offer], from: who('pc1')));
    stop();
    expect(s2.results['f1']!.offset, 30000);
    await expectLater(
      c.putChunk(s2.sessionId, 'f1', 0, data.length, data),
      throwsA(isA<LrHttpError>().having((e) => e.status, 'status', 409)),
    );
    await c.putChunk(s2.sessionId, 'f1', 30000, data.length, data.sublist(30000));
    await expectLater(
      c.complete(s2.sessionId, 'f1', CompleteRequest(size: data.length, sha256: '0' * 64)),
      throwsA(isA<LrHttpError>().having((e) => e.status, 'status', 422)),
    );
    expect(saver.saved, isEmpty);
  });

  test('more bytes than the file said: refused', () async {
    final stop = answering(const IncomingReply(accept: true));
    final c = sender('pc1');
    final s = await c.createSession(SessionRequest(files: [
      const FileOffer(id: 'f1', assetId: 'A', name: 'a.jpg', kind: MediaKind.image, createdMs: 1, modifiedMs: 1, size: 100),
    ], from: who('pc1')));
    stop();
    await expectLater(
      c.putChunk(s.sessionId, 'f1', 0, 100, bytesOf(10000)),
      throwsA(isA<LrHttpError>().having((e) => e.status, 'status', 413)),
    );
    expect(await c.status(s.sessionId, 'f1'), lessThanOrEqualTo(100));
  });

  test('huge or malformed requests are refused; it keeps working', () async {
    Future<int> raw(List<int> body) async {
      final h = lrHttpClient(pin: server.fingerprint);
      try {
        final req = await h.postUrl(Uri.parse('https://127.0.0.1:${server.port}${LrProtocol.pathSessions}'));
        req.headers.set(LrProtocol.headerDeviceId, 'pc1');
        req.add(body);
        final res = await req.close();
        await res.drain<void>();
        return res.statusCode;
      } finally {
        h.close(force: true);
      }
    }

    expect(await raw(utf8.encode('{"files":[${List.filled(300000, '"xxxxxxxxxxxxxxxx"').join(',')}]}')), 413);
    expect(await raw(utf8.encode('{nope')), 400);
    expect(await raw(utf8.encode('{"files":"nope"}')), 400);
    final stop = answering(const IncomingReply(accept: true));
    expect((await send(sender('pc1'), 'pc1', 'OK', bytesOf(10))).saved, isTrue);
    stop();
  });
}

/// Waits until [n] questions are open.
Future<void> eventuallyAsks(PhoneServer server, int n) async {
  final end = DateTime.now().add(const Duration(seconds: 5));
  while (server.asks.value.length < n) {
    if (DateTime.now().isAfter(end)) throw StateError('only ${server.asks.value.length} questions open');
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}
