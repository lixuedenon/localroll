// apps/desktop/lib/ui/tools/pdf_text_edit.dart
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:localroll_core/localroll_core.dart' show DiagLog;
import 'package:pdfrx/pdfrx.dart';

import '../../app_services.dart';
import '../../l10n/l10n.dart';
import '../../services/file_tools.dart';
import '../../services/pdf_fonts.dart';
import '../../services/tool_outputs.dart';
import '../light_look.dart';
import '../lr_dialog.dart';
import 'tools.dart';

/// One line (or one cell's text) on a page, as the PDF has it.
class _Line {
  _Line(this.page, this.box, this.text, this.size, this.base);

  /// 0-based.
  final int page;

  /// PDF points, the page's own space.
  final PdfRect box;
  final String text;

  /// Estimated font size (points) and baseline.
  final double size;
  final double base;

  /// How the PDF draws it (its font, size, bold, italic, colour), when the
  /// PDF helper could tell.
  PdfTextStyle? style;
}

/// A line changed.
class _Edit {
  _Edit(this.line, this.text, this.size, this.bold, this.italic, this.color, this.from);

  final _Line line;
  String text;
  double size;
  bool bold;
  bool italic;
  Color? color;

  /// Whose look it has: the line itself, or one picked with the brush.
  _Line from;
}

/// Changing words in a PDF in place: click a line, type, done. Only the
/// changed lines are touched — tables, stamps, pictures and the rest of the
/// text stay as they are.
class PdfTextEditPage extends StatefulWidget {
  const PdfTextEditPage({super.key, required this.services, required this.path});

  final AppServices services;
  final String path;

  @override
  State<PdfTextEditPage> createState() => _PdfTextEditPageState();
}

class _PdfTextEditPageState extends State<PdfTextEditPage> {
  AppServices get s => widget.services;

  PdfDocument? _doc;
  String? _error;
  int _page = 0;
  final Map<int, ui.Image> _pics = {};

  /// Each page's picture as pixels (to read the text's colour).
  final Map<int, ByteData> _px = {};
  final Map<_Line, Color?> _colors = {};
  final Map<int, List<_Line>> _lines = {};
  final List<_Edit> _edits = [];

  _Line? _hover;
  _Line? _editing;
  final _ctl = TextEditingController();
  final _focus = FocusNode();
  double _size = 12;
  bool _bold = false, _italic = false;
  Color? _color;

  /// Whose look the line being changed takes (itself unless brushed).
  _Line? _from;

  /// The brush is on: the next line clicked gives its look.
  bool _brush = false;

  /// The size / bold / colour bar under the line being changed. It sits in
  /// the overlay: drawn past the page's edge it would show but not take
  /// clicks (a Stack only hit-tests inside itself).
  final _bar = OverlayPortalController();
  final _barLink = LayerLink();

  /// Per page: which letters each of its fonts holds (a font is reused only
  /// when it holds every new letter).
  final Map<int, Map<int, Set<int>>> _fontChars = {};

  @override
  void initState() {
    super.initState();
    unawaited(_open());
  }

