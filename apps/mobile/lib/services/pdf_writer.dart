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

// ------------------------------------------------------------- forms

/// A field of a PDF form (one box): [kind] text / check / radio / choice;
/// its box in PDF points (the page's own space, y up).
class PdfFormField {
  PdfFormField({
    required this.page,
    required this.kind,
    required this.name,
    required this.label,
    required this.value,
    required this.checked,
    required this.options,
    required this.selected,
    required this.l,
    required this.b,
    required this.r,
    required this.t,
    this.multiline = false,
  });

  factory PdfFormField.fromMap(Map<Object?, Object?> m) => PdfFormField(
        page: (m['page'] as num?)?.toInt() ?? 0,
        kind: m['kind'] as String? ?? 'text',
        name: m['name'] as String? ?? '',
        label: m['label'] as String? ?? '',
        value: m['value'] as String? ?? '',
        checked: m['checked'] == true,
        options: [for (final o in (m['options'] as List?) ?? const []) '$o'],
        selected: (m['selected'] as num?)?.toInt() ?? -1,
        l: (m['l'] as num?)?.toDouble() ?? 0,
        b: (m['b'] as num?)?.toDouble() ?? 0,
        r: (m['r'] as num?)?.toDouble() ?? 0,
        t: (m['t'] as num?)?.toDouble() ?? 0,
        multiline: m['multiline'] == true,
      );

  final int page;
  final String kind, name, label, value;
  final bool checked, multiline;
  final List<String> options;
  final int selected;
  final double l, b, r, t;

  /// The name shown: the form's own label, else the last part of its name.
  String get shown {
    if (label.trim().isNotEmpty) return label.trim();
    return name.split('.').last.replaceAll(RegExp(r'\[\d+\]'), '').trim();
  }

  String get key => '$page|${l.toStringAsFixed(1)}|${b.toStringAsFixed(1)}|${r.toStringAsFixed(1)}|${t.toStringAsFixed(1)}';
}

/// Filling in a PDF's own form (its boxes, check boxes, choices): iPhone
/// with PDFKit, Android with pdfium. The result stays a form.
class PdfForms {
  PdfForms._();

  static const MethodChannel _ch = MethodChannel('localroll/pdfedit');

  /// The fields that can be filled in (empty: none).
  static Future<List<PdfFormField>> fields(String path) async {
    try {
      List<Object?> list;
      if (Platform.isIOS) {
        list = await _ch.invokeMethod<List<Object?>>('fields', {'path': path}) ?? const [];
      } else if (Platform.isAndroid) {
        list = await Isolate.run(() => _PdfiumForm.fields(path));
      } else {
        return const [];
      }
      return [for (final m in list) if (m is Map) PdfFormField.fromMap(m)];
    } catch (e) {
      DiagLog.log('pdf', 'form fields: $e');
      return const [];
    }
  }

  /// [path] with [values] (field → String for text, bool for a check box /
  /// radio button, int for a choice) written to [out]. True when done.
  static Future<bool> fill(String path, Map<PdfFormField, Object> values, String out) async {
    final list = [
      for (final e in values.entries)
        {
          'page': e.key.page,
          'l': e.key.l,
          'b': e.key.b,
          'r': e.key.r,
          't': e.key.t,
          'name': e.key.name,
          'kind': e.value is String ? 'text' : (e.value is bool ? 'check' : 'pick'),
          'value': e.value is String ? e.value : (e.value is bool ? ((e.value as bool) ? 1 : 0) : e.value),
        },
    ];
    try {
      if (Platform.isIOS) return await _ch.invokeMethod<bool>('fill', {'path': path, 'values': list, 'out': out}) ?? false;
      if (Platform.isAndroid) {
        final err = await Isolate.run(() => _PdfiumForm.fill(path, list, out));
        if (err != null) DiagLog.log('pdf', 'form fill: $err');
        return err == null;
      }
    } catch (e) {
      DiagLog.log('pdf', 'form fill failed: $e');
    }
    return false;
  }
}

