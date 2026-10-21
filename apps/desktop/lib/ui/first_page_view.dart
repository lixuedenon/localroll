// apps/desktop/lib/ui/first_page_view.dart
import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:localroll_core/localroll_core.dart';

/// First pages of documents (Word, Excel, PowerPoint, text, CSV), read in
/// the background — two files at a time — and kept for a while, so a list
/// scrolls without reading files again.
class FirstPages {
  FirstPages._();

  /// Remembered per file version; a failure (the file busy just after it
  /// arrived — a virus scanner reading it) is not remembered for good.
  static final SoftCache<FirstPage> _cache = SoftCache(max: 300);
  static int _running = 0;
  static final Queue<Completer<void>> _waiting = Queue();

  /// Largest Office file read for a thumbnail.
  static const int maxOffice = 60 * 1024 * 1024;

  /// The first page of the file at [path] ([name]: what it is called, for
  /// its kind; default its own name). Null if it can't be drawn. Tried a
  /// few times when the file can't be read yet.
  static Future<FirstPage?> of(String path, {String? name}) async {
    final shown = name ?? path.split(Platform.pathSeparator).last.split('/').last;
    if (!FirstPage.canDraw(shown)) return null;
    final FileStat st;
    try {
      st = await File(path).stat();
    } catch (_) {
      return null;
    }
    final key = '$path|${st.size}|${st.modified.millisecondsSinceEpoch}';
    return _cache.get(key, () => retryWhileNull(() => _readOnce(path, shown)));
  }

  static Future<FirstPage?> _readOnce(String path, String name) async {
    final (page, problem) = await _limited(() => Isolate.run(() => _read(path, name)));
    if (problem != null) DiagLog.log('thumb', 'first page of $name not read: $problem');
    return page;
  }

  /// The page, or why not (null, null: nothing to draw).
  static (FirstPage?, String?) _read(String path, String name) {
    try {
      final f = File(path);
      final len = f.lengthSync();
      final dot = name.lastIndexOf('.');
      final ext = dot < 0 ? '' : name.substring(dot + 1).toLowerCase();
      final Uint8List data;
      if (OfficeDoc.canRead(ext)) {
        if (len > maxOffice) return (null, null);
        data = f.readAsBytesSync();
      } else {
        final raf = f.openSync();
        try {
          data = raf.readSync(min(len, FirstPage.textHead));
        } finally {
          raf.closeSync();
        }
      }
      return (FirstPage.of(name, data), null);
    } catch (e) {
      return (null, '$e');
    }
  }

  static Future<T> _limited<T>(Future<T> Function() task) async {
    while (_running >= 2) {
      final c = Completer<void>();
      _waiting.add(c);
      await c.future;
    }
    _running++;
    try {
      return await task();
    } finally {
      _running--;
      if (_waiting.isNotEmpty) _waiting.removeFirst().complete();
    }
  }
}

/// A document's first page drawn small: a white page (Word, text), a grid
/// (Excel, CSV) or a slide (PowerPoint). Fills its box, top first.
class FirstPageView extends StatelessWidget {
  const FirstPageView({super.key, required this.page});

  final FirstPage page;

  static const Color _ink = Color(0xFF202124);
  static const Color _soft = Color(0xFF5F6368);
  static const Color _line = Color(0xFFDADCE0);

  @override
  Widget build(BuildContext context) {
    final cover = page.cover;
    if (cover != null) {
      return Container(
        color: Colors.white,
        child: Image.memory(cover, fit: BoxFit.cover, alignment: Alignment.topCenter, gaplessPlayback: true,
            errorBuilder: (_, _, _) => _drawn()),
      );
    }
    return _drawn();
  }

