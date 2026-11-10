// apps/desktop/lib/ui/tools/pdf_tool_page.dart
import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:localroll_core/localroll_core.dart';
import 'package:localroll_ink/localroll_ink.dart';
import 'package:pdfrx/pdfrx.dart';

import '../../app_services.dart';
import '../../l10n/l10n.dart';
import '../../services/file_tools.dart';
import '../../services/win_dialogs.dart';
import '../light_look.dart';
import 'tools.dart';

class _Doc {
  _Doc(this.path, this.doc);

  final String path;
  final PdfDocument doc;
}

/// A signature laid on a page: where (0–1 of the page as it was, before
/// our turning).
class _Sign {
  _Sign(this.sig, this.rect);

  final Signature sig;
  Rect rect;
}

class _Page {
  _Page(this.doc, this.number);

  final _Doc doc;

  /// 1-based.
  final int number;
  int turns = 0;
  final List<_Sign> signs = [];

  PdfPage get page => doc.doc.pages[number - 1];
}

/// PDF tools: the pages of one or more PDFs in a row — move them around,
/// turn, delete, sign; save as one PDF, split, make smaller, pictures, text.
class PdfToolPage extends StatefulWidget {
  const PdfToolPage({super.key, required this.services, required this.files});

  final AppServices services;
  final List<String> files;

  @override
  State<PdfToolPage> createState() => _PdfToolPageState();
}

class _PdfToolPageState extends State<PdfToolPage> {
  final List<_Doc> _docs = [];
  final List<_Page> _pages = [];
  final Set<_Page> _picked = {};
  bool _loading = true;
  Signature? _lastSig;

  AppServices get s => widget.services;

  @override
  void initState() {
    super.initState();
    unawaited(_add(widget.files));
  }

  @override
  void dispose() {
    for (final d in _docs) {
      unawaited(d.doc.dispose());
    }
    super.dispose();
  }

