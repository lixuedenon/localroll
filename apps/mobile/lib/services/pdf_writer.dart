// apps/mobile/lib/services/pdf_writer.dart
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';
import 'package:flutter/services.dart';
import 'package:localroll_core/localroll_core.dart';

/// A page of the PDF being made: page [index] (0-based) of [src], turned
/// [turn] × 90° clockwise more, with [stamp] (a see-through picture of
/// what was drawn / placed, covering the page as shown before the turn).
class PdfOutPage {
  PdfOutPage(this.src, this.index, {this.turn = 0, this.stamp});

  final String src;
  final int index;
  final int turn;
  final PdfStampFile? stamp;

  Map<String, Object?> toMap() => {
        'src': src,
        'index': index,
        'turn': turn % 4,
        if (stamp != null) 'png': stamp!.png,
        if (stamp != null) 'bgra': stamp!.bgra,
        if (stamp != null) 'w': stamp!.width,
        if (stamp != null) 'h': stamp!.height,
      };
}

/// A stamp as files: a PNG (iPhone) and raw blue-green-red-alpha rows
/// (Android's pdfium).
class PdfStampFile {
  const PdfStampFile({required this.png, required this.bgra, required this.width, required this.height});
  final String png, bgra;
  final int width, height;
}

/// Writes a new PDF from pages of others, keeping them as they are (text
/// stays text): iPhone with the system's PDFKit, Android with pdfium.
/// Page by page, without taking whole files into memory.
class PdfWriter {
  PdfWriter._();

  static const MethodChannel _ch = MethodChannel('localroll/pdfedit');

  /// True when [out] was written.
  static Future<bool> write(List<PdfOutPage> pages, String out) async {
    final list = [for (final p in pages) p.toMap()];
    try {
      if (Platform.isIOS) {
        return await _ch.invokeMethod<bool>('write', {'pages': list, 'out': out}) ?? false;
      }
      if (Platform.isAndroid) {
        final err = await Isolate.run(() => _Pdfium.write(list, out));
        if (err != null) DiagLog.log('pdf', 'pdfium write: $err');
        return err == null;
      }
    } catch (e) {
      DiagLog.log('pdf', 'pdf write failed: $e');
    }
    return false;
  }
}

// ------------------------------------------------------------ pdfium

final class _FileWrite extends Struct {
  @Int32()
  external int version;
  external Pointer<NativeFunction<Int32 Function(Pointer<_FileWrite>, Pointer<Void>, UnsignedLong)>> writeBlock;
}

RandomAccessFile? _sink;

int _writeBlock(Pointer<_FileWrite> self, Pointer<Void> data, int size) {
  try {
    _sink!.writeFromSync(data.cast<Uint8>().asTypedList(size));
    return 1;
  } catch (_) {
    return 0;
  }
}

