// apps/desktop/lib/ui/pdf_viewer_page.dart
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:localroll_core/localroll_core.dart';
import 'package:pdfrx/pdfrx.dart';

import '../l10n/l10n.dart';
import '../services/network.dart';
import 'theme.dart';

/// Reads a PDF inside LocalRoll (scans and documents that arrived): scroll
/// through the pages, zoom with the buttons, Ctrl + wheel or a pinch, jump
/// to a page. "Open with…" hands it to the PC's usual PDF program.
class PdfViewerPage extends StatefulWidget {
  const PdfViewerPage({super.key, required this.path});

  final String path;

  @override
  State<PdfViewerPage> createState() => _PdfViewerPageState();
}

class _PdfViewerPageState extends State<PdfViewerPage> {
  final PdfViewerController _c = PdfViewerController();
  final FocusNode _focus = FocusNode();
  int _page = 1;
  int _count = 0;

  String get _name => widget.path.split(Platform.pathSeparator).last;

  @override
  void initState() {
    super.initState();
    DiagLog.log('ui', 'pdf reader open');
  }

  @override
  void dispose() {
    DiagLog.log('ui', 'pdf reader closed');
    _focus.dispose();
    super.dispose();
  }

  void _go(int page) {
    if (_count == 0) return;
    final p = page.clamp(1, _count);
    _c.goToPage(pageNumber: p);
  }

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
        appBar: AppBar(
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
            const SizedBox(width: 8),
          ],
        ),
        body: Container(
          color: LrColors.ink,
          child: PdfViewer.file(
            widget.path,
            controller: _c,
            params: PdfViewerParams(
              backgroundColor: LrColors.ink,
              maxScale: 8,
              onViewerReady: (document, controller) {
                DiagLog.log('ui', 'pdf ready: ${document.pages.length} pages');
                if (mounted) setState(() => _count = document.pages.length);
              },
              onPageChanged: (n) {
                if (n != null && mounted) setState(() => _page = n);
              },
            ),
          ),
        ),
      ),
    );
  }
}

/// Shown in LocalRoll's own reader (other kinds open with their program).
bool isPdfPath(String path) => path.toLowerCase().endsWith('.pdf');
