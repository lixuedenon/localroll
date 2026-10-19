// packages/core/test/office_test.dart
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:localroll_core/localroll_core.dart';
import 'package:test/test.dart';

Uint8List fixture(String name) => File('test/fixtures/$name').readAsBytesSync();

void main() {
  test('xml: attributes, entities, CDATA, comments, self-closing', () {
    final x = parseXml('<?xml version="1.0"?><!-- c --><a k="1 &amp; 2"><b/>x &lt; y<![CDATA[<z>]]><c>&#x4E2D;&#25991;</c></a>')!;
    expect(x.name, 'a');
    expect(x.attr('k'), '1 & 2');
    expect(x.child('b'), isNotNull);
    expect(x.text, 'x < y<z>中文');
  });

  test('zip: a file that is not a zip gives null', () {
    expect(ZipReader.open(Uint8List.fromList(List.filled(100, 7))), isNull);
    expect(OfficeDoc.read(Uint8List.fromList(List.filled(100, 7)), 'docx'), isNull);
  });

  test('Word: headings, bold / italic, table, picture', () {
    final d = OfficeDoc.read(fixture('sample.docx'), 'docx')!;
    expect(d.kind, OfficeKind.word);
    final paras = d.blocks.whereType<OfficeParagraph>().toList();
    final title = paras.firstWhere((p) => p.text == '季度报告 Q3');
    expect(title.heading, 1);
    expect(paras.firstWhere((p) => p.text == '明细').heading, 2);
    final mixed = paras.firstWhere((p) => p.text.startsWith('普通文字'));
    expect(mixed.text, '普通文字，加粗 和 斜体');
    expect(mixed.runs.firstWhere((r) => r.text == '加粗').bold, isTrue);
    expect(mixed.runs.firstWhere((r) => r.text == '斜体').italic, isTrue);
    expect(paras.any((p) => p.text == '第一项'), isTrue);
    final table = d.blocks.whereType<OfficeTable>().single;
    expect(table.rows, [
      ['名称', '数量'],
      ['苹果 & 梨', '3'],
    ]);
    expect(d.blocks.whereType<OfficeImage>(), hasLength(1));
  });

  test('Excel: sheets, strings, numbers, dates, gaps', () {
    final d = OfficeDoc.read(fixture('sample.xlsx'), 'xlsx')!;
    expect(d.kind, OfficeKind.excel);
    expect(d.sheets.map((s) => s.name), ['预算', '第二页']);
    final rows = d.sheets.first.rows;
    expect(rows[0].sublist(0, 3), ['项目', '金额', '日期']);
    expect(rows[1].sublist(0, 3), ['房租', '1250.5', '2024-05-01']);
    expect(rows[2].sublist(0, 2), ['水电', '80']);
    expect(rows[4][3], '远处');
    expect(rows.every((r) => r.length == 4), isTrue);
  });

  test('PowerPoint: slide text in order, pictures', () {
    final d = OfficeDoc.read(fixture('sample.pptx'), 'pptx')!;
    expect(d.kind, OfficeKind.powerpoint);
    expect(d.slides, hasLength(2));
    expect(d.slides[0].paragraphs, ['欢迎', '第一点']);
    expect(d.slides[1].paragraphs, ['图片页']);
    expect(d.slides[1].images, hasLength(1));
  });

  test('Excel day numbers', () {
    expect(excelDate(45413), '2024-05-01');
    expect(excelDate(45413.5), '2024-05-01 12:00');
    expect(excelDate(0.75), '18:00');
  });

  group('first page (thumbnails)', () {
    test('Word: title and text in order, its table, its picture', () {
      final p = FirstPage.of('report.docx', fixture('sample.docx'))!;
      expect(p.layout, FirstPageLayout.page);
      expect(p.lines.first.text, '季度报告 Q3');
      expect(p.lines.first.heading, 1);
      expect(p.lines.any((l) => l.text == '普通文字，加粗 和 斜体'), isTrue);
      expect(p.table, [
        ['名称', '数量'],
        ['苹果 & 梨', '3'],
      ]);
      expect(p.picture, isNotNull);
    });

    test('Excel: the first sheet\'s top-left cells', () {
      final p = FirstPage.of('budget.XLSX', fixture('sample.xlsx'))!;
      expect(p.layout, FirstPageLayout.sheet);
      expect(p.table.first.sublist(0, 3), ['项目', '金额', '日期']);
      expect(p.table.length, lessThanOrEqualTo(FirstPage.maxRows));
    });

    test('PowerPoint: the first slide, its title first', () {
      final p = FirstPage.of('talk.pptx', fixture('sample.pptx'))!;
      expect(p.layout, FirstPageLayout.slide);
      expect(p.lines.map((l) => l.text), ['欢迎', '第一点']);
      expect(p.lines.first.heading, 1);
    });

    test('text, Markdown headings, UTF-16, CSV', () {
      final t = FirstPage.of('notes.md', utf8Bytes('# 标题\n\nfirst line\r\nsecond\n\n\n'))!;
      expect(t.lines.first.text, '标题');
      expect(t.lines.first.heading, 1);
      expect(t.lines.last.text, 'second');
      final u16 = Uint8List.fromList([0xFF, 0xFE, 0x2D, 0x4E, 0x87, 0x65]); // 中文
      expect(FirstPage.of('a.txt', u16)!.lines.single.text, '中文');
      final csv = FirstPage.of('a.csv', utf8Bytes('名字,"数量, 个"\n苹果,3\n'))!;
      expect(csv.layout, FirstPageLayout.sheet);
      expect(csv.table, [
        ['名字', '数量, 个'],
        ['苹果', '3'],
      ]);
    });

    test('not a document / not readable: null', () {
      expect(FirstPage.of('a.zip', Uint8List(10)), isNull);
      expect(FirstPage.of('a.docx', Uint8List.fromList(List.filled(100, 7))), isNull);
      expect(FirstPage.canDraw('x.PPTX'), isTrue);
      expect(FirstPage.canDraw('x.mp4'), isFalse);
    });
  });
}

Uint8List utf8Bytes(String s) => Uint8List.fromList(utf8.encode(s));
