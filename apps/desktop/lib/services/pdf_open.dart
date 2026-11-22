// apps/desktop/lib/services/pdf_open.dart
import 'dart:io';

import 'package:localroll_core/localroll_core.dart' show DiagLog;
import 'package:pdfrx/pdfrx.dart';

/// A PDF opened from its bytes: the file itself isn't held while it is
/// shown, so it can be replaced (saved over), moved or deleted meanwhile.
Future<PdfDocument> openPdfLoose(String path) async {
  final data = await File(path).readAsBytes();
  return PdfDocument.openData(data, sourceName: '$path#${DateTime.now().microsecondsSinceEpoch}');
}

/// [made] put in place of [target]. Held a moment by something else (a
/// thumbnail being made): tried again for about 2 s. True when done; when
/// not, [made] is left where it is.
Future<bool> replaceFileWith(String made, String target) async {
  Object? why;
  for (var i = 0; i < 8; i++) {
    try {
      await File(made).rename(target);
      return true;
    } catch (e) {
      why = e;
    }
    try {
      await File(made).copy(target);
      try {
        await File(made).delete();
      } catch (_) {}
      return true;
    } catch (e) {
      why = e;
    }
    await Future<void>.delayed(const Duration(milliseconds: 250));
  }
  DiagLog.log('tools', 'file not replaced (held by another program?): $why');
  return false;
}