  @override
  void dispose() {
    for (final p in _pics.values) {
      p.dispose();
    }
    _px.clear();
    unawaited(_doc?.dispose());
    _ctl.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _open() async {
    try {
      final d = await PdfDocument.openFile(widget.path);
      if (!mounted) {
        await d.dispose();
        return;
      }
      setState(() => _doc = d);
      await _load(0);
    } catch (e) {
      DiagLog.log('tools', 'pdf edit open: $e');
      if (mounted) setState(() => _error = '$e');
    }
  }

  /// A page's picture and its lines.
  Future<void> _load(int i) async {
    final d = _doc;
    if (d == null || _pics.containsKey(i)) return;
    final page = d.pages[i];
    final w = (page.width * 2.4).round(), h = (page.height * 2.4).round();
    final pic = await page.render(width: w, height: h, fullWidth: w.toDouble(), fullHeight: h.toDouble(), backgroundColor: Colors.white);
    final im = await pic?.createImage();
    pic?.dispose();
    final px = await im?.toByteData(format: ui.ImageByteFormat.rawRgba);
    final lines = await _readLines(page, i);
    // How each line is drawn (font, size, bold, italic, colour).
    final styles = await PdfBuilder.styles(widget.path, i);
    final chars = <int, Set<int>>{};
    for (final st in styles) {
      (chars[st.font] ??= <int>{}).addAll(st.text.runes);
    }
    for (final l in lines) {
      PdfTextStyle? best;
      for (final st in styles) {
        final cx = (st.l + st.r) / 2, cy = (st.b + st.t) / 2;
        final tol = (l.box.top - l.box.bottom) * 0.3 + 1;
        if (cx < l.box.left - tol || cx > l.box.right + tol || cy < l.box.bottom - tol || cy > l.box.top + tol) continue;
        if (best == null || st.text.trim().length > best.text.trim().length) best = st;
      }
      l.style = best;
    }
    if (!mounted) {
      im?.dispose();
      return;
    }
    setState(() {
      if (im != null) _pics[i] = im;
      if (px != null) _px[i] = px;
      _lines[i] = lines;
      _fontChars[i] = chars;
    });
  }

  static bool _cjk(int c) => (c >= 0x2E80 && c <= 0x9FFF) || (c >= 0xAC00 && c <= 0xD7AF) || (c >= 0xF900 && c <= 0xFAFF) || (c >= 0xFF00 && c <= 0xFFEF);

  /// The page's text cut into lines; a big gap (table cells side by side)
  /// starts a new one, so each can be changed alone.
  Future<List<_Line>> _readLines(PdfPage page, int index) async {
    final PdfPageText t;
    try {
      t = await page.loadText();
    } catch (_) {
      return const [];
    }
    final chars = <(int, PdfRect)>[];
    for (final f in t.fragments) {
      for (var k = 0; k < f.length && k < f.charRects.length; k++) {
        chars.add((t.fullText.codeUnitAt(f.index + k), f.charRects[k]));
      }
    }
    final out = <_Line>[];
    var cur = <(int, PdfRect)>[];
    void flush() {
      final seen = [for (final c in cur) if (c.$2.width > 0.1 && c.$2.height > 0.1 && c.$1 > 32) c];
      final text = String.fromCharCodes([for (final c in cur) c.$1]).trim();
      cur = [];
      if (seen.isEmpty || text.isEmpty) return;
      var l = double.infinity, b = double.infinity, r = -double.infinity, tp = -double.infinity;
      for (final c in seen) {
        if (c.$2.left < l) l = c.$2.left;
        if (c.$2.bottom < b) b = c.$2.bottom;
        if (c.$2.right > r) r = c.$2.right;
        if (c.$2.top > tp) tp = c.$2.top;
      }
      final cjk = seen.any((c) => _cjk(c.$1));
      final hs = [for (final c in seen) c.$2.height]..sort();
      var size = cjk ? hs[hs.length ~/ 2] / 0.88 : hs.last / 0.72;
      size = size.clamp(4.0, 96.0);
      double base;
      if (cjk) {
        base = b + size * 0.11;
      } else {
        // Most letters sit on the line; g, p, y… hang below it.
        final bs = [for (final c in seen) if (!'gjpqy,;()'.contains(String.fromCharCode(c.$1))) c.$2.bottom]..sort();
        base = bs.isEmpty ? b + size * 0.2 : bs[bs.length ~/ 2];
      }
      out.add(_Line(index, PdfRect(l, tp, r, b), text, size, base));
    }

    for (final c in chars) {
      if (c.$1 == 10 || c.$1 == 13) {
        flush();
        continue;
      }
      final rc = c.$2;
      if (cur.isNotEmpty && rc.height > 0.1 && c.$1 > 32) {
        final prev = cur.lastWhere((x) => x.$2.height > 0.1 && x.$1 > 32, orElse: () => cur.last).$2;
        final h = prev.height > 0.1 ? prev.height : rc.height;
        final sameRow = (rc.bottom + rc.top) / 2 > prev.bottom - h * 0.3 && (rc.bottom + rc.top) / 2 < prev.top + h * 0.3;
        final gap = rc.left - prev.right;
        if (!sameRow || gap > h * 1.6 || gap < -h * 2) flush();
      }
      cur.add(c);
    }
    flush();
    return out;
  }

  Future<void> _go(int i) async {
    final d = _doc;
    if (d == null || i < 0 || i >= d.pages.length) return;
    _cancel();
    setState(() => _page = i);
    await _load(i);
  }

  /// The colour the line's text is drawn in, read from the page's picture:
  /// the pixels inside its box that differ most from the background around
  /// it (null: can't tell — the old text's colour is kept).
  Color? _colorOf(_Line l) {
    if (_colors.containsKey(l)) return _colors[l];
    final im = _pics[l.page], px = _px[l.page], d = _doc;
    if (im == null || px == null || d == null) return null;
    final w = im.width, h = im.height;
    final r = l.box.toRect(page: d.pages[l.page], scaledPageSize: Size(w.toDouble(), h.toDouble()));
    int cl(int v, int hi) => v < 0 ? 0 : (v > hi ? hi : v);
    final x0 = cl(r.left.floor(), w - 1), x1 = cl(r.right.ceil(), w - 1);
    final y0 = cl(r.top.floor(), h - 1), y1 = cl(r.bottom.ceil(), h - 1);
    int at(int x, int y) => (y * w + x) * 4;
    // Background: the pixels just around the box.
    final edge = <int>[];
    for (var x = x0; x <= x1; x += 2) {
      for (final y in [cl(y0 - 3, h - 1), cl(y1 + 3, h - 1)]) {
        edge.add(at(x, y));
      }
    }
    if (edge.isEmpty) return null;
    int med(int o) {
      final v = [for (final e in edge) px.getUint8(e + o)]..sort();
      return v[v.length ~/ 2];
    }

    final br = med(0), bg = med(1), bb = med(2);
    // Ink: the pixels farthest from it; the darkest third of those.
    final ink = <(int, int, int, int)>[];
    for (var y = y0; y <= y1; y++) {
      for (var x = x0; x <= x1; x++) {
        final o = at(x, y);
        final cr = px.getUint8(o), cg = px.getUint8(o + 1), cb = px.getUint8(o + 2);
        final dist = (cr - br).abs() + (cg - bg).abs() + (cb - bb).abs();
        if (dist > 120) ink.add((dist, cr, cg, cb));
      }
    }
    Color? c;
    if (ink.length >= 6) {
      ink.sort((a, b) => b.$1.compareTo(a.$1));
      final top = ink.take((ink.length / 3).ceil()).toList();
      var sr = 0, sg = 0, sb = 0;
      for (final p in top) {
        sr += p.$2;
        sg += p.$3;
        sb += p.$4;
      }
      c = Color.fromARGB(255, sr ~/ top.length, sg ~/ top.length, sb ~/ top.length);
    }
    return _colors[l] = c;
  }

  static String _hex(Color c) =>
      [(c.r * 255).round(), (c.g * 255).round(), (c.b * 255).round()].map((v) => v.toRadixString(16).padLeft(2, '0')).join();

  _Edit? _editOf(_Line l) => _edits.where((e) => identical(e.line, l)).firstOrNull;

  static Color? _rgbColor(String? hex) {
    final v = int.tryParse(hex ?? '', radix: 16);
    return v == null ? null : Color(0xFF000000 | v);
  }

  /// The look [l] is drawn with: size, bold, italic, colour.
  (double, bool, bool, Color?) _lookOf(_Line l) {
    final st = l.style;
    final size = st != null && st.size > 0 ? st.size : l.size;
    final color = _rgbColor(st?.rgb);
    // The PDF's colour unless it says plain black while the page shows
    // another (some PDFs colour text in ways the helper can't read).
    final seen = _colorOf(l);
    final c = color == null || (color.toARGB32() == 0xFF000000 && seen != null && _far(seen, color)) ? seen : color;
    return (double.parse(size.toStringAsFixed(1)), st?.bold ?? false, st?.slanted ?? false, c);
  }

  static bool _far(Color a, Color b) =>
      ((a.r - b.r).abs() + (a.g - b.g).abs() + (a.b - b.b).abs()) * 255 > 120;

  /// The line being changed differs from how it was when opened.
  bool get _typing {
    final l = _editing;
    if (l == null) return false;
    final text = _ctl.text.replaceAll('\n', ' ').trimRight();
    final e = _editOf(l);
    if (e != null) {
      return text != e.text || _size != e.size || _bold != e.bold || _italic != e.italic || !identical(_from ?? l, e.from);
    }
    final (size, bold, italic, _) = _lookOf(l);
    return text != l.text || _size != size || _bold != bold || _italic != italic || !identical(_from ?? l, l);
  }

  /// Something not saved yet (done, or still being typed).
  bool get _unsaved => _edits.isNotEmpty || _typing;

  void _start(_Line l) {
    final e = _editOf(l);
    final (size, bold, italic, color) = _lookOf(l);
    setState(() {
      _brush = false;
      _editing = l;
      _ctl.text = e?.text ?? l.text;
      _ctl.selection = TextSelection(baseOffset: 0, extentOffset: _ctl.text.length);
      _size = e?.size ?? size;
      _bold = e?.bold ?? bold;
      _italic = e?.italic ?? italic;
      _color = e?.color ?? color;
      _from = e?.from ?? l;
    });
    _bar.show();
    _focus.requestFocus();
  }

  /// The brush: [src]'s look for the line being changed.
  void _copyLook(_Line src) {
    final (size, bold, italic, color) = _lookOf(src);
    setState(() {
      _brush = false;
      _size = size;
      _bold = bold;
      _italic = italic;
      _color = color;
      _from = src;
    });
    _focus.requestFocus();
  }

  void _cancel() {
    if (_editing != null) setState(() => _editing = _from = null);
    _bar.hide();
  }

  void _done() {
    final l = _editing;
    if (l == null) return;
    final text = _ctl.text.replaceAll('\n', ' ').trimRight();
    final (size, bold, italic, _) = _lookOf(l);
    setState(() {
      final e = _editOf(l);
      final same = text == l.text && _size == size && _bold == bold && _italic == italic && identical(_from ?? l, l);
      if (same) {
        // Back as it was.
        if (e != null) _edits.remove(e);
      } else if (e != null) {
        e
          ..text = text
          ..size = _size
          ..bold = _bold
          ..italic = _italic
          ..color = _color
          ..from = _from ?? l;
      } else {
        _edits.add(_Edit(l, text, _size, _bold, _italic, _color, _from ?? l));
      }
      _editing = null;
      _from = null;
      _brush = false;
    });
    _bar.hide();
  }

  /// The PDF's own font can write [text] for [target], looking like [from]:
  /// same page, same bold / italic, and it holds every new letter (a PDF
  /// usually carries only the letters it used).
  bool _canReuse(String text, _Line from, _Line target, bool bold, bool italic) {
    final st = from.style;
    if (st == null || from.page != target.page || bold != st.bold || italic != st.slanted) return false;
    final chars = _fontChars[from.page]?[st.font] ?? const <int>{};
    for (final r in text.runes) {
      if (r == 32 || chars.contains(r)) continue;
      if (!st.embedded && r < 128) continue;
      return false;
    }
    return true;
  }

  /// "Font: …" for the line being changed.
  String _fontNote(String text, _Line from, _Line target, bool bold, bool italic) {
    final st = from.style;
    if (_canReuse(text, from, target, bold, italic)) {
      return tr('pdfedit.font_same', {'name': PdfFonts.familyOf(st?.name) ?? _plainName(st?.name ?? '')});
    }
    final fam = PdfFonts.familyOf(st?.name);
    final cjk = text.runes.any(PdfFonts.isCjk);
    final near = fam != null && (!cjk || PdfFonts.familyOf(st?.name) != 'Times New Roman') ? fam : (cjk ? 'Microsoft YaHei' : 'Arial');
    return tr('pdfedit.font_near', {'name': near});
  }

  static String _plainName(String n) => n.contains('+') && n.indexOf('+') == 6 ? n.substring(7) : n;

  /// The family to show [e]'s words in on screen.
  String _screenFamily(String text, _Line from) {
    final fam = PdfFonts.familyOf(from.style?.name);
    if (fam != null) return fam;
    return text.runes.any(PdfFonts.isCjk) ? 'Microsoft YaHei' : 'Arial';
  }

  /// Saves; true when it worked.
  Future<bool> _save({required bool replace}) async {
    // What is still being typed counts too.
    _done();
    final d = _doc;
    if (d == null || _edits.isEmpty) return false;
    DiagLog.log('tools', 'pdf edit save: ${_edits.length} change(s), ${replace ? 'replace' : 'new file'}');
    try {
      return await _saving(d, replace: replace);
    } catch (e, st) {
      DiagLog.log('tools', 'pdf edit save failed: $e\n$st');
      if (mounted) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(tr('tool.failed', {'why': '$e'}))));
      }
      return false;
    }
  }

  Future<bool> _saving(PdfDocument d, {required bool replace}) async {
    // Each change: the PDF's own font when it holds all the new letters,
    // else the closest Windows font (bold / italic drawn if it has none).
    final made = <int, List<PdfTextEdit>>{};
    for (final e in _edits) {
      String font;
      var fake = 0;
      if (_canReuse(e.text, e.from, e.line, e.bold, e.italic)) {
        final st = e.from.style!;
        font = identical(e.from, e.line) ? 'obj' : 'objat:${(st.l + st.r) / 2},${(st.b + st.t) / 2}';
      } else {
        final c = await PdfFonts.pick(e.text, like: e.from.style?.name, bold: e.bold, italic: e.italic);
        font = c?.path ?? '';
        if (e.bold && !(c?.hasBold ?? false)) fake |= 1;
        if (e.italic && !(c?.hasItalic ?? false)) fake |= 2;
      }
      (made[e.line.page] ??= []).add(PdfTextEdit(
        l: e.line.box.left,
        b: e.line.box.bottom,
        r: e.line.box.right,
        t: e.line.box.top,
        x: e.line.box.left,
        base: e.from.style != null && identical(e.from, e.line) ? e.line.base : e.line.base,
        size: e.size,
        font: font,
        text: e.text,
        // The colour the old words had (red stays red), or the brushed one.
        rgb: e.color == null ? 'auto' : _hex(e.color!),
        fake: fake,
      ));
    }
    DiagLog.log('tools', 'pdf edit fonts: ${[for (final p in made.values) for (final e in p) e.font.isEmpty ? '?' : e.font.split(r'\\').last].join(', ')}');
    final plan = <PdfPlanPage>[for (var i = 0; i < d.pages.length; i++) PdfFromDoc(widget.path, i, edits: made[i] ?? const [])];
    final out = replace ? '${widget.path}.lr-edit.pdf' : toolOutPath(s, widget.path, tr('pdfedit.suffix'), 'pdf');
    final n = _edits.length;
    String? err;
    var skipped = 0;
    await runBusy(context, tr('pdf.saving'), () async {
      err = await PdfBuilder.build(out, plan);
      skipped = PdfBuilder.lastSkipped;
      if (err == null && replace) {
        // The open copy lets go of the file first.
        await _doc?.dispose();
        _doc = null;
        await File(out).copy(widget.path);
        await File(out).delete();
      }
    });
    DiagLog.log('tools', 'pdf edit saved: ${err ?? 'ok'}, skipped $skipped');
    if (!mounted) {
      if (err == null && !replace) await s.tools.saved([out]);
      return err == null;
    }
    if (err != null) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(tr('tool.failed', {'why': err!}))));
      return false;
    }
    final note = skipped > 0 ? tr('pdfedit.skipped', {'count': skipped, 'all': n}) : null;
    if (replace) {
      // Open again: the file now has the changes.
      for (final p in _pics.values) {
        p.dispose();
      }
      setState(() {
        _pics.clear();
        _px.clear();
        _colors.clear();
        _lines.clear();
        _edits.clear();
      });
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(note ?? tr('pdfedit.replaced'))));
      await _open();
      return true;
    }
    // Saved as a new file: the changes are in it, nothing left to keep.
    setState(_edits.clear);
    await showToolResult(context, s, [out], note: note);
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final d = _doc;
    return PopScope(
      // Changes not saved: leaving asks first.
      canPop: !_unsaved,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_leave());
      },
      child: Theme(
      data: LightLook.theme(Theme.of(context)),
      child: Scaffold(
        backgroundColor: LightLook.page,
        appBar: AppBar(
          backgroundColor: Colors.white,
          title: Text('${tr('pdfedit.title')} · ${widget.path.split(Platform.pathSeparator).last}', overflow: TextOverflow.ellipsis),
          actions: [
            if (d != null) ...[
              IconButton(onPressed: _page > 0 ? () => _go(_page - 1) : null, icon: const Icon(Icons.chevron_left_rounded)),
              Text(tr('pdfedit.page', {'n': _page + 1, 'count': d.pages.length}), style: const TextStyle(color: LightLook.muted)),
              IconButton(onPressed: _page < d.pages.length - 1 ? () => _go(_page + 1) : null, icon: const Icon(Icons.chevron_right_rounded)),
            ],
            const SizedBox(width: 12),
          ],
        ),
        body: _error != null
            ? Center(child: Text(tr('pdfedit.cannot_open'), style: const TextStyle(color: LightLook.muted)))
            : d == null
                ? const Center(child: CircularProgressIndicator())
                : Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    Expanded(child: _pageView(d)),
                    SizedBox(width: 320, child: _side(d)),
                  ]),
      ),
      ),
    );
  }

  /// Leaving with changes not saved: save, drop them, or stay.
  Future<void> _leave() async {
    _done();
    final n = _edits.length;
    if (n == 0) {
      if (mounted) Navigator.of(context).pop();
      return;
    }
    final pick = await showLrDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(tr('pdfedit.leave_title')),
        content: SizedBox(width: 420, child: Text(tr('pdfedit.leave_body', {'count': n}))),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, 'stay'), child: Text(tr('common.cancel'))),
          TextButton(onPressed: () => Navigator.pop(c, 'drop'), child: Text(tr('pdfedit.leave_drop'))),
          FilledButton(onPressed: () => Navigator.pop(c, 'save'), child: Text(tr('pdfedit.save_new'))),
        ],
      ),
    );
    if (!mounted || pick == null || pick == 'stay') return;
    DiagLog.log('tools', 'pdf edit leave: $pick');
    if (pick == 'save' && !await _save(replace: false)) return;
    if (!mounted) return;
    setState(_edits.clear);
    Navigator.of(context).pop();
  }

  Widget _pageView(PdfDocument d) {
    final page = d.pages[_page];
    final pic = _pics[_page];
    final lines = _lines[_page] ?? const [];
    return LayoutBuilder(builder: (context, box) {
      final w = (box.maxWidth - 48).clamp(300.0, 900.0);
      final scale = w / page.width;
      final size = Size(w, page.height * scale);
      Rect at(PdfRect r) => r.toRect(page: page, scaledPageSize: size);
      return SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Center(
          child: Container(
            width: size.width,
            height: size.height,
            decoration: const BoxDecoration(color: Colors.white, boxShadow: [BoxShadow(color: Color(0x261F3B70), blurRadius: 24, offset: Offset(0, 8))]),
            child: pic == null
                ? const Center(child: CircularProgressIndicator())
                : Stack(clipBehavior: Clip.none, children: [
                    Positioned.fill(child: RawImage(image: pic, fit: BoxFit.fill)),
                    // Changed lines: the old words covered, the new shown.
                    for (final e in _edits)
                      if (e.line.page == _page && !identical(e.line, _editing)) _preview(e, at(e.line.box), scale),
                    // Every line can be clicked.
                    for (final l in lines)
                      if (!identical(l, _editing))
                        Positioned.fromRect(
                          rect: at(l.box).inflate(2),
                          child: MouseRegion(
                            cursor: _brush ? SystemMouseCursors.precise : SystemMouseCursors.text,
                            onEnter: (_) => setState(() => _hover = l),
                            onExit: (_) {
                              if (identical(_hover, l)) setState(() => _hover = null);
                            },
                            child: GestureDetector(
                              behavior: HitTestBehavior.opaque,
                              onTap: () => _brush && _editing != null ? _copyLook(l) : _start(l),
                              child: Container(
                                decoration: identical(_hover, l)
                                    ? BoxDecoration(
                                        color: const Color(0x0F2F6BFF),
                                        border: Border.all(color: LightLook.blue.withValues(alpha: 0.7)),
                                        borderRadius: BorderRadius.circular(2),
                                      )
                                    : null,
                              ),
                            ),
                          ),
                        ),
                    if (_editing case final l? when l.page == _page) ..._editor(l, at(l.box), scale, size),
                  ]),
          ),
        ),
      );
    });
  }

  Widget _preview(_Edit e, Rect r, double scale) => Positioned(
        left: r.left - 1,
        top: r.top - 1,
        child: Container(
          constraints: BoxConstraints(minWidth: r.width + 2, minHeight: r.height + 2),
          color: Colors.white,
          alignment: Alignment.centerLeft,
          child: Text(
            e.text,
            softWrap: false,
            style: TextStyle(
              fontSize: e.size * scale,
              height: 1.0,
              fontWeight: e.bold ? FontWeight.w700 : FontWeight.w400,
              fontStyle: e.italic ? FontStyle.italic : FontStyle.normal,
              fontFamily: _screenFamily(e.text, e.from),
              color: e.color ?? const Color(0xFF1A1A1A),
              decoration: TextDecoration.underline,
              decorationColor: const Color(0x8012A35F),
              decorationThickness: 2,
            ),
          ),
        ),
      );

  List<Widget> _editor(_Line l, Rect r, double scale, Size page) {
    // Room to type more; not past the page's right edge if it can help it.
    var width = r.width + 80;
    if (width < 220) width = 220;
    final room = page.width - r.left + 40;
    if (width > room && room >= 220) width = room;
    // The bar goes under the line, or over it near the page's foot; lined
    // up on the right for a line on the right half (so it stays in view).
    final up = page.height - r.bottom < 120;
    final right = r.left > page.width / 2;
    return [
      Positioned(
        left: r.left - 4,
        top: r.top - 5,
        width: width,
        child: CompositedTransformTarget(
          link: _barLink,
          child: Material(
          color: Colors.white,
          child: Container(
            decoration: BoxDecoration(
              border: Border.all(color: LightLook.blue, width: 2),
              boxShadow: const [BoxShadow(color: Color(0x262F6BFF), blurRadius: 0, spreadRadius: 4)],
            ),
            padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 2),
            child: CallbackShortcuts(
              bindings: {
                const SingleActivator(LogicalKeyboardKey.enter): _done,
                const SingleActivator(LogicalKeyboardKey.escape): _cancel,
              },
              child: TextField(
                controller: _ctl,
                focusNode: _focus,
                maxLines: 1,
                style: TextStyle(
                  fontSize: _size * scale,
                  height: 1.15,
                  fontWeight: _bold ? FontWeight.w700 : FontWeight.w400,
                  fontStyle: _italic ? FontStyle.italic : FontStyle.normal,
                  fontFamily: _screenFamily(_ctl.text, _from ?? l),
                  color: _color ?? const Color(0xFF1A1A1A),
                ),
                decoration: const InputDecoration(isDense: true, border: InputBorder.none, contentPadding: EdgeInsets.zero),
                onSubmitted: (_) => _done(),
                // The font note follows what is typed.
                onChanged: (_) => setState(() {}),
              ),
            ),
          ),
        ),
        ),
      ),
      Positioned(
        left: 0,
        top: 0,
        width: 0,
        height: 0,
        child: OverlayPortal(
          controller: _bar,
          overlayChildBuilder: (_) => Align(
            alignment: Alignment.topLeft,
            child: CompositedTransformFollower(
              link: _barLink,
              showWhenUnlinked: false,
              targetAnchor: up ? (right ? Alignment.topRight : Alignment.topLeft) : (right ? Alignment.bottomRight : Alignment.bottomLeft),
              followerAnchor: up ? (right ? Alignment.bottomRight : Alignment.bottomLeft) : (right ? Alignment.topRight : Alignment.topLeft),
              offset: Offset(0, up ? -10 : 10),
              child: _toolbar(l),
            ),
          ),
        ),
      ),
    ];
  }

  /// Size, bold, italic, colour, brush, cancel / done.
  Widget _toolbar(_Line l) => Material(
          color: Colors.white,
          elevation: 6,
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(mainAxisSize: MainAxisSize.min, children: [
              Text(tr('pdfedit.size'), style: const TextStyle(fontSize: 12.5)),
              IconButton(
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.remove_rounded, size: 16),
                onPressed: () => setState(() => _size = (_size - 0.5).clamp(4.0, 96.0)),
              ),
              Text(_size.toStringAsFixed(1), style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700)),
              IconButton(
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.add_rounded, size: 16),
                onPressed: () => setState(() => _size = (_size + 0.5).clamp(4.0, 96.0)),
              ),
              const SizedBox(width: 4),
              FilterChip(
                label: const Text('B', style: TextStyle(fontWeight: FontWeight.w800)),
                selected: _bold,
                onSelected: (v) => setState(() => _bold = v),
                visualDensity: VisualDensity.compact,
              ),
              const SizedBox(width: 6),
              FilterChip(
                label: const Text('I', style: TextStyle(fontStyle: FontStyle.italic, fontWeight: FontWeight.w700)),
                selected: _italic,
                onSelected: (v) => setState(() => _italic = v),
                visualDensity: VisualDensity.compact,
              ),
              const SizedBox(width: 8),
              // The colour (the original's, or the brushed text's).
              Container(
                width: 18,
                height: 18,
                decoration: BoxDecoration(
                  color: _color ?? const Color(0xFF1A1A1A),
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white, width: 2),
                  boxShadow: const [BoxShadow(color: Color(0x40000000), blurRadius: 2)],
                ),
              ),
              const SizedBox(width: 6),
              // The brush: take the look of another line.
              FilterChip(
                avatar: const Icon(Icons.format_paint_rounded, size: 16),
                label: Text(tr('pdfedit.brush')),
                selected: _brush,
                onSelected: (v) => setState(() => _brush = v),
                visualDensity: VisualDensity.compact,
              ),
              const SizedBox(width: 10),
              TextButton(onPressed: _cancel, child: Text(tr('common.cancel'))),
              const SizedBox(width: 4),
              FilledButton(onPressed: _done, child: Text(tr('pdfedit.done'))),
              ]),
              // Which font the new words get; what the brush does.
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 0, 4, 4),
                child: Text(
                  _brush ? tr('pdfedit.brush_hint') : _fontNote(_ctl.text, _from ?? l, l, _bold, _italic),
                  style: TextStyle(fontSize: 12, color: _brush ? LightLook.blue : LightLook.muted),
                ),
              ),
            ]),
          ),
      );

  Widget _side(PdfDocument d) => ListView(padding: const EdgeInsets.fromLTRB(0, 24, 20, 24), children: [
        _box(Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(tr('pdfedit.title'), style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: LightLook.text)),
          const SizedBox(height: 6),
          Text(tr('pdfedit.hint'), style: const TextStyle(color: LightLook.muted, fontSize: 12.5, height: 1.5)),
          if ((_lines[_page]?.isEmpty ?? false) && _pics.containsKey(_page)) ...[
            const SizedBox(height: 8),
            Text(tr('pdfedit.no_text'), style: const TextStyle(color: Color(0xFFC0560A), fontSize: 12.5, height: 1.5)),
          ],
        ])),
        const SizedBox(height: 14),
        _box(Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(tr('pdfedit.changed', {'count': _edits.length}), style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: LightLook.text)),
          for (final e in _edits)
            InkWell(
              onTap: () async {
                await _go(e.line.page);
                _start(e.line);
              },
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Row(children: [
                  Expanded(
                    child: Text.rich(
                      TextSpan(children: [
                        TextSpan(text: '${tr('pdfedit.page_short', {'n': e.line.page + 1})}  ', style: const TextStyle(color: LightLook.muted)),
                        TextSpan(text: e.line.text, style: const TextStyle(decoration: TextDecoration.lineThrough, color: Color(0xFFA3AEC0))),
                        const TextSpan(text: '  →  '),
                        TextSpan(text: e.text, style: const TextStyle(color: Color(0xFF15803D), fontWeight: FontWeight.w600)),
                      ]),
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 13),
                    ),
                  ),
                  IconButton(
                    tooltip: tr('pdfedit.undo'),
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.undo_rounded, size: 18),
                    onPressed: () => setState(() => _edits.remove(e)),
                  ),
                ]),
              ),
            ),
          const SizedBox(height: 10),
          FilledButton(onPressed: _unsaved ? () => _save(replace: false) : null, child: Text(tr('pdfedit.save_new'))),
          const SizedBox(height: 8),
          OutlinedButton(onPressed: _unsaved ? _confirmReplace : null, child: Text(tr('pdfedit.save_over'))),
          const SizedBox(height: 8),
          Text(tr('pdfedit.save_note'), style: const TextStyle(color: LightLook.muted, fontSize: 12, height: 1.5)),
        ])),
      ]);

  Future<void> _confirmReplace() async {
    _done();
    final ok = await showLrDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(tr('pdfedit.save_over')),
        content: SizedBox(width: 420, child: Text(tr('pdfedit.over_body'))),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: Text(tr('common.cancel'))),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: Text(tr('pdfedit.save_over'))),
        ],
      ),
    );
    if (ok == true) await _save(replace: true);
  }

  Widget _box(Widget child) => Container(
        padding: const EdgeInsets.all(16),
        decoration: LightLook.card(),
        child: child,
      );
}
