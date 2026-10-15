// apps/desktop/test/settings_test.dart
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:localroll_desktop/services/settings.dart';

void main() {
  late Directory dir;

  setUp(() async => dir = await Directory.systemTemp.createTemp('lr_settings'));
  tearDown(() async => dir.delete(recursive: true));

  File file() => File('${dir.path}${Platform.pathSeparator}settings.json');

  test('device tokens are never written down, only their hash', () async {
    final s = await AppSettings.loadFrom(dir);
    await s.update((x) => x.trusted['p1'] = TrustedDevice(id: 'p1', name: 'Phone', platform: 'ios', token: 'secret-token-123', pairedMs: 1));
    final text = await file().readAsString();
    expect(text, isNot(contains('secret-token-123')));
    final again = await AppSettings.loadFrom(dir);
    expect(again.trusted['p1']!.signsIn('secret-token-123'), isTrue);
    expect(again.trusted['p1']!.signsIn('secret-token-124'), isFalse);
    expect(again.trusted['p1']!.signsIn(''), isFalse);
  });

  test('older settings with plain tokens still work, and lose the plain token on save', () async {
    await file().writeAsString(jsonEncode({
      'deviceId': 'pc',
      'trusted': [
        {'id': 'old', 'name': 'Old phone', 'platform': 'android', 'token': 'legacy-token', 'pairedMs': 1},
      ],
      'peers': [
        {'id': 'pc2', 'name': 'PC 2', 'hosts': ['10.0.0.2'], 'port': 53317, 'token': 'peer-token', 'pairedMs': 1},
      ],
    }));
    final s = await AppSettings.loadFrom(dir); // load also saves
    expect(s.trusted['old']!.signsIn('legacy-token'), isTrue);
    expect(s.peers['pc2']!.token, 'peer-token');
    final text = await file().readAsString();
    expect(text, isNot(contains('legacy-token')));
    expect(text, isNot(contains('"token"')));
    // The token for the other PC is kept so that it can be used again.
    expect((await AppSettings.loadFrom(dir)).peers['pc2']!.token, 'peer-token');
  });

  test('a new token replaces the old one', () async {
    final d = TrustedDevice(id: 'x', name: 'x', platform: 'ios', token: 'a', pairedMs: 1);
    d.setToken('b');
    expect(d.signsIn('a'), isFalse);
    expect(d.signsIn('b'), isTrue);
  });
}
