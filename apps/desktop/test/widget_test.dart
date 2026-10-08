// apps/desktop/test/widget_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:localroll_desktop/services/library_index.dart';
import 'package:localroll_desktop/ui/format.dart';

void main() {
  test('formatBytes', () {
    expect(formatBytes(500), '500 B');
    expect(formatBytes(1536), '1.5 KB');
    expect(formatBytes(3 * 1024 * 1024 * 1024), '3.0 GB');
  });

  test('uniquePath keeps the name when free', () {
    final p = LibraryIndex.uniquePath('Z:/surely/missing', 'IMG_1.HEIC');
    expect(p.endsWith('IMG_1.HEIC'), isTrue);
  });
}
