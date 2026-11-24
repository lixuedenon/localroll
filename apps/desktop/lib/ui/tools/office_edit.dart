// apps/desktop/lib/ui/tools/office_edit.dart
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:localroll_core/localroll_core.dart' show DiagLog;

import '../../app_services.dart';
import '../../l10n/l10n.dart';
import '../../services/bg_tasks.dart';
import '../../services/doc_editors.dart';
import '../../services/office_engines.dart';
import '../../services/pdf_docx.dart';
import '../../services/tool_outputs.dart';
import '../app_nav.dart';
import '../lr_dialog.dart';
import 'tools.dart';

/// "Edit in Word / WPS / LibreOffice": the PDF made into a Word file (by
/// Word itself when there is Word, else by Keepnear), opened in that
/// program; once it is saved and closed, "Back to PDF?". Waiting is a
/// background task: the app stays usable.
Future<void> editPdfInOffice(BuildContext context, AppServices s, String pdf) async {
  final have = await OfficeEngines.installed();
  if (!context.mounted) return;
  if (have.isEmpty) {
    await showLrDialog<void>(
      context: context,
      builder: (c) => AlertDialog(
        icon: const Icon(Icons.info_outline_rounded, size: 30),
        title: Text(tr('pdfword.none_title')),
        content: SizedBox(width: 460, child: Text(tr('pdfword.none_body'))),
        actions: [
          TextButton(
            onPressed: () => unawaited(Process.run('explorer.exe', ['https://www.libreoffice.org/download/download/'])),
            child: Text(tr('pdfword.get_libre')),
          ),
          FilledButton(onPressed: () => Navigator.pop(c), child: Text(tr('common.ok'))),
        ],
      ),
    );
    return;
  }
  final word = have.contains(OfficeApp.office);
  final docx = toolOutPath(s, pdf, '', 'docx');
  // A background task that can be stopped (Word / Keepnear's own).
  final err = await BgTasks.instance.run<String?>(
    title: tr('pdfword.making'),
    job: (t) async {
      var stop = false;
      t.cancellable(() {
        stop = true;
        unawaited(OfficeEngines.cancel());
      });
      // Word's own reading of a PDF is the best; without Word, Keepnear's.
      if (word) {
        final e = await OfficeEngines.run('wordDocx', pdf, docx);
        if (e == null || stop) return stop ? 'cancelled' : null;
        DiagLog.log('tools', 'pdf → docx by Word failed ($e), Keepnear makes it');
      }
      return PdfToDocx.make(pdf, docx, stop: () => stop);
    },
    ok: (e) => e == null,
  );
  if (!context.mounted || err == 'cancelled') {
    try {
      if (File(docx).existsSync()) File(docx).deleteSync();
    } catch (_) {}
    return;
  }
  if (err != null || !File(docx).existsSync()) {
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(tr('tool.failed', {'why': err ?? '?'}))));
    return;
  }
  await s.tools.saved([docx]);
  final before = File(docx).lastModifiedSync();
  // Word (if activated) → WPS → ONLYOFFICE → LibreOffice → …: the first
  // that can edit, nothing asked.
  final by = await DocEditors.open(docx);
  DiagLog.log('tools', 'pdf → docx (${word ? 'Word' : 'Keepnear'}), editing in ${by ?? 'nothing'}');
  if (by == null) {
    try {
      await Process.start('cmd', ['/c', 'start', '', docx], mode: ProcessStartMode.detached);
    } catch (_) {}
  }
  unawaited(_waitAndAsk(s, pdf, docx, before));
}

/// Open in a program, by the lock file it leaves beside it (Word / WPS:
/// "~\$…", LibreOffice / OpenOffice: ".~lock.<name>#"). The file itself is
/// not touched (that could make the program open it read-only).
bool _inUse(String path) {
  final dir = File(path).parent.path;
  final name = path.split(Platform.pathSeparator).last;
  final sep = Platform.pathSeparator;
  if (File('$dir$sep.~lock.$name#').existsSync()) return true;
  if (name.length > 2 && File('$dir$sep~\$${name.substring(2)}').existsSync()) return true;
  if (File('$dir$sep~\$$name').existsSync()) return true;
  return false;
}

Future<void> _waitAndAsk(AppServices s, String pdf, String docx, DateTime before) async {
  final name = docx.split(Platform.pathSeparator).last;
  var stop = false;
  final saved = await BgTasks.instance.run<bool>(
    title: tr('pdfword.waiting', {'name': name}),
    job: (t) async {
      t.cancellable(() => stop = true);
      var seenOpen = false;
      final until = DateTime.now().add(const Duration(hours: 12));
      while (!stop && DateTime.now().isBefore(until)) {
        await Future<void>.delayed(const Duration(seconds: 2));
        if (!File(docx).existsSync()) return false;
        final open = _inUse(docx);
        if (open) {
          seenOpen = true;
          continue;
        }
        final changed = File(docx).lastModifiedSync().isAfter(before);
        // Saved and closed: done. Closed without saving: nothing to do.
        // A program that leaves no lock file: saved and quiet for a while.
        if (changed && seenOpen) return true;
        if (changed && DateTime.now().difference(File(docx).lastModifiedSync()) > const Duration(seconds: 20)) return true;
        if (seenOpen && !changed) return false;
      }
      return false;
    },
    ok: (_) => true,
  );
  if (saved != true) return;
  final ctx = AppNav.instance.navigatorKey.currentContext;
  if (ctx == null || !ctx.mounted) return;
  final back = await showLrDialog<bool>(
    context: ctx,
    builder: (c) => AlertDialog(
      icon: const Icon(Icons.picture_as_pdf_outlined, size: 30),
      title: Text(tr('pdfword.back_title')),
      content: SizedBox(width: 440, child: Text(tr('pdfword.back_body', {'name': name}))),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c, false), child: Text(tr('pdfword.not_now'))),
        FilledButton(onPressed: () => Navigator.pop(c, true), child: Text(tr('pdfword.back'))),
      ],
    ),
  );
  if (back != true) return;
  final ctx2 = AppNav.instance.navigatorKey.currentContext;
  if (ctx2 == null || !ctx2.mounted) return;
  // A new PDF beside the old one: the original stays as it was.
  final out = toolOutPath(s, pdf, tr('pdfword.suffix'), 'pdf');
  final err = await BgTasks.instance.run<String?>(
    title: tr('pdfword.making_pdf'),
    job: (t) {
      t.cancellable(() => unawaited(OfficeEngines.cancel()));
      return OfficeEngines.run('pdf', docx, out);
    },
    ok: (e) => e == null,
  );
  if (err == 'cancelled') return;
  final ctx3 = AppNav.instance.navigatorKey.currentContext;
  if (ctx3 == null || !ctx3.mounted) return;
  if (err != null || !File(out).existsSync()) {
    ScaffoldMessenger.maybeOf(ctx3)?.showSnackBar(SnackBar(content: Text(tr('tool.failed', {'why': err ?? '?'}))));
    return;
  }
  await showToolResult(ctx3, s, [out]);
}
