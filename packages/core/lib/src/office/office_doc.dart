// packages/core/lib/src/office/office_doc.dart
import 'dart:typed_data';

import 'xml_lite.dart';
import 'zip_reader.dart';

/// What LocalRoll can show of a Word / Excel / PowerPoint file without
/// Office: the text with headings, lists, bold / italic, tables and
/// pictures; the cells of each sheet; each slide's text and pictures.
/// A simple "look inside", not a faithful layout.
sealed class OfficeBlock {}

class OfficeRun {
  OfficeRun(this.text, {this.bold = false, this.italic = false});

  final String text;
  final bool bold;
  final bool italic;
}

class OfficeParagraph extends OfficeBlock {
  OfficeParagraph(this.runs, {this.heading = 0, this.bullet = false});

  final List<OfficeRun> runs;

  /// 0: body text; 1–6: heading level (1 also for a title).
  final int heading;
  final bool bullet;

  String get text => runs.map((r) => r.text).join();
}

class OfficeTable extends OfficeBlock {
  OfficeTable(this.rows);

  final List<List<String>> rows;
}

class OfficeImage extends OfficeBlock {
  OfficeImage(this.bytes);

  final Uint8List bytes;
}

class OfficeSheet {
  OfficeSheet(this.name, this.rows);

  final String name;

  /// Row by row; every row as long as the widest one.
  final List<List<String>> rows;
}

class OfficeSlide {
  OfficeSlide(this.paragraphs, this.images);

  final List<String> paragraphs;
  final List<Uint8List> images;
}

enum OfficeKind { word, excel, powerpoint }

class OfficeDoc {
  OfficeDoc.word(this.blocks, this.thumbnail)
      : kind = OfficeKind.word,
        sheets = const [],
        slides = const [];
  OfficeDoc.excel(this.sheets, this.thumbnail)
      : kind = OfficeKind.excel,
        blocks = const [],
        slides = const [];
  OfficeDoc.powerpoint(this.slides, this.thumbnail)
      : kind = OfficeKind.powerpoint,
        blocks = const [],
        sheets = const [];

  final OfficeKind kind;
  final List<OfficeBlock> blocks;
  final List<OfficeSheet> sheets;
  final List<OfficeSlide> slides;

  /// The preview picture Office saved inside the file, if any.
  final Uint8List? thumbnail;

  /// docx / docm / dotx, xlsx / xlsm, pptx / ppsx / pptm (the old binary
  /// .doc / .xls / .ppt are not ZIP files and can't be read this way).
  static const extensions = {'docx', 'docm', 'dotx', 'xlsx', 'xlsm', 'xltx', 'pptx', 'pptm', 'ppsx', 'potx'};

  static bool canRead(String ext) => extensions.contains(ext.toLowerCase());

  /// Reads [data] ([ext] without the dot); null if it can't be read.
  static OfficeDoc? read(Uint8List data, String ext) {
    final zip = ZipReader.open(data);
    if (zip == null) return null;
    final e = ext.toLowerCase();
    try {
      if (e.startsWith('doc') || e == 'dotx') return _Word(zip).read();
      if (e.startsWith('xl')) return _Excel(zip).read();
      if (e.startsWith('pp') || e == 'potx') return _Slides(zip).read();
    } catch (_) {}
    return null;
  }

  /// Only the preview picture Office saved in the file (fast; for lists).
  static Uint8List? thumbnailOf(Uint8List data) {
    final zip = ZipReader.open(data);
    return zip == null ? null : _thumbnail(zip);
  }
}

// ------------------------------------------------------------------ shared

/// "word/media/image1.png" from a target relative to [base] ("word/").
String _resolve(String base, String target) {
  if (target.startsWith('/')) return target.substring(1);
  final parts = [...base.split('/').where((p) => p.isNotEmpty), ...target.split('/')];
  final out = <String>[];
  for (final p in parts) {
    if (p == '..') {
      if (out.isNotEmpty) out.removeLast();
    } else if (p != '.' && p.isNotEmpty) {
      out.add(p);
    }
  }
  return out.join('/');
}

