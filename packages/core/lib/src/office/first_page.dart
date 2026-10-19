// packages/core/lib/src/office/first_page.dart
import 'dart:convert';
import 'dart:typed_data';

import 'office_doc.dart';

/// How a first page is laid out when drawn small.
enum FirstPageLayout {
  /// A portrait page of text (Word, text files).
  page,

  /// A grid of cells (Excel, CSV).
  sheet,

  /// A landscape slide (PowerPoint).
  slide,
}

/// One line on a first page.
class FirstPageLine {
  const FirstPageLine(this.text, {this.heading = 0, this.bullet = false, this.bold = false});

  final String text;

  /// 1 = title … 6; 0 = body text.
  final int heading;
  final bool bullet;
  final bool bold;
}

/// What a document's first page shows, small: enough to draw a thumbnail
/// (lines of text, the first table, the first picture) without the whole
/// document. Made from [OfficeDoc] or plain text, in pure Dart.
class FirstPage {
  const FirstPage({
    required this.layout,
    this.lines = const [],
    this.table = const [],
    this.picture,
    this.cover,
  });

  final FirstPageLayout layout;

  /// Text from the top of the page, in order.
  final List<FirstPageLine> lines;

  /// The first table (Word), the sheet's top-left cells (Excel / CSV).
  final List<List<String>> table;

  /// The first picture on the page (Word, a slide).
  final Uint8List? picture;

  /// A picture of the whole page that the file itself carries (Office
  /// saves one when asked): drawn instead of everything else.
  final Uint8List? cover;

  bool get isEmpty => lines.isEmpty && table.isEmpty && picture == null && cover == null;

  /// Lines and table cells kept (a thumbnail can't show more).
  static const int maxLines = 28;
  static const int maxRows = 14;
  static const int maxCols = 7;
  static const int maxChars = 160;

  static String _cut(String s) {
    final t = s.replaceAll(RegExp(r'\s+'), ' ').trim();
    return t.length > maxChars ? t.substring(0, maxChars) : t;
  }

  /// Top-left [maxRows] × [maxCols] cells, empty trailing columns dropped.
  static List<List<String>> _corner(List<List<String>> rows) {
    final out = <List<String>>[
      for (final r in rows.take(maxRows)) [for (final c in r.take(maxCols)) _cut(c)],
    ];
    var width = 0;
    for (final r in out) {
      for (var i = r.length - 1; i >= 0; i--) {
        if (r[i].isNotEmpty) {
          if (i + 1 > width) width = i + 1;
          break;
        }
      }
    }
    while (out.isNotEmpty && out.last.every((c) => c.isEmpty)) {
      out.removeLast();
    }
    return [
      for (final r in out) [for (var i = 0; i < width; i++) i < r.length ? r[i] : ''],
    ];
  }

  /// The first page of an Office document.
  static FirstPage fromOffice(OfficeDoc d) {
    switch (d.kind) {
      case OfficeKind.word:
        final lines = <FirstPageLine>[];
        List<List<String>> table = const [];
        Uint8List? picture;
        for (final b in d.blocks) {
          if (lines.length >= maxLines) break;
          if (b is OfficeParagraph) {
            final t = _cut(b.text);
            if (t.isEmpty) continue;
            lines.add(FirstPageLine(t, heading: b.heading, bullet: b.bullet, bold: b.runs.isNotEmpty && b.runs.every((r) => r.bold)));
          } else if (b is OfficeTable && table.isEmpty) {
            table = _corner(b.rows);
            if (lines.length >= maxLines ~/ 2) break; // the table is the rest of the page
          } else if (b is OfficeImage && picture == null && lines.length < maxLines ~/ 2) {
            picture = b.bytes;
          }
        }
        return FirstPage(layout: FirstPageLayout.page, lines: lines, table: table, picture: picture, cover: d.thumbnail);
      case OfficeKind.excel:
        final filled = d.sheets.where((s) => s.rows.any((r) => r.any((c) => c.trim().isNotEmpty)));
        final sheet = filled.isEmpty ? null : filled.first;
        return FirstPage(
          layout: FirstPageLayout.sheet,
          table: sheet == null ? const [] : _corner(sheet.rows),
          cover: d.thumbnail,
        );
      case OfficeKind.powerpoint:
        final s = d.slides.isEmpty ? null : d.slides.first;
        final paras = [for (final p in s?.paragraphs ?? const <String>[]) if (_cut(p).isNotEmpty) _cut(p)];
        return FirstPage(
          layout: FirstPageLayout.slide,
          lines: [
            for (var i = 0; i < paras.length && i < 10; i++) FirstPageLine(paras[i], heading: i == 0 ? 1 : 0, bullet: i > 0),
          ],
          picture: s == null || s.images.isEmpty ? null : s.images.first,
          cover: d.thumbnail,
        );
    }
  }

