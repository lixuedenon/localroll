// apps/desktop/lib/ui/tools/pdf_tool_page.dart
import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:localroll_core/localroll_core.dart';
import 'package:localroll_ink/localroll_ink.dart';
import 'package:pdfrx/pdfrx.dart';

import '../../app_services.dart';
import '../../l10n/l10n.dart';
import '../../services/office_engines.dart';
import '../../services/file_tools.dart';
import '../../services/pdf_open.dart';
import '../../services/win_dialogs.dart';
import '../light_look.dart';
import '../send_page.dart' show baseNameOf;
import 'ocr_box_page.dart';
import 'pdf_text_edit.dart';
import 'tools.dart';
import '../lr_dialog.dart';
import '../trash_actions.dart';

class _Doc {
  _Doc(this.path, this.doc);

  final String path;
  final PdfDocument doc;
}

/// A signature laid on a page: where (0–1 of the page as it was, before
/// our turning), turned about its middle ([angle], clockwise, radians).
class _Sign {
  _Sign(this.sig, this.rect, {this.angle = 0});

  final Signature sig;
  Rect rect;
  double angle;

  _Sign copy() => _Sign(sig, rect, angle: angle);
}

/// One page in a remembered state (undo / redo).
class _Was {
  _Was(this.page) : turns = page.turns, signs = [for (final s in page.signs) s.copy()];
  _Was.of(this.page, this.turns, this.signs);

  final _Page page;
  final int turns;
  final List<_Sign> signs;
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
  /// How big the pages are shown (a slider and Ctrl + wheel change it;
  /// kept while Keepnear runs).
  static double _thumbW = 170;

  /// Office programs here, for "Open with".
  Set<OfficeApp> _apps = const {};
  final List<_Doc> _docs = [];
  final List<_Page> _pages = [];
  final Set<_Page> _picked = {};
  bool _loading = true;

  /// Undo / redo: the pages as they were (order, turning, signatures).
  final List<List<_Was>> _undo = [], _redo = [];

  List<_Was> _now() => [for (final p in _pages) _Was(p)];

  /// Remembers the pages as they are now, before a change.
  void _mark() {
    _undo.add(_now());
    if (_undo.length > 100) _undo.removeAt(0);
    _redo.clear();
  }

  /// A change that can be undone.
  void _change(VoidCallback f) {
    _mark();
    setState(f);
  }

  void _back(List<List<_Was>> from, List<List<_Was>> to) {
    if (from.isEmpty) return;
    to.add(_now());
    final was = from.removeLast();
    setState(() {
      _pages
        ..clear()
        ..addAll([for (final w in was) w.page]);
      for (final w in was) {
        w.page.turns = w.turns;
        w.page.signs
          ..clear()
          ..addAll([for (final s in w.signs) s.copy()]);
      }
      _picked.retainWhere(_pages.contains);
    });
  }

  void _undoOne() => _back(_undo, _redo);
  void _redoOne() => _back(_redo, _undo);

  AppServices get s => widget.services;

  @override
  void initState() {
    super.initState();
    unawaited(OfficeEngines.installed().then((a) {
      if (mounted) setState(() => _apps = a);
    }));
    unawaited(_add(widget.files, undoable: false));
  }

  @override
  void dispose() {
    for (final d in _docs) {
      unawaited(d.doc.dispose());
    }
    super.dispose();
  }

