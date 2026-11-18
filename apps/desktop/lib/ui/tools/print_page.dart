// apps/desktop/lib/ui/tools/print_page.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import 'package:localroll_core/localroll_core.dart' show DiagLog;
import 'package:pdfrx/pdfrx.dart';

import '../../app_services.dart';
import '../../l10n/l10n.dart';
import '../../services/file_tools.dart';
import '../../services/tool_outputs.dart';
import '../light_look.dart';
import 'doc_pages.dart';
import 'tools.dart';

/// Print preview for any files: PDFs as they are, photos one to a page,
/// Office documents made into PDFs first, text set on pages. All of it
/// becomes one PDF, shown page by page, then printed (or kept as a PDF).
class PrintPage extends StatefulWidget {
  const PrintPage({super.key, required this.services, required this.paths});

  final AppServices services;
  final List<String> paths;

  @override
  State<PrintPage> createState() => _PrintPageState();
}

class _Printer {
  const _Printer(this.name, this.isDefault);
  final String name;
  final bool isDefault;
}

class _PrintPageState extends State<PrintPage> {
  String? _pdf;
  PdfDocument? _doc;
  String? _why;
  int _at = 0;
  List<_Printer> _printers = const [];
  String? _printer;
  bool _allPages = true;
  final TextEditingController _range = TextEditingController();
  int _copies = 1;
  bool _landscape = false, _fit = true, _gray = false, _duplex = false;
  bool _busy = false;

  AppServices get s => widget.services;

  @override
  void initState() {
    super.initState();
    DiagLog.log('tools', 'print: ${widget.paths.length} files');
    unawaited(_prepare());
    unawaited(_loadPrinters());
  }

  @override
  void dispose() {
    _range.dispose();
    unawaited(_doc?.dispose());
    super.dispose();
  }

  Future<void> _loadPrinters() async {
    try {
      final r = await Process.run('powershell', [
        '-NoProfile',
        '-NonInteractive',
        '-Command',
        '[Console]::OutputEncoding=[Text.Encoding]::UTF8; @(Get-CimInstance Win32_Printer | Select-Object Name, Default) | ConvertTo-Json -Compress',
      ], stdoutEncoding: utf8);
      final j = jsonDecode('${r.stdout}'.trim());
      final list = [
        for (final p in (j is List ? j : [j]))
          if (p is Map && p['Name'] != null) _Printer('${p['Name']}', p['Default'] == true),
      ];
      if (!mounted) return;
      setState(() {
        _printers = list;
        _printer = (list.where((p) => p.isDefault).firstOrNull ?? list.firstOrNull)?.name;
      });
    } catch (e) {
      DiagLog.log('tools', 'printers: $e');
    }
  }

  /// One PDF of everything, in order.
  Future<void> _prepare() async {
    try {
      final tmp = await Directory.systemTemp.createTemp('lr_print');
      final pages = <PdfPlanPage>[];
      var n = 0;
      for (final p in widget.paths) {
        final lower = p.toLowerCase();
        if (lower.endsWith('.pdf')) {
          final d = await PdfDocument.openFile(p);
          for (var i = 0; i < d.pages.length; i++) {
            pages.add(PdfFromDoc(p, i));
          }
          await d.dispose();
        } else if (DocPages.isPicture(p)) {
          final j = await uprightJpeg(s, p, max: 4096);
          if (j == null) continue;
          final (path, w, h) = j;
          final land = w > h;
          final pw = land ? 792.0 : 612.0, ph = land ? 612.0 : 792.0;
          const m = 18.0;
          final k = math.min((pw - 2 * m) / w, (ph - 2 * m) / h);
          final iw = w * k, ih = h * k;
          pages.add(PdfFromJpeg(path, pw, ph, Rect.fromLTWH((pw - iw) / 2, (ph - ih) / 2, iw, ih)));
        } else if (OfficePdf.handles(p)) {
          final out = '${tmp.path}${Platform.pathSeparator}d${n++}.pdf';
          final err = await OfficePdf.convert(p, out);
          if (err != null) {
            _why = err;
            continue;
          }
          final d = await PdfDocument.openFile(out);
          for (var i = 0; i < d.pages.length; i++) {
            pages.add(PdfFromDoc(out, i));
          }
          await d.dispose();
        } else {
          // Text: set on letter pages (pictures at 150 dpi).
          String text;
          try {
            text = await File(p).readAsString();
          } catch (_) {
            text = utf8.decode(await File(p).readAsBytes(), allowMalformed: true);
          }
          for (final jpg in await _textPages(text, tmp.path, n)) {
            pages.add(PdfFromJpeg(jpg, 612, 792, const Rect.fromLTWH(0, 0, 612, 792)));
            n++;
          }
          n += 1000;
        }
      }
      if (pages.isEmpty) {
        if (mounted) setState(() => _why ??= 'empty');
        return;
      }
      final out = '${tmp.path}${Platform.pathSeparator}print.pdf';
      final err = await PdfBuilder.build(out, pages);
      if (err != null) {
        if (mounted) setState(() => _why = err);
        return;
      }
      final d = await PdfDocument.openFile(out);
      if (!mounted) {
        await d.dispose();
        return;
      }
      setState(() {
        _pdf = out;
        _doc = d;
      });
    } catch (e) {
      DiagLog.log('tools', 'print prepare: $e');
      if (mounted) setState(() => _why = '$e');
    }
  }

