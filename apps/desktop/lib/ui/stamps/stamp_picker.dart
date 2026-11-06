// apps/desktop/lib/ui/stamps/stamp_picker.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:localroll_core/localroll_core.dart' show sanitizeFileName;

import '../../l10n/l10n.dart';
import '../../services/annotations.dart';
import '../../services/peers.dart' show SendFile;
import '../../services/stamp_library.dart';
import '../../services/win_dialogs.dart';
import '../player/ink_editor.dart';
import '../player/ink_paint.dart';
import '../screen/pen_bar.dart' show PenSession;
import '../send_page.dart';
import '../theme.dart';
import 'candle_panel.dart';

/// A stamp chosen: its picture (rising / falling colours set) and name.
typedef PickedStamp = ({String id, StampShape shape, String name});

/// Choose a stamp, then place it on the picture being drawn on.
Future<void> pickStampInto(BuildContext context, InkEditor editor) async {
  final r = await showStampPicker(context, drawn: editor.inks, aspect: editor.aspect);
  if (r == null || !context.mounted) return;
  if (r.id == StampLibrary.candleDraw) return pickCandleInto(context, editor);
  editor
            ..upColor = StampLibrary.instance.colors.$1
            ..downColor = StampLibrary.instance.colors.$2;
  editor.setStamp(r.shape, r.name);
}

/// The stamp panel: packs, recent, favourites, the user's own; search by
/// name. [drawn]: marks that can be kept as a stamp of one's own.
Future<PickedStamp?> showStampPicker(BuildContext context, {List<InkMark> drawn = const [], double aspect = 16 / 9}) =>
    showDialog<PickedStamp>(context: context, builder: (_) => _StampPicker(drawn: drawn, aspect: aspect));

String stampName(String id) {
  for (final (end, word) in const [('_up', 'stamp.rising'), ('_down', 'stamp.falling')]) {
    if (id.endsWith(end)) return '${tr('stamp.${id.substring(0, id.length - end.length)}')} · ${tr(word)}';
  }
  if (id == StampLibrary.candleDraw) return tr('stamp.candle_draw');
  if (id.startsWith('my_')) {
    for (final m in StampLibrary.instance.mine) {
      if (m.id == id) return m.name;
    }
    return '';
  }
  return StampPacks.realName(id, chinese: _chinese) ?? tr('stamp.$id');
}

/// The realistic stamps have Chinese and English names only.
bool get _chinese => translator.language.startsWith('zh');

/// A pack's name.
String packName(String pack) => StampPacks.realPackName(pack, chinese: _chinese) ?? tr('stamp.pack_$pack');

class _StampPicker extends StatefulWidget {
  const _StampPicker({required this.drawn, required this.aspect});

  final List<InkMark> drawn;
  final double aspect;

  @override
  State<_StampPicker> createState() => _StampPickerState();
}

class _StampPickerState extends State<_StampPicker> {
  final TextEditingController _q = TextEditingController();
  final StampLibrary _lib = StampLibrary.instance;
  late String _tab = _lib.recent.isEmpty ? 'c_basic' : 'recent';

  @override
  void dispose() {
    _q.dispose();
    super.dispose();
  }

  /// Every stamp there is, by id.
  Map<String, StampShape> get _all => {
        for (final s in StampPacks.all) s.id: s.shape,
        StampLibrary.candleDraw: candleDrawShape,
        for (final m in _lib.mine) m.id: m.shape,
      };

  List<String> _shown() {
    final all = _all;
    final q = _q.text.trim().toLowerCase();
    if (q.isNotEmpty) {
      final hidden = {for (final s in StampPacks.all) if (_lib.hiddenPacks.contains(s.pack) || !StampPacks.offered.contains(s.pack)) s.id};
      bool hit(String id) {
        if (stampName(id).toLowerCase().contains(q) || id.replaceAll('_', ' ').contains(q)) return true;
        // Realistic stamps: found by either name.
        final n = StampPacks.realNames(id);
        return n != null && (n.$1.contains(q) || n.$2.toLowerCase().contains(q));
      }

      return [
        for (final id in all.keys)
          if (!hidden.contains(id) && hit(id)) id,
      ];
    }
    return switch (_tab) {
      'recent' => [for (final id in _lib.recent) if (all.containsKey(id)) id],
      'fav' => [for (final id in all.keys) if (_lib.favorites.contains(id)) id],
      'mine' => [for (final m in _lib.mine) m.id],
      _ => [if (_tab == 'finance') StampLibrary.candleDraw, for (final s in StampPacks.all) if (s.pack == _tab) s.id],
    };
  }

