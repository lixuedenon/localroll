// apps/desktop/lib/services/format_convert.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import 'package:localroll_core/localroll_core.dart';
import 'package:pdfrx/pdfrx.dart';

import '../app_services.dart';
import 'converter.dart';
import 'file_tools.dart';

// "Format conversion": what can be turned into what, by kind of file, and
// doing it (ffmpeg's queue for pictures, video and sound; PDF and Office
// work here, Office through Microsoft Office on this PC).

enum ConvCat { image, video, audio, doc }

/// A format on the wheels: its name and the file endings that are it.
class Fmt {
  const Fmt(this.id, this.label, this.exts);

  final String id;
  final String label;
  final Set<String> exts;

  bool takes(String path) => exts.contains(extensionOf(path));
}

/// How one pair is done.
sealed class ConvOp {
  const ConvOp();

  /// Needs Microsoft Office on this PC.
  bool get office => false;

  /// The new file's ending.
  String get ext;
}

/// ffmpeg's queue (results arrive by themselves, in the tool history).
class MediaOp extends ConvOp {
  const MediaOp(this.format);
  final ConvertFormat format;
  @override
  String get ext => format.ext;
}

/// Photos into one PDF.
class ImagesToPdf extends ConvOp {
  const ImagesToPdf();
  @override
  String get ext => 'pdf';
}

/// Each page a picture.
class PdfToImages extends ConvOp {
  const PdfToImages(this.ext);
  @override
  final String ext;
}

/// The words in a PDF (pages without words: read off the picture).
class PdfToText extends ConvOp {
  const PdfToText();
  @override
  String get ext => 'txt';
}

/// Plain text laid out on A4 pages (no Office needed).
class TextToPdf extends ConvOp {
  const TextToPdf();
  @override
  String get ext => 'pdf';
}

/// Word / Excel / PowerPoint do it.
class OfficeOp extends ConvOp {
  const OfficeOp(this.kind, this.ext);

  /// pdf · wordDocx · wordTxt · excelCsv · excelXlsx · pptImages
  final String kind;
  @override
  final String ext;
  @override
  bool get office => true;
}

class FormatTable {
  FormatTable._();

  static const _heic = Fmt('heic', 'HEIC', {'heic', 'heif'});
  static const _jpg = Fmt('jpg', 'JPG', {'jpg', 'jpeg'});
  static const _png = Fmt('png', 'PNG', {'png'});
  static const _webp = Fmt('webp', 'WebP', {'webp'});
  static const _bmp = Fmt('bmp', 'BMP', {'bmp'});
  static const _tiff = Fmt('tiff', 'TIFF', {'tif', 'tiff'});
  static const _gif = Fmt('gif', 'GIF', {'gif'});
  static const _avif = Fmt('avif', 'AVIF', {'avif'});
  static const _pdf = Fmt('pdf', 'PDF', {'pdf'});

  static const _mp4 = Fmt('mp4', 'MP4', {'mp4', 'm4v'});
  static const _mov = Fmt('mov', 'MOV', {'mov'});
  static const _mkv = Fmt('mkv', 'MKV', {'mkv'});
  static const _avi = Fmt('avi', 'AVI', {'avi'});
  static const _wmv = Fmt('wmv', 'WMV', {'wmv'});
  static const _webm = Fmt('webm', 'WebM', {'webm'});
  static const _flv = Fmt('flv', 'FLV', {'flv'});
  static const _3gp = Fmt('3gp', '3GP', {'3gp'});
  static const _mts = Fmt('mts', 'MTS', {'mts', 'm2ts', 'ts'});