  Future<void> _add(List<String> files) async {
    setState(() => _loading = true);
    for (final f in files) {
      try {
        final d = await PdfDocument.openFile(f);
        final doc = _Doc(f, d);
        _docs.add(doc);
        for (var i = 1; i <= d.pages.length; i++) {
          _pages.add(_Page(doc, i));
        }
      } catch (e) {
        DiagLog.log('tools', 'pdf not opened: $e');
        if (mounted) {
          ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(tr('pdf.cannot_open', {'name': baseNameOf(f)}))));
        }
      }
    }
    if (mounted) setState(() => _loading = false);
  }

  List<_Page> get _chosen => _picked.isEmpty ? _pages : [for (final p in _pages) if (_picked.contains(p)) p];

  String get _title => _docs.isEmpty
      ? tr('tool.pdfTools')
      : _docs.length == 1
          ? baseNameOf(_docs.first.path)
          : tr('pdf.n_files', {'name': baseNameOf(_docs.first.path), 'count': _docs.length});

  // ------------------------------------------------------------- actions

  Future<List<PdfPlanPage>> _plan(List<_Page> pages) async {
    final out = <PdfPlanPage>[];
    for (final p in pages) {
      final stamps = <PdfStamp>[];
      for (final sg in p.signs) {
        final px = await sg.sig.bgra();
        if (px != null) stamps.add(PdfStamp(px, sg.sig.width, sg.sig.height, sg.rect));
      }
      out.add(PdfFromDoc(p.doc.path, p.number - 1, turns: p.turns, stamps: stamps));
    }
    return out;
  }

  Future<void> _saveOne({bool ask = false}) async {
    if (_pages.isEmpty) return;
    var out = toolOutPath(s, _docs.first.path, _suffix(), 'pdf');
    if (ask) {
      final p = await WinDialogs.saveFile(suggestedName: baseNameOf(out), extensions: const ['pdf']);
      if (p == null) return;
      out = p.toLowerCase().endsWith('.pdf') ? p : '$p.pdf';
    }
    if (!mounted) return;
    final plan = await _plan(_pages);
    if (!mounted) return;
    final err = await runBusy(context, tr('pdf.saving'), () => PdfBuilder.build(out, plan));
    if (!mounted) return;
    if (err != null) return _failed(err);
    await showToolResult(context, s, [out]);
  }

  String _suffix() {
    if (_pages.any((p) => p.signs.isNotEmpty)) return tr('pdf.suffix_signed');
    if (_docs.length > 1) return tr('pdf.suffix_joined');
    return tr('pdf.suffix_edited');
  }

  void _failed(String why) =>
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(tr('tool.failed', {'why': why}))));

  Future<void> _split() async {
    final how = await showDialog<String>(
      context: context,
      builder: (c) => SimpleDialog(title: Text(tr('pdf.split')), children: [
        SimpleDialogOption(onPressed: () => Navigator.pop(c, 'picked'), child: Text(tr('pdf.split_picked', {'count': _chosen.length}))),
        SimpleDialogOption(onPressed: () => Navigator.pop(c, 'each'), child: Text(tr('pdf.split_each', {'count': _chosen.length}))),
      ]),
    );
    if (how == null || !mounted) return;
    final outs = <String>[];
    String? err;
    await runBusy(context, tr('pdf.saving'), () async {
      if (how == 'picked') {
        final out = toolOutPath(s, _docs.first.path, tr('pdf.suffix_part'), 'pdf');
        err = await PdfBuilder.build(out, await _plan(_chosen));
        if (err == null) outs.add(out);
      } else {
        for (final p in _chosen) {
          final out = toolOutPath(s, p.doc.path, '-p${p.number}', 'pdf');
          err = await PdfBuilder.build(out, await _plan([p]));
          if (err != null) break;
          outs.add(out);
        }
      }
    });
    if (!mounted) return;
    if (err != null) return _failed(err!);
    await showToolResult(context, s, outs);
  }

  /// The page as a picture: its own turning, our turning, signatures.
  Future<ui.Image?> _picture(_Page p, double dpi) async {
    final pg = p.page;
    final w = (pg.width * dpi / 72).round(), h = (pg.height * dpi / 72).round();
    final img = await pg.render(width: w, height: h, fullWidth: w.toDouble(), fullHeight: h.toDouble(), backgroundColor: Colors.white);
    if (img == null) return null;
    final base = await img.createImage();
    img.dispose();
    final turned = p.turns % 4;
    final ow = turned.isOdd ? h : w, oh = turned.isOdd ? w : h;
    final rec = ui.PictureRecorder();
    final c = Canvas(rec);
    c.translate(ow / 2, oh / 2);
    c.rotate(turned * math.pi / 2);
    c.translate(-w / 2, -h / 2);
    c.drawImage(base, Offset.zero, Paint()..filterQuality = FilterQuality.high);
    for (final sg in p.signs) {
      final r = sg.rect;
      c.drawImageRect(
        sg.sig.image,
        Rect.fromLTWH(0, 0, sg.sig.width.toDouble(), sg.sig.height.toDouble()),
        Rect.fromLTWH(r.left * w, r.top * h, r.width * w, r.height * h),
        Paint()..filterQuality = FilterQuality.high,
      );
    }
    final out = await rec.endRecording().toImage(ow, oh);
    base.dispose();
    return out;
  }

  Future<String?> _png(_Page p, double dpi, String out) async {
    final im = await _picture(p, dpi);
    if (im == null) return 'no picture';
    final d = await im.toByteData(format: ui.ImageByteFormat.png);
    im.dispose();
    if (d == null) return 'no picture';
    await File(out).writeAsBytes(d.buffer.asUint8List());
    return null;
  }

  Future<void> _toImages() async {
    final outs = <String>[];
    String? err;
    await runBusy(context, tr('pdf.making_images', {'count': _chosen.length}), () async {
      for (final p in _chosen) {
        final out = toolOutPath(s, p.doc.path, '-p${p.number}', 'png');
        err = await _png(p, 200, out);
        if (err != null) break;
        outs.add(out);
      }
    });
    if (!mounted) return;
    if (err != null) return _failed(err!);
    await showToolResult(context, s, outs);
  }

  /// Smaller: every page made a JPEG picture at 150 dpi (the text can no
  /// longer be selected — said before).
  Future<void> _compress() async {
    final go = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(tr('pdf.compress')),
        content: SizedBox(width: 440, child: Text(tr('pdf.compress_body'))),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: Text(tr('common.cancel'))),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: Text(tr('pdf.compress_go'))),
        ],
      ),
    );
    if (go != true || !mounted) return;
    final exe = s.ffmpeg.ffmpeg;
    if (exe == null) return _failed('ffmpeg');
    final out = toolOutPath(s, _docs.first.path, tr('pdf.suffix_small'), 'pdf');
    final tmp = await Directory.systemTemp.createTemp('lr_pdfz');
    String? err;
    if (!mounted) return;
    await runBusy(context, tr('pdf.compressing'), () async {
      final plan = <PdfPlanPage>[];
      var i = 0;
      for (final p in _pages) {
        final png = '${tmp.path}${Platform.pathSeparator}${i++}.png';
        err = await _png(p, 150, png);
        if (err != null) return;
        final jpg = png.replaceAll('.png', '.jpg');
        await Process.run(exe, ['-hide_banner', '-loglevel', 'error', '-y', '-i', png, '-q:v', '5', jpg]);
        if (!File(jpg).existsSync()) {
          err = 'jpeg';
          return;
        }
        final odd = p.turns.isOdd;
        final pw = odd ? p.page.height : p.page.width, ph = odd ? p.page.width : p.page.height;
        plan.add(PdfFromJpeg(jpg, pw, ph, Rect.fromLTWH(0, 0, pw, ph)));
      }
      err = await PdfBuilder.build(out, plan);
    });
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
    if (!mounted) return;
    if (err != null) return _failed(err!);
    final before = _docs.fold<int>(0, (n, d) => n + File(d.path).lengthSync());
    final after = File(out).lengthSync();
    await showToolResult(context, s, [out], note: tr('pdf.compressed', {'before': _mb(before), 'after': _mb(after)}));
  }

  static String _mb(int b) => b < 1024 * 1024 ? '${(b / 1024).round()} KB' : '${(b / 1024 / 1024).toStringAsFixed(1)} MB';

  /// The words on the pages: the PDF's own text, or read from the picture
  /// (scans) by Windows.
  Future<void> _text() async {
    final buf = StringBuffer();
    await runBusy(context, tr('tool.reading'), () async {
      final tmp = await Directory.systemTemp.createTemp('lr_pdft');
      try {
        for (final p in _chosen) {
          var t = '';
          try {
            t = (await p.page.loadText()).fullText.trim();
          } catch (_) {}
          if (t.isEmpty) {
            final png = '${tmp.path}${Platform.pathSeparator}${p.number}.png';
            if (await _png(p, 200, png) == null) t = (await s.textIndexer.ocr.read(png))?.trim() ?? '';
          }
          if (_chosen.length > 1) buf.writeln('— ${tr('pdf.page_n', {'n': p.number})} —');
          buf.writeln(t);
          buf.writeln();
        }
      } finally {
        try {
          await tmp.delete(recursive: true);
        } catch (_) {}
      }
    });
    if (!mounted) return;
    final ctl = TextEditingController(text: buf.toString().trim());
    await showDialog<void>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(tr('pdf.text')),
        content: SizedBox(
          width: 680,
          child: TextField(controller: ctl, maxLines: 20, minLines: 12, decoration: const InputDecoration(border: OutlineInputBorder())),
        ),
        actions: [
          TextButton(
            onPressed: () async {
              final out = toolOutPath(s, _docs.first.path, '', 'txt');
              await File(out).writeAsString(ctl.text);
              if (c.mounted) Navigator.pop(c);
              if (mounted) await showToolResult(context, s, [out]);
            },
            child: Text(tr('pdf.save_txt')),
          ),
          FilledButton(
            onPressed: () {
              unawaited(Clipboard.setData(ClipboardData(text: ctl.text)));
              Navigator.pop(c);
            },
            child: Text(tr('tool.copy_text')),
          ),
        ],
      ),
    );
  }

  Future<void> _sign() async {
    final target = _picked.length == 1 ? _picked.first : (_pages.isNotEmpty ? _pages.first : null);
    if (target == null) return;
    var sig = _lastSig;
    if (sig != null) {
      final again = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: Text(tr('pdf.sign')),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            Container(color: Colors.white, padding: const EdgeInsets.all(8), height: 90, child: Image.memory(sig.png)),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: Text(tr('pdf.sign_new'))),
            FilledButton(onPressed: () => Navigator.pop(c, true), child: Text(tr('pdf.sign_same'))),
          ],
        ),
      );
      if (again == null) return;
      if (!again) sig = null;
    }
    if (!mounted) return;
    sig ??= await showSignaturePad(context, (k) => tr('sig.$k'));
    if (sig == null || !mounted) return;
    _lastSig = sig;
    final placed = await showDialog<Rect>(context: context, builder: (_) => _PlaceSign(page: target, sig: sig!));
    if (placed == null) return;
    setState(() => target.signs.add(_Sign(sig!, placed)));
  }

  // ------------------------------------------------------------- page

  @override
  Widget build(BuildContext context) {
    final one = _picked.length == 1;
    Widget act(IconData icon, String label, VoidCallback? on, {Color? color}) => Padding(
          padding: const EdgeInsets.only(right: 8, bottom: 8),
          child: FilledButton.tonalIcon(
            style: color == null ? null : FilledButton.styleFrom(backgroundColor: color, foregroundColor: Colors.white),
            onPressed: on,
            icon: Icon(icon, size: 18),
            label: Text(label),
          ),
        );
    final busy = _loading || _pages.isEmpty;
    return Theme(
      data: LightLook.theme(Theme.of(context)),
      child: Scaffold(
        backgroundColor: LightLook.page,
        appBar: AppBar(
          title: Text(_title, overflow: TextOverflow.ellipsis),
          backgroundColor: Colors.white,
          actions: [
            TextButton(onPressed: busy ? null : () => _saveOne(ask: true), child: Text(tr('tool.save_as'))),
            const SizedBox(width: 6),
            FilledButton.icon(
              onPressed: busy ? null : _saveOne,
              icon: const Icon(Icons.save_rounded, size: 18),
              label: Text(tr('pdf.save_one')),
            ),
            const SizedBox(width: 16),
          ],
        ),
        body: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Wrap(children: [
              act(Icons.add_rounded, tr('pdf.add'), () async {
                final f = await WinDialogs.pickFiles(title: tr('pdf.add'), extensions: const ['pdf']);
                if (f.isNotEmpty) await _add(f);
              }),
              act(Icons.rotate_right_rounded, tr('pdf.turn'), busy
                  ? null
                  : () => setState(() {
                        for (final p in _chosen) {
                          p.turns = (p.turns + 1) % 4;
                        }
                      })),
              act(Icons.delete_outline_rounded, tr('pdf.delete'), _picked.isEmpty
                  ? null
                  : () => setState(() {
                        _pages.removeWhere(_picked.contains);
                        _picked.clear();
                      })),
              act(Icons.draw_rounded, tr('pdf.sign'), busy ? null : _sign, color: const Color(0xFF7B4DEB)),
              act(Icons.call_split_rounded, tr('pdf.split'), busy ? null : _split),
              act(Icons.compress_rounded, tr('pdf.compress'), busy ? null : _compress),
              act(Icons.image_outlined, tr('pdf.images'), busy ? null : _toImages),
              act(Icons.text_snippet_outlined, tr('pdf.text'), busy ? null : _text),
            ]),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18),
            child: Text(
              _picked.isEmpty ? tr('pdf.hint', {'count': _pages.length}) : tr('pdf.picked', {'count': _picked.length}) + (one ? ' · ${tr('pdf.sign_hint')}' : ''),
              style: const TextStyle(color: LightLook.muted, fontSize: 13),
            ),
          ),
          Expanded(
            child: _loading && _pages.isEmpty
                ? const Center(child: CircularProgressIndicator())
                : SingleChildScrollView(
                    padding: const EdgeInsets.all(18),
                    child: Wrap(spacing: 18, runSpacing: 22, children: [
                      for (var i = 0; i < _pages.length; i++) _tile(i),
                    ]),
                  ),
          ),
        ]),
      ),
    );
  }

  Widget _tile(int i) {
    final p = _pages[i];
    final on = _picked.contains(p);
    final thumb = _Thumb(page: p, width: 132, picked: on);
    return DragTarget<int>(
      onWillAcceptWithDetails: (d) => d.data != i,
      onAcceptWithDetails: (d) => setState(() {
        final moved = _pages.removeAt(d.data);
        _pages.insert(i, moved);
      }),
      builder: (context, cand, _) => Draggable<int>(
        data: i,
        feedback: Opacity(opacity: 0.85, child: Material(color: Colors.transparent, child: _Thumb(page: p, width: 132, picked: true))),
        childWhenDragging: Opacity(opacity: 0.3, child: thumb),
        child: GestureDetector(
          onTap: () => setState(() => on ? _picked.remove(p) : _picked.add(p)),
          child: Column(children: [
            Container(
              decoration: BoxDecoration(border: cand.isNotEmpty ? const Border(left: BorderSide(color: Color(0xFF2F6BFF), width: 4)) : null),
              child: thumb,
            ),
            const SizedBox(height: 6),
            Text(
              _docs.length > 1 ? '${i + 1} · ${baseNameOf(p.doc.path)} p${p.number}' : '${i + 1}',
              style: const TextStyle(fontSize: 12, color: LightLook.muted),
              overflow: TextOverflow.ellipsis,
            ),
          ]),
        ),
      ),
    );
  }
}

