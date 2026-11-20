// apps/desktop/lib/ui/pdf_viewer_page.dart
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:localroll_core/localroll_core.dart';
import 'package:pdfrx/pdfrx.dart';

import '../app_services.dart';
import '../l10n/l10n.dart';
import '../services/file_tools.dart';
import '../services/network.dart';
import 'theme.dart';
import 'tools/pdf_text_edit.dart';
import 'tools/ocr_box_page.dart';
import 'tools/pdf_notes.dart';
import 'tools/print_page.dart';
import 'trash_actions.dart';

/// Reads a PDF inside LocalRoll (scans and documents that arrived): scroll
/// through the pages, zoom with the buttons, Ctrl + wheel or a pinch, jump
/// to a page. "Open with…" hands it to the PC's usual PDF program.
class PdfViewerPage extends StatefulWidget {
  const PdfViewerPage({super.key, required this.path, this.services});

  final String path;

  /// Given: a "Delete" button (into "Recently deleted").
  final AppServices? services;

  @override
  State<PdfViewerPage> createState() => _PdfViewerPageState();
}

class _PdfViewerPageState extends State<PdfViewerPage> {
  Future<void> _delete(AppServices s) async {
    if (await deleteOneFile(context, s, widget.path) && mounted) Navigator.of(context).maybePop();
  }

  final PdfViewerController _c = PdfViewerController();
  final FocusNode _focus = FocusNode();
  int _page = 1;
  int _count = 0;

  /// Notes in the file (numbers' words, other programs' notes).
  List<PdfNoteAt> _notes = const [];

  /// The page number typed (Enter: go there); the pages down the left.
  final TextEditingController _pageCtl = TextEditingController();
  final FocusNode _pageFocus = FocusNode();
  final ScrollController _thumbScroll = ScrollController();
  PdfDocument? _doc;
  bool _thumbs = false;

  String get _name => widget.path.split(Platform.pathSeparator).last;

  @override
  void initState() {
    super.initState();
    DiagLog.log('ui', 'pdf reader open');
    unawaited(PdfBuilder.notesOf(widget.path).then((n) {
      if (mounted && n.isNotEmpty) setState(() => _notes = n);
    }));
  }

  @override
  void dispose() {
    DiagLog.log('ui', 'pdf reader closed');
    _focus.dispose();
    _pageCtl.dispose();
    _pageFocus.dispose();
    _thumbScroll.dispose();
    super.dispose();
  }

  void _go(int page) {
    if (_count == 0) return;
    final p = page.clamp(1, _count);
    _c.goToPage(pageNumber: p);
  }

  void _showPage(int n) {
    _page = n;
    if (!_pageFocus.hasFocus) _pageCtl.text = '$n';
    // The page's picture in view down the left.
    if (_thumbs && _thumbScroll.hasClients) {
      const h = 182.0;
      final y = (n - 1) * h;
      final pos = _thumbScroll.position;
      if (y < pos.pixels || y + h > pos.pixels + pos.viewportDimension) {
        unawaited(_thumbScroll.animateTo((y - pos.viewportDimension / 3).clamp(0.0, pos.maxScrollExtent),
            duration: const Duration(milliseconds: 200), curve: Curves.easeOut));
      }
    }
  }