final class _RectF extends Struct {
  @Float()
  external double left;
  @Float()
  external double top;
  @Float()
  external double right;
  @Float()
  external double bottom;
}

typedef _StrFn = int Function(Pointer<Void>, Pointer<Void>, Pointer<Uint16>, int);
typedef _StrNative = UnsignedLong Function(Pointer<Void>, Pointer<Void>, Pointer<Uint16>, UnsignedLong);

/// pdfium's form calls (Android).
class _PdfiumForm {
  _PdfiumForm(this.l)
      : init = l.lookupFunction<Void Function(), void Function()>('FPDF_InitLibrary'),
        loadDoc = l.lookupFunction<Pointer<Void> Function(Pointer<Utf8>, Pointer<Utf8>), Pointer<Void> Function(Pointer<Utf8>, Pointer<Utf8>)>(
            'FPDF_LoadDocument'),
        closeDoc = l.lookupFunction<Void Function(Pointer<Void>), void Function(Pointer<Void>)>('FPDF_CloseDocument'),
        pageCount = l.lookupFunction<Int32 Function(Pointer<Void>), int Function(Pointer<Void>)>('FPDF_GetPageCount'),
        loadPage = l.lookupFunction<Pointer<Void> Function(Pointer<Void>, Int32), Pointer<Void> Function(Pointer<Void>, int)>('FPDF_LoadPage'),
        closePage = l.lookupFunction<Void Function(Pointer<Void>), void Function(Pointer<Void>)>('FPDF_ClosePage'),
        initForm = l.lookupFunction<Pointer<Void> Function(Pointer<Void>, Pointer<Uint8>), Pointer<Void> Function(Pointer<Void>, Pointer<Uint8>)>(
            'FPDFDOC_InitFormFillEnvironment'),
        exitForm = l.lookupFunction<Void Function(Pointer<Void>), void Function(Pointer<Void>)>('FPDFDOC_ExitFormFillEnvironment'),
        afterLoad = l.lookupFunction<Void Function(Pointer<Void>, Pointer<Void>), void Function(Pointer<Void>, Pointer<Void>)>('FORM_OnAfterLoadPage'),
        beforeClose = l.lookupFunction<Void Function(Pointer<Void>, Pointer<Void>), void Function(Pointer<Void>, Pointer<Void>)>('FORM_OnBeforeClosePage'),
        annotCount = l.lookupFunction<Int32 Function(Pointer<Void>), int Function(Pointer<Void>)>('FPDFPage_GetAnnotCount'),
        getAnnot = l.lookupFunction<Pointer<Void> Function(Pointer<Void>, Int32), Pointer<Void> Function(Pointer<Void>, int)>('FPDFPage_GetAnnot'),
        closeAnnot = l.lookupFunction<Void Function(Pointer<Void>), void Function(Pointer<Void>)>('FPDFPage_CloseAnnot'),
        subtype = l.lookupFunction<Int32 Function(Pointer<Void>), int Function(Pointer<Void>)>('FPDFAnnot_GetSubtype'),
        rect = l.lookupFunction<Int32 Function(Pointer<Void>, Pointer<_RectF>), int Function(Pointer<Void>, Pointer<_RectF>)>('FPDFAnnot_GetRect'),
        fieldType = l.lookupFunction<Int32 Function(Pointer<Void>, Pointer<Void>), int Function(Pointer<Void>, Pointer<Void>)>('FPDFAnnot_GetFormFieldType'),
        fieldFlags = l.lookupFunction<Int32 Function(Pointer<Void>, Pointer<Void>), int Function(Pointer<Void>, Pointer<Void>)>('FPDFAnnot_GetFormFieldFlags'),
        isChecked = l.lookupFunction<Int32 Function(Pointer<Void>, Pointer<Void>), int Function(Pointer<Void>, Pointer<Void>)>('FPDFAnnot_IsChecked'),
        optionCount = l.lookupFunction<Int32 Function(Pointer<Void>, Pointer<Void>), int Function(Pointer<Void>, Pointer<Void>)>('FPDFAnnot_GetOptionCount'),
        optionLabel = l.lookupFunction<UnsignedLong Function(Pointer<Void>, Pointer<Void>, Int32, Pointer<Uint16>, UnsignedLong),
            int Function(Pointer<Void>, Pointer<Void>, int, Pointer<Uint16>, int)>('FPDFAnnot_GetOptionLabel'),
        optionSelected = l.lookupFunction<Int32 Function(Pointer<Void>, Pointer<Void>, Int32), int Function(Pointer<Void>, Pointer<Void>, int)>(
            'FPDFAnnot_IsOptionSelected'),
        fieldName = l.lookupFunction<_StrNative, _StrFn>('FPDFAnnot_GetFormFieldName'),
        fieldValue = l.lookupFunction<_StrNative, _StrFn>('FPDFAnnot_GetFormFieldValue'),
        focus = l.lookupFunction<Int32 Function(Pointer<Void>, Pointer<Void>), int Function(Pointer<Void>, Pointer<Void>)>('FORM_SetFocusedAnnot'),
        selectAll = l.lookupFunction<Int32 Function(Pointer<Void>, Pointer<Void>), int Function(Pointer<Void>, Pointer<Void>)>('FORM_SelectAllText'),
        replace = l.lookupFunction<Void Function(Pointer<Void>, Pointer<Void>, Pointer<Uint16>), void Function(Pointer<Void>, Pointer<Void>, Pointer<Uint16>)>(
            'FORM_ReplaceSelection'),
        killFocus = l.lookupFunction<Int32 Function(Pointer<Void>), int Function(Pointer<Void>)>('FORM_ForceToKillFocus'),
        setIndex = l.lookupFunction<Int32 Function(Pointer<Void>, Pointer<Void>, Int32, Int32), int Function(Pointer<Void>, Pointer<Void>, int, int)>(
            'FORM_SetIndexSelected'),
        down = l.lookupFunction<Int32 Function(Pointer<Void>, Pointer<Void>, Int32, Double, Double), int Function(Pointer<Void>, Pointer<Void>, int, double, double)>(
            'FORM_OnLButtonDown'),
        up = l.lookupFunction<Int32 Function(Pointer<Void>, Pointer<Void>, Int32, Double, Double), int Function(Pointer<Void>, Pointer<Void>, int, double, double)>(
            'FORM_OnLButtonUp'),
        save = l.lookupFunction<Int32 Function(Pointer<Void>, Pointer<_FileWrite>, Uint32), int Function(Pointer<Void>, Pointer<_FileWrite>, int)>(
            'FPDF_SaveAsCopy');

