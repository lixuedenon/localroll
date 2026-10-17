// apps/mobile/lib/ui/office_view.dart
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/material.dart';
import 'package:localroll_core/localroll_core.dart';

import '../l10n/l10n.dart';
import 'theme.dart';

/// A simple look inside a Word / Excel / PowerPoint file, without Office:
/// text with headings, lists and tables, pictures; each sheet's cells; each
/// slide's text and pictures. Layout is not the original's.
class OfficeViewPage extends StatefulWidget {
  const OfficeViewPage({super.key, required this.path, required this.name, this.actions = const []});

  final String path;
  final String name;
  final List<Widget> actions;

  /// Can this file be shown here (by its name)?
  static bool canShow(String name) {
    final i = name.lastIndexOf('.');
    return i >= 0 && OfficeDoc.canRead(name.substring(i + 1));
  }

  @override
  State<OfficeViewPage> createState() => _OfficeViewPageState();
}

class _OfficeViewPageState extends State<OfficeViewPage> {
  OfficeDoc? _doc;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final path = widget.path;
    final name = widget.name;
    try {
      final doc = await Isolate.run(() {
        final f = File(path);
        if (f.lengthSync() > 80 * 1024 * 1024) return null;
        final i = name.lastIndexOf('.');
        return OfficeDoc.read(f.readAsBytesSync(), i < 0 ? '' : name.substring(i + 1));
      });
      if (!mounted) return;
      setState(() {
        _doc = doc;
        _failed = doc == null;
      });
    } catch (e) {
      DiagLog.log('office', 'read failed: $e');
      if (mounted) setState(() => _failed = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final d = _doc;
    final sheets = d?.kind == OfficeKind.excel ? d!.sheets : const <OfficeSheet>[];
    final page = Scaffold(
      appBar: AppBar(
        title: Text(widget.name, overflow: TextOverflow.ellipsis),
        actions: widget.actions,
        bottom: sheets.length > 1
            ? TabBar(isScrollable: true, tabAlignment: TabAlignment.start, tabs: [for (final s in sheets) Tab(text: s.name)])
            : null,
      ),
      body: _failed
          ? _message(tr('office.cant_read'))
          : d == null
              ? const Center(child: CircularProgressIndicator())
              : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  Container(
                    color: LrColors.surface,
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                    child: Text(tr('office.simple_note'), style: const TextStyle(color: LrColors.muted, fontSize: 12)),
                  ),
                  Expanded(child: _body(d)),
                ]),
    );
    return sheets.length > 1 ? DefaultTabController(length: sheets.length, child: page) : page;
  }

  Widget _message(String t) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(t, textAlign: TextAlign.center, style: const TextStyle(color: LrColors.muted)),
        ),
      );

  Widget _body(OfficeDoc d) {
    switch (d.kind) {
      case OfficeKind.word:
        if (d.blocks.isEmpty) return _thumbOr(d);
        return SelectionArea(
          child: ListView.builder(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
            itemCount: d.blocks.length,
            itemBuilder: (context, i) => _block(d.blocks[i]),
          ),
        );
      case OfficeKind.excel:
        if (d.sheets.isEmpty) return _thumbOr(d);
        if (d.sheets.length == 1) return _sheet(d.sheets.first);
        return TabBarView(children: [for (final s in d.sheets) _sheet(s)]);
      case OfficeKind.powerpoint:
        if (d.slides.isEmpty) return _thumbOr(d);
        return ListView.builder(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 32),
          itemCount: d.slides.length,
          itemBuilder: (context, i) => _slide(i, d.slides[i]),
        );
    }
  }

  Widget _thumbOr(OfficeDoc d) {
    final t = d.thumbnail;
    if (t == null) return _message(tr('office.empty'));
    return InteractiveViewer(maxScale: 5, child: Center(child: Image.memory(t)));
  }

  // ------------------------------------------------------------------ Word

  static const _headingSizes = [0.0, 24.0, 21.0, 19.0, 17.0, 16.0, 15.0];

  Widget _block(OfficeBlock b) {
    switch (b) {
      case OfficeParagraph p:
        if (p.runs.isEmpty) return const SizedBox(height: 8);
        final size = p.heading > 0 ? _headingSizes[p.heading] : 15.0;
        final spans = [
          for (final r in p.runs)
            TextSpan(
              text: r.text,
              style: TextStyle(
                fontWeight: r.bold || p.heading > 0 ? FontWeight.w700 : FontWeight.w400,
                fontStyle: r.italic ? FontStyle.italic : FontStyle.normal,
              ),
            ),
        ];
        return Padding(
          padding: EdgeInsets.only(top: p.heading > 0 ? 14 : 3, bottom: p.heading > 0 ? 6 : 3),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (p.bullet) Padding(padding: EdgeInsets.only(right: 8, left: 4, top: size * 0.15), child: Text('•', style: TextStyle(fontSize: size))),
            Expanded(child: Text.rich(TextSpan(children: spans), style: TextStyle(fontSize: size, height: 1.45))),
          ]),
        );
      case OfficeTable t:
        return Padding(padding: const EdgeInsets.symmetric(vertical: 8), child: _grid(t.rows, headers: false, scrollable: true));
      case OfficeImage img:
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Center(child: Image.memory(img.bytes, fit: BoxFit.contain, errorBuilder: (_, _, _) => const SizedBox.shrink())),
        );
    }
  }

  // ----------------------------------------------------------------- Excel

  static const _showRows = 500;
  static const _showCols = 40;

  Widget _sheet(OfficeSheet s) {
    if (s.rows.isEmpty) return _message(tr('office.empty'));
    final rows = s.rows.length > _showRows ? s.rows.sublist(0, _showRows) : s.rows;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Expanded(
        child: InteractiveViewer(
          constrained: false,
          minScale: 0.3,
          maxScale: 3,
          child: Padding(padding: const EdgeInsets.all(8), child: _grid(rows, headers: true)),
        ),
      ),
      if (s.rows.length > _showRows)
        Padding(
          padding: const EdgeInsets.all(8),
          child: Text(tr('office.more_rows', {'shown': _showRows, 'count': s.rows.length}),
              style: const TextStyle(color: LrColors.muted, fontSize: 12)),
        ),
    ]);
  }

  static String _colName(int i) {
    var n = i + 1;
    var s = '';
    while (n > 0) {
      final r = (n - 1) % 26;
      s = String.fromCharCode(65 + r) + s;
      n = (n - 1) ~/ 26;
    }
    return s;
  }

  /// Cells in a grid; [headers]: A B C… above and 1 2 3… on the left.
  Widget _grid(List<List<String>> rows, {required bool headers, bool scrollable = false}) {
    final cols = rows.fold<int>(0, (m, r) => r.length > m ? r.length : m).clamp(0, _showCols);
    Widget cell(String t, {bool head = false}) => Container(
          color: head ? LrColors.raised : null,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 260),
            child: Text(t,
                style: TextStyle(fontSize: 13, color: head ? LrColors.muted : null, fontWeight: head ? FontWeight.w600 : null)),
          ),
        );
    final table = Table(
      defaultColumnWidth: const IntrinsicColumnWidth(),
      border: TableBorder.all(color: LrColors.line),
      children: [
        if (headers) TableRow(children: [cell('', head: true), for (var c = 0; c < cols; c++) cell(_colName(c), head: true)]),
        for (var r = 0; r < rows.length; r++)
          TableRow(children: [
            if (headers) cell('${r + 1}', head: true),
            for (var c = 0; c < cols; c++) cell(c < rows[r].length ? rows[r][c] : ''),
          ]),
      ],
    );
    return scrollable ? SingleChildScrollView(scrollDirection: Axis.horizontal, child: table) : table;
  }

  // ------------------------------------------------------------ PowerPoint

  Widget _slide(int i, OfficeSlide s) => Container(
        margin: const EdgeInsets.only(bottom: 14),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: LrColors.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: LrColors.line),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(tr('office.slide', {'n': i + 1}), style: const TextStyle(color: LrColors.muted, fontSize: 12)),
          const SizedBox(height: 6),
          for (var k = 0; k < s.paragraphs.length; k++)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: SelectableText(s.paragraphs[k],
                  style: TextStyle(fontSize: k == 0 ? 19 : 15, fontWeight: k == 0 ? FontWeight.w700 : FontWeight.w400, height: 1.4)),
            ),
          for (final img in s.images)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Image.memory(img, fit: BoxFit.contain, errorBuilder: (_, _, _) => const SizedBox.shrink()),
            ),
        ]),
      );
}
