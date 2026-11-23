// apps/desktop/lib/ui/tools/pdf_text_edit.dart
import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:localroll_core/localroll_core.dart' show DiagLog;
import 'package:pdfrx/pdfrx.dart';

import '../../app_services.dart';
import '../../l10n/l10n.dart';
import '../../services/annotations.dart';
import '../../services/file_tools.dart';
import '../../services/pdf_fonts.dart';
import '../../services/pdf_open.dart';
import '../../services/tool_outputs.dart';
import '../../services/windows_ocr.dart';
import '../light_look.dart';
import '../lr_dialog.dart';
import '../player/ink_editor.dart';
import 'annotate_page.dart';
import 'office_edit.dart';
import 'pdf_notes.dart';
import 'sig_library.dart';
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

/// A line changed (or, with [para], a whole paragraph).
class _Edit {
  _Edit(this.line, this.text, this.size, this.bold, this.italic, this.color, this.from, {this.para, this.dx = 0, this.dy = 0});

  final _Line line;
  String text;
  double size;
  bool bold;
  bool italic;
  Color? color;

  /// Whose look it has: the line itself, or one picked with the brush.
  _Line from;

  /// The paragraph's lines, top first ([line] is the first): [text] is all
  /// of it, laid out again inside the lines' area.
  List<_Line>? para;

  /// Moved by this much (page points; dy down the page).
  double dx, dy;

  List<_Line> get lines => para ?? [line];

  _Edit copy() => _Edit(line, text, size, bold, italic, color, from, para: para, dx: dx, dy: dy);
}

/// One line as it will be written: page points, [hscale] its width
/// squeezed (1: as is).
class _Out {
  const _Out(this.text, this.x, this.base, this.size, this.hscale);
  final String text;
  final double x, base, size, hscale;
}

/// How an edit's words are laid out; [squeezed] 0–1 how much it had to
/// give (1: not at all), [tooLong] it still doesn't fit.
class _Layout {
  const _Layout(this.out, this.squeezed, this.tooLong);
  final List<_Out> out;
  final double squeezed;
  final bool tooLong;
}

/// A signature or picture laid on a page: its box 0–1 of the page as
/// shown, turned about its middle ([angle], clockwise, radians).
class _Put {
  _Put(this.page, this.sig, this.rect, {this.angle = 0});

  final int page;
  final Signature sig;
  Rect rect;
  double angle;

  _Put copy() => _Put(page, sig, rect, angle: angle);
}

/// Words written over a scan (or a picture in the page): the old ones
/// covered with the paper's colour, the new ones written on it. [size] in
/// page points; [rect] 0–1 of the page as shown.
class _Patch {
  _Patch(this.page, this.rect, this.text, this.bg, this.color, this.size);

  final int page;
  Rect rect;
  String text;
  int bg, color;
  double size;

  _Patch copy() => _Patch(page, rect, text, bg, color, size);
}

/// Everything as it was (one undo for all kinds of change).
class _Snap {
  _Snap(this.edits, this.puts, this.inks, this.patches);

  final List<_Edit> edits;
  final List<_Put> puts;
  final Map<int, List<InkMark>> inks;
  final List<_Patch> patches;
}

/// What a click on the page does.
enum _Mode { text, mark, sign, picture }

/// 编辑: one page for changing words in place, marks, signatures and
/// pictures — mixed in any order, one undo, saved together once. Changing
/// words touches only the changed lines (tables, stamps, pictures and the
/// rest of the text stay as they are).
class PdfTextEditPage extends StatefulWidget {
  const PdfTextEditPage({
    super.key,
    required this.services,
    required this.path,
    this.page = 0,
    this.onSaved,
    this.original,
    this.mark = false,
  });

  final AppServices services;
  final String path;

  /// An Office document made into [path] for this: words can't be changed,
  /// the result is a new PDF named after it.
  final String? original;

  /// Start with marking.
  final bool mark;

  /// The page shown first (0-based).
  final int page;

  /// Told the file once the changes are saved (the new file, or [path]
  /// when replaced); the PDF tool then uses it.
  final ValueChanged<String>? onSaved;

  @override
  State<PdfTextEditPage> createState() => _PdfTextEditPageState();
}

class _PdfTextEditPageState extends State<PdfTextEditPage> {
  AppServices get s => widget.services;

  bool get _office => widget.original != null;

  /// What the pages come from: the file, or — when it holds Keepnear's marks
  /// from before — a copy with them taken off (they are back as marks to
  /// change, and saved again into the new file).
  String? _clean;
  String get _src => _clean ?? widget.path;

  /// Marks changed since the file was opened (marks brought back don't
  /// count as changes).
  bool _inkTouched = false;

  /// Notes of other programs in the file (hover for their words).
  List<PdfNoteAt> _notes = const [];
  String get _named => widget.original ?? widget.path;

  late _Mode _mode = _office || widget.mark ? _Mode.mark : _Mode.text;

  /// The right side (hints, changes, saving) shown; folded: a thin strip,
  /// saving in the title bar.
  late bool _sideOpen = s.settings.editSideOpen;

  /// The page number in the title bar being typed (go to that page).
  bool _jumping = false;
  final TextEditingController _jumpCtl = TextEditingController();

  /// Page size: 1 = as wide as the room (up to 900); Ctrl + wheel, −/+.
  double _zoom = 1;

  /// Marks per page (the screen pen's tools).
  final Map<int, InkEditor> _eds = {};

  /// Signatures and pictures, and the one chosen.
  final List<_Put> _puts = [];
  _Put? _sel;
  String? _grab;
  Offset _grabFrom = Offset.zero;
  _Put? _grabStart;
  MouseCursor _putCursor = SystemMouseCursors.basic;

  /// One undo / redo for words, marks, signatures and pictures.
  final List<_Snap> _undo = [], _redo = [];

  /// Words changed on a scan, the one being written, and a box being drawn.
  final List<_Patch> _patches = [];
  _Patch? _patching;
  final TextEditingController _patchCtl = TextEditingController();
  Rect? _boxing;
  Offset? _boxFrom;
  bool _reading = false;
  static final WindowsOcr _ocr = WindowsOcr();

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

  /// The paragraph being changed as one (its lines, top first), or null.
  List<_Line>? _paraLines;

