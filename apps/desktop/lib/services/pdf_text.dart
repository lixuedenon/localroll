// apps/desktop/lib/services/pdf_text.dart
import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart' show Colors;
import 'package:localroll_core/localroll_core.dart';
import 'package:pdfrx/pdfrx.dart';

/// The text of a PDF, page by page: the text the PDF carries, and for
/// pages without any (a scan) a picture of the page for text recognition.
class PdfText {
  PdfText._();

  /// Reads [path]: each page's own text; for a page with none, [ocrPage]
  /// gets a picture of it (a PNG file, deleted afterwards) and returns its
  /// text. [keepGoing] is asked between pages (false: stop for now, null
  /// is returned). Null if the PDF can't be opened.
  static Future<(String, bool)?> read(
    String path, {
    required String tmpDir,
    required Future<String?> Function(String png) ocrPage,
    Future<bool> Function()? keepGoing,
    int width = 1600,
  }) async {
    PdfDocument? doc;
    try {
      doc = await PdfDocument.openFile(path);
      final out = StringBuffer();
      var usedOcr = false;
      for (final page in doc.pages) {
        if (keepGoing != null && !await keepGoing()) return null;
        var text = '';
        try {
          text = (await page.loadText()).fullText.trim();
        } catch (_) {}
        if (text.isEmpty) {
          final png = await _render(page, '$tmpDir${Platform.pathSeparator}pdf_page.png', width);
          if (png != null) {
            try {
              text = (await ocrPage(png.path)) ?? '';
              usedOcr = true;
            } finally {
              try {
                await png.delete();
              } catch (_) {}
            }
          }
        }
        if (text.isNotEmpty) out.writeln(text);
      }
      return (out.toString().trim(), usedOcr);
    } catch (e) {
      DiagLog.log('search', 'pdf not read: $e');
      return null;
    } finally {
      try {
        await doc?.dispose();
      } catch (_) {}
    }
  }

  static Future<File?> _render(PdfPage page, String outPath, int width) async {
    try {
      final w = width.toDouble();
      final h = (w * page.height / page.width).clamp(40.0, w * 3);
      final img = await page.render(fullWidth: w, fullHeight: h, backgroundColor: Colors.white);
      if (img == null) return null;
      final c = Completer<ui.Image>();
      ui.decodeImageFromPixels(img.pixels, img.width, img.height, img.format, c.complete);
      final picture = await c.future;
      img.dispose();
      final png = await picture.toByteData(format: ui.ImageByteFormat.png);
      picture.dispose();
      if (png == null) return null;
      final out = File(outPath);
      await out.parent.create(recursive: true);
      await out.writeAsBytes(png.buffer.asUint8List(), flush: true);
      return out;
    } catch (e) {
      DiagLog.log('search', 'pdf page not drawn: $e');
      return null;
    }
  }
}
