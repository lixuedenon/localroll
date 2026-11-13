// apps/desktop/lib/ui/pdf_thumb.dart
import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import 'package:localroll_core/localroll_core.dart';
import 'package:pdfrx/pdfrx.dart';

import 'theme.dart';

/// The first page of a PDF as a small picture, made once and kept in the
/// library's picture cache (PNG). One PDF at a time, so a folder full of
/// scans never loads many documents at once.
class PdfThumbs {
  PdfThumbs._();

  static final Map<String, Future<File?>> _pending = {};

  /// Ticks each time a picture is made: tiles showing "making…" look again
  /// at once instead of waiting for their next turn.
  static final ValueNotifier<int> made = ValueNotifier(0);
  static final Queue<Completer<void>> _waiting = Queue();
  static bool _busy = false;

  /// Width of the stored picture, in pixels.
  static const int width = 240;

  /// A name that changes when the file changes (path, size, time).
  static String _key(String path, FileStat st) {
    var h = 0xcbf29ce484222325;
    // Path and size only: a file that has just arrived gets its date put
    // back to the phone's a moment later, which must not mean "a new file"
    // (that made a second picture and kept a tile waiting for it).
    for (final b in utf8.encode('$path|${st.size}|v2')) {
      h ^= b;
      h *= 0x100000001b3; // wraps at 64 bits
    }
    return 'pdf_${h.toRadixString(16).replaceAll('-', 'n')}';
  }

  /// lr_pdf.exe next to the app: draws the page in its own process.
  static String get _exe => '${File(Platform.resolvedExecutable).parent.path}${Platform.pathSeparator}lr_pdf.exe';

  static Future<File?> of(String path, String cacheDir) async {
    final FileStat st;
    try {
      st = await File(path).stat();
    } catch (e) {
      DiagLog.log('ui', 'pdf thumbnail: file not readable: $e');
      return null;
    }
    if (st.type != FileSystemEntityType.file || st.size == 0) {
      DiagLog.log('ui', 'pdf thumbnail: not there yet (${st.type}, ${st.size} bytes)');
      return null;
    }
    final base = '$cacheDir${Platform.pathSeparator}${_key(path, st)}';
    // Made before (older versions: PNG).
    final png = File('$base.png');
    if (await png.exists()) return png;
    final out = File('$base.bmp');
    if (await out.exists()) return out;
    return _pending.putIfAbsent(out.path, () => _make(path, out).whenComplete(() => _pending.remove(out.path)));
  }

  static Future<File?> _make(String path, File out) async {
    // One at a time.
    if (_busy) {
      final c = Completer<void>();
      _waiting.add(c);
      final waited = Stopwatch()..start();
      // Never wait for good on the others (one may be stuck).
      await c.future.timeout(const Duration(seconds: 60), onTimeout: () {
        DiagLog.log('ui', 'pdf thumbnail: the queue did not move for 60 s, going ahead');
        _waiting.remove(c);
      });
      if (waited.elapsedMilliseconds > 10000) DiagLog.log('ui', 'pdf thumbnail: waited ${waited.elapsedMilliseconds} ms for others');
    }
    _busy = true;
    final clock = Stopwatch()..start();
    try {
      // One PDF that never finishes must not hold up all the others.
      final f = await _draw(path, out).timeout(const Duration(seconds: 25));
      DiagLog.log('ui', f == null
          ? 'pdf thumbnail: nothing drawn (${clock.elapsedMilliseconds} ms, ${_size(path)})'
          : 'pdf thumbnail: made in ${clock.elapsedMilliseconds} ms (${_size(path)})');
      if (f != null) made.value++;
      return f;
    } on TimeoutException {
      DiagLog.log('ui', 'pdf thumbnail: gave up after 25 s (${_size(path)})');
      return null;
    } catch (e) {
      DiagLog.log('ui', 'pdf thumbnail failed: $e');
      return null;
    } finally {
      _busy = false;
      if (_waiting.isNotEmpty) _waiting.removeFirst().complete();
    }
  }

  static String _size(String path) {
    try {
      return '${(File(path).lengthSync() / 1024).round()} KB';
    } catch (_) {
      return 'gone';
    }
  }

  /// lr_pdf.exe draws it (a separate process: nothing in the app can be
  /// held up); without it, pdfrx here.
  static Future<File?> _draw(String path, File out) async {
    final exe = _exe;
    if (!File(exe).existsSync()) return _render(path, File('${out.path.substring(0, out.path.length - 4)}.png'));
    await out.parent.create(recursive: true);
    final p = await Process.start(exe, ['--thumb', path, out.path, '$width']);
    final said = p.stdout.transform(utf8.decoder).join();
    unawaited(p.stderr.drain<void>());
    final code = await p.exitCode.timeout(const Duration(seconds: 20), onTimeout: () {
      p.kill();
      return -1;
    });
    if (code == 0 && await out.exists() && await out.length() > 0) {
      // Kept as PNG (a fraction of the BMP's size; also what phones get).
      final png = File('${out.path.substring(0, out.path.length - 4)}.png');
      try {
        final pic = img.decodeBmp(await out.readAsBytes());
        if (pic != null) {
          await png.writeAsBytes(img.encodePng(pic), flush: true);
          await out.delete();
          return png;
        }
      } catch (e) {
        DiagLog.log('ui', 'pdf thumbnail: kept as BMP ($e)');
      }
      return out;
    }
    final why = code == -1 ? 'timed out' : (await said.timeout(const Duration(seconds: 1), onTimeout: () => '')).trim();
    DiagLog.log('ui', 'pdf thumbnail (lr_pdf): $why');
    // pdfium not usable there: try here.
    if (why.contains('pdfium')) return _render(path, File('${out.path.substring(0, out.path.length - 4)}.png'));
    return null;
  }

  static Future<File?> _render(String path, File out) async {
    PdfDocument? doc;
    try {
      doc = await PdfDocument.openFile(path);
      if (doc.pages.isEmpty) return null;
      final page = doc.pages.first;
      final w = width.toDouble();
      final h = (w * page.height / page.width).clamp(40.0, w * 2);
      final img = await page.render(width: w.round(), height: h.round(), fullWidth: w, fullHeight: h, backgroundColor: Colors.white);
      if (img == null) return null;
      final picture = await img.createImage();
      img.dispose();
      final png = await picture.toByteData(format: ui.ImageByteFormat.png);
      picture.dispose();
      if (png == null) return null;
      await out.parent.create(recursive: true);
      await out.writeAsBytes(png.buffer.asUint8List(), flush: true);
      return out;
    } finally {
      try {
        await doc?.dispose();
      } catch (_) {}
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
