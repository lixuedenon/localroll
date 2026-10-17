// apps/desktop/lib/ui/pdf_thumb.dart
import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:localroll_core/localroll_core.dart';
import 'package:pdfrx/pdfrx.dart';

import 'theme.dart';

/// The first page of a PDF as a small picture, made once and kept in the
/// library's picture cache (PNG). One PDF at a time, so a folder full of
/// scans never loads many documents at once.
class PdfThumbs {
  PdfThumbs._();

  static final Map<String, Future<File?>> _pending = {};
  static final Queue<Completer<void>> _waiting = Queue();
  static bool _busy = false;

  /// Width of the stored picture, in pixels.
  static const int width = 240;

  /// A name that changes when the file changes (path, size, time).
  static String _key(String path, FileStat st) {
    var h = 0xcbf29ce484222325;
    for (final b in utf8.encode('$path|${st.size}|${st.modified.millisecondsSinceEpoch}')) {
      h ^= b;
      h *= 0x100000001b3; // wraps at 64 bits
    }
    return 'pdf_${h.toRadixString(16).replaceAll('-', 'n')}.png';
  }

  static Future<File?> of(String path, String cacheDir) async {
    final FileStat st;
    try {
      st = await File(path).stat();
    } catch (_) {
      return null;
    }
    final out = File('$cacheDir${Platform.pathSeparator}${_key(path, st)}');
    if (await out.exists()) return out;
    return _pending.putIfAbsent(out.path, () => _make(path, out).whenComplete(() => _pending.remove(out.path)));
  }

  static Future<File?> _make(String path, File out) async {
    // One at a time.
    if (_busy) {
      final c = Completer<void>();
      _waiting.add(c);
      await c.future;
    }
    _busy = true;
    PdfDocument? doc;
    try {
      doc = await PdfDocument.openFile(path);
      if (doc.pages.isEmpty) return null;
      final page = doc.pages.first;
      final w = width.toDouble();
      final h = (w * page.height / page.width).clamp(40.0, w * 2);
      final img = await page.render(fullWidth: w, fullHeight: h, backgroundColor: Colors.white);
      if (img == null) return null;
      final c = Completer<ui.Image>();
      ui.decodeImageFromPixels(img.pixels, img.width, img.height, img.format, c.complete);
      final picture = await c.future;
      img.dispose();
      final png = await picture.toByteData(format: ui.ImageByteFormat.png);
      picture.dispose();
      if (png == null) return null;
      await out.parent.create(recursive: true);
      await out.writeAsBytes(png.buffer.asUint8List(), flush: true);
      return out;
    } catch (e) {
      DiagLog.log('ui', 'pdf thumbnail failed: $e');
      return null;
    } finally {
      try {
        await doc?.dispose();
      } catch (_) {}
      _busy = false;
      if (_waiting.isNotEmpty) _waiting.removeFirst().complete();
    }
  }
}

/// A PDF's first page (or the PDF icon while it is made / if it can't be).
class PdfThumb extends StatefulWidget {
  const PdfThumb({super.key, required this.path, required this.cacheDir, this.size = 48});

  final String path;
  final String cacheDir;
  final double size;

  @override
  State<PdfThumb> createState() => _PdfThumbState();
}

class _PdfThumbState extends State<PdfThumb> {
  File? _file;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(PdfThumb old) {
    super.didUpdateWidget(old);
    if (old.path != widget.path) {
      _file = null;
      _load();
    }
  }

  Future<void> _load() async {
    final f = await PdfThumbs.of(widget.path, widget.cacheDir);
    if (mounted && f != null) setState(() => _file = f);
  }

  @override
  Widget build(BuildContext context) {
    final f = _file;
    return SizedBox(
      width: widget.size,
      height: widget.size,
      child: f == null
          ? Icon(Icons.picture_as_pdf_rounded, color: LrColors.muted, size: widget.size * 0.62)
          : ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: Container(
                color: Colors.white,
                alignment: Alignment.topCenter,
                child: Image.file(f, fit: BoxFit.cover, alignment: Alignment.topCenter, width: widget.size, height: widget.size,
                    cacheWidth: (widget.size * 2).round()),
              ),
            ),
    );
  }
}
