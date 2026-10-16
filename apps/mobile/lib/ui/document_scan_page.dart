// apps/mobile/lib/ui/document_scan_page.dart
import 'dart:async';
import 'dart:io';

import 'package:cunning_document_scanner/cunning_document_scanner.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:localroll_core/localroll_core.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../l10n/l10n.dart';
import '../services/discovery.dart';
import '../services/file_sender.dart';
import '../services/media_saver.dart';
import '../services/mobile_settings.dart';
import '../services/my_library.dart';
import '../services/scan_pdf.dart';
import 'cleanup_page.dart' show formatSize;
import 'send_files_page.dart';
import 'theme.dart';

/// Scan paper with the phone's own document scanner (edges found, pages
/// straightened, shadows evened out — all on the phone), then make one PDF
/// and choose: send to the PC (its "Documents" folder) or a nearby phone,
/// share (e-mail, messages, print…), or keep it on this phone.
class DocumentScanPage extends StatefulWidget {
  const DocumentScanPage({super.key, required this.settings, required this.discovery});

  final MobileSettings settings;
  final DesktopDiscovery discovery;

  @override
  State<DocumentScanPage> createState() => _DocumentScanPageState();
}

class _DocumentScanPageState extends State<DocumentScanPage> {
  final List<String> _pages = [];
  final DateTime _started = DateTime.now();
  late final TextEditingController _name = TextEditingController(text: ScanPdf.defaultName(_started));
  bool _busy = false;
  File? _pdf; // made for the current pages and name
  String? _pdfKey;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _scan(first: true));
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _toast(String t) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(t)));
  }

  /// The system scanner is missing (Android without Google Play services):
  /// pages are taken as photos instead.
  bool _photoMode = false;

  Future<void> _scan({bool first = false}) async {
    List<String>? got;
    if (_photoMode) {
      got = await _photo();
    } else {
      try {
        got = await CunningDocumentScanner.getPictures();
      } catch (e) {
        DiagLog.error('scan', e);
        if (Platform.isAndroid) {
          // No scanner on this phone: take a photo instead (now and later).
          _photoMode = true;
          _toast(tr('scan.photo_mode'));
          got = await _photo();
        } else {
          _toast(tr('scan.failed'));
        }
      }
    }
    if (!mounted) return;
    final list = got ?? const <String>[];
    if (list.isEmpty) {
      if (first && _pages.isEmpty) Navigator.of(context).pop(); // cancelled before anything
      return;
    }
    setState(() => _pages.addAll(list));
  }

  /// One page as a camera photo (no edge finding).
  Future<List<String>?> _photo() async {
    try {
      final x = await ImagePicker().pickImage(source: ImageSource.camera, imageQuality: 90, maxWidth: 3000, maxHeight: 3000);
      return x == null ? null : [x.path];
    } catch (e) {
      DiagLog.error('scan', e);
      _toast(tr('scan.failed'));
      return null;
    }
  }

  /// The PDF for what is on screen now (made again only when pages or the
  /// name changed).
  Future<File?> _makePdf() async {
    if (_pages.isEmpty) return null;
    final name = ScanPdf.fileName(_name.text, _started);
    final key = '$name|${_pages.join('|')}';
    final ready = _pdf;
    if (ready != null && _pdfKey == key && await ready.exists()) return ready;
    final dir = Directory('${(await getTemporaryDirectory()).path}/lr_scan_${_started.millisecondsSinceEpoch}');
    final out = await ScanPdf.build(_pages, File('${dir.path}/$name'));
    _pdf = out;
    _pdfKey = key;
    return out;
  }

  Future<void> _run(Future<void> Function(File pdf) action) async {
    setState(() => _busy = true);
    try {
      final pdf = await _makePdf();
      if (pdf == null) return;
      await action(pdf);
    } catch (e) {
      DiagLog.error('scan', e);
      _toast(tr('scan.failed'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _send() => _run((pdf) async {
        final sender = await pickFileTarget(context, widget.settings, widget.discovery, [pdf]);
        if (sender == null || !mounted) return;
        final ok = await Navigator.of(context).push<bool>(MaterialPageRoute(builder: (_) => SendFilesPage(sender: sender)));
        if (ok == true && mounted) _toast(tr('scan.sent', {'name': sender.targetName}));
      });

  Future<void> _share(BuildContext buttonContext) => _run((pdf) async {
        final box = buttonContext.findRenderObject() as RenderBox?;
        await SharePlus.instance.share(ShareParams(
          files: [XFile(pdf.path, mimeType: 'application/pdf')],
          subject: FileSender.nameOfPath(pdf.path),
          sharePositionOrigin: box == null ? null : box.localToGlobal(Offset.zero) & box.size,
        ));
      });

  /// Into "My files" (LocalRoll's folder › Scans › this phone).
  Future<void> _keep() => _run((pdf) async {
        final me = Sender(widget.settings.deviceId, tr('mylib.this_phone'));
        final dir = await MediaSaver.folderFor(MyKind.scan, me);
        final target = await MediaSaver.freeFile(dir, FileSender.nameOfPath(pdf.path));
        await pdf.copy(target.path);
        await MyLibrary.instance.addFile(target.path, MyKind.scan, fromId: me.id, fromName: me.name);
        _toast(tr('scan.kept_mine'));
      });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(tr('scan.title'))),
      body: _pages.isEmpty
          ? const Center(child: CircularProgressIndicator())
          : ListView(padding: const EdgeInsets.all(16), children: [
              TextField(
                controller: _name,
                decoration: InputDecoration(labelText: tr('scan.name'), suffixText: '.pdf'),
              ),
              const SizedBox(height: 12),
              Text(tr('scan.pages', {'count': _pages.length}), style: theme.textTheme.bodySmall?.copyWith(color: LrColors.muted)),
              const SizedBox(height: 8),
              SizedBox(
                height: 180,
                child: ReorderableListView.builder(
                  scrollDirection: Axis.horizontal,
                  itemCount: _pages.length,
                  onReorder: (a, b) => setState(() {
                    if (b > a) b--;
                    _pages.insert(b, _pages.removeAt(a));
                  }),
                  itemBuilder: (context, i) => Padding(
                    key: ValueKey('${_pages[i]}#$i'),
                    padding: const EdgeInsets.only(right: 10),
                    child: Stack(children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: Image.file(File(_pages[i]), height: 180, width: 130, fit: BoxFit.cover, cacheWidth: 300),
                      ),
                      Positioned(
                        left: 6,
                        bottom: 6,
                        child: CircleAvatar(radius: 12, backgroundColor: Colors.black54, child: Text('${i + 1}', style: const TextStyle(fontSize: 12, color: Colors.white))),
                      ),
                      Positioned(
                        right: 0,
                        top: 0,
                        child: IconButton(
                          tooltip: tr('scan.remove_page'),
                          onPressed: () => setState(() => _pages.removeAt(i)),
                          icon: const CircleAvatar(radius: 13, backgroundColor: Colors.black54, child: Icon(Icons.close_rounded, size: 16, color: Colors.white)),
                        ),
                      ),
                    ]),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: TextButton.icon(
                  onPressed: _busy ? null : _scan,
                  icon: const Icon(Icons.add_a_photo_outlined),
                  label: Text(tr('scan.more')),
                ),
              ),
              const SizedBox(height: 16),
              if (_busy) const LinearProgressIndicator(),
              const SizedBox(height: 8),
              SizedBox(
                height: 52,
                child: FilledButton.icon(
                  onPressed: _busy ? null : _send,
                  icon: const Icon(Icons.send_rounded),
                  label: Text(tr('scan.send')),
                ),
              ),
              const SizedBox(height: 10),
              Row(children: [
                Expanded(
                  child: Builder(
                    builder: (b) => OutlinedButton.icon(
                      onPressed: _busy ? null : () => _share(b),
                      icon: const Icon(Icons.ios_share_rounded),
                      label: Text(tr('scan.share')),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _busy ? null : _keep,
                    icon: const Icon(Icons.save_alt_rounded),
                    label: Text(tr('scan.keep')),
                  ),
                ),
              ]),
              const SizedBox(height: 12),
              if (_pdf != null)
                FutureBuilder<int>(
                  future: _pdf!.length(),
                  builder: (_, s) => s.hasData
                      ? Text(tr('scan.size', {'size': formatSize(s.data!)}), style: const TextStyle(color: LrColors.muted))
                      : const SizedBox.shrink(),
                ),
              const SizedBox(height: 8),
              Text(tr('scan.private_hint'), style: theme.textTheme.bodySmall?.copyWith(color: LrColors.muted)),
            ]),
    );
  }
}
