// apps/desktop/lib/services/docx_letters.dart
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:localroll_core/localroll_core.dart' show DiagLog, ZipReader;

import 'pdf_docx.dart';

/// Word's PDF reflow sometimes puts every letter (or a few) of a line in a
/// text box of its own: the line looks right but can't be edited as text.
/// This joins the boxes of each line (where they touch) into one box that
/// holds the whole line, each letter keeping its own font, size and colour;
/// boxes far apart (another column) stay apart. Everything else in the file
/// is left as it was.
class DocxLetters {
  static final _t = RegExp(r'<w:t(?:\s[^>]*)?>([^<]*)</w:t>');
  static final _box = RegExp(r'<a:off x="(-?\d+)" y="(-?\d+)"/><a:ext cx="(\d+)" cy="(\d+)"/>');

  /// Mends [path] in place. The number of boxes joined (0: nothing to do).
  static int mend(String path) {
    try {
      final zip = ZipReader.open(File(path).readAsBytesSync());
      final raw = zip?.read('word/document.xml');
      if (zip == null || raw == null) return 0;
      final (xml, joined) = mendXml(utf8.decode(raw, allowMalformed: true));
      if (joined == 0) return 0;
      final files = <String, List<int>>{};
      for (final n in zip.names) {
        final d = n == 'word/document.xml' ? utf8.encode(xml) : zip.read(n);
        if (d == null) return 0; // something we can't copy: leave the file alone
        files[n] = d;
      }
      final tmp = File('$path.mend');
      tmp.writeAsBytesSync(PdfToDocx.zip(files), flush: true);
      tmp.renameSync(path);
      DiagLog.log('tools', 'docx: joined $joined one-letter text boxes into whole lines');
      return joined;
    } catch (e) {
      DiagLog.log('tools', 'docx: could not join text boxes: $e');
      return 0;
    }
  }

  /// [xml] (word/document.xml) with the letter boxes joined, and how many.
  static (String, int) mendXml(String xml) {
    var total = 0;
    // A drawing group comes twice (DrawingML for Word 2010+, VML for older
    // programs): when the group changes, only the DrawingML one is kept.
    final out = xml.replaceAllMapped(RegExp(r'<mc:AlternateContent>.*?</mc:AlternateContent>', dotAll: true), (m) {
      final a = m.group(0)!;
      final ch = RegExp(r'<mc:Choice Requires="wpg">(.*?)</mc:Choice>', dotAll: true).firstMatch(a);
      if (ch == null) return a;
      var n = 0;
      final inner = ch.group(1)!.replaceAllMapped(RegExp(r'<wpg:wgp>.*?</wpg:wgp>', dotAll: true), (g) {
        final (s, k) = _group(g.group(0)!);
        n += k;
        return s;
      });
      if (n == 0) return a;
      total += n;
      return inner;
    });
    // Groups without the two versions.
    final rest = out.replaceAllMapped(RegExp(r'<wpg:wgp>.*?</wpg:wgp>', dotAll: true), (g) {
      final (s, k) = _group(g.group(0)!);
      total += k;
      return s;
    });
    return (rest, total);
  }

