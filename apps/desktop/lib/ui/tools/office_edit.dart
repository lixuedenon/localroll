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

/// PDF → Word for editing: Word (activated or not, as long as it can) or
/// the one chosen in the format converter; when that can't, Keepnear's own.
/// [stop]: cancelled. Null when done, else why not.
Future<String?> pdfToWord(String pdf, String out, {bool Function()? stop}) async {
  final pick = OfficeEngines.preferred;
  final have = await OfficeEngines.installed();
  final app = pick == 'keepnear'
      ? null
      : (OfficeApp.values.where((a) => a.name == pick && have.contains(a)).firstOrNull ?? (have.contains(OfficeApp.office) ? OfficeApp.office : null));
  if (app != null) {
    final e = await OfficeEngines.runOnly(app, 'wordDocx', pdf, out);
    if (stop?.call() ?? false) return 'cancelled';
    if (e == null) {
      DiagLog.log('tools', 'pdf → docx by ${app.label}');
      return null;
    }
    DiagLog.log('tools', 'pdf → docx by ${app.label} failed ($e): Keepnear makes it');
  }
  final e = await PdfToDocx.make(pdf, out, stop: stop);
  if (e == null) DiagLog.log('tools', 'pdf → docx by Keepnear');
  return e;
}

/// After PDF → Word: "Edit it now?" → opened in the first program that can
/// edit (activated Word → WPS → ONLYOFFICE → LibreOffice → …) → once it is
/// saved and closed, "Back to PDF?". Waiting is a still card (no moving
/// bar), and it ends by itself if the file never shows up in a window.
Future<void> offerEdit(BuildContext context, AppServices s, String docx, {required String pdf}) async {
  final name = docx.split(Platform.pathSeparator).last;
  final all = await DocEditors.found();
  final can = await DocEditors.usable();
  final wordOff = all.any((e) => e.word) && !can.any((e) => e.word);
  if (!context.mounted) return;
  // "Edit it now?" with the program it opens in; another can be picked.
  DocEditor? pick = can.firstOrNull;
  final edit = await showLrDialog<bool>(
    context: context,
    builder: (c) => StatefulBuilder(
      builder: (c, set) => AlertDialog(
        icon: const Icon(Icons.description_outlined, size: 30),
        title: Text(tr('pdfword.edit_title')),
        content: SizedBox(
          width: 460,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(tr('pdfword.edit_body', {'name': name})),
              if (can.isNotEmpty) ...[
                const SizedBox(height: 14),
                Row(children: [
                  Text(tr('pdfword.open_with')),
                  const SizedBox(width: 10),
                  DropdownButton<DocEditor>(
                    value: pick,
                    isDense: true,
                    items: [for (final e in can) DropdownMenuItem(value: e, child: Text(e.name))],
                    onChanged: (e) => set(() => pick = e),
                  ),
                ]),
              ],
              if (wordOff) ...[
                const SizedBox(height: 8),
                Text(tr('pdfword.word_off_short'), style: const TextStyle(fontSize: 12, color: Color(0xFF8A8F98))),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: Text(tr('pdfword.not_now'))),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: Text(tr('pdfword.edit_now'))),
        ],
      ),
    ),
  );
  if (!context.mounted) return;
  if (edit != true) {
    await showToolResult(context, s, [docx]);
    return;
  }
  final before = File(docx).lastModifiedSync();
  final r = can.isEmpty ? (by: null, wordRefused: false) : await DocEditors.open(docx, first: pick);
  final by = r.by;
  if (!context.mounted) return;
  if (by == null) {
    if (!context.mounted) return;
    await showLrDialog<void>(
      context: context,
      builder: (c) => AlertDialog(
        icon: const Icon(Icons.info_outline_rounded, size: 30),
        title: Text(tr('pdfword.none_title')),
        content: SizedBox(width: 460, child: Text(tr(wordOff || r.wordRefused ? 'pdfword.word_unlicensed' : 'pdfword.none_body'))),
        actions: [
          TextButton(
            onPressed: () => unawaited(Process.run('explorer.exe', ['https://www.libreoffice.org/download/download/'])),
            child: Text(tr('pdfword.get_libre')),
          ),
          FilledButton(onPressed: () => Navigator.pop(c), child: Text(tr('common.ok'))),
        ],
      ),
    );
    if (context.mounted) await showToolResult(context, s, [docx]);
    return;
  }
  if (r.wordRefused) {
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(tr('pdfword.word_switched', {'app': by.name}))));
  }
  unawaited(_waitAndAsk(s, pdf, docx, before, by.name));
}

/// Open somewhere: a lock file beside it (Word / WPS "~$…", LibreOffice /
/// OpenOffice ".~lock.<name>#"), or a window with its name in the title.
/// The file itself is not touched (that could make it open read-only).
Future<bool> _openNow(String path) async {
  final dir = File(path).parent.path;
  final name = path.split(Platform.pathSeparator).last;
  final sep = Platform.pathSeparator;
  if (File('$dir$sep.~lock.$name#').existsSync()) return true;
  if (name.length > 2 && File('$dir$sep~\$${name.substring(2)}').existsSync()) return true;
  if (File('$dir$sep~\$$name').existsSync()) return true;
  final stem = (name.contains('.') ? name.substring(0, name.lastIndexOf('.')) : name).toLowerCase();
  return (await DocEditors.titles()).split('\n').any((t) => t.contains(stem));
}

Future<void> _waitAndAsk(AppServices s, String pdf, String docx, DateTime before, String by) async {
  final name = docx.split(Platform.pathSeparator).last;
  final saved = await BgTasks.instance.run<bool>(
    title: tr('pdfword.editing', {'name': name, 'app': by}),
    job: (t) async {
      var stop = false;
      t.cancellable(() => stop = true);
      t.waitForUser(tr('pdfword.editing_note'));
      var seen = false;
      final start = DateTime.now();
      while (!stop) {
        await Future<void>.delayed(const Duration(seconds: 3));
        if (!File(docx).existsSync()) return false;
        if (await _openNow(docx)) {
          seen = true;
          continue;
        }
        // Never seen open: the program didn't take it.
        if (!seen && DateTime.now().difference(start) > const Duration(minutes: 2)) {
          DiagLog.log('tools', '$by never showed $name: no more waiting');
          return false;
        }
        // Closed: saved (changed) or not.
        if (seen) return File(docx).lastModifiedSync().isAfter(before);
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