  final DynamicLibrary l;
  final void Function() init;
  final Pointer<Void> Function(Pointer<Utf8>, Pointer<Utf8>) loadDoc;
  final void Function(Pointer<Void>) closeDoc;
  final int Function(Pointer<Void>) pageCount;
  final Pointer<Void> Function(Pointer<Void>, int) loadPage;
  final void Function(Pointer<Void>) closePage;
  final Pointer<Void> Function(Pointer<Void>, Pointer<Uint8>) initForm;
  final void Function(Pointer<Void>) exitForm;
  final void Function(Pointer<Void>, Pointer<Void>) afterLoad, beforeClose;
  final int Function(Pointer<Void>) annotCount;
  final Pointer<Void> Function(Pointer<Void>, int) getAnnot;
  final void Function(Pointer<Void>) closeAnnot;
  final int Function(Pointer<Void>) subtype;
  final int Function(Pointer<Void>, Pointer<_RectF>) rect;
  final int Function(Pointer<Void>, Pointer<Void>) fieldType, fieldFlags, isChecked, optionCount, focus, selectAll;
  final int Function(Pointer<Void>, Pointer<Void>, int, Pointer<Uint16>, int) optionLabel;
  final int Function(Pointer<Void>, Pointer<Void>, int) optionSelected;
  final _StrFn fieldName, fieldValue;
  final void Function(Pointer<Void>, Pointer<Void>, Pointer<Uint16>) replace;
  final int Function(Pointer<Void>) killFocus;
  final int Function(Pointer<Void>, Pointer<Void>, int, int) setIndex;
  final int Function(Pointer<Void>, Pointer<Void>, int, double, double) down, up;
  final int Function(Pointer<Void>, Pointer<_FileWrite>, int) save;

