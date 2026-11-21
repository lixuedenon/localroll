// apps/desktop/lib/ui/tools/annotate_page.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart' show sha1;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
import 'pdf_notes.dart';
import 'tools.dart';

/// Marks on any file (PDF, photo, Office document), with the screen pen's
/// tools; a number can say something (shown on the pointer, and as a PDF
/// note in the PDF saved). Saved as a new file next to the others.
class AnnotatePage extends StatefulWidget {
  const AnnotatePage({super.key, required this.services, required this.path, this.page = 0, this.onSaved});

  final AppServices services;
  final String path;

  /// The page shown first (0-based).
  final int page;

  /// Told the new file once saved (the PDF tool then uses it).
  final ValueChanged<String>? onSaved;

  @override
  State<AnnotatePage> createState() => _AnnotatePageState();
}

class _AnnotatePageState extends State<AnnotatePage> {
  DocPages? _doc;
  String? _why;
  int _at = 0;
  final Map<int, InkEditor> _eds = {};
  bool _saving = false;

  /// A photo marked here before: the photo as it was (the marks come back
  /// to be changed), kept beside Keepnear's settings (see [_sidecar]).
  String? _base;

  /// Marks changed since opening (marks brought back don't count).
  bool _touched = false;

  AppServices get s => widget.services;

  /// Where a marked photo's marks are kept: found by the file's own bytes
  /// (the first 256 KB and its length), so renaming / moving it keeps them.
  Future<File> _sidecar(String photo) async {
    final f = File(photo);
    final len = await f.length();
    final raf = await f.open();
    final head = await raf.read(256 * 1024);
    await raf.close();
    final h = sha1.convert([...head, ...utf8.encode('$len')]).toString();
    final dir = Directory('${s.settings.dataDir.path}${Platform.pathSeparator}marks');
    return File('${dir.path}${Platform.pathSeparator}$h.json');
  }

  /// The photo marked before and its marks, if [photo] is one.
  Future<(String, List<InkMark>)?> _marksBefore(String photo) async {
    if (!DocPages.isPicture(photo)) return null;
    try {
      final f = await _sidecar(photo);
      if (!await f.exists()) return null;
      final j = jsonDecode(await f.readAsString());
      if (j is! Map<String, dynamic>) return null;
      final base = j['base'] as String?;
      if (base == null || !await File(base).exists()) return null;
      return (base, [for (final i in (j['inks'] as List?) ?? const []) if (i is Map<String, dynamic>) InkMark.fromJson(i)]);
    } catch (e) {
      DiagLog.log('tools', 'marks before: $e');
      return null;
    }
  }

  @override
  void initState() {
    super.initState();
    DiagLog.log('tools', 'annotate open');
    unawaited(() async {
      // A photo marked here before: its marks come back to be changed.
      final before = await _marksBefore(widget.path);
      _base = before?.$1;
      final d = await DocPages.open(s, _base ?? widget.path, why: (w) => _why = w);
      if (!mounted) {
        unawaited(d?.dispose());
        return;
      }
      setState(() {
        _doc = d;
        if (d != null) _at = widget.page.clamp(0, d.count - 1);
        if (before != null && before.$2.isNotEmpty) {
          _ed(0).restore(before.$2);
          DiagLog.log('tools', 'annotate: ${before.$2.length} mark(s) back to change');
        }
      });
      if (d == null && mounted) setState(() => _why ??= 'kind');
    }());
  }

  @override
  void dispose() {
    for (final e in _eds.values) {
      e.dispose();
    }
    unawaited(_doc?.dispose());
    super.dispose();
  }

  InkEditor _ed(int i) => _eds.putIfAbsent(i, () => InkEditor(video: false, clock: () => 0)..beforeChange = () => _touched = true);

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

  List<PdfNote> _notesOf(InkEditor ed, int w, int h) => [
        for (final m in ed.inks)
          if (m.tool == InkTool.number && (m.note ?? '').isNotEmpty && m.points.isNotEmpty) numberNote(m, w.toDouble(), h.toDouble()),
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
          pages.add(PdfFromDoc(d.pdfPath!, i, stamps: [PdfStamp(b, w, h, const Rect.fromLTWH(0, 0, 1, 1))], notes: _notesOf(ed, w, h)));
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
        // The marks kept (and the photo they are on), to be changed again.
        try {
          final side = await _sidecar(out);
          await side.parent.create(recursive: true);
          await side.writeAsString(jsonEncode({
            'base': _base ?? widget.path,
            'inks': [for (final m in _ed(0).inks) m.toJson()],
          }));
        } catch (e) {
          DiagLog.log('tools', 'marks not kept: $e');
        }
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
      widget.onSaved?.call(out);
      await showToolResult(context, s, [out]);
    } catch (e) {
      DiagLog.log('tools', 'annotate save failed: $e');
      if (mounted) ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(tr('tool.failed', {'why': '$e'}))));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<bool> _leaveOk() async {
    if (!_any || !_touched) return true;
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
      child: Focus(
        autofocus: true,
        // A chosen number: a digit key changes it; Delete takes the chosen
        // mark away.
        onKeyEvent: (node, e) {
          if (e is! KeyDownEvent || inkTyping()) return KeyEventResult.ignored;
          final ed = _eds[_at];
          if (ed == null) return KeyEventResult.ignored;
          final digit = inkDigitOf(e.logicalKey);
          if (digit != null && ed.typeDigit(digit)) return KeyEventResult.handled;
          if (e.logicalKey == LogicalKeyboardKey.delete && ed.selected != null) {
            ed.deleteSelected();
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: Scaffold(
        backgroundColor: LrColors.ink,
        appBar: AppBar(automaticallyImplyLeading: false, title: Text('${tr('ann.title')} · $name', overflow: TextOverflow.ellipsis)),
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
      ),
    );
  }
}

/// Opens the marking page for [path].
Future<void> openAnnotate(BuildContext context, AppServices s, String path, {int page = 0, ValueChanged<String>? onSaved}) =>
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => AnnotatePage(services: s, path: path, page: page, onSaved: onSaved)));