  static const _mp3 = Fmt('mp3', 'MP3', {'mp3'});
  static const _m4a = Fmt('m4a', 'M4A / AAC', {'m4a', 'aac'});
  static const _wav = Fmt('wav', 'WAV', {'wav'});
  static const _flac = Fmt('flac', 'FLAC', {'flac'});
  static const _ogg = Fmt('ogg', 'OGG', {'ogg', 'oga'});
  static const _opus = Fmt('opus', 'Opus', {'opus'});
  static const _wma = Fmt('wma', 'WMA', {'wma'});
  static const _amr = Fmt('amr', 'AMR', {'amr'});

  static const _word = Fmt('word', 'Word', {'doc', 'docx', 'rtf', 'odt', 'wps'});
  static const _excel = Fmt('excel', 'Excel', {'xls', 'xlsx', 'xlsm', 'ods', 'et'});
  static const _csv = Fmt('csv', 'CSV', {'csv'});
  static const _ppt = Fmt('ppt', 'PowerPoint', {'ppt', 'pptx', 'pps', 'ppsx', 'odp', 'dps'});
  static const _txt = Fmt('txt', 'TXT', {'txt', 'md', 'log'});

  /// The wheels' items (the same on both sides).
  static List<Fmt> of(ConvCat c) => switch (c) {
        ConvCat.image => const [_heic, _jpg, _png, _webp, _bmp, _tiff, _gif, _avif, _pdf],
        ConvCat.video => const [_mp4, _mov, _mkv, _avi, _wmv, _webm, _flv, _3gp, _mts, _gif, _mp3, _m4a, _wav],
        ConvCat.audio => const [_mp3, _m4a, _wav, _flac, _ogg, _opus, _wma, _amr],
        ConvCat.doc => const [_pdf, _word, _excel, _csv, _ppt, _txt, _jpg, _png],
      };

  /// How [from] becomes [to] (null: it can't, or nothing to do).
  static ConvOp? op(ConvCat c, Fmt from, Fmt to) {
    if (from.id == to.id) return null;
    switch (c) {
      case ConvCat.image:
        if (to.id == 'heic') return null;
        if (to.id == 'pdf') return const ImagesToPdf();
        if (from.id == 'pdf') return (to.id == 'jpg' || to.id == 'png') ? PdfToImages(to.id) : null;
        return MediaOp(switch (to.id) {
          'jpg' => ConvertFormat.jpg,
          'png' => ConvertFormat.png,
          'webp' => ConvertFormat.webp,
          'bmp' => ConvertFormat.bmp,
          'tiff' => ConvertFormat.tiff,
          'gif' => ConvertFormat.gifImage,
          _ => ConvertFormat.avif,
        });
      case ConvCat.video:
        const audio = {'mp3', 'm4a', 'wav'};
        if (audio.contains(from.id)) return null;
        final f = switch (to.id) {
          'mp4' => ConvertFormat.mp4,
          'mov' => ConvertFormat.mov,
          'mkv' => ConvertFormat.mkv,
          'avi' => ConvertFormat.avi,
          'wmv' => ConvertFormat.wmv,
          'webm' => ConvertFormat.webm,
          'gif' => ConvertFormat.gif,
          'mp3' => ConvertFormat.mp3,
          'm4a' => ConvertFormat.m4a,
          'wav' => ConvertFormat.wav,
          _ => null,
        };
        return f == null ? null : MediaOp(f);
      case ConvCat.audio:
        final f = switch (to.id) {
          'mp3' => ConvertFormat.mp3,
          'm4a' => ConvertFormat.m4a,
          'wav' => ConvertFormat.wav,
          'flac' => ConvertFormat.flac,
          _ => null,
        };
        return f == null ? null : MediaOp(f);
      case ConvCat.doc:
        return switch ((from.id, to.id)) {
          ('pdf', 'jpg') || ('pdf', 'png') => PdfToImages(to.id),
          ('pdf', 'txt') => const PdfToText(),
          ('pdf', 'word') => const OfficeOp('wordDocx', 'docx'),
          ('word', 'pdf') || ('excel', 'pdf') || ('csv', 'pdf') || ('ppt', 'pdf') => const OfficeOp('pdf', 'pdf'),
          ('word', 'txt') => const OfficeOp('wordTxt', 'txt'),
          ('txt', 'word') => const OfficeOp('wordDocx', 'docx'),
          ('excel', 'csv') => const OfficeOp('excelCsv', 'csv'),
          ('csv', 'excel') => const OfficeOp('excelXlsx', 'xlsx'),
          ('ppt', 'jpg') => const OfficeOp('pptImages', 'jpg'),
          ('ppt', 'png') => const OfficeOp('pptImages', 'png'),
          ('txt', 'pdf') => const TextToPdf(),
          ('jpg', 'pdf') || ('png', 'pdf') => const ImagesToPdf(),
          _ => null,
        };
    }
  }