  /// 首页 · 上一页 · [ n ] / N · 下一页 · 尾页 · the pages down the left.
  Widget _pageBar() => Container(
        color: const Color(0xFF151A24),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          IconButton(
            tooltip: tr('pdf.thumbs'),
            isSelected: _thumbs,
            onPressed: () => setState(() => _thumbs = !_thumbs),
            icon: const Icon(Icons.view_sidebar_outlined, color: Colors.white70),
            selectedIcon: const Icon(Icons.view_sidebar_rounded, color: Colors.white),
          ),
          const SizedBox(width: 16),
          IconButton(
            tooltip: '${tr('pdf.first')} (Home)',
            onPressed: _page > 1 ? () => _go(1) : null,
            icon: const Icon(Icons.first_page_rounded, color: Colors.white70),
          ),
          IconButton(
            tooltip: tr('pdf.prev'),
            onPressed: _page > 1 ? () => _go(_page - 1) : null,
            icon: const Icon(Icons.chevron_left_rounded, color: Colors.white70),
          ),
          SizedBox(
            width: 64,
            child: TextField(
              controller: _pageCtl,
              focusNode: _pageFocus,
              textAlign: TextAlign.center,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              style: const TextStyle(color: Colors.white, fontSize: 14),
              decoration: const InputDecoration(
                isDense: true,
                contentPadding: EdgeInsets.symmetric(vertical: 8),
                enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: Colors.white24)),
                focusedBorder: OutlineInputBorder(borderSide: BorderSide(color: Colors.white70)),
              ),
              onSubmitted: (v) {
                final n = int.tryParse(v);
                if (n != null) _go(n);
                _focus.requestFocus();
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Text('/ $_count', style: const TextStyle(color: Colors.white70)),
          ),
          IconButton(
            tooltip: tr('pdf.next'),
            onPressed: _page < _count ? () => _go(_page + 1) : null,
            icon: const Icon(Icons.chevron_right_rounded, color: Colors.white70),
          ),
          IconButton(
            tooltip: '${tr('pdf.last')} (End)',
            onPressed: _page < _count ? () => _go(_count) : null,
            icon: const Icon(Icons.last_page_rounded, color: Colors.white70),
          ),
          const SizedBox(width: 64),
        ]),
      );

  /// Every page small, down the left: click to go there.
  Widget _thumbList(PdfDocument d) => Container(
        width: 150,
        color: const Color(0xFF151A24),
        child: ListView.builder(
          controller: _thumbScroll,
          itemExtent: 182,
          itemCount: d.pages.length,
          itemBuilder: (_, i) {
            final on = i + 1 == _page;
            final pg = d.pages[i];
            return InkWell(
              onTap: () => _go(i + 1),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 10, 14, 4),
                child: Column(children: [
                  Expanded(
                    child: Center(
                      child: AspectRatio(
                        aspectRatio: pg.width / pg.height,
                        child: Container(
                          decoration: BoxDecoration(
                            color: Colors.white,
                            border: Border.all(color: on ? const Color(0xFF4C8DFF) : Colors.transparent, width: 3),
                          ),
                          child: PdfPageView(key: ValueKey('t$i'), document: d, pageNumber: i + 1, maximumDpi: 36),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text('${i + 1}', style: TextStyle(color: on ? Colors.white : Colors.white54, fontSize: 12)),
                ]),
              ),
            );
          },
        ),
      );

  @override
  Widget build(BuildContext context) {
    return KeyboardListener(
      focusNode: _focus,
      autofocus: true,
      onKeyEvent: (e) {
        if (e is! KeyDownEvent) return;
        final k = e.logicalKey;
        if (k == LogicalKeyboardKey.escape) Navigator.of(context).maybePop();
        if (k == LogicalKeyboardKey.pageDown) _go(_page + 1);
        if (k == LogicalKeyboardKey.pageUp) _go(_page - 1);
        if (k == LogicalKeyboardKey.home) _go(1);
        if (k == LogicalKeyboardKey.end) _go(_count);
        if (k == LogicalKeyboardKey.equal || k == LogicalKeyboardKey.add || k == LogicalKeyboardKey.numpadAdd) _c.zoomUp();
        if (k == LogicalKeyboardKey.minus || k == LogicalKeyboardKey.numpadSubtract) _c.zoomDown();
      },
      child: Scaffold(
        appBar: AppBar(automaticallyImplyLeading: false,
          title: Text(_name, overflow: TextOverflow.ellipsis),
          actions: [
            IconButton(tooltip: tr('pdf.zoom_out'), onPressed: () => _c.zoomDown(), icon: const Icon(Icons.zoom_out_rounded)),
            IconButton(tooltip: tr('pdf.zoom_in'), onPressed: () => _c.zoomUp(), icon: const Icon(Icons.zoom_in_rounded)),
            const SizedBox(width: 8),
            IconButton(
              tooltip: tr('pdf.prev'),
              onPressed: _page > 1 ? () => _go(_page - 1) : null,
              icon: const Icon(Icons.keyboard_arrow_up_rounded),
            ),
            Center(child: Text(_count == 0 ? '' : '$_page / $_count', style: const TextStyle(color: LrColors.muted))),
            IconButton(
              tooltip: tr('pdf.next'),
              onPressed: _page < _count ? () => _go(_page + 1) : null,
              icon: const Icon(Icons.keyboard_arrow_down_rounded),
            ),
            const SizedBox(width: 8),
            IconButton(
              tooltip: tr('common.show_in_folder'),
              onPressed: () => revealInExplorer(widget.path),
              icon: const Icon(Icons.drive_folder_upload_rounded),
            ),
            IconButton(
              tooltip: tr('pdf.open_with'),
              onPressed: () => Process.run('explorer.exe', [widget.path]),
              icon: const Icon(Icons.open_in_new_rounded),
            ),
            if (widget.services case final s?) ...[
              IconButton(
                tooltip: tr('ocrbox.title'),
                onPressed: () => unawaited(openOcrBox(context, s, widget.path)),
                icon: const Icon(Icons.document_scanner_outlined),
              ),
              IconButton(
                tooltip: tr('edit.title'),
                onPressed: () => unawaited(openEditor(context, s, widget.path)),
                icon: const Icon(Icons.edit_document),
              ),
              IconButton(
                tooltip: tr('print.menu'),
                onPressed: () => unawaited(openPrint(context, s, [widget.path])),
                icon: const Icon(Icons.print_rounded),
              ),
            ],
            if (widget.services case final s?)
              IconButton(
                tooltip: tr('lib.delete'),
                onPressed: () => unawaited(_delete(s)),
                icon: const Icon(Icons.delete_outline_rounded, color: LrColors.danger),
              ),
            const SizedBox(width: 8),
          ],
        ),
        bottomNavigationBar: _count > 1 ? _pageBar() : null,
        body: Row(children: [
          if (_thumbs && _doc != null) _thumbList(_doc!),
          Expanded(
            child: Container(
          color: LrColors.ink,
          child: PdfViewer.file(
            widget.path,
            controller: _c,
            params: PdfViewerParams(
              backgroundColor: LrColors.ink,
              maxScale: 8,
              onViewerReady: (document, controller) {
                DiagLog.log('ui', 'pdf ready: ${document.pages.length} pages');
                if (mounted) {
                  setState(() {
                    _count = document.pages.length;
                    _doc = document;
                    _pageCtl.text = '$_page';
                  });
                }
              },
              onPageChanged: (n) {
                if (n != null && mounted) setState(() => _showPage(n));
              },
              // A thumb down the right: drag it to any page (its number shown).
              viewerOverlayBuilder: (context, size, handleLinkTap) => [
                PdfViewerScrollThumb(
                  controller: _c,
                  orientation: ScrollbarOrientation.right,
                  thumbSize: const Size(52, 30),
                  thumbBuilder: (context, thumbSize, pageNumber, controller) => Container(
                    decoration: BoxDecoration(
                      color: const Color(0xEE2F6BFF),
                      borderRadius: BorderRadius.circular(15),
                      boxShadow: const [BoxShadow(color: Color(0x55000000), blurRadius: 6)],
                    ),
                    alignment: Alignment.center,
                    child: Text(pageNumber == null ? '' : '$pageNumber',
                        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 13)),
                  ),
                ),
              ],
              // Notes on their pages: hover for the words.
              pageOverlaysBuilder: _notes.isEmpty
                  ? null
                  : (context, rect, page) => [
                        Positioned.fill(
                          child: LayoutBuilder(
                            builder: (context, box) => Stack(clipBehavior: Clip.none, children: [
                              ...noteMarkers(context, [for (final n in _notes) if (n.page == page.pageNumber - 1) n], box.biggest),
                            ]),
                          ),
                        ),
                      ],
            ),
          ),
            ),
          ),
        ]),
      ),
    );
  }
}

/// Shown in LocalRoll's own reader (other kinds open with their program).
bool isPdfPath(String path) => path.toLowerCase().endsWith('.pdf');
