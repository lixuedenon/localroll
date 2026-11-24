// apps/desktop/lib/services/pdf_docx.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart' show Colors;
import 'package:localroll_core/localroll_core.dart';
import 'package:pdfrx/pdfrx.dart';

import 'file_tools.dart';
import 'pdf_fonts.dart';
import 'pdf_open.dart';
import 'windows_ocr.dart';

/// Keepnear's own PDF → Word (.docx), for when there is no Word: the text
/// the PDF carries, as paragraphs (font, size, bold, italic, colour,
/// indents, centred lines), its pictures where they were, a page break per
/// page. A page with no text (a scan) is read by Windows' text recognition.
/// Made to be edited in WPS or LibreOffice Writer as ordinary text — not
/// a copy of the layout (that is what the PDF is for).
class PdfToDocx {
  PdfToDocx._();

  static final WindowsOcr _ocr = WindowsOcr();

  /// [pdf] → [out]; null when done, else why not. [progress]: page done of
  /// all.
  static Future<String?> make(String pdf, String out, {void Function(int done, int total)? progress, bool Function()? stop}) async {
    PdfDocument? doc;
    final tmp = await Directory.systemTemp.createTemp('lr_docx');
    try {
      doc = await openPdfLoose(pdf);
      final body = StringBuffer();
      final media = <String, Uint8List>{};
      double? pageW, pageH, marginL, marginR, marginT;
      for (var i = 0; i < doc.pages.length; i++) {
        if (stop?.call() ?? false) return 'cancelled';
        final page = doc.pages[i];
        if (i > 0) body.write('<w:p><w:r><w:br w:type="page"/></w:r></w:p>');
        final (styles, pics) = await PdfBuilder.stylesAndPictures(pdf, i);
        final lines = await _lines(page, styles);
        final pw = page.width.toDouble(), ph = page.height.toDouble();
        if (i == 0) {
          pageW = pw;
          pageH = ph;
          if (lines.isNotEmpty) {
            marginL = lines.map((l) => l.left).reduce(math.min).clamp(18.0, pw / 3).toDouble();
            marginR = (pw - lines.map((l) => l.right).reduce(math.max)).clamp(18.0, pw / 3).toDouble();
            marginT = (ph - lines.map((l) => l.top).reduce(math.max)).clamp(18.0, ph / 3).toDouble();
          }
        }
        final ml = marginL ?? 72, mr = marginR ?? 72;
        if (lines.isEmpty) {
          // A scan: its words, read from a picture of it.
          final text = await _ocrPage(page, tmp.path);
          if (text != null && text.trim().isNotEmpty) {
            for (final t in const LineSplitter().convert(text)) {
              if (t.trim().isEmpty) continue;
              body.write('<w:p><w:r><w:t xml:space="preserve">${_x(t.trim())}</w:t></w:r></w:p>');
            }
          } else {
            // Not even that: the page as a picture.
            final png = await _picture(page, 0, 0, pw, ph);
            if (png != null) {
              final id = 'img${media.length + 1}';
              media[id] = png;
              body.write(_pictureXml(id, media.length, pw - ml - mr, (pw - ml - mr) * ph / pw));
            }
          }
          progress?.call(i + 1, doc.pages.length);
          continue;
        }
        // Pictures go in among the paragraphs, by where their top is.
        final blocks = <(double, String)>[];
        for (final p in _paragraphs(lines, ml, pw - mr)) {
          blocks.add((p.top, p.xml(ml)));
        }
        for (final (l, b, r, t) in pics) {
          if (r - l < 12 || t - b < 12) continue;
          final png = await _picture(page, l, b, r, t);
          if (png == null) continue;
          final id = 'img${media.length + 1}';
          media[id] = png;
          final w = math.min(r - l, pw - ml - mr);
          blocks.add((t, _pictureXml(id, media.length, w, w * (t - b) / (r - l), indent: math.max(0.0, l - ml))));
        }
        blocks.sort((a, b) => b.$1.compareTo(a.$1));
        for (final b in blocks) {
          body.write(b.$2);
        }
        progress?.call(i + 1, doc.pages.length);
      }
      final w = pageW ?? 595, h = pageH ?? 842;
      body.write('<w:sectPr><w:pgSz w:w="${_tw(w)}" w:h="${_tw(h)}"${w > h ? ' w:orient="landscape"' : ''}/>'
          '<w:pgMar w:top="${_tw(marginT ?? 72)}" w:right="${_tw(marginR ?? 72)}" w:bottom="${_tw(54)}" w:left="${_tw(marginL ?? 72)}" '
          'w:header="0" w:footer="0" w:gutter="0"/></w:sectPr>');
      await File(out).writeAsBytes(_docx(body.toString(), media), flush: true);
      return null;
    } catch (e) {
      DiagLog.log('tools', 'pdf → docx failed: $e');
      return '$e';
    } finally {
      try {
        await doc?.dispose();
      } catch (_) {}
      try {
        await tmp.delete(recursive: true);
      } catch (_) {}
    }
  }