  /// Text set on letter pages: JPEG files.
  static Future<List<String>> _textPages(String text, String dir, int base) async {
    const w = 1275, h = 1650, margin = 112.0;
    const style = TextStyle(color: Colors.black, fontSize: 21, height: 1.45, fontFamily: 'Microsoft YaHei');
    final lines = text.replaceAll('\r\n', '\n').split('\n');
    final out = <String>[];
    var i = 0;
    while (i < lines.length || out.isEmpty) {
      final rec = ui.PictureRecorder();
      final c = Canvas(rec);
      c.drawRect(const Rect.fromLTWH(0, 0, w + 0.0, h + 0.0), Paint()..color = Colors.white);
      var y = margin;
      while (i < lines.length) {
        final tp = TextPainter(text: TextSpan(text: lines[i].isEmpty ? ' ' : lines[i], style: style), textDirection: TextDirection.ltr)
          ..layout(maxWidth: w - 2 * margin);
        if (y + tp.height > h - margin && y > margin) break;
        tp.paint(c, Offset(margin, y));
        y += tp.height;
        i++;
      }
      final im = await rec.endRecording().toImage(w, h);
      final bd = await im.toByteData(format: ui.ImageByteFormat.rawRgba);
      im.dispose();
      final pic = img.Image.fromBytes(width: w, height: h, bytes: bd!.buffer, numChannels: 4);
      final f = '$dir${Platform.pathSeparator}t${base + out.length}.jpg';
      await File(f).writeAsBytes(img.encodeJpg(pic, quality: 90), flush: true);
      out.add(f);
      if (i >= lines.length) break;
    }
    return out;
  }

  /// The pages asked for, 0-based (null: what was typed doesn't read).
  List<int>? _pages() {
    final count = _doc?.pages.length ?? 0;
    if (_allPages) return [for (var i = 0; i < count; i++) i];
    final out = <int>[];
    for (final part in _range.text.split(RegExp(r'[,，\s]+'))) {
      if (part.isEmpty) continue;
      final m = RegExp(r'^(\d+)(?:-(\d+))?$').firstMatch(part);
      if (m == null) return null;
      final a = int.parse(m[1]!), b = int.parse(m[2] ?? m[1]!);
      for (var p = math.min(a, b); p <= math.max(a, b); p++) {
        if (p >= 1 && p <= count) out.add(p - 1);
      }
    }
    return out.isEmpty ? null : out;
  }

