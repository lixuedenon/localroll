// apps/desktop/test/tls_test.dart
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:localroll_core/localroll_core.dart';
import 'package:localroll_desktop/server/port_mux.dart';
import 'package:localroll_desktop/services/tls_identity.dart';

void main() {
  late Directory dir;
  late TlsIdentity id;
  late PortMux mux;

  setUpAll(() async {
    dir = await Directory.systemTemp.createTemp('lr_tls');
    id = await TlsIdentity.load(dir);
    mux = await PortMux.bind(InternetAddress.loopbackIPv4, 0, id.context);
    for (final (src, label) in [(mux.plain, 'plain'), (mux.secure, 'secure')]) {
      final http = HttpServer.listenOn(src);
      http.listen((req) async {
        final n = await req.fold<int>(0, (a, b) => a + b.length);
        req.response.headers.contentType = ContentType.json;
        if (req.uri.path == LrProtocol.pathInfo) {
          req.response.write(jsonEncode(DeviceInfo(id: label, name: 'PC', platform: 'windows').toJson()));
        } else {
          req.response.write(jsonEncode({'echo': n, 'from': label}));
        }
        await req.response.close();
      });
    }
  });

  tearDownAll(() async {
    await mux.close();
    await dir.delete(recursive: true);
  });

  test('certificate is made once and reloaded with the same fingerprint', () async {
    expect(id.fingerprint, matches(RegExp(r'^[0-9a-f]{64}$')));
    final again = await TlsIdentity.load(dir);
    expect(again.fingerprint, id.fingerprint);
  });

  test('one port answers plain HTTP and HTTPS', () async {
    final plain = LrClient(host: '127.0.0.1', port: mux.port);
    final secure = LrClient(host: '127.0.0.1', port: mux.port, secure: true, pin: id.fingerprint);
    try {
      expect((await plain.info()).id, 'plain');
      expect((await secure.info()).id, 'secure');
    } finally {
      plain.close();
      secure.close();
    }
  });

  test('first contact sees the certificate; a wrong pin is refused', () async {
    final first = LrClient(host: '127.0.0.1', port: mux.port, secure: true);
    final wrong = LrClient(host: '127.0.0.1', port: mux.port, secure: true, pin: 'ab' * 32);
    try {
      expect((await first.info()).id, 'secure');
      expect(first.seenFingerprint, id.fingerprint);
      await expectLater(wrong.info(), throwsA(anything));
    } finally {
      first.close();
      wrong.close();
    }
  });

  test('large bodies pass through both paths intact', () async {
    final big = List<int>.generate(3 * 1024 * 1024, (i) => i % 251);
    for (final secure in [false, true]) {
      final c = HttpClient()..badCertificateCallback = (cert, _, _) => certFingerprint(cert.der) == id.fingerprint;
      try {
        final req = await c.putUrl(Uri(scheme: secure ? 'https' : 'http', host: '127.0.0.1', port: mux.port, path: '/x'));
        req.contentLength = big.length;
        req.add(big);
        final res = await req.close();
        final j = jsonDecode(await utf8.decoder.bind(res).join()) as Map<String, dynamic>;
        expect(j['from'], secure ? 'secure' : 'plain');
        expect(j['echo'], big.length);
      } finally {
        c.close(force: true);
      }
    }
  });

  test('LAN check', () {
    expect(isLanAddress(InternetAddress('192.168.1.5')), isTrue);
    expect(isLanAddress(InternetAddress('10.0.0.2')), isTrue);
    expect(isLanAddress(InternetAddress('172.20.1.1')), isTrue);
    expect(isLanAddress(InternetAddress('100.100.1.1')), isTrue);
    expect(isLanAddress(InternetAddress('127.0.0.1')), isTrue);
    expect(isLanAddress(InternetAddress('8.8.8.8')), isFalse);
    expect(isLanAddress(InternetAddress('172.32.0.1')), isFalse);
    expect(isLanAddress(InternetAddress('::ffff:192.168.0.9')), isTrue);
    expect(isLanAddress(InternetAddress('2001:4860::1')), isFalse);
    expect(isLanAddress(InternetAddress('fd00::1')), isTrue);
  });

  test('fresh certificates are always usable (several in a row)', () async {
    for (var i = 0; i < 4; i++) {
      final d = await Directory.systemTemp.createTemp('lr_tls_new');
      try {
        final fresh = await TlsIdentity.load(d);
        final m = await PortMux.bind(InternetAddress.loopbackIPv4, 0, fresh.context);
        await m.close();
        expect((await TlsIdentity.load(d)).fingerprint, fresh.fingerprint);
      } finally {
        await d.delete(recursive: true);
      }
    }
  }, timeout: const Timeout(Duration(minutes: 3)));
}

