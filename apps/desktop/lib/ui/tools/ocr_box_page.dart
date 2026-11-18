// apps/desktop/lib/ui/tools/ocr_box_page.dart
import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:localroll_core/localroll_core.dart' show DiagLog;

import '../../app_services.dart';
import '../../l10n/l10n.dart';
import '../../services/tool_outputs.dart';
import '../../services/windows_ocr.dart';
import '../theme.dart';
import 'doc_pages.dart';
import 'tools.dart';

/// Reads the words in a box drawn on a page (a scan, a photo, a PDF made of
/// pictures) — or the whole page — with Windows' own text recognition, on
/// this PC.
class OcrBoxPage extends StatefulWidget {
  const OcrBoxPage({super.key, required this.services, required this.path, this.page = 0});

  final AppServices services;
  final String path;

  /// The page shown first (0-based).
  final int page;

  @override
  State<OcrBoxPage> createState() => _OcrBoxPageState();
}

class _OcrBoxPageState extends State<OcrBoxPage> {
  DocPages? _doc;
  String? _why;
  int _at = 0;
  Rect? _box; // 0–1 of the page
  Offset? _from;
  bool _reading = false;
  final TextEditingController _text = TextEditingController();
  static final WindowsOcr _ocr = WindowsOcr();

  AppServices get s => widget.services;

  @override
  void initState() {
    super.initState();
    unawaited(DocPages.open(s, widget.path, why: (w) => _why = w).then((d) {
      if (!mounted) return;
      setState(() {
        _doc = d;
        if (d == null) _why ??= 'kind';
        if (d != null) _at = widget.page.clamp(0, d.count - 1);
      });
    }));
  }

  @override
  void dispose() {
    _text.dispose();
    unawaited(_doc?.dispose());
    super.dispose();
  }

