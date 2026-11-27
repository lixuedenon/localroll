// apps/desktop/lib/ui/tools/convert_run.dart
import 'dart:io';

import 'package:localroll_core/localroll_core.dart' show DiagLog;

import '../../app_services.dart';
import '../../l10n/l10n.dart';
import '../../services/file_tools.dart';
import '../../services/format_convert.dart';
import '../send_page.dart' show baseNameOf;
import '../theme.dart' show lrFontFallback;
import 'office_edit.dart';
import 'tools.dart';

/// The conversions that are not the picture / video / sound queue (PDF,
/// Office, text, photos → PDF): [files] made into [op]'s kind; what was
/// made goes in [outs], what failed (names) in [failed]. Used by the
/// format converter and by a phone controlling this PC.
Future<void> convertFiles(AppServices s, ConvOp op, List<String> files, List<String> outs, List<String> failed, {bool Function()? stop}) async {
  if (op is ImagesToPdf) {
    final out = toolOutPath(s, files.first, files.length > 1 ? '-${files.length}' : '', 'pdf');
    final err = await photosToPdf(s, files, out);
    err == null ? outs.add(out) : failed.add(baseNameOf(files.first));
    return;
  }
  for (final f in files) {
    try {
      switch (op) {
        case PdfToImages(:final ext):
          outs.addAll(await FormatConverter.pdfImages(s, f, ext));
        case PdfToWord():
          final out = toolOutPath(s, f, '', 'docx');
          final err = await pdfToWord(f, out, stop: stop);
          err == null && File(out).existsSync() ? outs.add(out) : failed.add(baseNameOf(f));
        case PdfToText():
          final out = toolOutPath(s, f, '', 'txt');
          await FormatConverter.pdfText(s, f, out);
          outs.add(out);
        case TextToPdf():
          final out = toolOutPath(s, f, '', 'pdf');
          final err = await FormatConverter.textPdf(f, out, lrFontFallback(translator.language));
          err == null ? outs.add(out) : failed.add(baseNameOf(f));
        case OfficeOp(:final kind, :final ext):
          if (kind == 'pptImages') {
            final made = await FormatConverter.pptImages(s, f, ext);
            made.isEmpty ? failed.add(baseNameOf(f)) : outs.addAll(made);
          } else {
            final out = toolOutPath(s, f, '', ext);
            final err = await FormatConverter.office(kind, f, out);
            err == null ? outs.add(out) : failed.add(baseNameOf(f));
          }
        default:
          break;
      }
    } catch (e) {
      DiagLog.log('tools', 'convert $f: $e');
      failed.add(baseNameOf(f));
    }
  }
}
