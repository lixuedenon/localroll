// packages/core/test/google_links_test.dart
import 'package:localroll_core/localroll_core.dart';
import 'package:test/test.dart';

void main() {
  test('doc_id becomes a docs.google.com address by kind', () {
    expect(googleShortcutUrl('{"doc_id": "1AbCdEfGhIjK_lmn-op", "email": "a@b.c"}', 'gsheet'),
        'https://docs.google.com/spreadsheets/d/1AbCdEfGhIjK_lmn-op');
  });
  test('a Google url is used as it is', () {
    expect(googleShortcutUrl('{"url": "https://docs.google.com/document/d/xyz/edit"}', 'gdoc'),
        'https://docs.google.com/document/d/xyz/edit');
  });
  test('other addresses and bad files give nothing', () {
    expect(googleShortcutUrl('{"url": "http://evil.example/x"}', 'gdoc'), isNull);
    expect(googleShortcutUrl('{"url": "https://evil.example/x"}', 'gdoc'), isNull);
    expect(googleShortcutUrl('{"doc_id": "../../etc"}', 'gdoc'), isNull);
    expect(googleShortcutUrl('not json', 'gdoc'), isNull);
  });
}
