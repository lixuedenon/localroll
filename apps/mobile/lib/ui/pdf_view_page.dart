// apps/mobile/lib/ui/pdf_view_page.dart
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../l10n/l10n.dart';
import '../services/pdf_pages.dart';
import 'theme.dart';

/// Reads a PDF inside LocalRoll: swipe between pages, pinch to zoom.
/// "Share" hands it to other apps (print, mail, another PDF app…).
class PdfViewPage extends StatefulWidget {
  const PdfViewPage({super.key, required this.path, this.title});

  final String path;
  final String? title;

  @override
  State<PdfViewPage> createState() => _PdfViewPageState();
}

class _PdfViewPageState extends State<PdfViewPage> {
  int? _count;
  int _page = 0;
  final Map<int, Future<Uint8List?>> _pages = {};

  String get _name => widget.title ?? widget.path.split(Platform.pathSeparator).last;

  @override
  void initState() {
    super.initState();
    PdfPages.count(widget.path).then((n) {
      if (mounted) setState(() => _count = n);
    });
  }

  Future<Uint8List?> _pageAt(int i, int width) => _pages.putIfAbsent(i, () => PdfPages.render(widget.path, i, width));

  Future<void> _share(BuildContext buttonContext) async {
    final box = buttonContext.findRenderObject() as RenderBox?;
    await SharePlus.instance.share(ShareParams(
      files: [XFile(widget.path, mimeType: 'application/pdf')],
      sharePositionOrigin: box == null ? null : box.localToGlobal(Offset.zero) & box.size,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final n = _count;
    final mq = MediaQuery.of(context);
    final width = (mq.size.width * mq.devicePixelRatio * 1.5).round();
    return Scaffold(
      backgroundColor: LrColors.ink,
      appBar: AppBar(
        title: Text(_name, overflow: TextOverflow.ellipsis),
        actions: [
          Builder(
            builder: (c) => IconButton(
              tooltip: tr('mylib.share'),
              onPressed: () => _share(c),
              icon: const Icon(Icons.ios_share_rounded),
            ),
          ),
        ],
      ),
      body: n == null
          ? const Center(child: CircularProgressIndicator())
          : n == 0
              ? Center(child: Text(tr('mylib.cannot_open'), style: const TextStyle(color: LrColors.muted)))
              : Stack(children: [
                  PageView.builder(
                    itemCount: n,
                    onPageChanged: (i) => setState(() => _page = i),
                    itemBuilder: (context, i) => FutureBuilder<Uint8List?>(
                      future: _pageAt(i, width),
                      builder: (context, s) {
                        if (s.connectionState != ConnectionState.done) {
                          return const Center(child: CircularProgressIndicator());
                        }
                        final b = s.data;
                        if (b == null) {
                          return Center(child: Text(tr('mylib.cannot_open'), style: const TextStyle(color: LrColors.muted)));
                        }
                        return InteractiveViewer(
                          maxScale: 6,
                          child: Center(
                            child: Padding(
                              padding: const EdgeInsets.all(8),
                              child: Image.memory(b, fit: BoxFit.contain, gaplessPlayback: true),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                  if (n > 1)
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 16 + mq.padding.bottom,
                      child: Center(
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
                          decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(14)),
                          child: Text('${_page + 1} / $n', style: const TextStyle(color: Colors.white, fontSize: 13)),
                        ),
                      ),
                    ),
                ]),
    );
  }
}
