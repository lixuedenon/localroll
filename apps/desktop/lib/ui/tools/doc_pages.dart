// apps/desktop/lib/ui/tools/doc_pages.dart
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:localroll_core/localroll_core.dart' show DiagLog;
import 'package:pdfrx/pdfrx.dart';

import '../../app_services.dart';
import '../../services/file_tools.dart';

/// Any file as pages to look at, draw on, read or print: a PDF's pages, a
/// photo as one page, an Office document made into a PDF first.
class DocPages {
  DocPages._(this.original, {this.pdfPath, this.pdf, this.image, this.jpeg});

  /// What was opened.
  final String original;

  /// The PDF behind the pages (the file itself, or one made from it).
  final String? pdfPath;
  final PdfDocument? pdf;

  /// A photo: the picture, and the upright JPEG it came from.
  final ui.Image? image;
  final String? jpeg;

  bool get isPdf => pdf != null;
  int get count => pdf?.pages.length ?? 1;

  /// Width ÷ height of page [i] (0-based).
  double aspect(int i) {
    final d = pdf;
    if (d != null) return d.pages[i].width / d.pages[i].height;
    final im = image!;
    return im.width / im.height;
  }

  /// Page size in points (a photo: as if 150 dpi).
  Size points(int i) {
    final d = pdf;
    if (d != null) return Size(d.pages[i].width, d.pages[i].height);
    final im = image!;
    return Size(im.width * 72 / 150, im.height * 72 / 150);
  }

  Widget view(int i) {
    final d = pdf;
    if (d != null) return PdfPageView(document: d, pageNumber: i + 1);
    return RawImage(image: image, fit: BoxFit.fill);
  }

  /// [part] (0–1) of page [i] as a picture [width] pixels wide (the whole
  /// page: [Rect.fromLTWH(0, 0, 1, 1)]).
  Future<ui.Image?> render(int i, Rect part, int width) async {
    final d = pdf;
    if (d != null) {
      final pg = d.pages[i];
      final fullW = width / part.width, fullH = fullW * pg.height / pg.width;
      final img = await pg.render(
        x: (part.left * fullW).round(),
        y: (part.top * fullH).round(),
        width: width,
        height: (part.height * fullH).round().clamp(1, 20000),
        fullWidth: fullW,
        fullHeight: fullH,
        backgroundColor: Colors.white,
      );
      if (img == null) return null;
      final out = await img.createImage();
      img.dispose();
      return out;
    }
    final im = image!;
    final src = Rect.fromLTWH(part.left * im.width, part.top * im.height, part.width * im.width, part.height * im.height);
    final h = (width * src.height / src.width).round().clamp(1, 20000);
    final rec = ui.PictureRecorder();
    Canvas(rec).drawImageRect(im, src, Rect.fromLTWH(0, 0, width.toDouble(), h.toDouble()), Paint()..filterQuality = FilterQuality.high);
    return rec.endRecording().toImage(width, h);
  }

  /// The words of page [i] stored in the PDF itself (not read from the
  /// picture: exact), in [part] (0–1) or all; '' when it has none (a scan).
  Future<String> textIn(int i, Rect? part) async {
    final d = pdf;
    if (d == null) return '';
    try {
      final pg = d.pages[i];
      final t = await pg.loadText();
      if (part == null) return t.fullText.trim();
      final keep = <int>[];
      for (final f in t.fragments) {
        for (var k = 0; k < f.charRects.length && k < f.length; k++) {
          final r = f.charRects[k].toRect(page: pg);
          if (part.contains(Offset(r.center.dx / pg.width, r.center.dy / pg.height))) keep.add(f.index + k);
        }
      }
      keep.sort();
      final b = StringBuffer();
      var last = -1;
      for (final k in keep) {
        if (k >= t.fullText.length) continue;
        if (last >= 0 && k > last + 1) {
          final gap = t.fullText.substring(last + 1, k);
          if (gap.contains('\n')) {
            b.write('\n');
          } else if (gap.contains(' ')) {
            b.write(' ');
          }
        }
        b.write(t.fullText[k]);
        last = k;
      }
      return b.toString().trim();
    } catch (e) {
      DiagLog.log('tools', 'text of page ${i + 1}: $e');
      return '';
    }
  }

  Future<void> dispose() async {
    await pdf?.dispose();
    image?.dispose();
  }

  static bool isPicture(String path) {
    final e = path.toLowerCase().split('.').last;
    return const {'jpg', 'jpeg', 'png', 'heic', 'heif', 'webp', 'bmp', 'gif', 'tif', 'tiff', 'dng'}.contains(e);
  }

  /// PDF, photo or Office document: shown (and printed) as pages.
  static bool handles(String path) => path.toLowerCase().endsWith('.pdf') || isPicture(path) || OfficePdf.handles(path);

  /// Opens [path]; null when it can't be shown as pages ([why] says).
  static Future<DocPages?> open(AppServices s, String path, {void Function(String why)? why}) async {
    try {
      final lower = path.toLowerCase();
      if (lower.endsWith('.pdf')) {
        return DocPages._(path, pdfPath: path, pdf: await PdfDocument.openFile(path));
      }
      if (isPicture(path)) {
        final j = await uprightJpeg(s, path, max: 4096);
        if (j == null) {
          why?.call('picture');
          return null;
        }
        final bytes = await File(j.$1).readAsBytes();
        final codec = await ui.instantiateImageCodec(Uint8List.fromList(bytes));
        final f = await codec.getNextFrame();
        return DocPages._(path, image: f.image, jpeg: j.$1);
      }
      if (OfficePdf.handles(path)) {
        final tmp = await Directory.systemTemp.createTemp('lr_doc');
        final name = path.split(Platform.pathSeparator).last;
        final out = '${tmp.path}${Platform.pathSeparator}${name.substring(0, name.lastIndexOf('.'))}.pdf';
        final err = await OfficePdf.convert(path, out);
        if (err != null) {
          why?.call(err);
          return null;
        }
        return DocPages._(path, pdfPath: out, pdf: await PdfDocument.openFile(out));
      }
      why?.call('kind');
      return null;
    } catch (e) {
      DiagLog.log('tools', 'pages of $path: $e');
      why?.call('$e');
      return null;
    }
  }
}
