// apps/mobile/lib/services/scan_pdf.dart
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

/// Scanned pages → one PDF. Each page keeps the shape of what was scanned
/// (A4 width, height to match), pictures as good-quality JPEG at about
/// 300 dpi — sharp to read and print, small enough to e-mail.
abstract final class ScanPdf {
  /// Long side of a page picture, in pixels (A4 at ~300 dpi).
  static const int maxSide = 3508;
  static const int quality = 85;

  /// Writes [pages] (image files, in order) as [out]. Runs off the UI thread.
  static Future<File> build(List<String> pages, File out) async {
    final bytes = await Isolate.run(() => _build(pages));
    await out.parent.create(recursive: true);
    await out.writeAsBytes(bytes, flush: true);
    return out;
  }

  static Future<Uint8List> _build(List<String> pages) async {
    final doc = pw.Document(producer: 'LocalRoll', creator: 'LocalRoll');
    for (final path in pages) {
      final raw = await File(path).readAsBytes();
      var picture = img.decodeImage(raw);
      if (picture == null) continue;
      picture = img.bakeOrientation(picture);
      final long = picture.width > picture.height ? picture.width : picture.height;
      if (long > maxSide) {
        picture = picture.width >= picture.height
            ? img.copyResize(picture, width: maxSide, interpolation: img.Interpolation.average)
            : img.copyResize(picture, height: maxSide, interpolation: img.Interpolation.average);
      }
      final jpg = img.encodeJpg(picture, quality: quality);
      final w = PdfPageFormat.a4.width;
      final h = w * picture.height / picture.width;
      doc.addPage(pw.Page(
        pageFormat: PdfPageFormat(w, h),
        margin: pw.EdgeInsets.zero,
        build: (_) => pw.Image(pw.MemoryImage(jpg), fit: pw.BoxFit.fill),
      ));
    }
    return doc.save();
  }

  /// "scan_2026-10-15_0930" (the name the person sees and can change).
  static String defaultName(DateTime t) {
    String two(int n) => n.toString().padLeft(2, '0');
    return 'scan_${t.year}-${two(t.month)}-${two(t.day)}_${two(t.hour)}${two(t.minute)}';
  }

  /// A name safe on Windows, Android and iOS, ending in .pdf.
  static String fileName(String typed, DateTime t) {
    var n = typed.trim().replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1F]'), '_');
    if (n.toLowerCase().endsWith('.pdf')) n = n.substring(0, n.length - 4);
    n = n.trim();
    if (n.isEmpty) n = defaultName(t);
    if (n.length > 120) n = n.substring(0, 120);
    return '$n.pdf';
  }
}