  /// The kind and format a file is (the current kind first).
  static (ConvCat, Fmt)? find(String path, ConvCat first) {
    for (final c in [first, ...ConvCat.values.where((x) => x != first)]) {
      for (final f in of(c)) {
        if (f.takes(path) && (c != ConvCat.doc || f.id != 'jpg' && f.id != 'png' || first == ConvCat.doc)) return (c, f);
      }
    }
    return null;
  }
}

/// Doing the pairs that are not ffmpeg's queue. Each returns the new files
/// and why some failed.
class FormatConverter {
  FormatConverter._();

  /// PowerShell, encoded (paths with any characters survive).
  static Future<String?> _ps(String script, {Duration limit = const Duration(minutes: 3)}) async {
    final units = <int>[];
    for (final u in script.codeUnits) {
      units
        ..add(u & 0xFF)
        ..add(u >> 8);
    }
    try {
      final r = await Process.run('powershell', ['-NoProfile', '-NonInteractive', '-EncodedCommand', base64.encode(units)]).timeout(limit);
      final err = '${r.stderr}'.trim();
      return err.isEmpty ? null : (err.length > 300 ? err.substring(0, 300) : err);
    } on TimeoutException {
      return 'timeout';
    } catch (e) {
      return '$e';
    }
  }

  static String _q(String v) => v.replaceAll("'", "''");

  /// Office: [src] into [out].
  static Future<String?> office(String kind, String src, String out) async {
    if (kind == 'pdf') return OfficePdf.convert(src, out);
    final s = _q(src), o = _q(out);
    final script = switch (kind) {
      // Word: a PDF opened in Word is turned into an editable document
      // (Word's own "PDF Reflow"; its question switched off first).
      'wordDocx' => "\$a=New-Object -ComObject Word.Application;\$a.Visible=\$false;\$a.DisplayAlerts=0;"
          "try{\$k='HKCU:\\Software\\Microsoft\\Office\\'+\$a.Version+'\\Word\\Options';if(!(Test-Path \$k)){New-Item \$k|Out-Null};"
          "Set-ItemProperty \$k DisableConvertPdfWarning 1 -Type DWord;"
          "\$d=\$a.Documents.Open('$s',\$false,\$true,\$false,'','',\$false,'','',${src.toLowerCase().endsWith('.txt') || src.toLowerCase().endsWith('.md') || src.toLowerCase().endsWith('.log') ? 5 : 0},65001);"
          "\$d.SaveAs2('$o',16);\$d.Close(\$false)}finally{\$a.Quit()}",
      'wordTxt' => "\$a=New-Object -ComObject Word.Application;\$a.Visible=\$false;\$a.DisplayAlerts=0;"
          "try{\$d=\$a.Documents.Open('$s',\$false,\$true);\$d.SaveAs2('$o',7,\$false,'',\$false,'',\$false,\$false,\$false,\$false,\$false,65001);\$d.Close(\$false)}finally{\$a.Quit()}",
      'excelCsv' => "\$a=New-Object -ComObject Excel.Application;\$a.Visible=\$false;\$a.DisplayAlerts=\$false;"
          "try{\$d=\$a.Workbooks.Open('$s',0,\$true);try{\$d.SaveAs('$o',62)}catch{\$d.SaveAs('$o',6)};\$d.Close(\$false)}finally{\$a.Quit()}",
      'excelXlsx' => "\$a=New-Object -ComObject Excel.Application;\$a.Visible=\$false;\$a.DisplayAlerts=\$false;"
          "try{\$a.Workbooks.OpenText('$s',65001,1,1,1,\$false,\$false,\$false,\$true);\$d=\$a.ActiveWorkbook;\$d.SaveAs('$o',51);\$d.Close(\$false)}finally{\$a.Quit()}",
      _ => '',
    };
    if (script.isEmpty) return 'unknown';
    final err = await _ps(script);
    if (await File(out).exists() && await File(out).length() > 0) return null;
    DiagLog.log('tools', 'office $kind failed: $err');
    return err ?? 'no file';
  }