  static (String, int) _group(String g) {
    // The group split into shapes and what is between them.
    final parts = <String>[];
    var at = 0;
    for (final m in RegExp(r'<wps:wsp>.*?</wps:wsp>', dotAll: true).allMatches(g)) {
      parts
        ..add(g.substring(at, m.start))
        ..add(m.group(0)!);
      at = m.end;
    }
    parts.add(g.substring(at));
    final boxes = <_Box>[];
    for (var i = 0; i < parts.length; i++) {
      final p = parts[i];
      if (!p.startsWith('<wps:wsp>') || !p.contains('<wps:txbx>')) continue;
      if (RegExp(r'<w:p[ >]').allMatches(p).length != 1) continue;
      final m = _box.firstMatch(p);
      if (m == null) continue;
      boxes.add(_Box(
        i,
        int.parse(m.group(1)!),
        int.parse(m.group(2)!),
        int.parse(m.group(3)!),
        int.parse(m.group(4)!),
        _t.allMatches(p).map((x) => x.group(1)!).join(),
        RegExp(r'<w:r>.*?</w:r>', dotAll: true).allMatches(p).map((x) => x.group(0)!).toList(),
        p,
      ));
    }
    if (boxes.length < 2) return (g, 0);
    // Lines: boxes at (about) the same height.
    boxes.sort((a, b) => a.y != b.y ? a.y.compareTo(b.y) : a.x.compareTo(b.x));
    final lines = <List<_Box>>[];
    for (final b in boxes) {
      final line = lines.where((l) => (l.first.y - b.y).abs() <= math.max(l.first.cy, b.cy) * 0.35).firstOrNull;
      line == null ? lines.add([b]) : line.add(b);
    }
    var joined = 0;
    for (final line in lines) {
      line.sort((a, b) => a.x.compareTo(b.x));
      // Runs of boxes that touch (a gap under about half a letter).
      final runs = <List<_Box>>[
        [line.first],
      ];
      for (final b in line.skip(1)) {
        final p = runs.last.last;
        final letter = p.cx / math.max(1, p.text.length);
        b.x <= p.x + p.cx + 0.6 * letter ? runs.last.add(b) : runs.add([b]);
      }
      for (var k = 0; k < runs.length; k++) {
        final r = runs[k];
        if (r.length < 2) continue;
        final x0 = r.first.x;
        final y0 = r.map((b) => b.y).reduce(math.min);
        // A little wider than the boxes were (the joined text may need it,
        // and a box that is too narrow wraps and hides the end), but not
        // into the next piece of the line.
        final w = r.map((b) => b.x + b.cx).reduce(math.max) - x0;
        final room = k + 1 < runs.length ? runs[k + 1].first.x - x0 - 20000 : 1 << 40;
        final x1 = x0 + math.min((w * 1.3).round(), math.max(w, room));
        final y1 = r.map((b) => b.y + b.cy).reduce(math.max);
        // The letters, the ones that look the same in one piece of text.
        final pieces = <List<String>>[];
        for (final w in r.expand((b) => b.runs)) {
          final look = RegExp(r'<w:rPr>.*?</w:rPr>', dotAll: true).firstMatch(w)?.group(0) ?? '';
          final text = _t.allMatches(w).map((x) => x.group(1)!).join();
          if (pieces.isNotEmpty && pieces.last[0] == look) {
            pieces.last[1] += text;
          } else {
            pieces.add([look, text]);
          }
        }
        final runsXml = pieces.map((p) => '<w:r>${p[0]}<w:t xml:space="preserve">${p[1]}</w:t></w:r>').join();
        var src = r.first.src.replaceFirst(_box, '<a:off x="$x0" y="$y0"/><a:ext cx="${x1 - x0}" cy="${y1 - y0}"/>');
        src = src.replaceFirstMapped(RegExp(r'(<w:p>(?:<w:pPr>.*?</w:pPr>)?).*?(</w:p>)', dotAll: true), (m) => '${m.group(1)}$runsXml${m.group(2)}');
        // The box grows with what is typed into it.
        src = src.replaceFirstMapped(RegExp(r'<wps:bodyPr([^>]*?)(/>|>.*?</wps:bodyPr>)', dotAll: true),
            (m) => '<wps:bodyPr${m.group(1)!.replaceAll(RegExp(r'\swrap="[^"]*"'), '')} wrap="none"><a:spAutoFit/></wps:bodyPr>');
        parts[r.first.i] = src;
        for (final b in r.skip(1)) {
          parts[b.i] = '';
        }
        joined += r.length - 1;
      }
    }
    return (parts.join(), joined);
  }
}

class _Box {
  _Box(this.i, this.x, this.y, this.cx, this.cy, this.text, this.runs, this.src);
  final int i, x, y, cx, cy;
  final String text;
  final List<String> runs;
  final String src;
}