  // ------------------------------------------------------------ reading

  /// The page's text as lines (a big gap — table cells side by side —
  /// becomes a tab), each in runs of one look.
  static Future<List<_TLine>> _lines(PdfPage page, List<PdfTextStyle> styles) async {
    final PdfPageText t;
    try {
      t = await page.loadText();
    } catch (_) {
      return const [];
    }
    final chars = <(int, PdfRect)>[];
    for (final f in t.fragments) {
      for (var k = 0; k < f.length && k < f.charRects.length; k++) {
        chars.add((t.fullText.codeUnitAt(f.index + k), f.charRects[k]));
      }
    }
    PdfTextStyle? styleOf(PdfRect r) {
      final cx = (r.left + r.right) / 2, cy = (r.top + r.bottom) / 2;
      PdfTextStyle? hit;
      for (final st in styles) {
        if (cx >= st.l - 0.5 && cx <= st.r + 0.5 && cy >= st.b - 0.5 && cy <= st.t + 0.5) {
          if (hit == null || (st.r - st.l) < (hit.r - hit.l)) hit = st;
        }
      }
      return hit;
    }

    final out = <_TLine>[];
    var cur = <(int, PdfRect)>[];
    void flush() {
      final seen = [for (final c in cur) if (c.$2.width > 0.1 && c.$2.height > 0.1 && c.$1 > 32) c];
      if (seen.isNotEmpty) {
        final line = _TLine();
        var last = seen.first.$2;
        PdfTextStyle? look;
        for (final c in cur) {
          final r = c.$2;
          final visible = r.width > 0.1 && r.height > 0.1 && c.$1 > 32;
          if (visible) {
            // A wide gap inside the line: a tab (cells side by side).
            if (line.runs.isNotEmpty && r.left - last.right > math.max(last.height, 6) * 1.6) line.add('\t', look, r);
            look = styleOf(r) ?? look;
            last = r;
          }
          line.add(String.fromCharCode(c.$1), look, r);
        }
        line.finish();
        if (line.text.trim().isNotEmpty) out.add(line);
      }
      cur = [];
    }

    for (final c in chars) {
      if (c.$1 == 10 || c.$1 == 13) {
        flush();
        continue;
      }
      final rc = c.$2;
      if (cur.isNotEmpty && rc.height > 0.1 && c.$1 > 32) {
        final prev = cur.lastWhere((x) => x.$2.height > 0.1 && x.$1 > 32, orElse: () => cur.last).$2;
        final h = prev.height > 0.1 ? prev.height : rc.height;
        final sameRow = (rc.bottom + rc.top) / 2 > prev.bottom - h * 0.3 && (rc.bottom + rc.top) / 2 < prev.top + h * 0.3;
        if (!sameRow || rc.left - prev.right < -h * 2) flush();
      }
      cur.add(c);
    }
    flush();
    // Pieces of one row (the PDF wrote them apart) joined, left to right.
    out.sort((a, b) => b.base.compareTo(a.base));
    final rows = <_TLine>[];
    for (final l in out) {
      final same = rows.isNotEmpty && (rows.last.base - l.base).abs() < l.size * 0.3;
      if (same) {
        rows.last.merge(l);
      } else {
        rows.add(l);
      }
    }
    return rows;
  }