  /// PowerPoint's slides as pictures (made in a temporary folder, then named
  /// like the other results).
  static Future<List<String>> pptImages(AppServices s, String src, String ext) async {
    final tmp = await Directory.systemTemp.createTemp('lr_ppt');
    final filter = ext == 'png' ? 'PNG' : 'JPG';
    final s0 = _q(src), d0 = _q(tmp.path);
    final script = "\$a=New-Object -ComObject PowerPoint.Application;"
        "try{\$d=\$a.Presentations.Open('$s0',\$true,\$false,\$false);\$w=[int](\$d.PageSetup.SlideWidth*2);\$h=[int](\$d.PageSetup.SlideHeight*2);\$i=1;"
        "foreach(\$sl in \$d.Slides){\$sl.Export('$d0\\'+\$i+'.$ext','$filter',\$w,\$h);\$i++};\$d.Close()}finally{\$a.Quit()}";
    final err = await _ps(script);
    final outs = <String>[];
    try {
      final made = [
        for (final e in tmp.listSync())
          if (e is File) e.path,
      ]..sort((a, b) => (int.tryParse(baseOf(a)) ?? 0).compareTo(int.tryParse(baseOf(b)) ?? 0));
      for (final m in made) {
        final out = toolOutPath(s, src, '-${baseOf(m)}', ext);
        await File(m).copy(out);
        outs.add(out);
      }
      await tmp.delete(recursive: true);
    } catch (_) {}
    if (outs.isEmpty) DiagLog.log('tools', 'powerpoint → pictures failed: $err');
    return outs;
  }

  static String baseOf(String p) {
    final n = p.split(Platform.pathSeparator).last;
    final dot = n.lastIndexOf('.');
    return dot > 0 ? n.substring(0, dot) : n;
  }

  /// A PDF's pages as JPG / PNG at 150 dpi.
  static Future<List<String>> pdfImages(AppServices s, String src, String ext) async {
    final outs = <String>[];
    final doc = await PdfDocument.openFile(src);
    try {
      for (final page in doc.pages) {
        final w = (page.width * 150 / 72).round(), h = (page.height * 150 / 72).round();
        final pic = await page.render(width: w, height: h, fullWidth: w.toDouble(), fullHeight: h.toDouble(), backgroundColor: Colors.white);
        if (pic == null) continue;
        final im = await pic.createImage();
        pic.dispose();
        final out = toolOutPath(s, src, '-p${page.pageNumber}', ext);
        await _write(im, out, ext);
        im.dispose();
        outs.add(out);
      }
    } finally {
      await doc.dispose();
    }
    return outs;
  }

  static Future<void> _write(ui.Image im, String out, String ext) async {
    final png = await im.toByteData(format: ui.ImageByteFormat.png);
    if (png == null) throw StateError('no picture');
    final bytes = png.buffer.asUint8List();
    if (ext == 'png') {
      await File(out).writeAsBytes(bytes, flush: true);
    } else {
      final d = img.decodePng(bytes);
      if (d == null) throw StateError('no picture');
      await File(out).writeAsBytes(img.encodeJpg(d, quality: 90), flush: true);
    }
  }

