// packages/core/test/core_test.dart
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

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

  test('pairing emoji are stable, 3 long, and differ between requests', () {
    final a = pairingEmoji('request-1');
    expect(a, hasLength(3));
    expect(pairingEmoji('request-1'), a);
    expect(pairingEmoji('request-2'), isNot(a));
  });

  test('random device names exist for every supported language', () {
    for (final l in supportedLanguages) {
      final n = DeviceNames.random(l.code, rng: Random(1));
      expect(n.trim(), isNotEmpty, reason: l.code);
      expect(n.length, lessThan(30), reason: l.code);
    }
    expect(DeviceNames.random('xx'), isNotEmpty); // falls back to English
  });

  test('every language has 576 names and avoid works', () {
    for (final l in supportedLanguages) {
      expect(DeviceNames.countFor(l.code), 576, reason: l.code);
    }
    final rng = Random(7);
    final seen = <String>{};
    for (var i = 0; i < 200; i++) {
      final n = DeviceNames.random('zh', rng: rng, avoid: seen);
      expect(seen.add(n), isTrue, reason: 'repeated $n after $i');
    }
  });

  test('DeviceInfo keeps its look', () {
    final d = DeviceInfo.fromJson(const DeviceInfo(
      id: 'a', name: 'n', platform: 'windows', icon: 'sofa', color: 0xFF5FD4C4, avatar: 3,
    ).toJson());
    expect(d.icon, 'sofa');
    expect(d.color, 0xFF5FD4C4);
    expect(d.avatar, 3);
  });

  test('language data comes from packages/core/l10n', () {
    expect(supportedLanguages.first.code, 'en');
    expect(supportedLanguages.length, 17);
    final t = Translator(const {})..language = 'ar';
    expect(t.isRtl, isTrue);
    for (final l in supportedLanguages) {
      expect(deviceNameWords.containsKey(l.code), isTrue, reason: l.code);
    }
  });

  test('names elide before a vowel (fr / it)', () {
    final fr = deviceNameWords['fr']!;
    expect(fr.compose('Phare', 'Ambre'), 'Phare d’Ambre');
    expect(fr.compose('Phare', 'Lune'), 'Phare de Lune');
    expect(deviceNameWords['it']!.compose('Faro', 'Luna'), 'Faro di Luna');
    expect(deviceNameWords['ja']!.compose('琥珀', '灯台'), '琥珀の灯台');
  });

  test('live photo companion ids', () {
    final id = liveCompanionId('ABC/L0/001');
    expect(id, 'ABC/L0/001#live');
    expect(isLiveCompanion(id), isTrue);
    expect(isLiveCompanion('ABC/L0/001'), isFalse);
    expect(livePhotoIdOf(id), 'ABC/L0/001');
    expect(livePhotoIdOf('X'), 'X');
  });

  group('Exif', () {
    // Made with libheif / Pillow: Orientation 6, Make "Apple",
    // DateTimeOriginal 2026:10:09 12:34:56.
    final heic = File('test/fixtures/sample.heic').readAsBytesSync();
    final jpg = File('test/fixtures/sample.jpg').readAsBytesSync();

    test('reads EXIF from HEIC and JPEG', () {
      for (final f in [heic, jpg]) {
        final tiff = Exif.extractTiff(f);
        expect(tiff, isNotNull);
        expect(Exif.orientation(tiff!), 6);
        expect(String.fromCharCodes(tiff).contains('2026:10:09 12:34:56'), isTrue);
      }
    });

    test('moves EXIF into a converted JPEG and resets orientation', () {
      final tiff = Exif.withOrientation(Exif.extractTiff(heic)!, 1);
      expect(Exif.orientation(tiff), 1);
      // A JPEG without EXIF (strip it from the sample).
      final bare = Exif.insertIntoJpeg(jpg, Uint8List.fromList([0x49, 0x49, 0x2A, 0, 8, 0, 0, 0, 0, 0]));
      expect(Exif.orientation(Exif.extractTiff(bare)!), isNull);
      final out = Exif.insertIntoJpeg(bare, tiff);
      final back = Exif.extractTiff(out)!;
      expect(Exif.orientation(back), 1);
      expect(String.fromCharCodes(back).contains('iPhone Test'), isTrue);
      expect(out.sublist(out.length - 2), [0xFF, 0xD9]);
    });

    test('upright filters', () {
      expect(Exif.uprightFilter(1), isNull);
      expect(Exif.uprightFilter(6), 'transpose=1');
      expect(Exif.uprightFilter(8), 'transpose=2');
    });

    test('not an image', () {
      expect(Exif.extractTiff(Uint8List.fromList([1, 2, 3, 4, 5])), isNull);
    });
  });
}