/// Relationship id → part name, for the part [part] ("word/document.xml").
Map<String, String> _rels(ZipReader zip, String part) {
  final slash = part.lastIndexOf('/');
  final dir = slash < 0 ? '' : part.substring(0, slash + 1);
  final file = part.substring(slash + 1);
  final x = parseXml(zip.text('${dir}_rels/$file.rels') ?? '');
  final out = <String, String>{};
  if (x == null) return out;
  for (final r in x.all('Relationship')) {
    final id = r.attr('Id');
    final t = r.attr('Target');
    if (id == null || t == null || r.attr('TargetMode') == 'External') continue;
    out[id] = _resolve(dir, t);
  }
  return out;
}

/// Pictures we can draw (not EMF / WMF).
bool _drawable(Uint8List b) {
  if (b.length < 12) return false;
  if (b[0] == 0x89 && b[1] == 0x50) return true; // PNG
  if (b[0] == 0xFF && b[1] == 0xD8) return true; // JPEG
  if (b[0] == 0x47 && b[1] == 0x49) return true; // GIF
  if (b[0] == 0x42 && b[1] == 0x4D) return true; // BMP
  if (b[0] == 0x52 && b[1] == 0x49 && b[8] == 0x57 && b[9] == 0x45) return true; // WEBP
  return false;
}

Uint8List? _image(ZipReader zip, String? part) {
  if (part == null) return null;
  final b = zip.read(part);
  return b != null && _drawable(b) ? b : null;
}

Uint8List? _thumbnail(ZipReader zip) {
  for (final n in zip.names) {
    if (n.toLowerCase().startsWith('docprops/thumbnail')) {
      final b = _image(zip, n);
      if (b != null) return b;
    }
  }
  return null;
}

bool _on(XElement? e) {
  if (e == null) return false;
  final v = e.attr('w:val') ?? e.attr('val');
  return v == null || !(v == '0' || v == 'false' || v == 'none');
}

// -------------------------------------------------------------------- Word

class _Word {
  _Word(this.zip);

  final ZipReader zip;
  late final String part = _mainPart();
  late final Map<String, String> rels = _rels(zip, part);
  int _images = 0;

  String _mainPart() {
    final x = parseXml(zip.text('_rels/.rels') ?? '');
    for (final r in x?.all('Relationship') ?? const <XElement>[]) {
      if ((r.attr('Type') ?? '').endsWith('/officeDocument')) return _resolve('', r.attr('Target') ?? '');
    }
    return 'word/document.xml';
  }

  OfficeDoc? read() {
    final doc = parseXml(zip.text(part) ?? '');
    final body = doc?.child('w:body');
    if (body == null) return null;
    final out = <OfficeBlock>[];
    for (final e in body.elements) {
      if (out.length > 20000) break;
      if (e.name == 'w:p') {
        _paragraph(e, out);
      } else if (e.name == 'w:tbl') {
        out.add(_table(e));
      } else if (e.name == 'w:sdt') {
        // Content controls (cover pages, tables of contents…).
        for (final p in e.find('w:p')) {
          _paragraph(p, out);
        }
      }
    }
    return OfficeDoc.word(out, _thumbnail(zip));
  }

  void _paragraph(XElement p, List<OfficeBlock> out) {
    final ppr = p.child('w:pPr');
    final style = (ppr?.child('w:pStyle')?.attr('w:val') ?? '').toLowerCase();
    var heading = 0;
    if (style == 'title') {
      heading = 1;
    } else if (style.startsWith('heading')) {
      heading = int.tryParse(style.substring(7)) ?? 1;
    } else {
      final lvl = ppr?.child('w:outlineLvl')?.attr('w:val');
      if (lvl != null) heading = (int.tryParse(lvl) ?? 8) + 1;
    }
    if (heading > 6) heading = 0;
    final runs = <OfficeRun>[];
    final pics = <Uint8List>[];
    for (final r in p.find('w:r')) {
      final rpr = r.child('w:rPr');
      final b = StringBuffer();
      for (final c in r.elements) {
        switch (c.name) {
          case 'w:t':
            b.write(c.text);
          case 'w:tab':
            b.write('\t');
          case 'w:br' || 'w:cr':
            b.write('\n');
          case 'w:drawing' || 'w:pict':
            for (final blip in c.descendants()) {
              final id = blip.attr('r:embed') ?? blip.attr('r:id');
              if ((blip.local == 'blip' || blip.local == 'imagedata') && id != null && _images < 200) {
                final img = _image(zip, rels[id]);
                if (img != null) {
                  pics.add(img);
                  _images++;
                }
              }
            }
        }
      }
      if (b.isNotEmpty) runs.add(OfficeRun(b.toString(), bold: _on(rpr?.child('w:b')), italic: _on(rpr?.child('w:i'))));
    }
    out.add(OfficeParagraph(runs, heading: heading, bullet: ppr?.child('w:numPr') != null));
    for (final img in pics) {
      out.add(OfficeImage(img));
    }
  }

