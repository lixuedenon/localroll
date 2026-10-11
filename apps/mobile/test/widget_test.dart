// apps/mobile/test/widget_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:localroll_mobile/services/backup_plan.dart';
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

  test('backup conditions are remembered exactly', () {
    final f = BackupFilter(
      fromMs: 1,
      toMs: 2,
      maxCount: 50,
      photos: false,
      skipScreenshots: true,
      albumIds: ['a', 'b'],
      maxFileMb: 2048,
      order: BackupOrder.largest,
      stopAfterMb: 5120,
      stopAfterMinutes: 15,
      pauseOnLowBattery: false,
    );
    final back = BackupFilter.fromJson(f.toJson());
    expect(back.toJson(), f.toJson());
    expect(back.needsSizes, isTrue);
    expect(BackupFilter().needsSizes, isFalse);
  });
}
