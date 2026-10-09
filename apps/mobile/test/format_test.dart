// apps/mobile/test/format_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:localroll_mobile/ui/cleanup_page.dart';

void main() {
  test('formatSize', () {
    expect(formatSize(512), '512 B');
    expect(formatSize(1536), '1.5 KB');
    expect(formatSize(340 * 1024 * 1024), '340 MB');
    expect(formatSize((2.25 * 1024 * 1024 * 1024).round()), '2.3 GB');
  });
}
