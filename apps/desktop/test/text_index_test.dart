// apps/desktop/test/text_index_test.dart
//
// Text search: what is found, how text is tidied, and that it is kept with
// the library.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:localroll_desktop/services/library_index.dart';
import 'package:localroll_desktop/services/text_index.dart';
import 'package:localroll_desktop/services/windows_ocr.dart';

void main() {
  late Directory tmp;
  late LibraryIndex lib;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('lr_text_test');
    lib = LibraryIndex('${tmp.path}${Platform.pathSeparator}Library', stateFile: File('${tmp.path}${Platform.pathSeparator}s.json'));
    await lib.load();
  });

  tearDown(() async {
    lib.dispose();
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  test('every word must be in the text or the name; case, spaces and full-width letters do not matter', () async {
    final idx = TextIndex(lib);
    await idx.load();
    idx.put('a', const TextEntry('发票号码 12345\nWiFi 密码: home-net'));
    idx.put('b', const TextEntry(''));
    expect(idx.matches('a', 'IMG_1.jpg', SearchQuery('wifi 密码')), isTrue);
    expect(idx.matches('a', 'IMG_1.jpg', SearchQuery('ＷＩＦＩ')), isTrue);
    expect(idx.matches('a', 'IMG_1.jpg', SearchQuery('发票 号码')), isTrue);
    expect(idx.matches('a', 'IMG_1.jpg', SearchQuery('wifi 收据')), isFalse);
    expect(idx.matches('b', '合同.pdf', SearchQuery('合同')), isTrue); // the name
    expect(idx.matches('b', '合同.pdf', SearchQuery('发票')), isFalse);
    expect(idx.snippet('a', SearchQuery('密码')), contains('密码'));
  });

  test('kept in the library folder and read back', () async {
    final idx = TextIndex(lib);
    await idx.load();
    idx.put('m:2026/10/a.jpg|10', const TextEntry('Hello', lang: 'en-US', ocr: true));
    await idx.save();
    final again = TextIndex(lib);
    await again.load();
    expect(again['m:2026/10/a.jpg|10']?.text, 'Hello');
    expect(again['m:2026/10/a.jpg|10']?.lang, 'en-US');
    again.prune({});
    expect(again.count, 0);
  });

  test('Chinese read one character at a time loses its spaces', () {
    expect(tidyOcrText('发 票 号 码 12 34'), '发票号码 12 34');
    expect(tidyOcrText('Total 合 计 100'), 'Total 合计 100');
  });

  test('the recognizer prefers Chinese, then Japanese / Korean', () {
    expect(const OcrLanguages(['en-US', 'zh-Hans-CN']).preferred, 'zh-Hans-CN');
    expect(const OcrLanguages(['en-US', 'ja']).preferred, 'ja');
    expect(const OcrLanguages(['en-US']).chinese, isFalse);
  });
}