  /// Lines → paragraphs: lines that line up on the left, follow at a
  /// line's distance and look alike; a line ending well short of the right
  /// edge ends its paragraph.
  static List<_Para> _paragraphs(List<_TLine> lines, double left, double right) {
    final paras = <_Para>[];
    _Para? p;
    final width = right - left;
    for (final l in lines) {
      var join = false;
      final q = p;
      if (q != null) {
        final prev = q.lines.last;
        final gap = prev.base - l.base;
        join = !l.text.contains('\t') &&
            !prev.text.contains('\t') &&
            (l.size - prev.size).abs() < prev.size * 0.15 &&
            gap > prev.size * 0.8 &&
            gap < prev.size * 1.9 &&
            // Same left (the first line may be indented).
            ((l.left - prev.left).abs() < prev.size * 1.2 || (q.lines.length == 1 && prev.left - l.left > 0 && prev.left - l.left < prev.size * 4.5)) &&
            // The line before ran (nearly) to the right edge.
            prev.right > left + width * 0.8 &&
            !q.centred(left, right);
      }
      if (join) {
        q!.lines.add(l);
      } else {
        p = _Para([l], q == null ? 0 : math.max(0, q.lines.last.base - l.base - q.lines.last.size * 1.25));
        paras.add(p);
      }
    }
    for (final x in paras) {
      x._isCentred = x.centred(left, right);
    }
    return paras;
  }

  static Future<String?> _ocrPage(PdfPage page, String tmp) async {
    final png = await _picture(page, 0, 0, page.width.toDouble(), page.height.toDouble(), dpi: 200);
    if (png == null) return null;
    final f = File('$tmp${Platform.pathSeparator}ocr.png');
    await f.writeAsBytes(png, flush: true);
    try {
      return await _ocr.read(f.path);
    } finally {
      try {
        await f.delete();
      } catch (_) {}
    }
  }

  /// The part l b r t (PDF points) of the page as a PNG.
  static Future<Uint8List?> _picture(PdfPage page, double l, double b, double r, double t, {double dpi = 150}) async {
    try {
      final k = dpi / 72;
      final fw = page.width * k, fh = page.height * k;
      final x = (l * k).floor(), y = ((page.height - t) * k).floor();
      final w = math.max(1, ((r - l) * k).ceil()), h = math.max(1, ((t - b) * k).ceil());
      if (w * h > 40000000) return null;
      final img = await page.render(x: x, y: y, width: w, height: h, fullWidth: fw, fullHeight: fh, backgroundColor: Colors.white);
      if (img == null) return null;
      final c = Completer<ui.Image>();
      ui.decodeImageFromPixels(img.pixels, img.width, img.height, img.format, c.complete);
      final pic = await c.future;
      img.dispose();
      final png = await pic.toByteData(format: ui.ImageByteFormat.png);
      pic.dispose();
      return png?.buffer.asUint8List();
    } catch (e) {
      DiagLog.log('tools', 'pdf → docx picture: $e');
      return null;
    }
  }

  // ------------------------------------------------------------ writing

  /// Points → twentieths of a point (Word's unit).
  static int _tw(double pt) => (pt * 20).round();

  static String _x(String s) => s
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;')
      .replaceAll(RegExp(r'[\x00-\x08\x0B\x0C\x0E-\x1F]'), '');