  Future<void> _print() async {
    final pdf = _pdf, printer = _printer, pages = _pages();
    if (pdf == null || printer == null) return;
    if (pages == null) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(tr('print.bad_range'))));
      return;
    }
    setState(() => _busy = true);
    final err = await PdfBuilder.print(pdf, printer, pages,
        copies: _copies, landscape: _landscape, fit: _fit, gray: _gray, duplex: _duplex);
    if (!mounted) return;
    setState(() => _busy = false);
    ScaffoldMessenger.maybeOf(context)
        ?.showSnackBar(SnackBar(content: Text(err == null ? tr('print.sent', {'n': pages.length * _copies}) : tr('tool.failed', {'why': err}))));
  }

  Future<void> _savePdf() async {
    final pdf = _pdf;
    if (pdf == null) return;
    final out = toolOutPath(s, widget.paths.first, tr('print.suffix'), 'pdf');
    await File(pdf).copy(out);
    if (mounted) await showToolResult(context, s, [out]);
  }

  Widget _row(String label, Widget child) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Row(children: [
          SizedBox(width: 64, child: Text(label, style: const TextStyle(color: LightLook.muted))),
          Expanded(child: child),
        ]),
      );

  Widget _two(String a, String b, bool first, ValueChanged<bool> set) => SegmentedButton<bool>(
        segments: [ButtonSegment(value: true, label: Text(a)), ButtonSegment(value: false, label: Text(b))],
        selected: {first},
        showSelectedIcon: false,
        onSelectionChanged: (v) => set(v.first),
      );

  @override
  Widget build(BuildContext context) {
    final d = _doc;
    return Theme(
      data: LightLook.theme(Theme.of(context)),
      child: Scaffold(
        backgroundColor: LightLook.page,
        appBar: AppBar(title: Text(tr('print.title'))),
        body: d == null
            ? Center(
                child: _why == null
                    ? Column(mainAxisSize: MainAxisSize.min, children: [
                        const CircularProgressIndicator(),
                        const SizedBox(height: 12),
                        Text(tr('print.preparing'), style: const TextStyle(color: LightLook.muted)),
                      ])
                    : Text(tr('tool.failed', {'why': _why!}), style: const TextStyle(color: LightLook.muted)),
              )
            : Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                SizedBox(
                  width: 140,
                  child: ListView.builder(
                    padding: const EdgeInsets.all(12),
                    itemCount: d.pages.length,
                    itemBuilder: (_, i) => Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: InkWell(
                        onTap: () => setState(() => _at = i),
                        child: Column(children: [
                          Container(
                            decoration: BoxDecoration(
                              color: Colors.white,
                              border: Border.all(color: i == _at ? LightLook.blue : const Color(0xFFDDE4F0), width: i == _at ? 2 : 1),
                            ),
                            child: AspectRatio(
                              aspectRatio: d.pages[i].width / d.pages[i].height,
                              child: IgnorePointer(child: PdfPageView(document: d, pageNumber: i + 1)),
                            ),
                          ),
                          Text('${i + 1}', style: const TextStyle(color: LightLook.muted, fontSize: 12)),
                        ]),
                      ),
                    ),
                  ),
                ),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Center(
                      child: AspectRatio(
                        aspectRatio: d.pages[_at].width / d.pages[_at].height,
                        child: Container(
                          decoration: const BoxDecoration(color: Colors.white, boxShadow: [BoxShadow(color: Color(0x22000000), blurRadius: 12)]),
                          child: ColorFiltered(
                            colorFilter: _gray
                                ? const ColorFilter.matrix([0.3, 0.59, 0.11, 0, 0, 0.3, 0.59, 0.11, 0, 0, 0.3, 0.59, 0.11, 0, 0, 0, 0, 0, 1, 0])
                                : const ColorFilter.mode(Colors.transparent, BlendMode.dst),
                            child: PdfPageView(document: d, pageNumber: _at + 1),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                Container(
                  width: 340,
                  padding: const EdgeInsets.all(18),
                  decoration: LightLook.card(),
                  margin: const EdgeInsets.fromLTRB(0, 16, 16, 16),
                  child: ListView(children: [
                    _row(
                      tr('print.printer'),
                      _printers.isEmpty
                          ? Text(tr('print.no_printer'), style: const TextStyle(color: LightLook.muted))
                          : DropdownButton<String>(
                              isExpanded: true,
                              value: _printer,
                              items: [for (final p in _printers) DropdownMenuItem(value: p.name, child: Text(p.name, overflow: TextOverflow.ellipsis))],
                              onChanged: (v) => setState(() => _printer = v),
                            ),
                    ),
                    _row(
                      tr('print.pages'),
                      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        _two(tr('print.all', {'n': d.pages.length}), tr('print.some'), _allPages, (v) => setState(() => _allPages = v)),
                        if (!_allPages)
                          Padding(
                            padding: const EdgeInsets.only(top: 6),
                            child: TextField(controller: _range, decoration: const InputDecoration(isDense: true, hintText: '1-3, 5')),
                          ),
                      ]),
                    ),
                    _row(
                      tr('print.copies'),
                      Row(children: [
                        IconButton(onPressed: _copies > 1 ? () => setState(() => _copies--) : null, icon: const Icon(Icons.remove_rounded)),
                        Text('$_copies', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                        IconButton(onPressed: _copies < 99 ? () => setState(() => _copies++) : null, icon: const Icon(Icons.add_rounded)),
                      ]),
                    ),
                    _row(tr('print.orient'), _two(tr('print.portrait'), tr('print.landscape'), !_landscape, (v) => setState(() => _landscape = !v))),
                    _row(tr('print.size'), _two(tr('print.fit'), tr('print.actual'), _fit, (v) => setState(() => _fit = v))),
                    _row(tr('print.color'), _two(tr('print.colour'), tr('print.gray'), !_gray, (v) => setState(() => _gray = !v))),
                    CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      value: _duplex,
                      onChanged: (v) => setState(() => _duplex = v ?? false),
                      title: Text(tr('print.duplex')),
                    ),
                    const SizedBox(height: 10),
                    FilledButton.icon(
                      onPressed: _busy || _printer == null ? null : () => unawaited(_print()),
                      icon: _busy
                          ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                          : const Icon(Icons.print_rounded),
                      label: Text(tr('print.go')),
                    ),
                    const SizedBox(height: 8),
                    OutlinedButton.icon(onPressed: () => unawaited(_savePdf()), icon: const Icon(Icons.picture_as_pdf_outlined), label: Text(tr('print.save_pdf'))),
                  ]),
                ),
              ]),
      ),
    );
  }
}

Future<void> openPrint(BuildContext context, AppServices s, List<String> paths) =>
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => PrintPage(services: s, paths: paths)));