  /// The line / paragraph being changed is moved by this much (points).
  double _dx = 0, _dy = 0;

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
    _jumpCtl.dispose();
    for (final e in _eds.values) {
      e.dispose();
    }
    for (final p in _pics.values) {
      p.dispose();
    }
    _px.clear();
    unawaited(_doc?.dispose());
    _ctl.dispose();
    _focus.dispose();
    _hScroll.dispose();
    _vScroll.dispose();
    _patchCtl.dispose();
    if (_clean case final c?) unawaited(File(c).delete().then((_) {}, onError: (_) {}));
    super.dispose();
  }

  InkEditor _ed(int i) => _eds.putIfAbsent(
        i,
        () => InkEditor(video: false, clock: () => 0)
          ..beforeChange = () {
            _inkTouched = true;
            _mark();
          }
          ..undoAll = _undoOne
          ..redoAll = _redoOne
          ..forgetChange = () {
            if (_undo.isNotEmpty) setState(() => _undo.removeLast());
          },
      );

  _Snap _now() => _Snap(
        [for (final e in _edits) e.copy()],
        [for (final p in _puts) p.copy()],
        {for (final e in _eds.entries) e.key: [for (final m in e.value.inks) m.copy()]},
        [for (final p in _patches) p.copy()],
      );

  /// Remembers everything as it is now, before a change.
  void _mark() {
    _undo.add(_now());
    if (_undo.length > 100) _undo.removeAt(0);
    _redo.clear();
    if (mounted) setState(() {});
  }

  void _restore(_Snap w) {
    _edits
      ..clear()
      ..addAll([for (final e in w.edits) e.copy()]);
    _puts
      ..clear()
      ..addAll([for (final p in w.puts) p.copy()]);
    for (final e in _eds.entries) {
      e.value.restore(w.inks[e.key] ?? const []);
    }
    _patches
      ..clear()
      ..addAll([for (final p in w.patches) p.copy()]);
    _patching = null;
    _sel = null;
  }

  void _undoOne() {
    if (_undo.isEmpty) return;
    _cancel();
    _redo.add(_now());
    setState(() => _restore(_undo.removeLast()));
  }

  void _redoOne() {
    if (_redo.isEmpty) return;
    _cancel();
    _undo.add(_now());
    setState(() => _restore(_redo.removeLast()));
  }

  int get _markCount => _eds.values.fold(0, (n, e) => n + e.inks.length);

  /// Changes of every kind not saved yet.
  int get _changes => _edits.length + _puts.length + (_inkTouched ? math.max<int>(1, _markCount) : 0) + _patches.length;

  void _setMode(_Mode m) {
    _finishPatch();
    if (m == _Mode.sign || m == _Mode.picture) {
      // Its buttons are on the right side: shown (this time only).
      if (!_sideOpen) setState(() => _sideOpen = true);
      unawaited(_addPut(picture: m == _Mode.picture));
      return;
    }
    _done();
    setState(() {
      _mode = m;
      _sel = null;
    });
  }

  /// A signature (saved, drawn, from a file) or a picture, in the middle of
  /// the page shown; chosen, to move / size / turn.
  Future<void> _addPut({required bool picture}) async {
    _done();
    final sig = picture ? await pictureCutout(context, s) : await pickSignature(context, s);
    if (sig == null || !mounted) {
      if (mounted) setState(() => _mode = picture ? _Mode.picture : _Mode.sign);
      return;
    }
    final d = _doc;
    if (d == null) return;
    final pg = d.pages[_page];
    final w = picture ? 0.4 : 0.3;
    final h = w * pg.width / pg.height * sig.height / sig.width;
    _mark();
    final p = _Put(_page, sig, Rect.fromCenter(center: const Offset(0.5, 0.5), width: w, height: h));
    setState(() {
      _puts.add(p);
      _sel = p;
      _mode = picture ? _Mode.picture : _Mode.sign;
    });
  }

  /// The chosen one on every page too (a logo).
  void _everyPage() {
    final p = _sel, d = _doc;
    if (p == null || d == null) return;
    _mark();
    setState(() {
      for (var i = 0; i < d.pages.length; i++) {
        if (i != p.page) _puts.add(_Put(i, p.sig, p.rect, angle: p.angle));
      }
    });
  }

  /// Delete: the chosen mark (marking) or signature / picture.
  void _deleteKey() {
    final ed = _eds[_page];
    if (_mode == _Mode.mark && ed != null && ed.selected != null) {
      ed.deleteSelected();
      return;
    }
    _removeSel();
  }

  void _removeSel() {
    final p = _sel;
    if (p == null) return;
    _mark();
    setState(() {
      _puts.remove(p);
      _sel = null;
    });
  }

  // ------------------------------------------------- words on a scan

  /// A box drawn on the page (改字): its words read (Windows' own text
  /// recognition, on this PC), the paper's colour and the ink's taken from
  /// the page; then they can be written anew.
  Future<void> _scanEdit(Rect box) async {
    _done();
    _finishPatch();
    final d = _doc, pic = _pics[_page], px = _px[_page];
    if (d == null || pic == null || px == null) return;
    final pg = d.pages[_page];
    final w = pic.width, h = pic.height;
    final l = (box.left * w).floor().clamp(0, w - 1), t = (box.top * h).floor().clamp(0, h - 1);
    final r = (box.right * w).ceil().clamp(l + 1, w), b = (box.bottom * h).ceil().clamp(t + 1, h);
    int at(int x, int y) {
      final o = (y * w + x) * 4;
      return (px.getUint8(o) << 16) | (px.getUint8(o + 1) << 8) | px.getUint8(o + 2);
    }

    int lum(int c) => ((c >> 16) & 255) * 3 + ((c >> 8) & 255) * 6 + (c & 255);
    // Paper: the middle colour along the box's edge; ink: the darkest inside.
    final edge = <int>[
      for (var x = l; x < r; x += 2) ...[at(x, t), at(x, b - 1)],
      for (var y = t; y < b; y += 2) ...[at(l, y), at(r - 1, y)],
    ]..sort((a, c) => lum(a).compareTo(lum(c)));
    final bg = edge.isEmpty ? 0xFFFFFF : edge[edge.length ~/ 2];
    final inside = <int>[
      for (var y = t; y < b; y += 2)
        for (var x = l; x < r; x += 2) at(x, y),
    ]..sort((a, c) => lum(a).compareTo(lum(c)));
    final dark = inside.take(math.max(1, inside.length ~/ 12)).toList();
    var ink = 0x000000;
    if (dark.isNotEmpty && lum(bg) - lum(dark.first) > 400) {
      var rr = 0, gg = 0, bb = 0;
      for (final c in dark) {
        rr += (c >> 16) & 255;
        gg += (c >> 8) & 255;
        bb += c & 255;
      }
      ink = ((rr ~/ dark.length) << 16) | ((gg ~/ dark.length) << 8) | (bb ~/ dark.length);
    }
    setState(() => _reading = true);
    String words = '';
    try {
      // The box made larger (letters 20+ px high read best).
      const k = 2.0;
      final rec = ui.PictureRecorder();
      final c = Canvas(rec);
      final src = Rect.fromLTRB(l.toDouble(), t.toDouble(), r.toDouble(), b.toDouble());
      c.drawImageRect(pic, src, Rect.fromLTWH(0, 0, src.width * k, src.height * k), Paint()..filterQuality = FilterQuality.high);
      final im = await rec.endRecording().toImage((src.width * k).round(), (src.height * k).round());
      final png = await im.toByteData(format: ui.ImageByteFormat.png);
      im.dispose();
      final f = File('${Directory.systemTemp.path}${Platform.pathSeparator}keepnear_scan_${DateTime.now().millisecondsSinceEpoch}.png');
      await f.writeAsBytes(png!.buffer.asUint8List(), flush: true);
      words = (await _ocr.read(f.path))?.trim() ?? '';
      unawaited(f.delete().then((_) {}, onError: (_) {}));
    } catch (e) {
      DiagLog.log('tools', 'scan edit read: $e');
    }
    if (!mounted) return;
    final lines = math.max(1, '\n'.allMatches(words).length + 1);
    final size = (box.height * pg.height / lines * 0.72).clamp(5.0, 96.0);
    DiagLog.log('tools', 'scan edit: ${words.length} chars, ${size.toStringAsFixed(1)} pt');
    _mark();
    final p = _Patch(_page, box, words, bg, ink, size);
    setState(() {
      _reading = false;
      _patches.add(p);
      _patching = p;
      _patchCtl.text = words;
    });
  }

  void _startPatch(_Patch p) {
    _done();
    _finishPatch();
    setState(() {
      _patching = p;
      _patchCtl.text = p.text;
    });
  }

  /// The words written: kept (remembered for undo when changed).
  void _finishPatch() {
    final p = _patching;
    if (p == null) return;
    final t = _patchCtl.text.trimRight();
    if (t != p.text) {
      _mark();
      p.text = t;
    }
    setState(() => _patching = null);
  }

  void _patchSize(double by) {
    final p = _patching;
    if (p == null) return;
    _mark();
    setState(() => p.size = (p.size + by).clamp(4.0, 120.0));
  }

  void _dropPatch() {
    final p = _patching;
    if (p == null) return;
    _mark();
    setState(() {
      _patches.remove(p);
      _patching = null;
    });
  }

  /// The patch as a picture for the PDF (4 px per point): the paper's
  /// colour, the words on it.
  Future<PdfStamp?> _patchStamp(_Patch p, PdfPage pg) async {
    const k = 4.0;
    final w = math.max(1, (p.rect.width * pg.width * k).round()), h = math.max(1, (p.rect.height * pg.height * k).round());
    final rec = ui.PictureRecorder();
    final c = Canvas(rec);
    c.drawRect(Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()), Paint()..color = Color(0xFF000000 | p.bg));
    final tp = TextPainter(
      text: TextSpan(text: p.text, style: TextStyle(color: Color(0xFF000000 | p.color), fontSize: p.size * k, height: 1.15)),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(c, Offset(p.size * k * 0.1, math.max(0, (h - tp.height) / 2)));
    final im = await rec.endRecording().toImage(w, h);
    final bd = await im.toByteData(format: ui.ImageByteFormat.rawStraightRgba);
    im.dispose();
    if (bd == null) return null;
    final bytes = bd.buffer.asUint8List();
    for (var j = 0; j + 3 < bytes.length; j += 4) {
      final r = bytes[j];
      bytes[j] = bytes[j + 2];
      bytes[j + 2] = r;
    }
    return PdfStamp(bytes, w, h, p.rect);
  }

  /// A patch on the page: shown, or being written.
  List<Widget> _patchViews(Size size, double scale) => [
        for (final p in _patches)
          if (p.page == _page)
            Positioned(
              left: p.rect.left * size.width,
              top: p.rect.top * size.height,
              width: p.rect.width * size.width,
              height: p.rect.height * size.height,
              child: identical(p, _patching)
                  ? Container(
                      color: Color(0xFF000000 | p.bg),
                      child: TextField(
                        controller: _patchCtl,
                        autofocus: true,
                        maxLines: null,
                        expands: true,
                        style: TextStyle(color: Color(0xFF000000 | p.color), fontSize: p.size * scale, height: 1.15),
                        decoration: const InputDecoration(
                          isDense: true,
                          contentPadding: EdgeInsets.zero,
                          border: OutlineInputBorder(borderSide: BorderSide(color: LightLook.blue)),
                          focusedBorder: OutlineInputBorder(borderSide: BorderSide(color: LightLook.blue, width: 2)),
                        ),
                      ),
                    )
                  : MouseRegion(
                      cursor: _mode == _Mode.text ? SystemMouseCursors.text : MouseCursor.defer,
                      child: GestureDetector(
                        onTap: _mode == _Mode.text ? () => _startPatch(p) : null,
                        child: Container(
                          color: Color(0xFF000000 | p.bg),
                          padding: EdgeInsets.only(left: p.size * scale * 0.1),
                          alignment: Alignment.centerLeft,
                          child: ClipRect(
                            child: Text(p.text,
                                softWrap: false,
                                overflow: TextOverflow.visible,
                                style: TextStyle(color: Color(0xFF000000 | p.color), fontSize: p.size * scale, height: 1.15)),
                          ),
                        ),
                      ),
                    ),
            ),
        // The bar over the one being written.
        for (final p in _patches)
          if (identical(p, _patching) && p.page == _page)
            Positioned(
              left: p.rect.left * size.width,
              top: p.rect.top * size.height - 40,
              child: Material(
                elevation: 3,
                borderRadius: BorderRadius.circular(8),
                color: Colors.white,
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  IconButton(tooltip: 'A−', onPressed: () => _patchSize(-1), icon: const Icon(Icons.text_decrease_rounded, size: 18)),
                  Text('${p.size.toStringAsFixed(0)} pt', style: const TextStyle(fontSize: 12, color: LightLook.muted)),
                  IconButton(tooltip: 'A+', onPressed: () => _patchSize(1), icon: const Icon(Icons.text_increase_rounded, size: 18)),
                  IconButton(
                    tooltip: tr('pdf.sign_remove'),
                    onPressed: _dropPatch,
                    icon: const Icon(Icons.delete_outline_rounded, size: 18, color: Color(0xFFE5484D)),
                  ),
                  TextButton(onPressed: _finishPatch, child: Text(tr('pdfedit.done'))),
                ]),
              ),
            ),
      ];

  /// 改字: a box drawn where there are no words to click (a scan).
  Widget _boxLayer(Size size) => GestureDetector(
        behavior: HitTestBehavior.translucent,
        onPanStart: (e) {
          if (_reading) return;
          _finishPatch();
          _boxFrom = Offset(e.localPosition.dx / size.width, e.localPosition.dy / size.height);
        },
        onPanUpdate: (e) {
          final f = _boxFrom;
          if (f == null) return;
          final p = Offset((e.localPosition.dx / size.width).clamp(0.0, 1.0), (e.localPosition.dy / size.height).clamp(0.0, 1.0));
          setState(() => _boxing = Rect.fromPoints(f, p));
        },
        onPanEnd: (_) {
          final r = _boxing;
          _boxFrom = null;
          setState(() => _boxing = null);
          if (r != null && r.width * size.width > 8 && r.height * size.height > 6) unawaited(_scanEdit(r));
        },
        child: CustomPaint(
          size: Size.infinite,
          painter: _BoxPaint(_boxing == null
              ? null
              : Rect.fromLTRB(_boxing!.left * size.width, _boxing!.top * size.height, _boxing!.right * size.width, _boxing!.bottom * size.height)),
        ),
      );

  Future<void> _open() async {
    try {
      // Keepnear's marks saved in the file earlier: taken off the pages and
      // brought back as marks that can be changed.
      final clean = '${Directory.systemTemp.path}${Platform.pathSeparator}keepnear_clean_${DateTime.now().microsecondsSinceEpoch}.pdf';
      final marks = _office ? null : await PdfBuilder.cleanMarks(widget.path, clean);
      final old = _clean;
      _clean = marks == null ? null : clean;
      if (old != null) unawaited(File(old).delete().then((_) {}, onError: (_) {}));
      final d = await openPdfLoose(_src);
      if (!mounted) {
        await d.dispose();
        return;
      }
      if (marks != null) {
        for (final m in marks.entries) {
          if (m.key < d.pages.length) _ed(m.key).restore(unpackMarks(m.value));
        }
        DiagLog.log('tools', 'pdf edit: marks of ${marks.length} page(s) back to change');
      }
      _inkTouched = false;
      final notes = await PdfBuilder.notesOf(_src);
      if (mounted) _notes = notes;
      final at = _page == 0 ? widget.page.clamp(0, d.pages.length - 1) : _page.clamp(0, d.pages.length - 1);
      setState(() {
        _doc = d;
        _page = at;
      });
      await _load(at);
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
    // How the text is drawn (font, size, bold, italic, colour).
    final styles = await PdfBuilder.styles(_src, i);
    final lines = await _readLines(page, i, styles);
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
  /// starts a new one, so each can be changed alone. A line drawn in two
  /// looks (a red amount after black words, bold then plain) is cut where
  /// the look changes: each part changed keeps its own colour and font.
  Future<List<_Line>> _readLines(PdfPage page, int index, List<PdfTextStyle> styles) async {
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

    // The look of the text object a letter belongs to (null: can't tell).
    String? lookOf((int, PdfRect) c) {
      final r = c.$2;
      if (r.width <= 0.1 || r.height <= 0.1 || c.$1 <= 32) return null;
      final cx = (r.left + r.right) / 2, cy = (r.top + r.bottom) / 2;
      PdfTextStyle? hit;
      for (final st in styles) {
        if (cx >= st.l - 0.5 && cx <= st.r + 0.5 && cy >= st.b - 0.5 && cy <= st.t + 0.5) {
          // The smallest object holding it (a word inside a line object).
          if (hit == null || (st.r - st.l) < (hit.r - hit.l)) hit = st;
        }
      }
      if (hit == null) return null;
      return '${hit.font}|${hit.rgb}|${hit.weight >= 600}|${hit.italic}|${hit.size.round()}';
    }

    void emit(List<(int, PdfRect)> part) {
      final seen = [for (final c in part) if (c.$2.width > 0.1 && c.$2.height > 0.1 && c.$1 > 32) c];
      final text = String.fromCharCodes([for (final c in part) c.$1]).trim();
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

    void flush() {
      final all = cur;
      cur = [];
      if (all.isEmpty) return;
      // Cut where the look changes (spaces go with the letters before).
      var part = <(int, PdfRect)>[];
      String? look;
      for (final c in all) {
        final k = lookOf(c);
        if (k != null && look != null && k != look && part.isNotEmpty) {
          emit(part);
          part = [];
        }
        if (k != null) look = k;
        part.add(c);
      }
      emit(part);
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

  _Edit? _editOf(_Line l) => _edits.where((e) => identical(e.line, l) || (e.para?.any((x) => identical(x, l)) ?? false)).firstOrNull;

  // ------------------------------------------------ laying the words out

  final Map<String, double> _widths = {};

  /// [text]'s width on screen at [size] points (in points), in [family].
  double _measure(String text, double size, String family, bool bold, bool italic) {
    final key = '$family|$size|$bold|$italic|$text';
    return _widths[key] ??= () {
      final tp = TextPainter(
        text: TextSpan(
          text: text,
          style: TextStyle(
            fontSize: size,
            fontFamily: family,
            fontWeight: bold ? FontWeight.w700 : FontWeight.w400,
            fontStyle: italic ? FontStyle.italic : FontStyle.normal,
          ),
        ),
        textDirection: TextDirection.ltr,
        maxLines: 1,
      )..layout();
      final w = tp.width;
      tp.dispose();
      return w;
    }();
  }

  /// The paragraph [l] is in: lines above / below it on its page that line
  /// up on the left, are about as big and follow at a line's distance.
  List<_Line> _paraOf(_Line l) {
    final all = [...?_lines[l.page]]..sort((a, b) => b.base.compareTo(a.base));
    bool near(_Line a, _Line b) =>
        (a.box.left - b.box.left).abs() < math.max(a.size, b.size) * 1.2 &&
        (a.size - b.size).abs() < math.max(a.size, b.size) * 0.15 &&
        (a.base - b.base).abs() > a.size * 0.8 &&
        (a.base - b.base).abs() < a.size * 2.0;
    final out = [l];
    // Up, then down: each next line close to the one before.
    var cur = l;
    for (final x in all.where((x) => x.base > l.base).toList().reversed) {
      if (!near(cur, x)) break;
      out.insert(0, x);
      cur = x;
    }
    cur = l;
    for (final x in all.where((x) => x.base < l.base)) {
      if (!near(cur, x)) break;
      out.add(x);
      cur = x;
    }
    return out;
  }

  /// How far to the right [l]'s words may go before they run into the
  /// text beside it (page points); [x] where they start now.
  double _roomRight(_Line l, double x, double pageWidth, {bool moved = false}) {
    var limit = pageWidth - 18;
    if (!moved) {
      for (final o in _lines[l.page] ?? const <_Line>[]) {
        if (identical(o, l) || o.box.left < l.box.right - 1) continue;
        final overlap = math.min(o.box.top, l.box.top) - math.max(o.box.bottom, l.box.bottom);
        if (overlap > (l.box.top - l.box.bottom) * 0.5 && o.box.left - 2 < limit) limit = o.box.left - 2;
      }
    }
    return math.max(limit - x, 10);
  }

  static bool _cjkText(String s) => s.runes.any(PdfFonts.isCjk);

  /// Where [e]'s words go: a line squeezed a little when it grew past the
  /// text beside it (letters narrower first, then smaller; not below 75%);
  /// a paragraph laid out again inside its lines' area (smaller, down to
  /// 85%, only when it doesn't fit).
  _Layout _layout(_Edit e, {String? text, double? size, bool? bold, bool? italic, List<_Line>? para, double? dx, double? dy}) {
    final t = text ?? e.text;
    final sz = size ?? e.size;
    final b = bold ?? e.bold, it = italic ?? e.italic;
    final lines = para ?? e.para ?? [e.line];
    final mx = dx ?? e.dx, my = dy ?? e.dy;
    final pw = (_doc?.pages[e.line.page].width ?? 600).toDouble();
    final fam = _screenFamily(t, e.from);
    // Screen widths → the PDF's (its font is not the one shown).
    var shown = 0.0, real = 0.0;
    for (final l in lines) {
      final w = _measure(l.text, l.size, _screenFamily(l.text, l), b, it);
      if (w > 0) {
        shown += w;
        real += l.box.width;
      }
    }
    final k = shown > 0 && real > 0 ? (real / shown).clamp(0.5, 2.0) : 1.0;
    double width(String s, double z) => _measure(s, z, fam, b, it) * k;
    if (lines.length == 1) {
      final l = lines.first;
      final x = l.box.left + mx, base = l.base - my;
      final room = _roomRight(l, x, pw, moved: mx != 0 || my != 0);
      final need = width(t, sz);
      if (need <= room || t.isEmpty) return _Layout([_Out(t, x, base, sz, 1)], 1, false);
      final f = room / need;
      if (f >= 0.85) return _Layout([_Out(t, x, base, sz, f)], f, false);
      final g = math.max(f, 0.75);
      return _Layout([_Out(t, x, base, sz * g / 0.85, 0.85)], g, f < 0.75);
    }
    // A paragraph: its area, its line distance.
    final x0 = lines.map((l) => l.box.left).reduce(math.min) + mx;
    final w = lines.map((l) => l.box.right).reduce(math.max) - lines.map((l) => l.box.left).reduce(math.min);
    final top = lines.first.base - my;
    final pitch = (lines.first.base - lines.last.base) / (lines.length - 1);
    List<String> wrap(double z) {
      final out = <String>[];
      for (final hard in t.split('\n')) {
        var cur = '';
        // CJK breaks between any two letters; other text at spaces.
        final parts = _cjkText(hard) ? hard.split('') : hard.split(RegExp(r'(?<= )'));
        for (final piece in parts) {
          final next = cur + piece;
          if (cur.isNotEmpty && width(next.trimRight(), z) > w) {
            out.add(cur.trimRight());
            cur = piece.trimLeft();
          } else {
            cur = next;
          }
        }
        out.add(cur.trimRight());
      }
      return out;
    }

    var scale = 1.0;
    var rows = wrap(sz);
    while (rows.length > lines.length && scale > 0.851) {
      scale -= 0.05;
      rows = wrap(sz * scale);
    }
    return _Layout([
      for (var i = 0; i < rows.length; i++) _Out(rows[i], x0, top - i * pitch * scale, sz * scale, 1),
    ], scale, rows.length > lines.length);
  }

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
    final text = _paraLines == null ? _ctl.text.replaceAll('\n', ' ').trimRight() : _ctl.text.trimRight();
    final e = _editOf(l);
    if (e != null) {
      return text != e.text ||
          _size != e.size ||
          _bold != e.bold ||
          _italic != e.italic ||
          !identical(_from ?? l, e.from) ||
          _dx != e.dx ||
          _dy != e.dy ||
          !identical(_paraLines, e.para);
    }
    final (size, bold, italic, _) = _lookOf(l);
    return text != l.text ||
        _size != size ||
        _bold != bold ||
        _italic != italic ||
        !identical(_from ?? l, l) ||
        _dx != 0 ||
        _dy != 0 ||
        _paraLines != null;
  }

  /// Something not saved yet (done, or still being typed).
  bool get _unsaved => _changes > 0 || _typing;

  void _start(_Line l) {
    final e = _editOf(l);
    if (e != null) l = e.line;
    final (size, bold, italic, color) = _lookOf(l);
    setState(() {
      _brush = false;
      _editing = l;
      _paraLines = e?.para;
      _dx = e?.dx ?? 0;
      _dy = e?.dy ?? 0;
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
    if (_editing != null) {
      setState(() {
        _editing = _from = null;
        _paraLines = null;
        _dx = _dy = 0;
      });
    }
    _bar.hide();
  }

  /// The line being changed becomes its whole paragraph (or back).
  void _togglePara() {
    final l = _editing;
    if (l == null) return;
    setState(() {
      if (_paraLines != null) {
        _paraLines = null;
        _ctl.text = l.text;
      } else {
        final p = _paraOf(l);
        if (p.length < 2) return;
        _paraLines = p;
        _editing = p.first;
        _ctl.text = _joinPara(p);
      }
      _ctl.selection = TextSelection(baseOffset: 0, extentOffset: _ctl.text.length);
    });
    _focus.requestFocus();
  }

  /// A paragraph's lines as one text (CJK joined straight, others with a
  /// space; a hyphen at a line's end joins the word).
  static String _joinPara(List<_Line> p) {
    final b = StringBuffer();
    for (var i = 0; i < p.length; i++) {
      var s = p[i].text;
      if (i > 0) {
        final prev = b.toString();
        final cjk = prev.isNotEmpty && PdfFonts.isCjk(prev.runes.last) && s.isNotEmpty && PdfFonts.isCjk(s.runes.first);
        if (prev.endsWith('-')) {
          b.clear();
          b.write(prev.substring(0, prev.length - 1));
        } else if (!cjk) {
          b.write(' ');
        }
      }
      b.write(s);
    }
    return b.toString();
  }

  void _done() {
    final l = _editing;
    if (l == null) return;
    final para = _paraLines;
    final text = para == null ? _ctl.text.replaceAll('\n', ' ').trimRight() : _ctl.text.trimRight();
    final (size, bold, italic, _) = _lookOf(l);
    final e0 = _editOf(l);
    final still = _dx == 0 && _dy == 0 && para == null;
    final same0 = still && text == l.text && _size == size && _bold == bold && _italic == italic && identical(_from ?? l, l);
    final unchanged = e0 == null
        ? same0
        : text == e0.text &&
            _size == e0.size &&
            _bold == e0.bold &&
            _italic == e0.italic &&
            _color == e0.color &&
            identical(_from ?? l, e0.from) &&
            _dx == e0.dx &&
            _dy == e0.dy &&
            identical(para, e0.para);
    if (!unchanged) _mark();
    setState(() {
      final e = _editOf(l);
      // A paragraph changed now replaces changes made in its lines alone.
      if (para != null) _edits.removeWhere((x) => !identical(x, e) && x.lines.any((y) => para.any((z) => identical(y, z))));
      final same = still && text == l.text && _size == size && _bold == bold && _italic == italic && identical(_from ?? l, l);
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
          ..from = _from ?? l
          ..para = para
          ..dx = _dx
          ..dy = _dy;
      } else {
        _edits.add(_Edit(l, text, _size, _bold, _italic, _color, _from ?? l, para: para, dx: _dx, dy: _dy));
      }
      _editing = null;
      _from = null;
      _paraLines = null;
      _dx = _dy = 0;
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
    _finishPatch();
    final d = _doc;
    if (d == null || _changes == 0) return false;
    DiagLog.log('tools',
        'pdf edit save: ${_edits.length} word change(s), $_markCount mark(s), ${_puts.length} signature(s)/picture(s), ${replace ? 'replace' : 'new file'}');
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
      final plain = e.text.replaceAll('\n', '');
      // Lines added below a paragraph (it grew) are written first: the
      // old text whose font they copy is still there then.
      String? addFont;
      if (_canReuse(plain, e.from, e.line, e.bold, e.italic)) {
        final st = e.from.style!;
        final at = 'objat:${(st.l + st.r) / 2},${(st.b + st.t) / 2}';
        font = identical(e.from, e.line) ? 'obj' : at;
        addFont = at;
      } else {
        final c = await PdfFonts.pick(plain, like: e.from.style?.name, bold: e.bold, italic: e.italic);
        font = c?.path ?? '';
        if (e.bold && !(c?.hasBold ?? false)) fake |= 1;
        if (e.italic && !(c?.hasItalic ?? false)) fake |= 2;
      }
      final lay = _layout(e);
      final rgb = e.color == null ? 'auto' : _hex(e.color!);
      final list = made[e.line.page] ??= [];
      final lines = e.lines;
      for (var i = lines.length; i < lay.out.length; i++) {
        final o = lay.out[i];
        list.insert(
            0,
            PdfTextEdit(
              l: 0, b: 0, r: 0, t: 0, x: o.x, base: o.base, size: o.size,
              // "obj" has no old text to copy here: the paragraph's first line's.
              font: addFont ?? font, text: o.text, rgb: rgb == 'auto' ? _hex(_lookOf(e.line).$4 ?? const Color(0xFF000000)) : rgb,
              fake: fake, hscale: o.hscale, add: true,
            ));
      }
      for (var i = 0; i < lines.length; i++) {
        final l = lines[i];
        final o = i < lay.out.length ? lay.out[i] : null;
        list.add(PdfTextEdit(
          l: l.box.left,
          b: l.box.bottom,
          r: l.box.right,
          t: l.box.top,
          x: o?.x ?? l.box.left,
          base: o?.base ?? l.base,
          size: o?.size ?? e.size,
          font: font,
          // Nothing left for this line: its old words just go.
          text: o?.text ?? '',
          // The colour the old words had (red stays red), or the brushed one.
          rgb: rgb,
          fake: fake,
          hscale: o?.hscale ?? 1,
        ));
      }
    }
    DiagLog.log('tools', 'pdf edit fonts: ${[for (final p in made.values) for (final e in p) e.font.isEmpty ? '?' : e.font.split(r'\\').last].join(', ')}');
    // Marks: one see-through picture per page (about 200 dpi) and the
    // numbers' notes; signatures and pictures each laid where they are.
    final plan = <PdfPlanPage>[];
    for (var i = 0; i < d.pages.length; i++) {
      final stamps = <PdfStamp>[];
      var notes = const <PdfNote>[];
      final ed = _eds[i];
      if (ed != null && !ed.isEmpty) {
        final pg = d.pages[i];
        const k = 200 / 72;
        final w = (pg.width * k).round(), h = (pg.height * k).round();
        final rec = ui.PictureRecorder();
        final c = Canvas(rec);
        for (final m in ed.inks) {
          InkGeometry.paint(c, Size(w.toDouble(), h.toDouble()), m);
        }
        final im = await rec.endRecording().toImage(w, h);
        final bd = await im.toByteData(format: ui.ImageByteFormat.rawStraightRgba);
        im.dispose();
        final b = bd!.buffer.asUint8List();
        for (var j = 0; j + 3 < b.length; j += 4) {
          final r = b[j];
          b[j] = b[j + 2];
          b[j + 2] = r;
        }
        stamps.add(PdfStamp(b, w, h, const Rect.fromLTWH(0, 0, 1, 1), marks: true));
        notes = [
          for (final m in ed.inks)
            if (m.tool == InkTool.number && (m.note ?? '').isNotEmpty && m.points.isNotEmpty)
              numberNote(m, d.pages[i].width, d.pages[i].height),
        ];
      }
      for (final p in _patches) {
        if (p.page != i) continue;
        final st = await _patchStamp(p, d.pages[i]);
        if (st != null) stamps.add(st);
      }
      for (final p in _puts) {
        if (p.page != i) continue;
        final px = await p.sig.bgra();
        if (px != null) stamps.add(PdfStamp(px, p.sig.width, p.sig.height, p.rect, angle: p.angle));
      }
      final ink = _eds[i];
      plan.add(PdfFromDoc(_src, i,
          edits: made[i] ?? const [],
          stamps: stamps,
          notes: notes,
          // The marks kept too: changed again when the file is edited again.
          marks: ink == null || ink.isEmpty ? null : packMarks(ink.inks)));
    }
    if (!mounted) return false;
    final out = replace ? '${widget.path}.lr-edit.pdf' : toolOutPath(s, _named, tr('pdfedit.suffix'), 'pdf');
    final n = _changes;
    String? err;
    // Saving over the file failed (held open elsewhere, e.g. in WPS): the
    // changes kept as a new file instead.
    String? beside;
    var skipped = 0;
    await runBusy(context, tr('pdf.saving'), () async {
      err = await PdfBuilder.build(out, plan);
      skipped = PdfBuilder.lastSkipped;
      if (err == null && replace) {
        // The open copy lets go first (it is read into memory anyway).
        await _doc?.dispose();
        _doc = null;
        if (!await replaceFileWith(out, widget.path)) {
          final alt = toolOutPath(s, _named, tr('pdfedit.suffix'), 'pdf');
          beside = await replaceFileWith(out, alt) ? alt : out;
        }
      }
    });
    DiagLog.log('tools', 'pdf edit saved: ${err ?? 'ok'}, skipped $skipped${beside == null ? '' : ', beside: $beside'}');
    if (!mounted) {
      if (err == null && (!replace || beside != null)) await s.tools.saved([beside ?? out]);
      return err == null;
    }
    if (err != null) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(tr('tool.failed', {'why': err!}))));
      return false;
    }
    final note = skipped > 0 ? tr('pdfedit.skipped', {'count': skipped, 'all': n}) : null;
    final kept = beside;
    if (kept != null) {
      // The file as it was, shown again; the changes are in [kept].
      await _open();
      if (!mounted) return true;
      setState(_clearAll);
      widget.onSaved?.call(kept);
      final name = kept.split(RegExp(r'[\\/]')).last;
      await showToolResult(context, s, [kept], note: tr('pdfedit.replace_busy', {'name': name}));
      return true;
    }
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
        _clearAll();
      });
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(note ?? tr('pdfedit.replaced'))));
      widget.onSaved?.call(widget.path);
      await _open();
      return true;
    }
    // Saved as a new file: the changes are in it, nothing left to keep.
    setState(_clearAll);
    widget.onSaved?.call(out);
    await showToolResult(context, s, [out], note: note);
    return true;
  }

  /// Everything saved (or dropped): nothing left to keep or undo.
  void _clearAll() {
    _inkTouched = false;
    _patches.clear();
    _patching = null;
    _edits.clear();
    _puts.clear();
    _sel = null;
    for (final e in _eds.values) {
      e.restore(const []);
    }
    _undo.clear();
    _redo.clear();
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
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.keyZ, control: true): _undoOne,
          const SingleActivator(LogicalKeyboardKey.keyY, control: true): _redoOne,
          const SingleActivator(LogicalKeyboardKey.keyZ, control: true, shift: true): _redoOne,
        },
        child: Focus(
          autofocus: true,
          // Delete: the chosen mark / signature away; marking: a chosen
          // number changes with a digit key. Typing in a box: its own keys.
          onKeyEvent: (node, e) {
            if (e is! KeyDownEvent || inkTyping()) return KeyEventResult.ignored;
            if (e.logicalKey == LogicalKeyboardKey.delete) {
              _deleteKey();
              return KeyEventResult.handled;
            }
            if (_mode != _Mode.mark) return KeyEventResult.ignored;
            final digit = inkDigitOf(e.logicalKey);
            if (digit != null && _ed(_page).typeDigit(digit)) return KeyEventResult.handled;
            return KeyEventResult.ignored;
          },
          child: Theme(
      data: LightLook.theme(Theme.of(context)),
      child: Scaffold(
        backgroundColor: LightLook.page,
        appBar: AppBar(automaticallyImplyLeading: false,
          backgroundColor: Colors.white,
          title: Text('${tr('edit.title')} · ${_named.split(Platform.pathSeparator).last}', overflow: TextOverflow.ellipsis),
          actions: [
            if (d != null) ...[
              IconButton(onPressed: _page > 0 ? () => _go(_page - 1) : null, icon: const Icon(Icons.chevron_left_rounded)),
              _pageJump(d),
              IconButton(onPressed: _page < d.pages.length - 1 ? () => _go(_page + 1) : null, icon: const Icon(Icons.chevron_right_rounded)),
            ],
            // The right side folded: saving here.
            if (d != null && !_sideOpen) ...[
              const SizedBox(width: 8),
              FilledButton.tonal(onPressed: _unsaved ? () => _save(replace: false) : null, child: Text(tr('pdfedit.save_new'))),
              if (!_office)
                PopupMenuButton<String>(
                  enabled: _unsaved,
                  icon: const Icon(Icons.arrow_drop_down_rounded),
                  onSelected: (_) => unawaited(_confirmReplace()),
                  itemBuilder: (_) => [PopupMenuItem(value: 'over', child: Text(tr('pdfedit.save_over')))],
                ),
            ],
            const SizedBox(width: 12),
          ],
        ),
        body: _error != null
            ? Center(child: Text(tr('pdfedit.cannot_open'), style: const TextStyle(color: LightLook.muted)))
            : d == null
                ? const Center(child: CircularProgressIndicator())
                : Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                        _modeBar(),
                        if (_mode == _Mode.mark)
                          InkToolbar(
                            editor: _ed(_page),
                            doneLabel: tr('pdfedit.save_new'),
                            onDone: () => unawaited(_save(replace: false)),
                          ),
                        Expanded(child: _pageView(d)),
                      ]),
                    ),
                    _sideStrip(),
                    if (_sideOpen) SizedBox(width: 320, child: _side(d)),
                  ]),
      ),
      ),
        ),
      ),
    );
  }

  /// 改字 | 标注 | 签名 | 插图片 — undo / redo — page size.
  Widget _modeBar() {
    Widget mode(_Mode m, IconData icon, String label, Color color) {
      final on = _mode == m;
      return Padding(
        padding: const EdgeInsets.only(right: 8),
        child: FilledButton.tonalIcon(
          style: FilledButton.styleFrom(
            backgroundColor: on ? color : Colors.white,
            foregroundColor: on ? Colors.white : color,
            side: BorderSide(color: color.withValues(alpha: on ? 1 : 0.4)),
          ),
          onPressed: () => _setMode(m),
          icon: Icon(icon, size: 18),
          label: Text(label),
        ),
      );
    }

    return Container(
      color: Colors.white,
      padding: const EdgeInsets.fromLTRB(16, 8, 12, 8),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(children: [
        if (!_office) mode(_Mode.text, Icons.edit_note_rounded, tr('pdfedit.title'), LightLook.blue),
        mode(_Mode.mark, Icons.gesture_rounded, tr('ann.title'), const Color(0xFFE5484D)),
        mode(_Mode.sign, Icons.draw_rounded, tr('pdf.sign'), const Color(0xFF7B4DEB)),
        mode(_Mode.picture, Icons.add_photo_alternate_outlined, tr('pdf.add_picture'), const Color(0xFF0E9F6E)),
        const SizedBox(width: 8),
        IconButton(tooltip: '${tr('pdf.undo')} (Ctrl+Z)', onPressed: _undo.isEmpty ? null : _undoOne, icon: const Icon(Icons.undo_rounded)),
        IconButton(tooltip: '${tr('pdf.redo')} (Ctrl+Y)', onPressed: _redo.isEmpty ? null : _redoOne, icon: const Icon(Icons.redo_rounded)),
        const SizedBox(width: 24),
        // Page size.
        IconButton(
          tooltip: '−',
          onPressed: _zoom > 0.4 ? () => setState(() => _zoom = (_zoom / 1.2).clamp(0.3, 6.0)) : null,
          icon: const Icon(Icons.zoom_out_rounded),
        ),
        SizedBox(width: 48, child: Text('${(_zoom * 100).round()}%', textAlign: TextAlign.center, style: const TextStyle(color: LightLook.muted))),
        IconButton(
          tooltip: '+',
          onPressed: _zoom < 6 ? () => setState(() => _zoom = (_zoom * 1.2).clamp(0.3, 6.0)) : null,
          icon: const Icon(Icons.zoom_in_rounded),
        ),
        TextButton(onPressed: () => setState(() => _zoom = 1), child: Text(tr('edit.zoom_fit'))),
        TextButton(onPressed: () => setState(() => _zoom = 2), child: const Text('200%')),
        TextButton(onPressed: () => setState(() => _zoom = 3), child: const Text('300%')),
      ]),
      ),
    );
  }

  /// Leaving with changes not saved: save, drop them, or stay.
  Future<void> _leave() async {
    _done();
    _finishPatch();
    final n = _changes;
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
    setState(_clearAll);
    Navigator.of(context).pop();
  }

  final _hScroll = ScrollController(), _vScroll = ScrollController();

  Widget _pageView(PdfDocument d) {
    final page = d.pages[_page];
    final pic = _pics[_page];
    final lines = _lines[_page] ?? const [];
    return LayoutBuilder(builder: (context, box) {
      final w = (box.maxWidth - 48).clamp(300.0, 900.0) * _zoom;
      final scale = w / page.width;
      final size = Size(w, page.height * scale);
      Rect at(PdfRect r) => r.toRect(page: page, scaledPageSize: size);
      final ed = _ed(_page);
      final putting = _mode == _Mode.sign || _mode == _Mode.picture;
      final content = Container(
        width: size.width,
        height: size.height,
        decoration: const BoxDecoration(color: Colors.white, boxShadow: [BoxShadow(color: Color(0x261F3B70), blurRadius: 24, offset: Offset(0, 8))]),
        child: pic == null
            ? const Center(child: CircularProgressIndicator())
            : Stack(clipBehavior: Clip.none, children: [
                Positioned.fill(child: RawImage(image: pic, fit: BoxFit.fill)),
                // Changed lines: the old words covered, the new shown.
                for (final e in _edits)
                  if (e.line.page == _page && !identical(e.line, _editing)) ..._preview(e, at, scale, page.height),
                // Signatures and pictures.
                for (final p in _puts)
                  if (p.page == _page)
                    Positioned(
                      left: p.rect.left * size.width,
                      top: p.rect.top * size.height,
                      width: p.rect.width * size.width,
                      height: p.rect.height * size.height,
                      child: IgnorePointer(
                        child: Transform.rotate(angle: p.angle, child: Image.memory(p.sig.png, fit: BoxFit.fill)),
                      ),
                    ),
                // Marks: drawn on only while marking.
                Positioned.fill(
                  child: IgnorePointer(
                    ignoring: _mode != _Mode.mark,
                    child: InkLayer(key: ValueKey('ink$_page'), notes: const [], video: false, editor: ed),
                  ),
                ),
                Positioned.fill(child: NumberNotes(marks: () => ed.inks, repaint: ed)),
                // Other programs' notes: hover for their words.
                ...noteMarkers(context, [for (final n in _notes) if (n.page == _page) n], size),
                // Words on a scan (or in a picture): covered and written anew.
                ..._patchViews(size, scale),
                // 改字 where no line can be clicked: draw a box.
                if (_mode == _Mode.text && _patching == null) Positioned.fill(child: _boxLayer(size)),
                if (_reading) const Positioned.fill(child: Center(child: CircularProgressIndicator())),
                // Changing words: every line can be clicked.
                if (_mode == _Mode.text)
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
                // Signatures and pictures: choose, move, size, turn.
                if (putting) Positioned.fill(child: _putLayer(size)),
                if (_mode == _Mode.text)
                  if (_editing case final l? when l.page == _page) ..._editor(l, _editRect(l, at), scale, size),
              ]),
      );
      return Listener(
        // Ctrl + wheel: the page bigger / smaller.
        onPointerSignal: (e) {
          if (e is PointerScrollEvent && HardwareKeyboard.instance.isControlPressed) {
            GestureBinding.instance.pointerSignalResolver.register(e, (ev) {
              if (ev is PointerScrollEvent) setState(() => _zoom = (_zoom * (ev.scrollDelta.dy < 0 ? 1.1 : 1 / 1.1)).clamp(0.3, 6.0));
            });
          }
        },
        child: Scrollbar(
          controller: _vScroll,
          child: SingleChildScrollView(
            controller: _vScroll,
            child: Scrollbar(
              controller: _hScroll,
              notificationPredicate: (n) => n.depth == 0,
              child: SingleChildScrollView(
                controller: _hScroll,
                scrollDirection: Axis.horizontal,
                child: ConstrainedBox(
                  constraints: BoxConstraints(minWidth: box.maxWidth),
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Center(child: content),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    });
  }

  /// The chosen signature / picture: its corners and its turning knob, in
  /// pixels of the page shown.
  (List<Offset>, Offset, Offset) _handles(_Put p, Size size) {
    final c = Offset(p.rect.center.dx * size.width, p.rect.center.dy * size.height);
    final bw = p.rect.width * size.width, bh = p.rect.height * size.height;
    final cs = math.cos(p.angle), sn = math.sin(p.angle);
    Offset turn(double x, double y) => c + Offset(x * cs - y * sn, x * sn + y * cs);
    return ([turn(-bw / 2, -bh / 2), turn(bw / 2, -bh / 2), turn(bw / 2, bh / 2), turn(-bw / 2, bh / 2)], turn(0, -bh / 2 - 26), c);
  }

  bool _onPut(_Put p, Offset at, Size size) {
    final c = Offset(p.rect.center.dx * size.width, p.rect.center.dy * size.height);
    final d = at - c;
    final cs = math.cos(-p.angle), sn = math.sin(-p.angle);
    final x = d.dx * cs - d.dy * sn, y = d.dx * sn + d.dy * cs;
    return x.abs() <= p.rect.width * size.width / 2 + 4 && y.abs() <= p.rect.height * size.height / 2 + 4;
  }

  static double _snap(double a) {
    final q = (a / (math.pi / 2)).roundToDouble() * (math.pi / 2);
    return (a - q).abs() < 3 * math.pi / 180 ? q : a;
  }

  Widget _putLayer(Size size) {
    final sel = _sel != null && _sel!.page == _page ? _sel : null;
    final h = sel == null ? null : _handles(sel, size);
    _Put? hit(Offset at) => _puts.reversed.where((p) => p.page == _page && _onPut(p, at, size)).firstOrNull;
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onTapDown: (e) => setState(() => _sel = hit(e.localPosition) ?? (h != null && (e.localPosition - h.$2).distance < 14 ? sel : null)),
      onPanStart: (e) {
        final at = e.localPosition;
        _grab = null;
        var p = sel;
        if (p != null && h != null && (at - h.$2).distance < 14) {
          _grab = 'turn';
        } else if (p != null && h != null && h.$1.any((q) => (at - q).distance < 14)) {
          _grab = 'size';
        } else {
          p = hit(at);
          if (p != null) _grab = 'move';
        }
        if (p == null || _grab == null) return;
        _mark();
        setState(() => _sel = p);
        _grabFrom = at;
        _grabStart = p.copy();
      },
      onPanUpdate: (e) {
        final p = _sel, st = _grabStart;
        if (p == null || st == null || _grab == null) return;
        final at = e.localPosition;
        final c = Offset(st.rect.center.dx * size.width, st.rect.center.dy * size.height);
        setState(() {
          switch (_grab) {
            case 'move':
              final dx = (at.dx - _grabFrom.dx) / size.width, dy = (at.dy - _grabFrom.dy) / size.height;
              p.rect = st.rect.shift(Offset(dx, dy));
            case 'size':
              final r0 = (_grabFrom - c).distance;
              if (r0 > 1) {
                final k = ((at - c).distance / r0).clamp(0.05, 20.0);
                final w = (st.rect.width * k).clamp(0.02, 1.5), hh = st.rect.height * w / st.rect.width;
                p.rect = Rect.fromCenter(center: st.rect.center, width: w, height: hh);
              }
            case 'turn':
              final v = at - c;
              p.angle = _snap(math.atan2(v.dy, v.dx) + math.pi / 2);
          }
        });
      },
      onPanEnd: (_) {
        _grab = null;
        _grabStart = null;
      },
      child: MouseRegion(
        // The pointer's shape: slanted arrows on corners, four arrows on
        // the knob, a hand on a signature / picture.
        cursor: _putCursor,
        onHover: (e) {
          final at = e.localPosition;
          var c = SystemMouseCursors.basic;
          if (sel != null && h != null && (at - h.$2).distance < 14) {
            c = SystemMouseCursors.move;
          } else if (sel != null && h != null && h.$1.any((q) => (at - q).distance < 14)) {
            final q = h.$1.firstWhere((q) => (at - q).distance < 14);
            final d = q - h.$3;
            c = d.dx * d.dy > 0 ? SystemMouseCursors.resizeUpLeftDownRight : SystemMouseCursors.resizeUpRightDownLeft;
          } else if (hit(at) != null) {
            c = SystemMouseCursors.click;
          }
          if (c != _putCursor) setState(() => _putCursor = c);
        },
        child: h == null ? const SizedBox.expand() : CustomPaint(size: Size.infinite, painter: _PutHandles(h.$1, h.$2)),
      ),
    );
  }

  /// A change as it will look: the old words covered, the new ones where
  /// they go (squeezed, laid out, moved).
  List<Widget> _preview(_Edit e, Rect Function(PdfRect) at, double scale, double pageHeight) {
    final lay = _layout(e);
    return [
      for (final l in e.lines)
        Positioned.fromRect(rect: at(l.box).inflate(1), child: const ColoredBox(color: Colors.white)),
      for (final o in lay.out)
        _words(o.text, o, scale, pageHeight, bold: e.bold, italic: e.italic, family: _screenFamily(e.text, e.from), color: e.color, mark: true),
    ];
  }

  /// [text] drawn as [o] lays it (baseline at [o].base, page points).
  Widget _words(String text, _Out o, double scale, double pageHeight,
          {required bool bold, required bool italic, required String family, Color? color, bool mark = false}) =>
      Positioned(
        left: o.x * scale,
        // The box's top: about one size above the baseline.
        top: (pageHeight - o.base - o.size * 0.88) * scale,
        child: IgnorePointer(
          child: Transform(
            alignment: Alignment.centerLeft,
            transform: Matrix4.diagonal3Values(o.hscale, 1, 1),
            child: Text(
              text,
              softWrap: false,
              style: TextStyle(
                fontSize: o.size * scale,
                height: 1.0,
                fontWeight: bold ? FontWeight.w700 : FontWeight.w400,
                fontStyle: italic ? FontStyle.italic : FontStyle.normal,
                fontFamily: family,
                color: color ?? const Color(0xFF1A1A1A),
                decoration: mark ? TextDecoration.underline : null,
                decorationColor: const Color(0x8012A35F),
                decorationThickness: 2,
              ),
            ),
          ),
        ),
      );

  /// Where the line (or paragraph) being changed is, as shown (moved too).
  Rect _editRect(_Line l, Rect Function(PdfRect) at) {
    final lines = _paraLines ?? [l];
    var r = at(lines.first.box);
    for (final x in lines.skip(1)) {
      r = r.expandToInclude(at(x.box));
    }
    // The page's scale: screen pixels per point.
    final w = lines.first.box.width;
    final s = w <= 0 ? 1.0 : at(lines.first.box).width / w;
    return r.shift(Offset(_dx * s, _dy * s));
  }

  List<Widget> _editor(_Line l, Rect r, double scale, Size page) {
    final para = _paraLines != null;
    // Room to type more; not past the page's right edge if it can help it.
    var width = para ? r.width + 8 : r.width + 80;
    if (width < 220) width = 220;
    final room = page.width - r.left + 40;
    if (width > room && room >= 220) width = room;
    final moved = _dx != 0 || _dy != 0;
    // The bar goes under the line, or over it near the page's foot; lined
    // up on the right for a line on the right half (so it stays in view).
    final up = page.height - r.bottom < 120;
    final right = r.left > page.width / 2;
    return [
      // Moved: the old place shows blank (the words go with the box).
      if (moved)
        Positioned.fromRect(
          rect: r.shift(Offset(-_dx * scale, -_dy * scale)).inflate(1),
          child: const IgnorePointer(child: ColoredBox(color: Colors.white)),
        ),
      // Drag to move the line (or paragraph); the old place stays blank.
      Positioned(
        left: r.left - 30,
        top: r.top - 4,
        child: Tooltip(
          message: tr('pdfedit.move_tip'),
          child: MouseRegion(
            cursor: SystemMouseCursors.move,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onPanUpdate: (d) => setState(() {
                _dx += d.delta.dx / scale;
                _dy += d.delta.dy / scale;
              }),
              child: Container(
                width: 24,
                height: 24,
                decoration: BoxDecoration(color: LightLook.blue, borderRadius: BorderRadius.circular(6)),
                child: const Icon(Icons.open_with_rounded, size: 16, color: Colors.white),
              ),
            ),
          ),
        ),
      ),
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
                // A paragraph: lines wrap (Shift+Enter: a new line).
                maxLines: para ? null : 1,
                minLines: para ? (_paraLines!.length) : 1,
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

  /// "· squeezed to 88%" / "· too long…" for what is being typed.
  String _fitNote(_Line l) {
    final probe = _Edit(l, _ctl.text.trimRight(), _size, _bold, _italic, _color, _from ?? l, para: _paraLines, dx: _dx, dy: _dy);
    final lay = _layout(probe);
    if (lay.tooLong) return '  ·  ${tr(_paraLines == null ? 'pdfedit.too_long' : 'pdfedit.para_too_long')}';
    if (lay.squeezed < 0.995) return '  ·  ${tr('pdfedit.squeezed', {'pct': (lay.squeezed * 100).round()})}';
    return '';
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
              // The whole paragraph as one: its lines laid out again.
              if (_paraLines != null || _paraOf(l).length > 1) ...[
                FilterChip(
                  avatar: const Icon(Icons.notes_rounded, size: 16),
                  label: Text(tr('pdfedit.para')),
                  tooltip: tr('pdfedit.para_tip'),
                  selected: _paraLines != null,
                  onSelected: (_) => _togglePara(),
                  visualDensity: VisualDensity.compact,
                ),
                const SizedBox(width: 6),
              ],
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
                  _brush ? tr('pdfedit.brush_hint') : '${_fontNote(_ctl.text, _from ?? l, l, _bold, _italic)}${_fitNote(l)}',
                  style: TextStyle(fontSize: 12, color: _brush ? LightLook.blue : LightLook.muted),
                ),
              ),
            ]),
          ),
      );

  /// The page number: a click makes it a box — type a page, Enter goes
  /// there, Esc (or a click elsewhere) leaves it.
  Widget _pageJump(PdfDocument d) {
    final label = tr('pdfedit.page', {'n': _page + 1, 'count': d.pages.length});
    if (!_jumping) {
      return TextButton(
        onPressed: d.pages.length < 2
            ? null
            : () {
                _jumpCtl.text = '${_page + 1}';
                _jumpCtl.selection = TextSelection(baseOffset: 0, extentOffset: _jumpCtl.text.length);
                setState(() => _jumping = true);
              },
        style: TextButton.styleFrom(foregroundColor: LightLook.muted, disabledForegroundColor: LightLook.muted),
        child: Text(label),
      );
    }
    return Row(mainAxisSize: MainAxisSize.min, children: [
      SizedBox(
        width: 56,
        child: CallbackShortcuts(
          bindings: {const SingleActivator(LogicalKeyboardKey.escape): () => setState(() => _jumping = false)},
          child: TextField(
            controller: _jumpCtl,
            autofocus: true,
            textAlign: TextAlign.center,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: const InputDecoration(isDense: true, contentPadding: EdgeInsets.symmetric(vertical: 8), border: OutlineInputBorder()),
            onTapOutside: (_) => setState(() => _jumping = false),
            onSubmitted: (v) {
              final n = int.tryParse(v);
              setState(() => _jumping = false);
              if (n != null) unawaited(_go((n - 1).clamp(0, d.pages.length - 1)));
            },
          ),
        ),
      ),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6),
        child: Text('/ ${d.pages.length}', style: const TextStyle(color: LightLook.muted)),
      ),
    ]);
  }

  /// The thin strip between the page and the right side: › folds the side
  /// away, ‹ brings it back (remembered).
  Widget _sideStrip() => Material(
        color: const Color(0xFFF1F3F7),
        child: InkWell(
          onTap: () {
            setState(() => _sideOpen = !_sideOpen);
            unawaited(s.settings.update((x) => x.editSideOpen = _sideOpen));
          },
          child: Container(
            width: 16,
            decoration: const BoxDecoration(border: Border(left: BorderSide(color: Color(0xFFE3E7EE)))),
            alignment: Alignment.center,
            child: Icon(_sideOpen ? Icons.chevron_right_rounded : Icons.chevron_left_rounded, size: 16, color: LightLook.blue),
          ),
        ),
      );

  Widget _side(PdfDocument d) => ListView(padding: const EdgeInsets.fromLTRB(0, 24, 20, 24), children: [
        // What a click does now.
        _box(Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(
            switch (_mode) {
              _Mode.text => tr('pdfedit.title'),
              _Mode.mark => tr('ann.title'),
              _Mode.sign => tr('pdf.sign'),
              _Mode.picture => tr('pdf.add_picture'),
            },
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: LightLook.text),
          ),
          const SizedBox(height: 6),
          Text(
            switch (_mode) {
              _Mode.text => '${tr('pdfedit.hint')}\n${tr('edit.box_hint')}',
              _Mode.mark => tr('ann.hint'),
              _ => tr('edit.put_hint'),
            },
            style: const TextStyle(color: LightLook.muted, fontSize: 12.5, height: 1.5),
          ),
          if (_mode == _Mode.text && (_lines[_page]?.isEmpty ?? false) && _pics.containsKey(_page)) ...[
            const SizedBox(height: 8),
            Text(tr('pdfedit.no_text'), style: const TextStyle(color: Color(0xFFC0560A), fontSize: 12.5, height: 1.5)),
          ],
          if (_mode == _Mode.sign || _mode == _Mode.picture) ...[
            const SizedBox(height: 10),
            FilledButton.tonalIcon(
              onPressed: () => unawaited(_addPut(picture: _mode == _Mode.picture)),
              icon: Icon(_mode == _Mode.picture ? Icons.add_photo_alternate_outlined : Icons.draw_rounded, size: 18),
              label: Text(tr(_mode == _Mode.picture ? 'edit.add_picture' : 'edit.add_sign')),
            ),
            if (_sel != null) ...[
              const SizedBox(height: 8),
              Row(children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () {
                      _mark();
                      setState(() => _sel!.angle = _snap(_sel!.angle + math.pi / 2));
                    },
                    child: Text(tr('pdf.turn')),
                  ),
                ),
                const SizedBox(width: 8),
                if (d.pages.length > 1) ...[
                  Expanded(child: OutlinedButton(onPressed: _everyPage, child: Text(tr('edit.every_page')))),
                  const SizedBox(width: 8),
                ],
                Expanded(
                  child: OutlinedButton(
                    style: OutlinedButton.styleFrom(foregroundColor: const Color(0xFFE5484D)),
                    onPressed: _removeSel,
                    child: Text(tr('pdf.sign_remove')),
                  ),
                ),
              ]),
            ],
          ],
        ])),
        const SizedBox(height: 14),
        _box(Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(tr('edit.changes', {'count': _changes}), style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: LightLook.text)),
          if (_markCount > 0 || _puts.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                tr('edit.counts', {'words': _edits.length, 'marks': _markCount, 'signs': _puts.length}),
                style: const TextStyle(color: LightLook.muted, fontSize: 12.5),
              ),
            ),
          for (final e in _edits)
            InkWell(
              onTap: () async {
                await _go(e.line.page);
                setState(() => _mode = _Mode.text);
                _start(e.line);
              },
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Row(children: [
                  Expanded(
                    child: Text.rich(
                      TextSpan(children: [
                        TextSpan(text: '${tr('pdfedit.page_short', {'n': e.line.page + 1})}  ', style: const TextStyle(color: LightLook.muted)),
                        TextSpan(
                            text: e.para == null ? e.line.text : _joinPara(e.para!),
                            style: const TextStyle(decoration: TextDecoration.lineThrough, color: Color(0xFFA3AEC0))),
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
                    onPressed: () {
                      _mark();
                      setState(() => _edits.remove(e));
                    },
                  ),
                ]),
              ),
            ),
          const SizedBox(height: 10),
          FilledButton(onPressed: _unsaved ? () => _save(replace: false) : null, child: Text(tr('pdfedit.save_new'))),
          if (!_office) ...[
            const SizedBox(height: 8),
            OutlinedButton(onPressed: _unsaved ? _confirmReplace : null, child: Text(tr('pdfedit.save_over'))),
          ],
          const SizedBox(height: 8),
          Text(tr('pdfedit.save_note'), style: const TextStyle(color: LightLook.muted, fontSize: 12, height: 1.5)),
          // Big changes: the whole PDF as a Word file, in Word / WPS /
          // LibreOffice (the PDF's own look changes somewhat).
          if (!_office) ...[
            const SizedBox(height: 16),
            const Divider(height: 1),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              icon: const Icon(Icons.description_outlined, size: 18),
              label: Text(tr('pdfword.edit')),
              onPressed: () {
                if (_unsaved) {
                  ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(tr('pdfword.save_first'))));
                  return;
                }
                unawaited(editPdfInOffice(context, widget.services, widget.path));
              },
            ),
            const SizedBox(height: 6),
            Text(tr('pdfword.edit_tip'), style: const TextStyle(color: LightLook.muted, fontSize: 12, height: 1.5)),
          ],
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