  Future<void> _pick(String id) async {
    final (up, down) = _lib.colors;
    // Drawing candles by hand: the caller opens the candle panel.
    if (id == StampLibrary.candleDraw) {
      Navigator.pop(context, (id: id, shape: candleDrawShape, name: stampName(id)));
      return;
    }
    var shape = _all[id];
    if (shape == null) return;
    // A number, a price, a year…: its words first.
    if (StampPacks.editable.contains(id)) {
      final words = await _askWords(shape);
      if (words == null || !mounted) return;
      shape = StampPacks.withWords(shape, words);
    }
    _lib.used(id);
    if (!mounted) return;
    Navigator.pop(context, (id: id, shape: shape.resolved(up, down), name: stampName(id)));
  }

  /// The words of [shape] (filled in with its own); null: cancelled.
  Future<List<String>?> _askWords(StampShape shape) async {
    final ctls = [for (final p in shape.parts) if (p.text != null) TextEditingController(text: p.text)];
    final r = await showDialog<List<String>>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('stamp.words_title')),
        content: SizedBox(
          width: 360,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            for (var k = 0; k < ctls.length; k++)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: TextField(
                  controller: ctls[k],
                  autofocus: k == 0,
                  decoration: const InputDecoration(isDense: true, border: OutlineInputBorder()),
                  onSubmitted: (_) => Navigator.pop(ctx, [for (final c in ctls) c.text]),
                ),
              ),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(tr('common.cancel'))),
          FilledButton(onPressed: () => Navigator.pop(ctx, [for (final c in ctls) c.text]), child: Text(tr('common.ok'))),
        ],
      ),
    );
    for (final c in ctls) {
      c.dispose();
    }
    return r;
  }

  /// Turn packs on / off (off: not shown here).
  Future<void> _managePacks() async {
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, set) => AlertDialog(
          title: Text(tr('stamp.packs_title')),
          content: SizedBox(
            width: 520,
            height: 440,
            child: ListView(children: [
              for (final k in StampPacks.kinds.entries) ...[
                Padding(
                  padding: const EdgeInsets.only(top: 8, bottom: 2),
                  child: Text(tr('stamp.kind_${k.key}'), style: const TextStyle(fontWeight: FontWeight.w600)),
                ),
                Wrap(spacing: 6, runSpacing: 4, children: [
                  for (final p in k.value)
                    FilterChip(
                      label: Text(packName(p)),
                      selected: !_lib.hiddenPacks.contains(p),
                      onSelected: (v) => set(() => _lib.setPackShown(p, v)),
                    ),
                ]),
              ],
            ]),
          ),
          actions: [FilledButton(onPressed: () => Navigator.pop(ctx), child: Text(tr('common.ok')))],
        ),
      ),
    );
    if (!mounted) return;
    setState(() {
      if (_lib.hiddenPacks.contains(_tab)) _tab = 'recent';
    });
  }

  Future<void> _exportMine() async {
    if (_lib.mine.isEmpty) return;
    final path = await WinDialogs.saveFile(suggestedName: '${tr('stamp.my_default')}.lrstamps', typeLabel: tr('stamp.file_type'), extensions: const ['lrstamps']);
    if (path == null) return;
    try {
      await File(path).writeAsString(_lib.exportMine());
      if (mounted) ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(tr('stamp.exported', {'n': _lib.mine.length}))));
    } catch (_) {
      if (mounted) ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(tr('stamp.import_failed'))));
    }
  }

  Future<void> _importMine() async {
    final files = await WinDialogs.pickFiles(multiple: true, typeLabel: tr('stamp.file_type'), extensions: const ['lrstamps', 'json']);
    var n = 0;
    var bad = false;
    for (final f in files) {
      try {
        n += _lib.importMine(await File(f).readAsString());
      } catch (_) {
        bad = true;
      }
    }
    if (!mounted || files.isEmpty) return;
    setState(() => _tab = 'mine');
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(bad && n == 0 ? tr('stamp.import_failed') : tr('stamp.imported', {'n': n}))));
  }

  /// The user's stamps as a file, sent to another PC / phone.
  Future<void> _sendMine() async {
    final s = PenSession.instance.services;
    if (_lib.mine.isEmpty || s == null) return;
    final name = '${sanitizeFileName(tr('stamp.my_default'))}.lrstamps';
    final f = File('${Directory.systemTemp.path}${Platform.pathSeparator}$name');
    await f.writeAsString(_lib.exportMine());
    final sf = SendFile.plain(f, name);
    if (sf == null || !mounted) return;
    await sendToPc(context, s, [sf], name);
  }

  Future<void> _menu(String id, Offset at) async {
    final mine = id.startsWith('my_');
    final v = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(at.dx, at.dy, at.dx, at.dy),
      items: [
        PopupMenuItem(value: 'fav', child: Text(tr(_lib.favorites.contains(id) ? 'stamp.unfavorite' : 'stamp.favorite'))),
        PopupMenuItem(value: 'quick', child: Text(tr(_lib.quick.contains(id) ? 'stamp.quick_off' : 'stamp.quick_on'))),
        if (mine) PopupMenuItem(value: 'rename', child: Text(tr('ink.rename'))),
        if (mine) PopupMenuItem(value: 'delete', child: Text(tr('ink.delete'))),
      ],
    );
    if (!mounted || v == null) return;
    if (v == 'fav') _lib.toggleFavorite(id);
    if (v == 'quick') _lib.quick.contains(id) ? _lib.unpinQuick(id) : _lib.pinQuick(id);
    if (v == 'delete') _lib.remove(id);
    if (v == 'rename') {
      final n = await _askName(stampName(id));
      if (n != null) _lib.rename(id, n);
    }
    setState(() {});
  }

  Future<String?> _askName(String initial) async {
    final c = TextEditingController(text: initial);
    final r = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('stamp.name_title')),
        content: TextField(controller: c, autofocus: true, onSubmitted: (v) => Navigator.pop(ctx, v)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(tr('common.cancel'))),
          FilledButton(onPressed: () => Navigator.pop(ctx, c.text), child: Text(tr('common.ok'))),
        ],
      ),
    );
    c.dispose();
    final n = r?.trim();
    return n == null || n.isEmpty ? null : n;
  }

  Future<void> _fromDrawn() async {
    final shape = shapeFromMarks(widget.drawn, widget.aspect);
    if (shape == null) return;
    final n = await _askName(tr('stamp.my_default'));
    if (n == null) return;
    _lib.add(n, shape);
    setState(() => _tab = 'mine');
  }

  Future<void> _fromPicture() async {
    final files = await WinDialogs.pickFiles(multiple: false, typeLabel: tr('stamp.pictures'), extensions: const ['png', 'jpg', 'jpeg']);
    if (files.isEmpty || !mounted) return;
    final white = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('stamp.white_title')),
        content: Text(tr('stamp.white_tip')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('stamp.white_keep'))),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(tr('stamp.white_remove'))),
        ],
      ),
    );
    if (white == null || !mounted) return;
    final shape = await shapeFromPicture(File(files.first), removeWhite: white);
    if (shape == null) {
      if (mounted) ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(tr('stamp.picture_failed'))));
      return;
    }
    final base = files.first.split(RegExp(r'[\\/]')).last;
    final n = await _askName(base.contains('.') ? base.substring(0, base.lastIndexOf('.')) : base);
    if (n == null) return;
    _lib.add(n, shape);
    setState(() => _tab = 'mine');
  }

  Widget _chip(String tab, String label) => Padding(
        padding: const EdgeInsets.only(right: 6),
        child: ChoiceChip(
          label: Text(label),
          selected: _q.text.isEmpty && _tab == tab,
          onSelected: (_) => setState(() {
            _q.clear();
            _tab = tab;
          }),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final shown = _shown();
    final all = _all;
    final (up, down) = _lib.colors;
    return AlertDialog(
      title: Row(children: [
        Text(tr('stamp.title')),
        const SizedBox(width: 16),
        Expanded(
          child: TextField(
            controller: _q,
            autofocus: true,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(isDense: true, prefixIcon: const Icon(Icons.search_rounded, size: 18), hintText: tr('stamp.search'), border: const OutlineInputBorder()),
          ),
        ),
        IconButton(tooltip: tr('stamp.packs_title'), onPressed: _managePacks, icon: const Icon(Icons.tune_rounded)),
      ]),
      content: SizedBox(
        width: 720,
        height: 460,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(children: [
              _chip('recent', tr('stamp.recent')),
              _chip('fav', tr('stamp.favorites')),
              // A kind (general, school…): its first pack, its packs below.
              for (final k in StampPacks.kinds.entries)
                if (k.value.any((p) => !_lib.hiddenPacks.contains(p)))
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: ChoiceChip(
                    label: Text(tr('stamp.kind_${k.key}')),
                    selected: _q.text.isEmpty && k.value.contains(_tab),
                    onSelected: (_) => setState(() {
                      _q.clear();
                      if (!k.value.contains(_tab)) _tab = k.value.firstWhere((p) => !_lib.hiddenPacks.contains(p));
                    }),
                  ),
                ),
              _chip('mine', tr('stamp.mine')),
            ]),
          ),
          // The packs of the kind chosen.
          for (final k in StampPacks.kinds.values)
            if (_q.text.isEmpty && k.contains(_tab))
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(children: [for (final p in k) if (!_lib.hiddenPacks.contains(p)) _chip(p, packName(p))]),
                ),
              ),
          const SizedBox(height: 8),
          if (_q.text.isEmpty && _tab == 'finance')
            Row(children: [
              Text(tr('stamp.colors'), style: const TextStyle(color: LrColors.muted)),
              const SizedBox(width: 10),
              SegmentedButton<bool>(
                showSelectedIcon: false,
                segments: [
                  ButtonSegment(value: true, label: Text(tr('stamp.red_up'))),
                  ButtonSegment(value: false, label: Text(tr('stamp.green_up'))),
                ],
                selected: {_lib.redUp},
                onSelectionChanged: (v) => setState(() => _lib.setRedUp(v.first)),
              ),
              const Spacer(),
              Flexible(child: Text(tr('stamp.candle_tip'), style: const TextStyle(color: LrColors.muted, fontSize: 12))),
            ]),
          if (_q.text.isEmpty && _tab == 'mine')
            Wrap(spacing: 8, children: [
              OutlinedButton.icon(onPressed: _fromPicture, icon: const Icon(Icons.image_outlined, size: 18), label: Text(tr('stamp.from_picture'))),
              OutlinedButton.icon(
                onPressed: widget.drawn.isEmpty ? null : _fromDrawn,
                icon: const Icon(Icons.gesture_rounded, size: 18),
                label: Text(tr('stamp.from_drawn')),
              ),
              TextButton.icon(onPressed: _importMine, icon: const Icon(Icons.file_open_outlined, size: 18), label: Text(tr('stamp.import'))),
              TextButton.icon(onPressed: _lib.mine.isEmpty ? null : _exportMine, icon: const Icon(Icons.save_alt_rounded, size: 18), label: Text(tr('stamp.export'))),
              TextButton.icon(onPressed: _lib.mine.isEmpty ? null : _sendMine, icon: const Icon(Icons.send_rounded, size: 18), label: Text(tr('stamp.send'))),
            ]),
          const SizedBox(height: 8),
          Expanded(
            child: shown.isEmpty
                ? Center(child: Text(tr(_tab == 'recent' && _q.text.isEmpty ? 'stamp.none_recent' : 'stamp.none'), style: const TextStyle(color: LrColors.muted)))
                : GridView.builder(
                    gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(maxCrossAxisExtent: 96, mainAxisSpacing: 6, crossAxisSpacing: 6, childAspectRatio: 0.85),
                    itemCount: shown.length,
                    itemBuilder: (context, k) {
                      final id = shown[k];
                      final shape = all[id]!.resolved(up, down);
                      return Tooltip(
                        message: stampName(id),
                        waitDuration: const Duration(milliseconds: 500),
                        child: InkWell(
                          borderRadius: BorderRadius.circular(8),
                          onTap: () => unawaited(_pick(id)),
                          onSecondaryTapDown: (d) => _menu(id, d.globalPosition),
                          onLongPress: () => _menu(id, MediaQuery.sizeOf(context).center(Offset.zero)),
                          child: Container(
                            decoration: BoxDecoration(color: const Color(0x14FFFFFF), borderRadius: BorderRadius.circular(8)),
                            padding: const EdgeInsets.all(6),
                            child: Column(children: [
                              Expanded(child: CustomPaint(painter: StampTile(shape), size: Size.infinite)),
                              const SizedBox(height: 4),
                              Row(children: [
                                if (_lib.favorites.contains(id)) const Icon(Icons.star_rounded, size: 12, color: LrColors.safelight),
                                Expanded(
                                  child: Text(stampName(id), maxLines: 1, overflow: TextOverflow.ellipsis, textAlign: TextAlign.center, style: const TextStyle(fontSize: 11.5)),
                                ),
                              ]),
                            ]),
                          ),
                        ),
                      );
                    },
                  ),
          ),
          Text(tr('stamp.tip'), style: const TextStyle(color: LrColors.muted, fontSize: 12)),
        ]),
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: Text(tr('common.cancel')))],
    );
  }
}