  /// The words in a PDF (a page with none: read off its picture).
  static Future<String?> pdfText(AppServices s, String src, String out) async {
    final buf = StringBuffer();
    final doc = await PdfDocument.openFile(src);
    final tmp = await Directory.systemTemp.createTemp('lr_pdft');
    try {
      for (final page in doc.pages) {
        var t = '';
        try {
          t = (await page.loadText()).fullText.trim();
        } catch (_) {}
        if (t.isEmpty) {
          final w = (page.width * 200 / 72).round(), h = (page.height * 200 / 72).round();
          final pic = await page.render(width: w, height: h, fullWidth: w.toDouble(), fullHeight: h.toDouble(), backgroundColor: Colors.white);
          if (pic != null) {
            final im = await pic.createImage();
            pic.dispose();
            final png = '${tmp.path}${Platform.pathSeparator}${page.pageNumber}.png';
            await _write(im, png, 'png');
            im.dispose();
            t = (await s.textIndexer.ocr.read(png))?.trim() ?? '';
          }
        }
        if (doc.pages.length > 1) buf.writeln('— ${page.pageNumber} —');
        buf.writeln(t);
        buf.writeln();
      }
    } finally {
      await doc.dispose();
      try {
        await tmp.delete(recursive: true);
      } catch (_) {}
    }
    await File(out).writeAsString(buf.toString().trim(), flush: true);
    return null;
  }

  /// Plain text on A4 pages (150 dpi pictures in a PDF), in the app's fonts.
  static Future<String?> textPdf(String src, String out, List<String> fonts) async {
    final raw = await File(src).readAsBytes();
    String text;
    try {
      text = utf8.decode(raw);
    } catch (_) {
      text = latin1.decode(raw);
    }
    if (text.startsWith('﻿')) text = text.substring(1);
    const pw = 1240.0, ph = 1754.0, margin = 120.0;
    final tp = TextPainter(
      text: TextSpan(
        text: text.isEmpty ? ' ' : text,
        style: TextStyle(fontSize: 26, height: 1.5, color: Colors.black, fontFamily: fonts.first, fontFamilyFallback: fonts.skip(1).toList()),
      ),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: pw - 2 * margin);
    final lines = tp.computeLineMetrics();
    // Page breaks between lines.
    final starts = <double>[0];
    var pageTop = 0.0;
    for (final l in lines) {
      final bottom = l.baseline + l.descent;
      if (bottom - pageTop > ph - 2 * margin) {
        pageTop = l.baseline - l.ascent;
        starts.add(pageTop);
      }
    }
    final tmp = await Directory.systemTemp.createTemp('lr_txtpdf');
    final pages = <PdfPlanPage>[];
    try {
      for (var i = 0; i < starts.length; i++) {
        final top = starts[i];
        final end = i + 1 < starts.length ? starts[i + 1] : tp.height;
        final rec = ui.PictureRecorder();
        final c = Canvas(rec);
        c.drawRect(const Rect.fromLTWH(0, 0, pw, ph), Paint()..color = Colors.white);
        c.save();
        c.clipRect(Rect.fromLTWH(margin, margin, pw - 2 * margin, end - top));
        tp.paint(c, Offset(margin, margin - top));
        c.restore();
        final im = await rec.endRecording().toImage(pw.toInt(), ph.toInt());
        final jpg = '${tmp.path}${Platform.pathSeparator}$i.jpg';
        await _write(im, jpg, 'jpg');
        im.dispose();
        pages.add(PdfFromJpeg(jpg, 595, 842, const Rect.fromLTWH(0, 0, 595, 842)));
      }
      return await PdfBuilder.build(out, pages);
    } finally {
      try {
        await tmp.delete(recursive: true);
      } catch (_) {}
    }
  }
}