  Future<void> _add(List<String> files, {bool undoable = true}) async {
    if (undoable) _mark();
    setState(() => _loading = true);
    for (final f in files) {
      try {
        final d = await openPdfLoose(f);
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
        if (px != null) stamps.add(PdfStamp(px, sg.sig.width, sg.sig.height, sg.rect, angle: sg.angle));
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
    if (!mounted) {
      // Left meanwhile: the results still go into the library / records.
      if (err == null) await s.tools.saved([out]);
      return;
    }
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

  /// The pages picked away. Every page picked: that is the file itself —
  /// asked, it goes to "Recently deleted" (a PDF has at least one page).
  Future<void> _delete() async {
    if (_picked.length < _pages.length) {
      _change(() {
        _pages.removeWhere(_picked.contains);
        _picked.clear();
      });
      return;
    }
    if (_docs.length != 1) {
      await showLrDialog<void>(
        context: context,
        builder: (c) => AlertDialog(
          content: Text(tr('pdf.keep_one')),
          actions: [FilledButton(onPressed: () => Navigator.pop(c), child: Text(tr('common.ok')))],
        ),
      );
      return;
    }
    final ok = await showLrDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        icon: const Icon(Icons.delete_outline_rounded, size: 32),
        title: Text(tr('pdf.delete_all_title', {'count': _pages.length})),
        content: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 440), child: Text(tr('pdf.delete_all_body'))),
        actions: [
          OutlinedButton(onPressed: () => Navigator.pop(c, false), child: Text(tr('common.cancel'))),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: const Color(0xFFE5484D)),
            onPressed: () => Navigator.pop(c, true),
            child: Text(tr('pdf.delete_file')),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    // The file let go first (an open file can't be moved), then away.
    final path = _docs.first.path;
    final docs = List.of(_docs);
    setState(() {
      _docs.clear();
      _pages.clear();
      _picked.clear();
    });
    for (final d in docs) {
      await d.doc.dispose();
    }
    if (!mounted) return;
    await deleteOneFile(context, s, path, ask: false);
    if (mounted) unawaited(Navigator.of(context).maybePop());
  }

  Future<void> _split() async {
    final how = await showLrDialog<String>(
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
    if (!mounted) {
      // Left meanwhile: the results still go into the library / records.
      await s.tools.saved(outs);
      return;
    }
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
      final box = Rect.fromLTWH(r.left * w, r.top * h, r.width * w, r.height * h);
      c.save();
      c.translate(box.center.dx, box.center.dy);
      c.rotate(sg.angle);
      c.drawImageRect(
        sg.sig.image,
        Rect.fromLTWH(0, 0, sg.sig.width.toDouble(), sg.sig.height.toDouble()),
        Rect.fromCenter(center: Offset.zero, width: box.width, height: box.height),
        Paint()..filterQuality = FilterQuality.high,
      );
      c.restore();
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
    if (!mounted) {
      // Left meanwhile: the results still go into the library / records.
      await s.tools.saved(outs);
      return;
    }
    if (err != null) return _failed(err!);
    await showToolResult(context, s, outs);
  }

  /// Smaller: every page made a JPEG picture at 150 dpi (the text can no
  /// longer be selected — said before).
  Future<void> _compress() async {
    final go = await showLrDialog<bool>(
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
    if (!mounted) {
      // Left meanwhile: the results still go into the library / records.
      if (err == null) await s.tools.saved([out]);
      return;
    }
    if (err != null) return _failed(err!);
    final before = _docs.fold<int>(0, (n, d) => n + File(d.path).lengthSync());
    final after = File(out).lengthSync();
    DiagLog.log('tools', 'pdf compressed: ${before ~/ 1024} KB → ${after ~/ 1024} KB');
    await showToolResult(context, s, [out], note: tr('pdf.compressed', {'before': _mb(before), 'after': _mb(after)}));
  }

  static String _mb(int b) => b < 1024 * 1024 ? '${(b / 1024).round()} KB' : '${(b / 1024 / 1024).toStringAsFixed(1)} MB';

  /// The file (and its page) a one-file action works on: the page picked
  /// first; else the only file; else the user says which file.
  Future<(_Doc, int)?> _target() async {
    for (final p in _pages) {
      if (_picked.contains(p)) return (p.doc, p.number - 1);
    }
    if (_docs.isEmpty) return null;
    if (_docs.length == 1) return (_docs.first, 0);
    final d = await showLrDialog<_Doc>(
      context: context,
      builder: (c) => SimpleDialog(title: Text(tr('pdf.which_file')), children: [
        for (final d in _docs)
          SimpleDialogOption(
            onPressed: () => Navigator.pop(c, d),
            child: Row(children: [
              const Icon(Icons.picture_as_pdf_outlined, size: 18, color: Color(0xFFE5484D)),
              const SizedBox(width: 10),
              Expanded(child: Text(baseNameOf(d.path), overflow: TextOverflow.ellipsis)),
              Text(tr('pdf.n_pages', {'count': d.doc.pages.length}), style: const TextStyle(color: LightLook.muted, fontSize: 12)),
            ]),
          ),
      ]),
    );
    return d == null ? null : (d, 0);
  }

  /// [old]'s pages now come from [path] (changed words, marks): same
  /// places, turning, signatures and picking.
  Future<void> _swap(_Doc old, String path) async {
    PdfDocument d;
    try {
      d = await openPdfLoose(path);
    } catch (e) {
      DiagLog.log('tools', 'pdf swap not opened: $e');
      return;
    }
    if (!mounted || !_docs.contains(old)) {
      await d.dispose();
      return;
    }
    final doc = _Doc(path, d);
    // Each old page has one new page (also in undo / redo).
    final made = <_Page, _Page>{};
    _Page? next(_Page p) => p.doc != old
        ? p
        : p.number > d.pages.length
            ? null
            : made.putIfAbsent(p, () => _Page(doc, p.number)
              ..turns = p.turns
              ..signs.addAll(p.signs));
    for (final list in [..._undo, ..._redo]) {
      for (var i = list.length - 1; i >= 0; i--) {
        final n = next(list[i].page);
        if (n == null) {
          list.removeAt(i);
        } else if (n != list[i].page) {
          list[i] = _Was.of(n, list[i].turns, list[i].signs);
        }
      }
    }
    setState(() {
      _docs[_docs.indexOf(old)] = doc;
      for (var i = 0; i < _pages.length; i++) {
        final p = _pages[i];
        final n = next(p);
        if (n == null || n == p) continue;
        if (_picked.remove(p)) _picked.add(n);
        _pages[i] = n;
      }
      _pages.removeWhere((p) => p.doc == old);
    });
    DiagLog.log('tools', 'pdf tool now uses ${baseNameOf(path)}');
    await old.doc.dispose();
  }

  /// 编辑: words, marks, signatures, pictures — in the file of the page
  /// picked; the tool then uses the new version.
  Future<void> _edit() async {
    final t = await _target();
    if (t == null || !mounted) return;
    final (doc, at) = t;
    await openEditor(context, s, doc.path, page: at, onSaved: (f) => unawaited(_swap(doc, f)));
  }

  /// 取字: a box on the page picked (or the first page); the whole page,
  /// or several pages at once, is one button away there / in the menu.
  Future<void> _boxText() async {
    final t = await _target();
    if (t == null || !mounted) return;
    final picked = [for (final p in _pages) if (_picked.contains(p) && p.doc == t.$1) p.number - 1];
    await openOcrBox(context, s, t.$1.path, page: t.$2, pages: picked.length > 1 ? picked : null);
  }

  // ------------------------------------------------------------- page

  @override
  Widget build(BuildContext context) {
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
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyZ, control: true): _undoOne,
        const SingleActivator(LogicalKeyboardKey.keyY, control: true): _redoOne,
        const SingleActivator(LogicalKeyboardKey.keyZ, control: true, shift: true): _redoOne,
      },
      child: Focus(
        autofocus: true,
        child: Theme(
      data: LightLook.theme(Theme.of(context)),
      child: Scaffold(
        backgroundColor: LightLook.page,
        appBar: AppBar(automaticallyImplyLeading: false,
          title: Text(_title, overflow: TextOverflow.ellipsis),
          backgroundColor: Colors.white,
          actions: [
            // The PDF in Word / LibreOffice / any program ("Open with").
            if (_docs.length == 1)
              PopupMenuButton<String>(
                tooltip: '',
                onSelected: (v) => unawaited(OfficeEngines.openWith(_docs.first.path, OfficeApp.values.where((a) => a.name == v).firstOrNull)),
                itemBuilder: (_) => [
                  for (final a in _apps)
                    if (a != OfficeApp.wps) PopupMenuItem(value: a.name, child: Text(tr('pdf.open_in', {'app': a == OfficeApp.office ? 'Word' : a.label}))),
                  PopupMenuItem(value: 'other', child: Text(tr('pdf.open_other'))),
                ],
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  child: Row(children: [
                    const Icon(Icons.open_in_new_rounded, size: 18),
                    const SizedBox(width: 4),
                    Text(tr('pdf.open_with')),
                  ]),
                ),
              ),
            ToolSaveChip(services: s),
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
              // Undo / redo (Ctrl+Z, Ctrl+Y): order, turning, deleting,
              // adding, signatures and pictures.
              Padding(
                padding: const EdgeInsets.only(right: 4, bottom: 8),
                child: IconButton.outlined(
                  tooltip: '${tr('pdf.undo')} (Ctrl+Z)',
                  onPressed: _undo.isEmpty ? null : _undoOne,
                  icon: const Icon(Icons.undo_rounded, size: 20),
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(right: 12, bottom: 8),
                child: IconButton.outlined(
                  tooltip: '${tr('pdf.redo')} (Ctrl+Y)',
                  onPressed: _redo.isEmpty ? null : _redoOne,
                  icon: const Icon(Icons.redo_rounded, size: 20),
                ),
              ),
              act(Icons.add_rounded, tr('pdf.add'), () async {
                final f = await pickPdfs(context, s);
                if (f.isNotEmpty) await _add(f);
              }),
              act(Icons.rotate_right_rounded, tr('pdf.turn'), busy
                  ? null
                  : () => _change(() {
                        for (final p in _chosen) {
                          p.turns = (p.turns + 1) % 4;
                        }
                      })),
              act(Icons.delete_outline_rounded, tr('pdf.delete'), _picked.isEmpty ? null : () => unawaited(_delete())),
              // 编辑: change words, mark, sign, pictures — in the file of
              // the page picked.
              act(Icons.edit_document, tr('edit.title'), busy ? null : _edit, color: LightLook.blue),
              // One page: nothing to split.
              act(Icons.call_split_rounded, tr('pdf.split'), busy || _pages.length < 2 ? null : _split),
              act(Icons.compress_rounded, tr('pdf.compress'), busy ? null : _compress),
              act(Icons.image_outlined, tr('pdf.images'), busy ? null : _toImages),
              act(Icons.crop_free_rounded, tr('pdf.text'), busy ? null : _boxText),
            ]),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18),
            child: Row(children: [
              Expanded(
                child: Text(
                  _picked.isEmpty ? tr('pdf.hint', {'count': _pages.length}) : tr('pdf.picked', {'count': _picked.length}),
                  style: const TextStyle(color: LightLook.muted, fontSize: 13),
                ),
              ),
              // Page size: smaller / bigger.
              const Icon(Icons.photo_size_select_small_rounded, size: 18, color: LightLook.muted),
              SizedBox(
                width: 160,
                child: Slider(
                  value: _thumbW,
                  min: 100,
                  max: 480,
                  onChanged: (v) => setState(() => _thumbW = v),
                ),
              ),
              const Icon(Icons.photo_size_select_large_rounded, size: 20, color: LightLook.muted),
            ]),
          ),
          Expanded(
            child: _loading && _pages.isEmpty
                ? const Center(child: CircularProgressIndicator())
                : Listener(
                    // Ctrl + wheel: pages bigger / smaller.
                    onPointerSignal: (e) {
                      if (e is PointerScrollEvent && HardwareKeyboard.instance.isControlPressed) {
                        GestureBinding.instance.pointerSignalResolver.register(e, (ev) {
                          if (ev is PointerScrollEvent) {
                            setState(() => _thumbW = (_thumbW - ev.scrollDelta.dy / 4).clamp(100.0, 480.0));
                          }
                        });
                      }
                    },
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.all(18),
                      child: Wrap(spacing: 18, runSpacing: 22, children: [
                        for (var i = 0; i < _pages.length; i++) _tile(i),
                      ]),
                    ),
                  ),
          ),
        ]),
      ),
        ),
      ),
    );
  }

  Widget _tile(int i) {
    final p = _pages[i];
    final on = _picked.contains(p);
    final thumb = _Thumb(page: p, width: _thumbW, picked: on);
    return DragTarget<int>(
      onWillAcceptWithDetails: (d) => d.data != i,
      onAcceptWithDetails: (d) => _change(() {
        final moved = _pages.removeAt(d.data);
        _pages.insert(i, moved);
      }),
      builder: (context, cand, _) => Draggable<int>(
        data: i,
        feedback: Opacity(opacity: 0.85, child: Material(color: Colors.transparent, child: _Thumb(page: p, width: _thumbW, picked: true))),
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
        // Sharper when shown bigger.
        Positioned.fill(child: PdfPageView(document: page.doc.doc, pageNumber: page.number, maximumDpi: width > 220 ? 150 : 96)),
        for (final sg in page.signs)
          Positioned(
            left: sg.rect.left * width,
            top: sg.rect.top * h,
            width: sg.rect.width * width,
            height: sg.rect.height * h,
            child: Transform.rotate(
              angle: sg.angle,
              child: Image.memory(sg.sig.png, fit: BoxFit.fill),
            ),
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