  /// The top of a text file ([csv]: as a grid).
  static FirstPage fromText(String text, {bool csv = false}) {
    final raw = text.replaceAll('\r\n', '\n').replaceAll('\r', '\n').split('\n');
    if (csv) {
      final sep = raw.isNotEmpty && raw.first.split(';').length > raw.first.split(',').length ? ';' : ',';
      return FirstPage(
        layout: FirstPageLayout.sheet,
        table: _corner([for (final l in raw.take(maxRows)) _csvLine(l, sep)]),
      );
    }
    final lines = <FirstPageLine>[];
    for (final l in raw) {
      if (lines.length >= maxLines) break;
      final t = l.length > maxChars ? l.substring(0, maxChars) : l.trimRight();
      // Markdown headings look like headings.
      final h = RegExp(r'^(#{1,6})\s+(.*)$').firstMatch(t);
      lines.add(h == null ? FirstPageLine(t) : FirstPageLine(h.group(2)!, heading: h.group(1)!.length));
    }
    while (lines.isNotEmpty && lines.last.text.trim().isEmpty) {
      lines.removeLast();
    }
    return FirstPage(layout: FirstPageLayout.page, lines: lines);
  }

  /// The top of a text file from its first bytes: UTF-8 (BOM or not) or
  /// UTF-16 with BOM; anything else as UTF-8 with bad bytes replaced.
  static FirstPage fromTextBytes(List<int> b, {bool csv = false}) => fromText(decodeStart(b), csv: csv);

  /// Decodes the start of a text file (a cut-off last character is fine).
  static String decodeStart(List<int> b) {
    if (b.length >= 3 && b[0] == 0xEF && b[1] == 0xBB && b[2] == 0xBF) return utf8.decode(b.sublist(3), allowMalformed: true);
    if (b.length >= 2 && ((b[0] == 0xFF && b[1] == 0xFE) || (b[0] == 0xFE && b[1] == 0xFF))) {
      final le = b[0] == 0xFF;
      return String.fromCharCodes([
        for (var i = 2; i + 1 < b.length; i += 2) le ? b[i] | (b[i + 1] << 8) : (b[i] << 8) | b[i + 1],
      ]);
    }
    return utf8.decode(b, allowMalformed: true);
  }

  static List<String> _csvLine(String line, String sep) {
    final out = <String>[];
    final cell = StringBuffer();
    var quoted = false;
    for (var i = 0; i < line.length; i++) {
      final c = line[i];
      if (quoted) {
        if (c == '"') {
          if (i + 1 < line.length && line[i + 1] == '"') {
            cell.write('"');
            i++;
          } else {
            quoted = false;
          }
        } else {
          cell.write(c);
        }
      } else if (c == '"') {
        quoted = true;
      } else if (c == sep) {
        out.add(cell.toString());
        cell.clear();
      } else {
        cell.write(c);
      }
    }
    out.add(cell.toString());
    return out;
  }

  /// File names whose first page can be drawn this way (by extension).
  static bool canDraw(String name) {
    final e = _ext(name);
    return OfficeDoc.canRead(e) || textExtensions.contains(e) || e == 'csv';
  }

  /// Plain-text files shown as text.
  static const Set<String> textExtensions = {
    'txt', 'md', 'markdown', 'log', 'json', 'xml', 'yaml', 'yml', 'ini', 'cfg', 'conf', 'tsv', 'srt', 'vtt', //
    'html', 'htm', 'css', 'js', 'ts', 'dart', 'py', 'java', 'kt', 'swift', 'c', 'h', 'cpp', 'cs', 'go', 'rs', 'sh', 'bat', 'ps1', 'sql',
  };

  static String _ext(String name) {
    final i = name.lastIndexOf('.');
    return i < 0 ? '' : name.substring(i + 1).toLowerCase();
  }

  /// The first page of the file [name] with content [data]; null if this
  /// kind can't be drawn or the file can't be read. [data] may be just the
  /// first part of a text file.
  static FirstPage? of(String name, Uint8List data) {
    final e = _ext(name);
    if (OfficeDoc.canRead(e)) {
      final d = OfficeDoc.read(data, e);
      if (d == null) return null;
      final p = fromOffice(d);
      return p.isEmpty ? null : p;
    }
    if (e == 'csv' || textExtensions.contains(e)) {
      final p = fromTextBytes(data, csv: e == 'csv');
      return p.isEmpty ? null : p;
    }
    return null;
  }

  /// How much of a text file is read for its first page.
  static const int textHead = 16 * 1024;
}