  /// Reads [part] of the page (the whole page: null).
  Future<void> _read(Rect? part) async {
    final d = _doc;
    if (d == null) return;
    setState(() => _reading = true);
    try {
      final r = part ?? const Rect.fromLTWH(0, 0, 1, 1);
      // Small boxes are made larger: the reader wants letters 20+ px high.
      final pts = d.points(_at);
      final w = (r.width * pts.width * 4).clamp(400, 4000).round();
      final pic = await d.render(_at, r, w);
      if (pic == null) throw 'no picture';
      final png = await pic.toByteData(format: ui.ImageByteFormat.png);
      pic.dispose();
      final f = File('${Directory.systemTemp.path}${Platform.pathSeparator}keepnear_ocr_${DateTime.now().millisecondsSinceEpoch}.png');
      await f.writeAsBytes(png!.buffer.asUint8List(), flush: true);
      final text = await _ocr.read(f.path);
      unawaited(f.delete().then((_) {}, onError: (_) {}));
      DiagLog.log('tools', 'ocr box: ${text == null ? 'nothing' : '${text.length} chars'}');
      if (!mounted) return;
      setState(() => _text.text = (text ?? '').trim().isEmpty ? '' : text!.trim());
      if ((text ?? '').trim().isEmpty) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(_ocr.problem ?? tr('ocrbox.none'))));
      }
    } catch (e) {
      DiagLog.log('tools', 'ocr box failed: $e');
      if (mounted) ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(tr('tool.failed', {'why': '$e'}))));
    } finally {
      if (mounted) setState(() => _reading = false);
    }
  }

  void _page(int i) => setState(() {
        _at = i;
        _box = null;
      });

  Future<void> _saveText() async {
    final t = _text.text;
    if (t.trim().isEmpty) return;
    final out = toolOutPath(s, widget.path, tr('ocrbox.suffix'), 'txt');
    await File(out).writeAsString(t, flush: true);
    if (mounted) await showToolResult(context, s, [out]);
  }

  @override
  Widget build(BuildContext context) {
    final d = _doc;
    final name = widget.path.split(Platform.pathSeparator).last;
    return Scaffold(
      backgroundColor: LrColors.ink,
      appBar: AppBar(title: Text('${tr('ocrbox.title')} · $name', overflow: TextOverflow.ellipsis)),
      body: d == null
          ? Center(
              child: _why == null ? const CircularProgressIndicator() : Text(tr('ann.cannot'), style: const TextStyle(color: LrColors.muted)),
            )
          : Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Expanded(
                child: Column(children: [
                  if (d.count > 1)
                    Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                      IconButton(onPressed: _at > 0 ? () => _page(_at - 1) : null, icon: const Icon(Icons.chevron_left_rounded)),
                      Text('${_at + 1} / ${d.count}', style: const TextStyle(color: LrColors.muted)),
                      IconButton(
                          onPressed: _at < d.count - 1 ? () => _page(_at + 1) : null,
                          icon: const Icon(Icons.chevron_right_rounded)),
                    ]),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Center(
                        child: AspectRatio(
                          aspectRatio: d.aspect(_at),
                          child: LayoutBuilder(builder: (context, c) {
                            Offset n(Offset p) => Offset((p.dx / c.maxWidth).clamp(0.0, 1.0), (p.dy / c.maxHeight).clamp(0.0, 1.0));
                            final b = _box;
                            return GestureDetector(
                              onPanStart: (e) => setState(() {
                                _from = n(e.localPosition);
                                _box = null;
                              }),
                              onPanUpdate: (e) {
                                final a = _from;
                                if (a != null) setState(() => _box = Rect.fromPoints(a, n(e.localPosition)));
                              },
                              onPanEnd: (_) {
                                final r = _box;
                                _from = null;
                                if (r != null && r.width > 0.01 && r.height > 0.005) unawaited(_read(r));
                              },
                              child: MouseRegion(
                                cursor: SystemMouseCursors.precise,
                                child: Stack(fit: StackFit.expand, children: [
                                  Container(color: Colors.white, child: d.view(_at)),
                                  if (b != null)
                                    Positioned(
                                      left: b.left * c.maxWidth,
                                      top: b.top * c.maxHeight,
                                      width: b.width * c.maxWidth,
                                      height: b.height * c.maxHeight,
                                      child: Container(
                                        decoration: BoxDecoration(
                                          color: const Color(0x142F6BFF),
                                          border: Border.all(color: const Color(0xFF2F6BFF), width: 2),
                                        ),
                                      ),
                                    ),
                                ]),
                              ),
                            );
                          }),
                        ),
                      ),
                    ),
                  ),
                ]),
              ),
              Container(
                width: 360,
                color: LrColors.surface,
                padding: const EdgeInsets.all(16),
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  Text(tr('ocrbox.hint'), style: const TextStyle(color: LrColors.muted, height: 1.5)),
                  const SizedBox(height: 10),
                  OutlinedButton.icon(
                    onPressed: _reading ? null : () => unawaited(_read(null)),
                    icon: const Icon(Icons.crop_free_rounded, size: 18),
                    label: Text(tr('ocrbox.whole')),
                  ),
                  const SizedBox(height: 12),
                  if (_reading) const LinearProgressIndicator(),
                  const SizedBox(height: 6),
                  Expanded(
                    child: TextField(
                      controller: _text,
                      maxLines: null,
                      expands: true,
                      textAlignVertical: TextAlignVertical.top,
                      decoration: InputDecoration(hintText: tr('ocrbox.result'), border: const OutlineInputBorder()),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Row(children: [
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: () {
                          unawaited(Clipboard.setData(ClipboardData(text: _text.text)));
                          ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(tr('ocrbox.copied'))));
                        },
                        icon: const Icon(Icons.copy_rounded, size: 18),
                        label: Text(tr('tool.copy_text')),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () => unawaited(_saveText()),
                        icon: const Icon(Icons.save_alt_rounded, size: 18),
                        label: Text(tr('ocrbox.save')),
                      ),
                    ),
                  ]),
                ]),
              ),
            ]),
    );
  }
}

Future<void> openOcrBox(BuildContext context, AppServices s, String path, {int page = 0}) =>
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => OcrBoxPage(services: s, path: path, page: page)));
