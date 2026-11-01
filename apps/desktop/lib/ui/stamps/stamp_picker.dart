// apps/desktop/lib/ui/stamps/stamp_picker.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../services/annotations.dart';
import '../../services/stamp_library.dart';
import '../../services/win_dialogs.dart';
import '../player/ink_editor.dart';
import '../player/ink_paint.dart';
import '../theme.dart';

/// A stamp chosen: its picture (rising / falling colours set) and name.
typedef PickedStamp = ({String id, StampShape shape, String name});

/// Choose a stamp, then place it on the picture being drawn on.
Future<void> pickStampInto(BuildContext context, InkEditor editor) async {
  final r = await showStampPicker(context, drawn: editor.inks, aspect: editor.aspect);
  if (r == null) return;
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
  if (id.startsWith('my_')) {
    for (final m in StampLibrary.instance.mine) {
      if (m.id == id) return m.name;
    }
    return '';
  }
  return tr('stamp.$id');
}

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
  late String _tab = _lib.recent.isEmpty ? 'basic' : 'recent';

  @override
  void dispose() {
    _q.dispose();
    super.dispose();
  }

  /// Every stamp there is, by id.
  Map<String, StampShape> get _all => {
        for (final s in StampPacks.all) s.id: s.shape,
        for (final m in _lib.mine) m.id: m.shape,
      };

  List<String> _shown() {
    final all = _all;
    final q = _q.text.trim().toLowerCase();
    if (q.isNotEmpty) {
      return [
        for (final id in all.keys)
          if (stampName(id).toLowerCase().contains(q) || id.replaceAll('_', ' ').contains(q)) id,
      ];
    }
    return switch (_tab) {
      'recent' => [for (final id in _lib.recent) if (all.containsKey(id)) id],
      'fav' => [for (final id in all.keys) if (_lib.favorites.contains(id)) id],
      'mine' => [for (final m in _lib.mine) m.id],
      _ => [for (final s in StampPacks.all) if (s.pack == _tab) s.id],
    };
  }

  void _pick(String id) {
    final (up, down) = _lib.colors;
    final shape = _all[id];
    if (shape == null) return;
    _lib.used(id);
    Navigator.pop(context, (id: id, shape: shape.resolved(up, down), name: stampName(id)));
  }

  Future<void> _menu(String id, Offset at) async {
    final mine = id.startsWith('my_');
    final v = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(at.dx, at.dy, at.dx, at.dy),
      items: [
        PopupMenuItem(value: 'fav', child: Text(tr(_lib.favorites.contains(id) ? 'stamp.unfavorite' : 'stamp.favorite'))),
        if (mine) PopupMenuItem(value: 'rename', child: Text(tr('ink.rename'))),
        if (mine) PopupMenuItem(value: 'delete', child: Text(tr('ink.delete'))),
      ],
    );
    if (!mounted || v == null) return;
    if (v == 'fav') _lib.toggleFavorite(id);
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
              for (final p in StampPacks.packs) _chip(p, tr('stamp.pack_$p')),
              _chip('mine', tr('stamp.mine')),
            ]),
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
                          onTap: () => _pick(id),
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
