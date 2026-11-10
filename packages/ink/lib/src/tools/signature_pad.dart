// packages/ink/lib/src/tools/signature_pad.dart
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// A signature drawn with the mouse / a finger: its picture (see-through
/// around the lines), cut to the lines.
class Signature {
  Signature(this.image, this.png);

  final ui.Image image;
  final Uint8List png;

  int get width => image.width;
  int get height => image.height;

  /// The pixels as blue-green-red-alpha rows (what a PDF writer takes).
  Future<Uint8List?> bgra() async {
    final d = await image.toByteData(format: ui.ImageByteFormat.rawStraightRgba);
    if (d == null) return null;
    final b = d.buffer.asUint8List();
    for (var i = 0; i + 3 < b.length; i += 4) {
      final r = b[i];
      b[i] = b[i + 2];
      b[i + 2] = r;
    }
    return b;
  }
}

/// Sign here: draw, clear, pick the ink. [texts]: 'title', 'clear', 'cancel',
/// 'ok', 'hint'.
Future<Signature?> showSignaturePad(BuildContext context, String Function(String key) texts) =>
    showDialog<Signature>(context: context, builder: (_) => _SignaturePad(texts: texts));

class _SignaturePad extends StatefulWidget {
  const _SignaturePad({required this.texts});

  final String Function(String) texts;

  @override
  State<_SignaturePad> createState() => _SignaturePadState();
}

class _SignaturePadState extends State<_SignaturePad> {
  final List<List<Offset>> _lines = [];
  Color _ink = const Color(0xFF1D3FA0);
  static const Size _size = Size(560, 220);

  Future<void> _done() async {
    if (_lines.every((l) => l.length < 2)) return;
    // Drawn three times larger, so it stays sharp on a printed page.
    const k = 3.0;
    var minX = double.infinity, minY = double.infinity, maxX = -double.infinity, maxY = -double.infinity;
    for (final l in _lines) {
      for (final p in l) {
        if (p.dx < minX) minX = p.dx;
        if (p.dy < minY) minY = p.dy;
        if (p.dx > maxX) maxX = p.dx;
        if (p.dy > maxY) maxY = p.dy;
      }
    }
    const pad = 6.0;
    minX -= pad;
    minY -= pad;
    maxX += pad;
    maxY += pad;
    final w = ((maxX - minX) * k).ceil().clamp(8, 4000);
    final h = ((maxY - minY) * k).ceil().clamp(8, 4000);
    final rec = ui.PictureRecorder();
    final c = Canvas(rec);
    c.scale(k);
    c.translate(-minX, -minY);
    _paint(c, _lines, _ink);
    final img = await rec.endRecording().toImage(w, h);
    final png = await img.toByteData(format: ui.ImageByteFormat.png);
    if (!mounted || png == null) return;
    Navigator.pop(context, Signature(img, png.buffer.asUint8List()));
  }

  static void _paint(Canvas c, List<List<Offset>> lines, Color ink) {
    final p = Paint()
      ..color = ink
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke;
    for (final l in lines) {
      if (l.length == 1) {
        c.drawCircle(l.first, 1.5, p..style = PaintingStyle.fill);
        p.style = PaintingStyle.stroke;
        continue;
      }
      final path = Path()..moveTo(l.first.dx, l.first.dy);
      for (var i = 1; i < l.length; i++) {
        final a = l[i - 1], b = l[i];
        path.quadraticBezierTo(a.dx, a.dy, (a.dx + b.dx) / 2, (a.dy + b.dy) / 2);
      }
      path.lineTo(l.last.dx, l.last.dy);
      c.drawPath(path, p);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.texts;
    return AlertDialog(
      title: Text(t('title')),
      content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(t('hint'), style: const TextStyle(fontSize: 13, color: Colors.grey)),
        const SizedBox(height: 10),
        Container(
          width: _size.width,
          height: _size.height,
          decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(10), border: Border.all(color: Colors.black26)),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: GestureDetector(
              onPanStart: (d) => setState(() => _lines.add([d.localPosition])),
              onPanUpdate: (d) => setState(() => _lines.last.add(d.localPosition)),
              child: CustomPaint(size: _size, painter: _Pad(_lines, _ink)),
            ),
          ),
        ),
        const SizedBox(height: 10),
        Row(children: [
          for (final c in const [Color(0xFF1D3FA0), Color(0xFF111111), Color(0xFFC62828)])
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: InkWell(
                onTap: () => setState(() => _ink = c),
                child: Container(
                  width: 26,
                  height: 26,
                  decoration: BoxDecoration(
                    color: c,
                    shape: BoxShape.circle,
                    border: Border.all(color: _ink == c ? Colors.orange : Colors.white, width: 3),
                  ),
                ),
              ),
            ),
          const Spacer(),
          TextButton(onPressed: () => setState(_lines.clear), child: Text(t('clear'))),
        ]),
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(t('cancel'))),
        FilledButton(onPressed: _lines.isEmpty ? null : _done, child: Text(t('ok'))),
      ],
    );
  }
}

class _Pad extends CustomPainter {
  _Pad(this.lines, this.ink);

  final List<List<Offset>> lines;
  final Color ink;

  @override
  void paint(Canvas canvas, Size size) {
    final base = Paint()
      ..color = Colors.black26
      ..strokeWidth = 1;
    canvas.drawLine(Offset(24, size.height - 50), Offset(size.width - 24, size.height - 50), base);
    _SignaturePadState._paint(canvas, lines, ink);
  }

  @override
  bool shouldRepaint(_Pad old) => true;
}
