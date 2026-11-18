// apps/desktop/lib/ui/tools/annotate_page.dart
import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import 'package:localroll_core/localroll_core.dart' show DiagLog;

import '../../app_services.dart';
import '../../l10n/l10n.dart';
import '../../services/annotations.dart';
import '../../services/file_tools.dart';
import '../../services/tool_outputs.dart';
import '../player/ink_editor.dart';
import '../theme.dart';
import 'doc_pages.dart';
import 'tools.dart';

/// Marks on any file (PDF, photo, Office document), with the screen pen's
/// tools; a number can say something (shown on the pointer, and as a PDF
/// note in the PDF saved). Saved as a new file next to the others.
class AnnotatePage extends StatefulWidget {
  const AnnotatePage({super.key, required this.services, required this.path});

  final AppServices services;
  final String path;

  @override
  State<AnnotatePage> createState() => _AnnotatePageState();
}

class _AnnotatePageState extends State<AnnotatePage> {
  DocPages? _doc;
  String? _why;
  int _at = 0;
  final Map<int, InkEditor> _eds = {};
  bool _saving = false;

  AppServices get s => widget.services;

  @override
  void initState() {
    super.initState();
    DiagLog.log('tools', 'annotate open');
    unawaited(DocPages.open(s, widget.path, why: (w) => _why = w).then((d) {
      if (mounted) setState(() => _doc = d);
      if (d == null && mounted) setState(() => _why ??= 'kind');
    }));
  }

  @override
  void dispose() {
    for (final e in _eds.values) {
      e.dispose();
    }
    unawaited(_doc?.dispose());
    super.dispose();
  }

  InkEditor _ed(int i) => _eds.putIfAbsent(i, () => InkEditor(video: false, clock: () => 0));

  bool get _any => _eds.values.any((e) => !e.isEmpty);

  /// The marks of a page as a see-through picture [w]×[h].
  Future<ui.Image> _marks(InkEditor ed, int w, int h) async {
    final rec = ui.PictureRecorder();
    final c = Canvas(rec);
    final size = Size(w.toDouble(), h.toDouble());
    for (final m in ed.inks) {
      InkGeometry.paint(c, size, m);
    }
    return rec.endRecording().toImage(w, h);
  }

  List<PdfNote> _notesOf(InkEditor ed) => [
        for (final m in ed.inks)
          if (m.tool == InkTool.number && (m.note ?? '').isNotEmpty && m.points.isNotEmpty)
            PdfNote((m.points.first.dx + m.dx).clamp(0.0, 1.0), (m.points.first.dy + m.dy).clamp(0.0, 1.0), '${m.number ?? ''}. ${m.note}',
                rgb: (m.color & 0xFFFFFF).toRadixString(16).padLeft(6, '0')),
      ];