class StampTile extends CustomPainter {
  StampTile(this.shape) : super(repaint: StampImages.loaded);

  final StampShape shape;

  @override
  void paint(Canvas canvas, Size size) => shape.paint(canvas, Offset.zero & size, 0xFFFFFFFF);

  @override
  bool shouldRepaint(StampTile old) => old.shape != shape;
}

/// What was drawn, kept as a stamp (lines, shapes and words; still lines).
/// [aspect]: the picture's width for 1 high.
StampShape? shapeFromMarks(List<InkMark> marks, double aspect) {
  const h = 1000.0;
  final s = Size(h * aspect, h);
  final parts = <({List<List<Offset>> polys, bool fill, double w, int color, String? text, Offset at, double size})>[];
  for (final m in marks) {
    final px = [for (final p in m.points) InkGeometry.px(p, s)];
    if (px.isEmpty) continue;
    List<Offset> t(List<Offset> l) => [for (final p in l) InkGeometry.transform(m, s, p)];
    final w = InkGeometry.lineWidth(m, s) * m.scale;
    switch (m.tool) {
      case InkTool.pen:
      case InkTool.line:
        parts.add((polys: [t(m.tool == InkTool.line ? [px.first, px.last] : px)], fill: false, w: w, color: m.color, text: null, at: Offset.zero, size: 0));
      case InkTool.marker:
        parts.add((polys: [t(px)], fill: false, w: w * 3, color: (m.color & 0x00FFFFFF) | 0x66000000, text: null, at: Offset.zero, size: 0));
      case InkTool.arrow:
        final a = px.first, b = px.last;
        final ang = math.atan2(b.dy - a.dy, b.dx - a.dx), head = math.max(10.0, w * 4);
        parts.add((
          polys: [
            t([a, b]),
            t([Offset(b.dx - head * math.cos(ang - 0.45), b.dy - head * math.sin(ang - 0.45)), b, Offset(b.dx - head * math.cos(ang + 0.45), b.dy - head * math.sin(ang + 0.45))]),
          ],
          fill: false,
          w: w,
          color: m.color,
          text: null,
          at: Offset.zero,
          size: 0
        ));
      case InkTool.rect:
        final r = Rect.fromPoints(px.first, px.last);
        parts.add((polys: [t([r.topLeft, r.topRight, r.bottomRight, r.bottomLeft, r.topLeft])], fill: false, w: w, color: m.color, text: null, at: Offset.zero, size: 0));
      case InkTool.ellipse:
        final r = Rect.fromPoints(px.first, px.last);
        parts.add((
          polys: [
            t([for (var k = 0; k <= 48; k++) Offset(r.center.dx + r.width / 2 * math.cos(k * math.pi / 24), r.center.dy + r.height / 2 * math.sin(k * math.pi / 24))]),
          ],
          fill: false,
          w: w,
          color: m.color,
          text: null,
          at: Offset.zero,
          size: 0
        ));
      case InkTool.text:
        final b = InkGeometry.box(m, s);
        if ((m.text ?? '').trim().isEmpty) continue;
        parts.add((polys: const [], fill: true, w: 0, color: m.color, text: m.text, at: InkGeometry.transform(m, s, b.center), size: b.height * m.scale));
      default:
        continue;
    }
  }
  if (parts.isEmpty) return null;
  var l = double.infinity, tp = double.infinity, r = -double.infinity, b = -double.infinity;
  void grow(Offset p, double pad) {
    l = math.min(l, p.dx - pad);
    r = math.max(r, p.dx + pad);
    tp = math.min(tp, p.dy - pad);
    b = math.max(b, p.dy + pad);
  }

  for (final p in parts) {
    for (final poly in p.polys) {
      for (final o in poly) {
        grow(o, p.w / 2);
      }
    }
    if (p.text != null) grow(p.at, p.size * 0.6 * math.max(1, p.text!.length / 2));
  }
  final bw = math.max(1.0, r - l), bh = math.max(1.0, b - tp);
  Offset u(Offset o) => Offset((o.dx - l) / bw, (o.dy - tp) / bh);
  // One colour throughout: it follows the colour chosen when placing it.
  final one = parts.every((p) => p.color == parts.first.color);
  return StampShape(aspect: bw / bh, parts: [
    for (final p in parts)
      StampPart(
        polys: [for (final poly in p.polys) [for (final o in poly) u(o)]],
        fill: p.fill,
        w: p.w / bh,
        color: one ? null : p.color,
        text: p.text,
        at: u(p.at),
        size: p.size / bh,
      ),
  ]);
}