/// One page, small: its picture turned as asked, its signatures on it.
class _Thumb extends StatelessWidget {
  const _Thumb({required this.page, required this.width, required this.picked});

  final _Page page;
  final double width;
  final bool picked;

  @override
  Widget build(BuildContext context) {
    final pg = page.page;
    final h = width * pg.height / pg.width;
    final content = SizedBox(
      width: width,
      height: h,
      child: Stack(children: [
        Positioned.fill(child: PdfPageView(document: page.doc.doc, pageNumber: page.number, maximumDpi: 72)),
        for (final sg in page.signs)
          Positioned(
            left: sg.rect.left * width,
            top: sg.rect.top * h,
            width: sg.rect.width * width,
            height: sg.rect.height * h,
            child: Image.memory(sg.sig.png, fit: BoxFit.fill),
          ),
      ]),
    );
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: picked ? const Color(0xFF2F6BFF) : const Color(0xFFDDE3EC), width: picked ? 3 : 1),
        boxShadow: const [BoxShadow(color: Color(0x1A1E3C78), blurRadius: 8, offset: Offset(0, 3))],
      ),
      child: RotatedBox(quarterTurns: page.turns, child: content),
    );
  }
}

/// Where the signature goes: drag it on the page, make it bigger / smaller.
class _PlaceSign extends StatefulWidget {
  const _PlaceSign({required this.page, required this.sig});

