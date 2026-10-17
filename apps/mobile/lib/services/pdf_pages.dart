// apps/mobile/lib/services/pdf_pages.dart
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:localroll_core/localroll_core.dart';

/// PDF pages as pictures, drawn by the phone itself (iPhone: PDFKit;
/// Android: PdfRenderer) — no extra library. Channel: localroll/pdf.
class PdfPages {
  PdfPages._();

  static const MethodChannel _ch = MethodChannel('localroll/pdf');

  /// Number of pages (0: can't be read).
  static Future<int> count(String path) async {
    try {
      return await _ch.invokeMethod<int>('count', {'path': path}) ?? 0;
    } catch (e) {
      DiagLog.log('pdf', 'count failed: $e');
      return 0;
    }
  }

  /// Page [index] (from 0) as a JPEG [width] pixels wide; null if it failed.
  static Future<Uint8List?> render(String path, int index, int width) async {
    try {
      return await _ch.invokeMethod<Uint8List>('render', {'path': path, 'page': index, 'width': width.clamp(64, 2400)});
    } catch (e) {
      DiagLog.log('pdf', 'render failed: $e');
      return null;
    }
  }

  static final Map<String, Future<Uint8List?>> _thumbs = {};

  /// The first page, small (kept in memory while the app runs).
  static Future<Uint8List?> thumb(String path) => _thumbs.putIfAbsent(path, () => render(path, 0, 300));

  /// Forget a thumbnail (the file was renamed / deleted).
  static void forget(String path) => _thumbs.remove(path);
}