/// A picture as a stamp: at most 512 on its long side, white made see-
/// through when asked.
Future<StampShape?> shapeFromPicture(File f, {required bool removeWhite}) async {
  try {
    final bytes = await f.readAsBytes();
    final probe = await ui.instantiateImageCodec(bytes);
    final first = (await probe.getNextFrame()).image;
    final k = math.min(1.0, 512 / math.max(first.width, first.height));
    final w = math.max(1, (first.width * k).round()), h = math.max(1, (first.height * k).round());
    first.dispose();
    final codec = await ui.instantiateImageCodec(bytes, targetWidth: w, targetHeight: h);
    final img = (await codec.getNextFrame()).image;
    final raw = await img.toByteData(format: ui.ImageByteFormat.rawStraightRgba);
    img.dispose();
    if (raw == null) return null;
    final px = raw.buffer.asUint8List();
    if (removeWhite) {
      for (var i = 0; i + 3 < px.length; i += 4) {
        final m = math.min(px[i], math.min(px[i + 1], px[i + 2]));
        // Near white: see-through, softly at the edge.
        if (m > 200) px[i + 3] = (px[i + 3] * (1 - ((m - 200) / 40).clamp(0.0, 1.0))).round();
      }
    }
    final done = Completer<ui.Image>();
    ui.decodeImageFromPixels(px, w, h, ui.PixelFormat.rgba8888, done.complete);
    final out = await done.future;
    final png = await out.toByteData(format: ui.ImageByteFormat.png);
    out.dispose();
    if (png == null) return null;
    return StampShape(aspect: w / h, png: base64Encode(png.buffer.asUint8List()));
  } catch (_) {
    return null;
  }
}

