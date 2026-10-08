// apps/mobile/test/widget_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:localroll_mobile/services/mobile_settings.dart';

void main() {
  test('PairedDesktop JSON round-trip', () {
    final d = PairedDesktop(
      id: 'pc1',
      name: '书房电脑',
      hosts: ['192.168.1.68'],
      port: 53530,
      token: 't',
      lastHost: '192.168.1.68',
    );
    final back = PairedDesktop.fromJson(d.toJson());
    expect(back.name, '书房电脑');
    expect(back.hosts, ['192.168.1.68']);
    expect(back.lastHost, '192.168.1.68');
  });
}