/// The few pdfium calls needed (libpdfium.so, bundled for arm64).
class _Pdfium {
  _Pdfium(DynamicLibrary l)
      : init = l.lookupFunction<Void Function(), void Function()>('FPDF_InitLibrary'),
        loadDoc = l.lookupFunction<Pointer<Void> Function(Pointer<Utf8>, Pointer<Utf8>), Pointer<Void> Function(Pointer<Utf8>, Pointer<Utf8>)>(
            'FPDF_LoadDocument'),
        newDoc = l.lookupFunction<Pointer<Void> Function(), Pointer<Void> Function()>('FPDF_CreateNewDocument'),
        closeDoc = l.lookupFunction<Void Function(Pointer<Void>), void Function(Pointer<Void>)>('FPDF_CloseDocument'),
        pageCount = l.lookupFunction<Int32 Function(Pointer<Void>), int Function(Pointer<Void>)>('FPDF_GetPageCount'),
        importPages = l.lookupFunction<Int32 Function(Pointer<Void>, Pointer<Void>, Pointer<Utf8>, Int32),
            int Function(Pointer<Void>, Pointer<Void>, Pointer<Utf8>, int)>('FPDF_ImportPages'),
        loadPage = l.lookupFunction<Pointer<Void> Function(Pointer<Void>, Int32), Pointer<Void> Function(Pointer<Void>, int)>('FPDF_LoadPage'),
        closePage = l.lookupFunction<Void Function(Pointer<Void>), void Function(Pointer<Void>)>('FPDF_ClosePage'),
        getRotation = l.lookupFunction<Int32 Function(Pointer<Void>), int Function(Pointer<Void>)>('FPDFPage_GetRotation'),
        setRotation = l.lookupFunction<Void Function(Pointer<Void>, Int32), void Function(Pointer<Void>, int)>('FPDFPage_SetRotation'),
        width = l.lookupFunction<Double Function(Pointer<Void>), double Function(Pointer<Void>)>('FPDF_GetPageWidth'),
        height = l.lookupFunction<Double Function(Pointer<Void>), double Function(Pointer<Void>)>('FPDF_GetPageHeight'),
        cropBox = l.lookupFunction<Int32 Function(Pointer<Void>, Pointer<Float>, Pointer<Float>, Pointer<Float>, Pointer<Float>),
            int Function(Pointer<Void>, Pointer<Float>, Pointer<Float>, Pointer<Float>, Pointer<Float>)>('FPDFPage_GetCropBox'),
        mediaBox = l.lookupFunction<Int32 Function(Pointer<Void>, Pointer<Float>, Pointer<Float>, Pointer<Float>, Pointer<Float>),
            int Function(Pointer<Void>, Pointer<Float>, Pointer<Float>, Pointer<Float>, Pointer<Float>)>('FPDFPage_GetMediaBox'),
        newImage = l.lookupFunction<Pointer<Void> Function(Pointer<Void>), Pointer<Void> Function(Pointer<Void>)>('FPDFPageObj_NewImageObj'),
        bitmap = l.lookupFunction<Pointer<Void> Function(Int32, Int32, Int32, Pointer<Void>, Int32), Pointer<Void> Function(int, int, int, Pointer<Void>, int)>(
            'FPDFBitmap_CreateEx'),
        bitmapDestroy = l.lookupFunction<Void Function(Pointer<Void>), void Function(Pointer<Void>)>('FPDFBitmap_Destroy'),
        setBitmap = l.lookupFunction<Int32 Function(Pointer<Pointer<Void>>, Int32, Pointer<Void>, Pointer<Void>),
            int Function(Pointer<Pointer<Void>>, int, Pointer<Void>, Pointer<Void>)>('FPDFImageObj_SetBitmap'),
        setMatrix = l.lookupFunction<Int32 Function(Pointer<Void>, Double, Double, Double, Double, Double, Double),
            int Function(Pointer<Void>, double, double, double, double, double, double)>('FPDFImageObj_SetMatrix'),
        insert = l.lookupFunction<Void Function(Pointer<Void>, Pointer<Void>), void Function(Pointer<Void>, Pointer<Void>)>('FPDFPage_InsertObject'),
        generate = l.lookupFunction<Int32 Function(Pointer<Void>), int Function(Pointer<Void>)>('FPDFPage_GenerateContent'),
        save = l.lookupFunction<Int32 Function(Pointer<Void>, Pointer<_FileWrite>, Uint32), int Function(Pointer<Void>, Pointer<_FileWrite>, int)>(
            'FPDF_SaveAsCopy');

  final void Function() init;
  final Pointer<Void> Function(Pointer<Utf8>, Pointer<Utf8>) loadDoc;
  final Pointer<Void> Function() newDoc;
  final void Function(Pointer<Void>) closeDoc;
  final int Function(Pointer<Void>) pageCount;
  final int Function(Pointer<Void>, Pointer<Void>, Pointer<Utf8>, int) importPages;
  final Pointer<Void> Function(Pointer<Void>, int) loadPage;
  final void Function(Pointer<Void>) closePage;
  final int Function(Pointer<Void>) getRotation;
  final void Function(Pointer<Void>, int) setRotation;
  final double Function(Pointer<Void>) width, height;
  final int Function(Pointer<Void>, Pointer<Float>, Pointer<Float>, Pointer<Float>, Pointer<Float>) cropBox, mediaBox;
  final Pointer<Void> Function(Pointer<Void>) newImage;
  final Pointer<Void> Function(int, int, int, Pointer<Void>, int) bitmap;
  final void Function(Pointer<Void>) bitmapDestroy;
  final int Function(Pointer<Pointer<Void>>, int, Pointer<Void>, Pointer<Void>) setBitmap;
  final int Function(Pointer<Void>, double, double, double, double, double, double) setMatrix;
  final void Function(Pointer<Void>, Pointer<Void>) insert;
  final int Function(Pointer<Void>) generate;
  final int Function(Pointer<Void>, Pointer<_FileWrite>, int) save;

  /// Shown x, y (y down, page as shown) → the page's own space.
  static (double, double) _toPage(int rot, double w, double h, double x, double y) => switch (rot & 3) {
        1 => (y, x),
        2 => (w - x, y),
        3 => (w - y, h - x),
        _ => (x, h - y),
      };

