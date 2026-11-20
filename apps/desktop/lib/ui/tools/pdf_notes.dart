// apps/desktop/lib/ui/tools/pdf_notes.dart
// Notes in a PDF (PDF text annotations — from Keepnear's numbers or from
// another program) shown on the page: hover for the words, click to read
// them all. And Keepnear's own marks kept inside a file so they can be
// changed again later (packed / unpacked here).

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:localroll_core/localroll_core.dart' show DiagLog;

import '../../l10n/l10n.dart';
import '../../services/annotations.dart';
import '../../services/file_tools.dart';

/// A number's words as a PDF note: its icon just outside the number's
/// circle (up and right), so the number stays readable; [pw] × [ph]: the
/// page's size (points).
PdfNote numberNote(InkMark m, double pw, double ph) {
  final size = Size(pw, ph);
  final r = InkGeometry.box(m, size);
  final c = r.center;
  return PdfNote(
    ((r.right + 9) / pw).clamp(0.0, 1.0),
    ((r.top - 9) / ph).clamp(0.0, 1.0),
    '${m.number ?? ''}. ${m.note}',
    rgb: (m.color & 0xFFFFFF).toRadixString(16).padLeft(6, '0'),
    ax: (c.dx / pw).clamp(0.0, 1.0),
    ay: (c.dy / ph).clamp(0.0, 1.0),
  );
}

/// Marks → the text kept in a PDF (zlib-packed JSON, base64).
String packMarks(List<InkMark> inks) =>
    base64.encode(zlib.encode(utf8.encode(jsonEncode({'v': 1, 'inks': [for (final m in inks) m.toJson()]}))));

/// The text kept in a PDF → marks (none when it can't be read).
List<InkMark> unpackMarks(String data) {
  try {
    final j = jsonDecode(utf8.decode(zlib.decode(base64.decode(data))));
    if (j is! Map<String, dynamic>) return const [];
    return [for (final i in (j['inks'] as List?) ?? const []) if (i is Map<String, dynamic>) InkMark.fromJson(i)];
  } catch (e) {
    DiagLog.log('tools', 'marks not read: $e');
    return const [];
  }
}

/// The markers of [notes] on a page of [size] (for a Stack the page's
/// size). Keepnear's own (on its numbers): a see-through spot with a small
/// dot; others: a note icon.
List<Widget> noteMarkers(BuildContext context, List<PdfNoteAt> notes, Size size) => [
      for (final n in notes)
        Positioned(
          left: n.x * size.width - 14,
          top: n.y * size.height - 14,
          width: 28,
          height: 28,
          child: _NoteMark(note: n),
        ),
    ];

class _NoteMark extends StatelessWidget {
  const _NoteMark({required this.note});

  final PdfNoteAt note;

  @override
  Widget build(BuildContext context) => Tooltip(
        message: note.text,
        waitDuration: const Duration(milliseconds: 150),
        preferBelow: false,
        textStyle: const TextStyle(color: Colors.white, fontSize: 13, height: 1.4),
        decoration: BoxDecoration(color: const Color(0xEE1F2937), borderRadius: BorderRadius.circular(8)),
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
            onTap: () => showDialog<void>(
              context: context,
              builder: (c) => AlertDialog(
                title: Text(tr('notes.title')),
                content: SizedBox(width: 420, child: SelectableText(note.text)),
                actions: [TextButton(onPressed: () => Navigator.pop(c), child: Text(tr('common.close')))],
              ),
            ),
            child: note.own
                ? Stack(children: [
                    const Positioned.fill(child: ColoredBox(color: Colors.transparent)),
                    Positioned(
                      right: 0,
                      top: 0,
                      child: Container(
                        width: 9,
                        height: 9,
                        decoration: BoxDecoration(
                          color: const Color(0xFFFFC53D),
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.white, width: 1.5),
                        ),
                      ),
                    ),
                  ])
                : const Icon(Icons.sticky_note_2_rounded, size: 22, color: Color(0xFFFFB020)),
          ),
        ),
      );
}