  OfficeTable _table(XElement t) {
    final rows = <List<String>>[];
    for (final tr in t.all('w:tr')) {
      rows.add([
        for (final tc in tr.all('w:tc'))
          tc.all('w:p').map((p) => p.find('w:t').map((x) => x.text).join()).join('\n'),
      ]);
      if (rows.length >= 2000) break;
    }
    return OfficeTable(rows);
  }
}

// ------------------------------------------------------------------- Excel

class _Excel {
  _Excel(this.zip);

  final ZipReader zip;

  static const maxRows = 3000;
  static const maxCols = 80;

  OfficeDoc? read() {
    const wbPart = 'xl/workbook.xml';
    final wb = parseXml(zip.text(wbPart) ?? '');
    if (wb == null) return null;
    final rels = _rels(zip, wbPart);
    final strings = _sharedStrings();
    final dates = _dateStyles();
    final sheets = <OfficeSheet>[];
    for (final s in wb.find('sheet')) {
      final part = rels[s.attr('r:id')];
      final x = part == null ? null : parseXml(zip.text(part) ?? '');
      if (x == null) continue;
      sheets.add(OfficeSheet(s.attr('name') ?? 'Sheet', _cells(x, strings, dates)));
      if (sheets.length >= 30) break;
    }
    return OfficeDoc.excel(sheets, _thumbnail(zip));
  }

  List<String> _sharedStrings() {
    final x = parseXml(zip.text('xl/sharedStrings.xml') ?? '');
    if (x == null) return const [];
    return [
      for (final si in x.all('si'))
        // Rich text: every <t> except phonetic hints (<rPh>).
        si.descendants().where((e) => e.name == 't').where((t) => !_inPhonetic(si, t)).map((t) => t.text).join(),
    ];
  }

  bool _inPhonetic(XElement si, XElement t) => si.all('rPh').any((r) => r.descendants().contains(t));

  /// Style indexes whose number format is a date / time.
  Set<int> _dateStyles() {
    final x = parseXml(zip.text('xl/styles.xml') ?? '');
    if (x == null) return const {};
    final custom = <int, String>{
      for (final f in x.find('numFmt')) int.tryParse(f.attr('numFmtId') ?? '') ?? -1: f.attr('formatCode') ?? '',
    };
    bool isDate(int id) {
      if ((id >= 14 && id <= 22) || (id >= 45 && id <= 47) || (id >= 27 && id <= 36) || (id >= 50 && id <= 58)) return true;
      final code = custom[id];
      if (code == null) return false;
      final plain = code.replaceAll(RegExp(r'"[^"]*"|\[[^\]]*\]|\\.'), '').toLowerCase();
      return RegExp(r'[dy]|h|(?<![0#])m').hasMatch(plain) && !plain.contains('0.0');
    }

    final xfs = x.child('cellXfs');
    final out = <int>{};
    var i = 0;
    for (final xf in xfs?.all('xf') ?? const <XElement>[]) {
      if (isDate(int.tryParse(xf.attr('numFmtId') ?? '') ?? 0)) out.add(i);
      i++;
    }
    return out;
  }

  static int _col(String ref) {
    var n = 0;
    for (final c in ref.codeUnits) {
      if (c >= 65 && c <= 90) {
        n = n * 26 + (c - 64);
      } else if (c >= 97 && c <= 122) {
        n = n * 26 + (c - 96);
      } else {
        break;
      }
    }
    return n - 1;
  }