  static String _pictureXml(String id, int n, double wPt, double hPt, {double indent = 0}) {
    const emu = 12700;
    final cx = (wPt * emu).round(), cy = (hPt * emu).round();
    return '<w:p>${indent > 1 ? '<w:pPr><w:ind w:left="${_tw(indent)}"/></w:pPr>' : ''}<w:r><w:drawing>'
        '<wp:inline distT="0" distB="0" distL="0" distR="0"><wp:extent cx="$cx" cy="$cy"/><wp:docPr id="$n" name="Picture $n"/>'
        '<a:graphic xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">'
        '<a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture">'
        '<pic:pic xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture">'
        '<pic:nvPicPr><pic:cNvPr id="$n" name="Picture $n"/><pic:cNvPicPr/></pic:nvPicPr>'
        '<pic:blipFill><a:blip r:embed="$id"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill>'
        '<pic:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="$cx" cy="$cy"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom></pic:spPr>'
        '</pic:pic></a:graphicData></a:graphic></wp:inline></w:drawing></w:r></w:p>';
  }

  static Uint8List _docx(String body, Map<String, Uint8List> media) {
    const ns = 'xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" '
        'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" '
        'xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing"';
    final files = <String, List<int>>{
      '[Content_Types].xml': utf8.encode('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
          '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
          '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
          '<Default Extension="xml" ContentType="application/xml"/>'
          '<Default Extension="png" ContentType="image/png"/>'
          '<Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>'
          '<Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/>'
          '</Types>'),
      '_rels/.rels': utf8.encode('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
          '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
          '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>'
          '</Relationships>'),
      'word/_rels/document.xml.rels': utf8.encode('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
          '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
          '<Relationship Id="rStyles" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>'
          '${[for (final id in media.keys) '<Relationship Id="$id" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" Target="media/$id.png"/>'].join()}'
          '</Relationships>'),
      'word/styles.xml': utf8.encode('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
          '<w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">'
          '<w:docDefaults><w:rPrDefault><w:rPr><w:rFonts w:ascii="Arial" w:hAnsi="Arial" w:eastAsia="Microsoft YaHei"/>'
          '<w:sz w:val="22"/></w:rPr></w:rPrDefault><w:pPrDefault><w:pPr><w:spacing w:after="0" w:line="240" w:lineRule="auto"/></w:pPr></w:pPrDefault>'
          '</w:docDefaults><w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/></w:style></w:styles>'),
      'word/document.xml': utf8.encode('<?xml version="1.0" encoding="UTF-8" standalone="yes"?><w:document $ns><w:body>$body</w:body></w:document>'),
      for (final e in media.entries) 'word/media/${e.key}.png': e.value,
    };
    return _zip(files);
  }

  // A small ZIP writer (deflated with dart:io's own zlib).
  static Uint8List _zip(Map<String, List<int>> files) {
    final out = BytesBuilder();
    final central = BytesBuilder();
    var count = 0;
    void u16(BytesBuilder b, int v) => b.add([v & 0xFF, (v >> 8) & 0xFF]);
    void u32(BytesBuilder b, int v) => b.add([v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF, (v >> 24) & 0xFF]);
    for (final e in files.entries) {
      final name = utf8.encode(e.key);
      final data = e.value;
      final crc = _crc32(data);
      final packed = ZLibEncoder(raw: true, level: 6).convert(data);
      final offset = out.length;
      u32(out, 0x04034b50);
      u16(out, 20);
      u16(out, 0x0800); // names in UTF-8
      u16(out, 8);
      u16(out, 0);
      u16(out, 0x21);
      u32(out, crc);
      u32(out, packed.length);
      u32(out, data.length);
      u16(out, name.length);
      u16(out, 0);
      out.add(name);
      out.add(packed);
      u32(central, 0x02014b50);
      u16(central, 20);
      u16(central, 20);
      u16(central, 0x0800);
      u16(central, 8);
      u16(central, 0);
      u16(central, 0x21);
      u32(central, crc);
      u32(central, packed.length);
      u32(central, data.length);
      u16(central, name.length);
      u16(central, 0);
      u16(central, 0);
      u16(central, 0);
      u16(central, 0);
      u32(central, 0);
      u32(central, offset);
      central.add(name);
      count++;
    }
    final cd = central.toBytes();
    final cdOffset = out.length;
    out.add(cd);
    u32(out, 0x06054b50);
    u16(out, 0);
    u16(out, 0);
    u16(out, count);
    u16(out, count);
    u32(out, cd.length);
    u32(out, cdOffset);
    u16(out, 0);
    return out.toBytes();
  }