  final _Page page;
  final Signature sig;

  @override
  State<_PlaceSign> createState() => _PlaceSignState();
}

class _PlaceSignState extends State<_PlaceSign> {
  Offset _at = const Offset(0.55, 0.8);
  double _w = 0.3;

  @override
  Widget build(BuildContext context) {
    final pg = widget.page.page;
    const maxH = 640.0, maxW = 620.0;
    final k = math.min(maxW / pg.width, maxH / pg.height);
    final w = pg.width * k, h = pg.height * k;
    final sw = _w * w, sh = sw * widget.sig.height / widget.sig.width;
    final rect = Rect.fromLTWH(_at.dx * w - sw / 2, _at.dy * h - sh / 2, sw, sh);
    return AlertDialog(
      title: Text(tr('pdf.place_sign')),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        Text(tr('pdf.place_hint'), style: const TextStyle(color: LightLook.muted, fontSize: 13)),
        const SizedBox(height: 8),
        Container(
          width: w,
          height: h,
          color: Colors.white,
          child: GestureDetector(
            onPanUpdate: (d) => setState(() => _at = Offset(((_at.dx * w + d.delta.dx) / w).clamp(0.0, 1.0), ((_at.dy * h + d.delta.dy) / h).clamp(0.0, 1.0))),
            onTapDown: (d) => setState(() => _at = Offset(d.localPosition.dx / w, d.localPosition.dy / h)),
            child: Stack(children: [
              Positioned.fill(child: PdfPageView(document: widget.page.doc.doc, pageNumber: widget.page.number)),
              Positioned.fromRect(
                rect: rect,
                child: Container(
                  decoration: BoxDecoration(border: Border.all(color: const Color(0x882F6BFF))),
                  child: Image.memory(widget.sig.png, fit: BoxFit.fill),
                ),
              ),
            ]),
          ),
        ),
        Row(children: [
          Text(tr('pdf.sign_size')),
          Expanded(child: Slider(value: _w, min: 0.08, max: 0.8, onChanged: (v) => setState(() => _w = v))),
        ]),
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(tr('common.cancel'))),
        FilledButton(
          onPressed: () => Navigator.pop(context, Rect.fromLTWH(rect.left / w, rect.top / h, rect.width / w, rect.height / h)),
          child: Text(tr('pdf.place_ok')),
        ),
      ],
    );
  }
}