  List<List<String>> _cells(XElement sheet, List<String> strings, Set<int> dates) {
    final data = sheet.child('sheetData');
    final rows = <int, Map<int, String>>{};
    var maxCol = -1;
    var maxRow = -1;
    var auto = 0;
    for (final r in data?.all('row') ?? const <XElement>[]) {
      final ri = (int.tryParse(r.attr('r') ?? '') ?? (auto + 1)) - 1;
      auto = ri + 1;
      if (ri >= maxRows) break;
      final cells = <int, String>{};
      var autoCol = 0;
      for (final c in r.all('c')) {
        final ref = c.attr('r');
        final ci = ref == null ? autoCol : _col(ref);
        autoCol = ci + 1;
        if (ci < 0 || ci >= maxCols) continue;
        final v = _value(c, strings, dates);
        if (v.isEmpty) continue;
        cells[ci] = v;
        if (ci > maxCol) maxCol = ci;
      }
      if (cells.isNotEmpty) {
        rows[ri] = cells;
        if (ri > maxRow) maxRow = ri;
      }
    }
    return [
      for (var r = 0; r <= maxRow; r++) [for (var c = 0; c <= maxCol; c++) rows[r]?[c] ?? ''],
    ];
  }

  String _value(XElement c, List<String> strings, Set<int> dates) {
    final t = c.attr('t');
    final v = c.child('v')?.text ?? '';
    switch (t) {
      case 's':
        final i = int.tryParse(v);
        return i != null && i >= 0 && i < strings.length ? strings[i] : '';
      case 'inlineStr':
        return c.child('is')?.find('t').map((e) => e.text).join() ?? '';
      case 'b':
        return v == '1' ? 'TRUE' : 'FALSE';
      case 'str' || 'e':
        return v;
    }
    if (v.isEmpty) return '';
    final n = double.tryParse(v);
    if (n == null) return v;
    final style = int.tryParse(c.attr('s') ?? '');
    if (style != null && dates.contains(style)) return excelDate(n);
    if (n == n.roundToDouble() && n.abs() < 1e15) return n.toInt().toString();
    final s = n.toStringAsFixed(10).replaceFirst(RegExp(r'0+$'), '');
    return s.endsWith('.') ? s.substring(0, s.length - 1) : s;
  }
}

/// Excel's day number (1900 system) → "2024-05-01" or "2024-05-01 14:30".
String excelDate(double serial) {
  if (serial < 0 || serial > 2958465) return serial.toString();
  final days = serial.floor();
  final base = DateTime.utc(1899, 12, 30);
  final d = base.add(Duration(days: days, milliseconds: ((serial - days) * 86400000).round()));
  String two(int v) => v.toString().padLeft(2, '0');
  final date = '${d.year}-${two(d.month)}-${two(d.day)}';
  if (days == 0) return '${two(d.hour)}:${two(d.minute)}';
  if (d.hour == 0 && d.minute == 0 && d.second == 0) return date;
  return '$date ${two(d.hour)}:${two(d.minute)}';
}

// -------------------------------------------------------------- PowerPoint

class _Slides {
  _Slides(this.zip);

  final ZipReader zip;

  OfficeDoc? read() {
    const presPart = 'ppt/presentation.xml';
    final pres = parseXml(zip.text(presPart) ?? '');
    if (pres == null) return null;
    final rels = _rels(zip, presPart);
    final slides = <OfficeSlide>[];
    for (final id in pres.find('p:sldId')) {
      final part = rels[id.attr('r:id')];
      final x = part == null ? null : parseXml(zip.text(part) ?? '');
      if (x == null) continue;
      final srels = _rels(zip, part!);
      final paras = <String>[];
      for (final p in x.find('a:p')) {
        final t = p.find('a:t').map((e) => e.text).join();
        if (t.trim().isNotEmpty) paras.add(t);
      }
      final pics = <Uint8List>[];
      for (final blip in x.find('a:blip')) {
        final img = _image(zip, srels[blip.attr('r:embed')]);
        if (img != null && pics.length < 12) pics.add(img);
      }
      slides.add(OfficeSlide(paras, pics));
      if (slides.length >= 500) break;
    }
    return OfficeDoc.powerpoint(slides, _thumbnail(zip));
  }
}