  /// The form's own label (/TU), when this pdfium has the call.
  late final _StrFn? altName = () {
    try {
      return l.lookupFunction<_StrNative, _StrFn>('FPDFAnnot_GetFormFieldAlternateName');
    } catch (_) {
      return null;
    }
  }();

  static String _read(_StrFn? fn, Pointer<Void> h, Pointer<Void> a) {
    if (fn == null) return '';
    final n = fn(h, a, nullptr, 0);
    if (n <= 2 || n > 200000) return '';
    final buf = calloc<Uint16>(n ~/ 2 + 1);
    try {
      fn(h, a, buf, n);
      return String.fromCharCodes(buf.asTypedList(n ~/ 2 - 1));
    } finally {
      calloc.free(buf);
    }
  }

  /// A document and its form, or null.
  (Pointer<Void>, Pointer<Void>, Pointer<Uint8>)? _open(String path) {
    init();
    final p = path.toNativeUtf8();
    final doc = loadDoc(p, nullptr);
    calloc.free(p);
    if (doc == nullptr) return null;
    final info = calloc<Uint8>(1024);
    info.cast<Int32>().value = 1;
    final form = initForm(doc, info);
    if (form == nullptr) {
      calloc.free(info);
      closeDoc(doc);
      return null;
    }
    return (doc, form, info);
  }

  static List<Map<String, Object?>> fields(String path) {
    final f = _PdfiumForm(DynamicLibrary.open('libpdfium.so'));
    final o = f._open(path);
    if (o == null) return const [];
    final (doc, form, info) = o;
    final out = <Map<String, Object?>>[];
    final rc = calloc<_RectF>();
    try {
      final n = f.pageCount(doc);
      for (var pi = 0; pi < n; pi++) {
        final pg = f.loadPage(doc, pi);
        if (pg == nullptr) continue;
        f.afterLoad(pg, form);
        final c = f.annotCount(pg);
        for (var ai = 0; ai < c; ai++) {
          final a = f.getAnnot(pg, ai);
          if (a == nullptr) continue;
          if (f.subtype(a) == 20 && f.rect(a, rc) != 0) {
            final type = f.fieldType(form, a);
            final flags = f.fieldFlags(form, a);
            final kind = switch (type) { 2 => 'check', 3 => 'radio', 4 || 5 => 'choice', 6 => 'text', _ => null };
            if (kind != null && flags & 1 == 0) {
              final opts = <String>[];
              var sel = -1;
              final oc = f.optionCount(form, a);
              for (var k = 0; k < oc && k < 500; k++) {
                final len = f.optionLabel(form, a, k, nullptr, 0);
                var label = '';
                if (len > 2 && len < 20000) {
                  final buf = calloc<Uint16>(len ~/ 2 + 1);
                  f.optionLabel(form, a, k, buf, len);
                  label = String.fromCharCodes(buf.asTypedList(len ~/ 2 - 1));
                  calloc.free(buf);
                }
                opts.add(label);
                if (sel < 0 && f.optionSelected(form, a, k) != 0) sel = k;
              }
              out.add({
                'page': pi,
                'kind': kind,
                'name': _read(f.fieldName, form, a),
                'label': _read(f.altName, form, a),
                'value': _read(f.fieldValue, form, a),
                'checked': f.isChecked(form, a) != 0,
                'options': opts,
                'selected': sel,
                'multiline': type == 6 && flags & (1 << 12) != 0,
                'l': rc.ref.left,
                'b': rc.ref.bottom,
                'r': rc.ref.right,
                't': rc.ref.top,
              });
            }
          }
          f.closeAnnot(a);
        }
        f.beforeClose(pg, form);
        f.closePage(pg);
      }
    } finally {
      calloc.free(rc);
      f.exitForm(form);
      calloc.free(info);
      f.closeDoc(doc);
    }
    return out;
  }