  /// Null when [out] was written, else why not. Runs in its own isolate.
  static String? write(List<Map<String, Object?>> pages, String out) {
    final _Pdfium p;
    try {
      p = _Pdfium(DynamicLibrary.open('libpdfium.so'));
    } catch (e) {
      return 'pdfium: $e';
    }
    p.init();
    final docs = <String, Pointer<Void>>{};
    final keep = <Pointer<Uint8>>[];
    final doc = p.newDoc();
    var made = 0;
    try {
      for (final pg in pages) {
        final src = pg['src'] as String;
        var d = docs[src];
        if (d == null) {
          final path = src.toNativeUtf8();
          d = p.loadDoc(path, nullptr);
          calloc.free(path);
          if (d == nullptr) return 'cannot open $src';
          docs[src] = d;
        }
        final index = pg['index'] as int;
        if (index < 0 || index >= p.pageCount(d)) continue;
        final range = '${index + 1}'.toNativeUtf8();
        final ok = p.importPages(doc, d, range, made);
        calloc.free(range);
        if (ok == 0) return 'cannot take page';
        final page = p.loadPage(doc, made);
        made++;
        if (page == nullptr) continue;
        final rot = p.getRotation(page) & 3;
        final dw = p.width(page), dh = p.height(page);
        final w = rot.isOdd ? dh : dw, h = rot.isOdd ? dw : dh;
        var x0 = 0.0, y0 = 0.0;
        final box = calloc<Float>(4);
        if (p.cropBox(page, box, box + 1, box + 2, box + 3) != 0 || p.mediaBox(page, box, box + 1, box + 2, box + 3) != 0) {
          x0 = box[0];
          y0 = box[1];
        }
        calloc.free(box);
        final turn = (pg['turn'] as int? ?? 0) & 3;
        if (turn != 0) p.setRotation(page, (rot + turn) & 3);
        final bgra = pg['bgra'] as String?;
        final pw = pg['w'] as int? ?? 0, ph = pg['h'] as int? ?? 0;
        if (bgra != null && pw > 0 && ph > 0) {
          final bytes = File(bgra).readAsBytesSync();
          if (bytes.length >= pw * ph * 4) {
            final buf = calloc<Uint8>(bytes.length);
            buf.asTypedList(bytes.length).setAll(0, bytes);
            keep.add(buf);
            // The whole page as shown (before the turn); u, v: the
            // picture's own space (from its bottom left, v up).
            final sw = rot.isOdd ? h : w, sh = rot.isOdd ? w : h;
            (double, double) at(double u, double v) {
              final (ox, oy) = _toPage(rot, w, h, u * sw, (1 - v) * sh);
              return (ox + x0, oy + y0);
            }

            final (x00, y00) = at(0, 0);
            final (x10, y10) = at(1, 0);
            final (x01, y01) = at(0, 1);
            final bmp = p.bitmap(pw, ph, 4, buf.cast<Void>(), pw * 4);
            final img = p.newImage(doc);
            if (bmp != nullptr && img != nullptr) {
              final arr = calloc<Pointer<Void>>(1)..value = page;
              if (p.setBitmap(arr, 1, img, bmp) != 0) {
                p.setMatrix(img, x10 - x00, y10 - y00, x01 - x00, y01 - y00, x00, y00);
                p.insert(page, img);
              }
              calloc.free(arr);
            }
            if (bmp != nullptr) p.bitmapDestroy(bmp);
          }
          p.generate(page);
        }
        p.closePage(page);
      }
      if (made == 0) return 'no pages';
      final tmp = '$out.part';
      _sink = File(tmp).openSync(mode: FileMode.write);
      final fw = calloc<_FileWrite>();
      fw.ref.version = 1;
      fw.ref.writeBlock = Pointer.fromFunction<Int32 Function(Pointer<_FileWrite>, Pointer<Void>, UnsignedLong)>(_writeBlock, 0);
      final saved = p.save(doc, fw, 0);
      calloc.free(fw);
      _sink!.closeSync();
      _sink = null;
      if (saved == 0) {
        File(tmp).deleteSync();
        return 'not saved';
      }
      File(tmp).renameSync(out);
      return null;
    } catch (e) {
      return '$e';
    } finally {
      p.closeDoc(doc);
      for (final d in docs.values) {
        p.closeDoc(d);
      }
      for (final b in keep) {
        calloc.free(b);
      }
    }
  }
}