  Widget _drawn() => ClipRect(
        child: Container(
          color: page.layout == FirstPageLayout.slide ? const Color(0xFFF1F3F4) : Colors.white,
          child: FittedBox(
            fit: page.layout == FirstPageLayout.slide ? BoxFit.contain : BoxFit.cover,
            alignment: Alignment.topCenter,
            child: switch (page.layout) {
              FirstPageLayout.page => _page(),
              FirstPageLayout.sheet => _sheet(),
              FirstPageLayout.slide => _slide(),
            },
          ),
        ),
      );

  /// Clips what doesn't fit instead of overflowing.
  static Widget _fit(double w, double h, EdgeInsets pad, List<Widget> children) => SizedBox(
        width: w,
        height: h,
        child: ClipRect(
          child: Padding(
            padding: pad,
            child: OverflowBox(
              alignment: Alignment.topLeft,
              minHeight: 0,
              maxHeight: double.infinity,
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: children),
            ),
          ),
        ),
      );

  static TextStyle _style(FirstPageLine l) => TextStyle(
        color: l.heading > 0 ? _ink : _soft,
        fontSize: switch (l.heading) { 1 => 15.0, 2 => 12.0, 3 => 10.5, 0 => 7.5, _ => 9.0 },
        height: 1.3,
        fontWeight: l.heading > 0 || l.bold ? FontWeight.w700 : FontWeight.w400,
      );

  Widget _text(FirstPageLine l, {int maxLines = 3}) => Padding(
        padding: EdgeInsets.only(bottom: l.heading > 0 ? 5 : 2),
        child: Text('${l.bullet ? '•  ' : ''}${l.text}', maxLines: maxLines, overflow: TextOverflow.clip, style: _style(l)),
      );

  Widget _page() => _fit(210, 297, const EdgeInsets.fromLTRB(16, 18, 16, 10), [
        for (final l in page.lines) _text(l),
        if (page.picture != null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 90, maxWidth: 178),
              child: Image.memory(page.picture!, fit: BoxFit.contain, errorBuilder: (_, _, _) => const SizedBox.shrink()),
            ),
          ),
        if (page.table.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 4), child: _grid(page.table, 178, 7)),
      ]);

  Widget _sheet() => _fit(260, 190, const EdgeInsets.all(6), [_grid(page.table, 248, 7.5, header: true)]);

  static Widget _grid(List<List<String>> rows, double width, double size, {bool header = false}) {
    final cols = rows.isEmpty ? 0 : rows.first.length;
    if (cols == 0) return const SizedBox.shrink();
    return SizedBox(
      width: width,
      child: Table(
        border: TableBorder.all(color: _line, width: 0.6),
        defaultColumnWidth: const FlexColumnWidth(),
        children: [
          for (var r = 0; r < rows.length; r++)
            TableRow(
              decoration: BoxDecoration(color: header && r == 0 ? const Color(0xFFE8F0FE) : null),
              children: [
                for (final c in rows[r])
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 1.5),
                    child: Text(c,
                        maxLines: 1,
                        overflow: TextOverflow.clip,
                        softWrap: false,
                        style: TextStyle(
                            fontSize: size, color: _ink, fontWeight: header && r == 0 ? FontWeight.w700 : FontWeight.w400)),
                  ),
              ],
            ),
        ],
      ),
    );
  }

  Widget _slide() {
    final pic = page.picture;
    return SizedBox(
      width: 320,
      height: 180,
      child: Container(
        color: Colors.white,
        child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Expanded(
            flex: 3,
            child: _fit(pic == null ? 320 : 190, 180, const EdgeInsets.fromLTRB(16, 18, 10, 8), [
              for (final l in page.lines)
                _text(l.heading > 0 ? FirstPageLine(l.text, heading: 1) : l, maxLines: l.heading > 0 ? 2 : 1),
            ]),
          ),
          if (pic != null)
            Expanded(
              flex: 2,
              child: Padding(
                padding: const EdgeInsets.all(10),
                child: Image.memory(pic, fit: BoxFit.contain, errorBuilder: (_, _, _) => const SizedBox.shrink()),
              ),
            ),
        ]),
      ),
    );
  }
}