  Future<void> _save() async {
    final d = _doc;
    if (d == null || !_any) return;
    setState(() => _saving = true);
    try {
      String? err;
      String out;
      if (d.isPdf) {
        out = toolOutPath(s, widget.path, tr('ann.suffix'), 'pdf');
        final pages = <PdfPlanPage>[];
        for (var i = 0; i < d.count; i++) {
          final ed = _eds[i];
          if (ed == null || ed.isEmpty) {
            pages.add(PdfFromDoc(d.pdfPath!, i));
            continue;
          }
          final pt = d.points(i);
          // About 200 dpi: sharp when printed.
          final k = 200 / 72;
          final w = (pt.width * k).round(), h = (pt.height * k).round();
          final im = await _marks(ed, w, h);
          final bd = await im.toByteData(format: ui.ImageByteFormat.rawStraightRgba);
          im.dispose();
          final b = bd!.buffer.asUint8List();
          for (var j = 0; j + 3 < b.length; j += 4) {
            final r = b[j];
            b[j] = b[j + 2];
            b[j + 2] = r;
          }
          pages.add(PdfFromDoc(d.pdfPath!, i, stamps: [PdfStamp(b, w, h, const Rect.fromLTWH(0, 0, 1, 1))], notes: _notesOf(ed)));
        }
        err = await PdfBuilder.build(out, pages);
      } else {
        // A photo: the marks laid on it, saved as a JPEG.
        out = toolOutPath(s, widget.path, tr('ann.suffix'), 'jpg');
        final base = d.image!;
        final rec = ui.PictureRecorder();
        final c = Canvas(rec);
        final size = Size(base.width.toDouble(), base.height.toDouble());
        c.drawImage(base, Offset.zero, Paint());
        for (final m in _ed(0).inks) {
          InkGeometry.paint(c, size, m);
        }
        final im = await rec.endRecording().toImage(base.width, base.height);
        final bd = await im.toByteData(format: ui.ImageByteFormat.rawRgba);
        im.dispose();
        final pic = img.Image.fromBytes(width: base.width, height: base.height, bytes: bd!.buffer, numChannels: 4);
        await File(out).writeAsBytes(img.encodeJpg(pic, quality: 92), flush: true);
      }
      DiagLog.log('tools', 'annotate saved: ${err ?? 'ok'}');
      if (!mounted) {
        if (err == null) await s.tools.saved([out]);
        return;
      }
      if (err != null) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(tr('tool.failed', {'why': err}))));
        return;
      }
      for (final e in _eds.values) {
        e.clear();
      }
      await showToolResult(context, s, [out]);
    } catch (e) {
      DiagLog.log('tools', 'annotate save failed: $e');
      if (mounted) ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(tr('tool.failed', {'why': '$e'}))));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<bool> _leaveOk() async {
    if (!_any) return true;
    final r = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(tr('ann.leave_title')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: Text(tr('common.cancel'))),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: Text(tr('pdfedit.leave_drop'))),
        ],
      ),
    );
    return r == true;
  }

  @override
  Widget build(BuildContext context) {
    final d = _doc;
    final name = widget.path.split(Platform.pathSeparator).last;
    return PopScope(
      canPop: !_any,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        if (await _leaveOk() && context.mounted) {
          for (final e in _eds.values) {
            e.clear();
          }
          setState(() {});
          if (context.mounted) Navigator.of(context).pop();
        }
      },
      child: Scaffold(
        backgroundColor: LrColors.ink,
        appBar: AppBar(title: Text('${tr('ann.title')} · $name', overflow: TextOverflow.ellipsis)),
        body: d == null
            ? Center(
                child: _why == null
                    ? const CircularProgressIndicator()
                    : Text(tr('ann.cannot'), style: const TextStyle(color: LrColors.muted)),
              )
            : Row(children: [
                if (d.count > 1)
                  SizedBox(
                    width: 130,
                    child: ListView.builder(
                      padding: const EdgeInsets.all(10),
                      itemCount: d.count,
                      itemBuilder: (_, i) => Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: InkWell(
                          onTap: () => setState(() => _at = i),
                          child: Container(
                            decoration: BoxDecoration(border: Border.all(color: i == _at ? LrColors.safelight : Colors.transparent, width: 2)),
                            child: AspectRatio(aspectRatio: d.aspect(i), child: IgnorePointer(child: d.view(i))),
                          ),
                        ),
                      ),
                    ),
                  ),
                Expanded(
                  child: Column(children: [
                    InkToolbar(
                      editor: _ed(_at),
                      doneLabel: _saving ? tr('ann.saving') : tr('ann.save'),
                      onDone: () => unawaited(_save()),
                    ),
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Center(
                          child: AspectRatio(
                            aspectRatio: d.aspect(_at),
                            child: Stack(fit: StackFit.expand, children: [
                              Container(color: Colors.white, child: d.view(_at)),
                              InkLayer(key: ValueKey(_at), notes: const [], video: false, editor: _ed(_at)),
                              NumberNotes(marks: () => _ed(_at).inks),
                            ]),
                          ),
                        ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: Text(tr('ann.hint'), style: const TextStyle(color: LrColors.muted, fontSize: 12.5)),
                    ),
                  ]),
                ),
              ]),
      ),
    );
  }
}

/// Opens the marking page for [path].
Future<void> openAnnotate(BuildContext context, AppServices s, String path) =>
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => AnnotatePage(services: s, path: path)));