  static final List<int> _crcTable = List<int>.generate(256, (n) {
    var c = n;
    for (var k = 0; k < 8; k++) {
      c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1;
    }
    return c;
  });

  static int _crc32(List<int> data) {
    var c = 0xFFFFFFFF;
    for (final b in data) {
      c = _crcTable[(c ^ b) & 0xFF] ^ (c >> 8);
    }
    return c ^ 0xFFFFFFFF;
  }
}

/// A run of text in one look.
class _Run {
  _Run(this.text, this.style);
  String text;
  final PdfTextStyle? style;

  String get key => style == null ? '' : '${style!.name}|${style!.size.round()}|${style!.bold}|${style!.slanted}|${style!.rgb}';
}

/// One line of a page (PDF points).
class _TLine {
  final List<_Run> runs = [];
  double left = double.infinity, right = -double.infinity, top = -double.infinity, bottom = double.infinity;
  double base = 0, size = 10;
  final List<double> _bottoms = [], _heights = [];
  bool _cjk = false;

  String get text => runs.map((r) => r.text).join();

  void add(String s, PdfTextStyle? st, PdfRect r) {
    if (runs.isNotEmpty && runs.last.style == st) {
      runs.last.text += s;
    } else {
      runs.add(_Run(s, st));
    }
    if (r.width > 0.1 && r.height > 0.1 && s.trim().isNotEmpty) {
      left = math.min(left, r.left);
      right = math.max(right, r.right);
      top = math.max(top, r.top);
      bottom = math.min(bottom, r.bottom);
      _bottoms.add(r.bottom);
      _heights.add(r.height);
      if (s.runes.any(PdfFonts.isCjk)) _cjk = true;
    }
  }

  void finish() {
    // Trailing spaces off; the size and baseline estimated.
    while (runs.isNotEmpty && runs.last.text.trimRight().isEmpty) {
      runs.removeLast();
    }
    if (runs.isNotEmpty) runs.last.text = runs.last.text.trimRight();
    if (runs.isNotEmpty) runs.first.text = runs.first.text.trimLeft();
    final st = runs.map((r) => r.style).whereType<PdfTextStyle>().firstOrNull;
    final hs = [..._heights]..sort();
    final guess = hs.isEmpty ? 10.0 : (_cjk ? hs[hs.length ~/ 2] / 0.88 : hs.last / 0.72);
    size = (st != null && st.size > 0 ? st.size : guess).clamp(4.0, 96.0).toDouble();
    final bs = [..._bottoms]..sort();
    base = bs.isEmpty ? bottom : bs[bs.length ~/ 2];
  }

  /// Another piece of the same row, after a tab when there is a gap.
  void merge(_TLine o) {
    final first = o.left < left;
    final a = first ? o : this, b = first ? this : o;
    final runs2 = [...a.runs, if (b.left - a.right > size * 1.6) _Run('\t', null) else _Run(' ', null), ...b.runs];
    runs
      ..clear()
      ..addAll(runs2);
    left = math.min(left, o.left);
    right = math.max(right, o.right);
    top = math.max(top, o.top);
    bottom = math.min(bottom, o.bottom);
  }
}

/// A paragraph: its lines, the room before it (points).
class _Para {
  _Para(this.lines, this.before);
  final List<_TLine> lines;
  final double before;

  double get top => lines.first.top;

  bool centred(double left, double right) {
    final mid = (left + right) / 2, w = right - left;
    return lines.every((l) => ((l.left + l.right) / 2 - mid).abs() < w * 0.03 && l.right - l.left < w * 0.85);
  }

