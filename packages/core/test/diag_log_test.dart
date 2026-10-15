// packages/core/test/diag_log_test.dart
import 'dart:io';

import 'package:localroll_core/localroll_core.dart';
import 'package:test/test.dart';

void main() {
  late Directory dir;

  setUp(() async {
    DiagLog.reset();
    DiagLog.maxBytes = 1024 * 1024;
    dir = await Directory.systemTemp.createTemp('lr_log');
  });

  tearDown(() async {
    DiagLog.reset();
    await dir.delete(recursive: true);
  });

  test('lines before init are kept; each entry stays on one line', () async {
    DiagLog.log('early', 'before the folder is known');
    await DiagLog.init(dir, about: 'v1 test');
    DiagLog.log('net', 'two\nlines');
    final text = await DiagLog.read();
    expect(text, contains('[early] before the folder is known'));
    expect(text, contains('[start] v1 test'));
    expect(text, contains('[net] two | lines'));
    expect(text.trim().split('\n'), hasLength(3));
  });

  test('errors keep a short stack', () async {
    await DiagLog.init(dir);
    try {
      throw StateError('boom');
    } catch (e, st) {
      DiagLog.error('x', e, st);
    }
    expect(await DiagLog.read(), contains('ERROR Bad state: boom @'));
  });

  test('size is bounded: one current and one older file', () async {
    DiagLog.maxBytes = 2000;
    await DiagLog.init(dir);
    for (var i = 0; i < 400; i++) {
      DiagLog.log('fill', 'line $i ${'x' * 40}');
      if (i % 20 == 0) await DiagLog.flush();
    }
    await DiagLog.flush();
    final files = dir.listSync().whereType<File>().toList();
    expect(files.length, lessThanOrEqualTo(2));
    for (final f in files) {
      expect(f.lengthSync(), lessThan(2000 + 20 * 80));
    }
    expect(await DiagLog.read(), contains('line 399'));
  });
}