  static String? fill(String path, List<Map<String, Object?>> values, String out) {
    final f = _PdfiumForm(DynamicLibrary.open('libpdfium.so'));
    final o = f._open(path);
    if (o == null) return 'cannot open';
    final (doc, form, info) = o;
    final rc = calloc<_RectF>();
    try {
      final byPage = <int, List<Map<String, Object?>>>{};
      for (final v in values) {
        (byPage[(v['page'] as num).toInt()] ??= []).add(v);
      }
      for (final e in byPage.entries) {
        if (e.key < 0 || e.key >= f.pageCount(doc)) continue;
        final pg = f.loadPage(doc, e.key);
        if (pg == nullptr) continue;
        f.afterLoad(pg, form);
        for (final v in e.value) {
          // The widget with this box.
          Pointer<Void> a = nullptr;
          final c = f.annotCount(pg);
          for (var k = 0; k < c && a == nullptr; k++) {
            final x = f.getAnnot(pg, k);
            if (x == nullptr) continue;
            if (f.subtype(x) == 20 &&
                f.rect(x, rc) != 0 &&
                (rc.ref.left - (v['l'] as num)).abs() < 0.6 &&
                (rc.ref.bottom - (v['b'] as num)).abs() < 0.6 &&
                (rc.ref.right - (v['r'] as num)).abs() < 0.6 &&
                (rc.ref.top - (v['t'] as num)).abs() < 0.6) {
              a = x;
            } else {
              f.closeAnnot(x);
            }
          }
          if (a == nullptr) continue;
          switch (v['kind']) {
            case 'text':
              final s = '${v['value']}';
              final w = calloc<Uint16>(s.length + 1);
              w.asTypedList(s.length + 1)
                ..setAll(0, s.codeUnits)
                ..[s.length] = 0;
              if (f.focus(form, a) != 0) {
                f.selectAll(form, pg);
                f.replace(form, pg, w);
                f.killFocus(form);
              }
              calloc.free(w);
            case 'check':
              final want = v['value'] == 1;
              if (want != (f.isChecked(form, a) != 0) && f.rect(a, rc) != 0) {
                final x = (rc.ref.left + rc.ref.right) / 2, y = (rc.ref.top + rc.ref.bottom) / 2;
                f.down(form, pg, 0, x, y);
                f.up(form, pg, 0, x, y);
                f.killFocus(form);
              }
            case 'pick':
              if (f.focus(form, a) != 0) {
                f.setIndex(form, pg, (v['value'] as num).toInt(), 1);
                f.killFocus(form);
              }
          }
          f.closeAnnot(a);
        }
        f.killFocus(form);
        f.beforeClose(pg, form);
        f.closePage(pg);
      }
      f.exitForm(form);
      final tmp = '$out.part';
      _sink = File(tmp).openSync(mode: FileMode.write);
      final fw = calloc<_FileWrite>();
      fw.ref.version = 1;
      fw.ref.writeBlock = Pointer.fromFunction<Int32 Function(Pointer<_FileWrite>, Pointer<Void>, UnsignedLong)>(_writeBlock, 0);
      final saved = f.save(doc, fw, 0);
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
      calloc.free(rc);
      calloc.free(info);
      f.closeDoc(doc);
    }
  }
}