/// The chosen signature / picture: its (turned) box, four corners, and the
/// knob above it that turns it.
class _PutHandles extends CustomPainter {
  _PutHandles(this.corners, this.knob);

  final List<Offset> corners;
  final Offset knob;

  @override
  void paint(Canvas canvas, Size size) {
    const blue = Color(0xFF2F6BFF);
    final line = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..color = blue;
    canvas.drawPath(Path()..addPolygon(corners, true), line);
    canvas.drawLine((corners[0] + corners[1]) / 2, knob, line);
    final fill = Paint()..color = Colors.white;
    for (final q in corners) {
      final r = Rect.fromCenter(center: q, width: 12, height: 12);
      canvas.drawRect(r, fill);
      canvas.drawRect(r, line..strokeWidth = 2);
    }
    canvas.drawCircle(knob, 7, fill);
    canvas.drawCircle(knob, 7, line..strokeWidth = 2);
  }

  @override
  bool shouldRepaint(_PutHandles old) => true;
}

/// 编辑 for any file: a PDF in the editor (words, marks, signatures,
/// pictures); an Office document made into a PDF first (no word changes);
/// a photo with the marking page.
Future<void> openEditor(BuildContext context, AppServices s, String path,
    {int page = 0, ValueChanged<String>? onSaved, bool mark = false}) async {
  final lower = path.toLowerCase();
  if (lower.endsWith('.pdf')) {
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => PdfTextEditPage(services: s, path: path, page: page, onSaved: onSaved, mark: mark),
    ));
    return;
  }
  if (OfficePdf.handles(path)) {
    final tmp = await Directory.systemTemp.createTemp('lr_edit');
    final name = path.split(Platform.pathSeparator).last;
    final dot = name.lastIndexOf('.');
    final out = '${tmp.path}${Platform.pathSeparator}${dot > 0 ? name.substring(0, dot) : name}.pdf';
    if (!context.mounted) return;
    final err = await runBusy(context, tr('print.preparing'), () => OfficePdf.convert(path, out));
    if (!context.mounted) return;
    if (err != null || !File(out).existsSync()) {
      DiagLog.log('tools', 'edit: office not made a pdf: $err');
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(tr('ann.cannot'))));
      return;
    }
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => PdfTextEditPage(services: s, path: out, original: path, onSaved: onSaved),
    ));
    return;
  }
  await openAnnotate(context, s, path, page: page, onSaved: onSaved);
}

/// The box being drawn for 改字 on a scan.
class _BoxPaint extends CustomPainter {
  _BoxPaint(this.box);

  final Rect? box;

  @override
  void paint(Canvas canvas, Size size) {
    final b = box;
    if (b == null) return;
    canvas.drawRect(b, Paint()..color = const Color(0x1A2F6BFF));
    canvas.drawRect(
        b,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5
          ..color = const Color(0xFF2F6BFF));
  }

  @override
  bool shouldRepaint(_BoxPaint old) => old.box != box;
}
