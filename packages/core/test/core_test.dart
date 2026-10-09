// packages/core/test/core_test.dart
import 'dart:convert';
import 'dart:io';

import 'package:localroll_core/localroll_core.dart';
import 'package:test/test.dart';

void main() {
  test('pairing payload round-trips', () {
    const p = PairingPayload(
      deviceId: 'abc',
      name: '客厅电脑',
      hosts: ['192.168.1.68', '10.0.0.5'],
      port: 53530,
      pin: '123456',
    );
    final decoded = PairingPayload.tryDecode(p.encode());
    expect(decoded, isNotNull);
    expect(decoded!.name, '客厅电脑');
    expect(decoded.hosts, ['192.168.1.68', '10.0.0.5']);
    expect(decoded.pin, '123456');
  });

  test('foreign QR codes are ignored', () {
    expect(PairingPayload.tryDecode('https://example.com'), isNull);
    expect(PairingPayload.tryDecode('LOCALROLL:not-base64!!'), isNull);
  });

  test('session models round-trip through JSON', () {
    const req = SessionRequest(files: [
      FileOffer(
        id: '0',
        assetId: 'A1/L0/001',
        name: 'IMG_0001.HEIC',
        kind: MediaKind.image,
        createdMs: 1700000000000,
        modifiedMs: 1700000000001,
      ),
    ]);
    final back = SessionRequest.fromJson(
        jsonDecode(jsonEncode(req.toJson())) as Map<String, dynamic>);
    expect(back.files.single.name, 'IMG_0001.HEIC');
    expect(back.files.single.kind, MediaKind.image);
    expect(back.files.single.size, isNull);
  });

  test('media kind and file names', () {
    expect(MediaKind.fromName('IMG_1.HEIC'), MediaKind.image);
    expect(MediaKind.fromName('clip.MOV'), MediaKind.video);
    expect(MediaKind.fromName('notes.txt'), MediaKind.other);
    expect(sanitizeFileName('../evil/na:me?.jpg'), 'na_me_.jpg');
    expect(sanitizeFileName('trailing. '), 'trailing');
  });

  test('streaming sha256 matches whole-file sha256', () async {
    final dir = await Directory.systemTemp.createTemp('lr');
    final f = File('${dir.path}/x.bin');
    await f.writeAsBytes(List<int>.generate(100000, (i) => i % 251));
    final h = StreamingSha256()
      ..add((await f.readAsBytes()).sublist(0, 4000))
      ..add((await f.readAsBytes()).sublist(4000));
    expect(h.finish(), await sha256OfFile(f));
    await dir.delete(recursive: true);
  });

  test('language matching', () {
    expect(matchLanguage('zh', countryCode: 'CN'), 'zh');
    expect(matchLanguage('zh', countryCode: 'TW'), 'zh_Hant');
    expect(matchLanguage('zh', scriptCode: 'Hant', countryCode: 'US'), 'zh_Hant');
    expect(matchLanguage('zh', scriptCode: 'Hans', countryCode: 'HK'), 'zh');
    expect(matchLanguage('in'), 'id');
    expect(matchLanguage('pl'), isNull);
  });

  test('translator falls back to English and fills placeholders', () {
    final t = Translator({
      'en': {'hi': 'Hello {name}', 'only_en': 'English only'},
      'ja': {'hi': 'こんにちは {name}'},
    })..language = 'ja';
    expect(t.tr('hi', {'name': 'Xue'}), 'こんにちは Xue');
    expect(t.tr('only_en'), 'English only');
    expect(t.tr('missing.key'), 'missing.key');
  });

  test('verify request/response round-trip', () {
    final req = VerifyRequest.fromJson(const VerifyRequest(assetIds: ['a', 'b']).toJson());
    expect(req.assetIds, ['a', 'b']);
    final res = VerifyResponse.fromJson(const VerifyResponse(items: [
      VerifiedAsset(assetId: 'a', ok: true, size: 42),
      VerifiedAsset(assetId: 'b', ok: false, reason: 'missing'),
    ]).toJson());
    expect(res.items.first.ok, isTrue);
    expect(res.items.first.size, 42);
    expect(res.items.last.reason, 'missing');
  });
}