/// The picture for "draw candles by hand" (a rising and a falling candle).
final StampShape candleDrawShape = Candles.pattern(const [(0.7, 0.35, 0.85, 0.2), (0.35, 0.75, 0.9, 0.25)]);

/// A stamp drawn small (toolbar buttons).
class StampThumb extends StatelessWidget {
  const StampThumb({super.key, required this.id, this.size = 24});

  final String id;
  final double size;

  @override
  Widget build(BuildContext context) {
    final lib = StampLibrary.instance;
    StampShape? shape;
    if (id == StampLibrary.candleDraw) {
      shape = candleDrawShape;
    } else if (id.startsWith('my_')) {
      for (final m in lib.mine) {
        if (m.id == id) shape = m.shape;
      }
    } else {
      shape = StampPacks.byId(id)?.shape;
    }
    if (shape == null) return Icon(Icons.help_outline_rounded, size: size, color: Colors.white54);
    final (up, down) = lib.colors;
    return SizedBox(width: size, height: size, child: CustomPaint(painter: StampTile(shape.resolved(up, down))));
  }
}

/// The stamp chosen for a toolbar button ([id]): its picture and name, or
/// null for drawing candles by hand (and unknown ids).
PickedStamp? quickStamp(String id) {
  if (id == StampLibrary.candleDraw) return null;
  final lib = StampLibrary.instance;
  final (up, down) = lib.colors;
  if (id.startsWith('my_')) {
    for (final m in lib.mine) {
      if (m.id == id) return (id: id, shape: m.shape, name: m.name);
    }
    return null;
  }
  final s = StampPacks.byId(id);
  return s == null ? null : (id: id, shape: s.shape.resolved(up, down), name: stampName(id));
}

/// Right-click on a toolbar stamp: another one in its place, or off the
/// toolbar ([pick]: how the stamp panel is opened there).
Future<void> quickMenu(BuildContext context, String id, Offset at, Future<PickedStamp?> Function() pick) async {
  final lib = StampLibrary.instance;
  final v = await showMenu<String>(
    context: context,
    position: RelativeRect.fromLTRB(at.dx, at.dy, at.dx, at.dy),
    items: [
      PopupMenuItem(value: 'swap', child: Text(tr('stamp.quick_swap'))),
      PopupMenuItem(value: 'off', child: Text(tr('stamp.quick_off'))),
    ],
  );
  if (v == 'off') lib.unpinQuick(id);
  if (v == 'swap') {
    final r = await pick();
    if (r != null) lib.pinQuick(r.id, at: lib.quick.indexOf(id));
  }
}