  String xml(double margin) {
    final runs = <_Run>[];
    for (var i = 0; i < lines.length; i++) {
      final l = lines[i];
      if (i > 0 && runs.isNotEmpty) {
        final prev = runs.last.text;
        final next = l.text;
        final cjk = prev.isNotEmpty && PdfFonts.isCjk(prev.runes.last) && next.isNotEmpty && PdfFonts.isCjk(next.runes.first);
        if (prev.endsWith('-') && prev.length > 1) {
          runs.last.text = prev.substring(0, prev.length - 1);
        } else if (!cjk) {
          runs.last.text += ' ';
        }
      }
      for (final r in l.runs) {
        if (runs.isNotEmpty && runs.last.key == r.key) {
          runs.last.text += r.text;
        } else {
          runs.add(_Run(r.text, r.style));
        }
      }
    }
    final first = lines.first;
    final rest = lines.length > 1 ? lines[1] : null;
    final indent = math.max(0.0, (rest?.left ?? first.left) - margin);
    final firstLine = rest == null ? 0.0 : first.left - rest.left;
    final ppr = StringBuffer('<w:pPr>');
    if (before > 1) ppr.write('<w:spacing w:before="${PdfToDocx._tw(math.min(before, 72))}"/>');
    final hasTab = first.text.contains('\t');
    if (!hasTab && (indent > 1 || firstLine.abs() > 1)) {
      ppr.write('<w:ind w:left="${PdfToDocx._tw(indent)}"${firstLine > 1 ? ' w:firstLine="${PdfToDocx._tw(firstLine)}"' : firstLine < -1 ? ' w:hanging="${PdfToDocx._tw(-firstLine)}"' : ''}/>');
    }
    if (_isCentred) ppr.write('<w:jc w:val="center"/>');
    ppr.write('</w:pPr>');
    final b = StringBuffer('<w:p>')..write(ppr);
    for (final r in runs) {
      if (r.text.isEmpty) continue;
      b.write('<w:r>${_rpr(r.style, first.size)}');
      final parts = r.text.split('\t');
      for (var i = 0; i < parts.length; i++) {
        if (i > 0) b.write('<w:tab/>');
        if (parts[i].isNotEmpty) b.write('<w:t xml:space="preserve">${PdfToDocx._x(parts[i])}</w:t>');
      }
      b.write('</w:r>');
    }
    b.write('</w:p>');
    return b.toString();
  }

  bool _isCentred = false;

  static String _rpr(PdfTextStyle? st, double size) {
    final b = StringBuffer('<w:rPr>');
    final fam = PdfFonts.familyOf(st?.name) ?? _plain(st?.name);
    if (fam != null && fam.isNotEmpty) {
      final f = PdfToDocx._x(fam);
      b.write('<w:rFonts w:ascii="$f" w:hAnsi="$f" w:eastAsia="$f" w:cs="$f"/>');
    }
    if (st?.bold ?? false) b.write('<w:b/>');
    if (st?.slanted ?? false) b.write('<w:i/>');
    final rgb = st?.rgb;
    if (rgb != null && rgb.length == 6 && rgb.toLowerCase() != '000000') b.write('<w:color w:val="${rgb.toUpperCase()}"/>');
    final sz = ((st != null && st.size > 0 ? st.size : size) * 2).round().clamp(8, 192);
    b.write('<w:sz w:val="$sz"/><w:szCs w:val="$sz"/></w:rPr>');
    return b.toString();
  }

  /// "ABCDEF+Calibri-Bold" → "Calibri".
  static String? _plain(String? n) {
    if (n == null || n.isEmpty) return null;
    var s = n.contains('+') && n.indexOf('+') == 6 ? n.substring(7) : n;
    s = s.split(RegExp(r'[-,]')).first;
    return s.replaceAllMapped(RegExp(r'(?<=[a-z])(?=[A-Z])'), (_) => ' ').trim();
  }
}
