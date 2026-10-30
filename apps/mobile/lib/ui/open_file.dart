// apps/mobile/lib/ui/open_file.dart
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:localroll_core/localroll_core.dart';
import 'package:share_plus/share_plus.dart';

import '../l10n/l10n.dart';
import 'cleanup_page.dart' show formatSize;
import 'office_view.dart';
import '../services/pdf_pages.dart';
import 'pdf_view_page.dart';
import 'theme.dart';

/// Opening any file that arrived, without other apps where possible:
///  * PDF → LocalRoll's reader (both phones);
///  * Google Docs / Sheets / Slides shortcuts → a card that opens it online;
///  * iPhone → the system preview (Word, Excel, PowerPoint, Pages, Numbers,
///    Keynote, text, CSV, RTF, web pages, audio…);
///  * Android → Word / Excel / PowerPoint (a simple look inside), text and
///    CSV shown here;
///  * anything else → a card: what it is, open with another app, send.
Future<void> openDocument(BuildContext context, String path, {String? name, Future<void> Function()? onSend}) async {
  final shown = name ?? path.split(Platform.pathSeparator).last;
  final ext = _ext(shown.isNotEmpty ? shown : path);
  final nav = Navigator.of(context);
  if (ext == 'pdf') {
    // LocalRoll's reader when the phone can read it; else (logged, to find
    // out why) the system's own preview / the file card.
    final n = await PdfPages.count(path).timeout(const Duration(seconds: 8), onTimeout: () => -1);
    if (n > 0) {
      await nav.push(MaterialPageRoute(builder: (_) => PdfViewPage(path: path, title: shown)));
      return;
    }
    await _logUnreadable(path, n);
    if (Platform.isIOS && await FileOpener.preview(path)) return;
    var size = 0;
    try {
      size = await File(path).length();
    } catch (_) {}
    await nav.push(MaterialPageRoute(builder: (_) => FileInfoPage(path: path, name: shown, size: size, onSend: onSend)));
    return;
  }
  if (googleShortcutKinds.containsKey(ext)) {
    await nav.push(MaterialPageRoute(builder: (_) => _GoogleDocPage(path: path, name: shown, ext: ext)));
    return;
  }
  if (Platform.isIOS && await FileOpener.preview(path)) return;
  int size = 0;
  try {
    size = await File(path).length();
  } catch (_) {}
  if (OfficeViewPage.canShow(shown)) {
    await nav.push(MaterialPageRoute(
      builder: (_) => OfficeViewPage(path: path, name: shown, actions: [_shareAction(path)]),
    ));
    return;
  }
  if (textKinds.contains(ext) && size <= 4 * 1024 * 1024) {
    await nav.push(MaterialPageRoute(builder: (_) => TextViewPage(path: path, name: shown, table: ext == 'csv' || ext == 'tsv')));
    return;
  }
  await nav.push(MaterialPageRoute(builder: (_) => FileInfoPage(path: path, name: shown, size: size, onSend: onSend)));
}

/// Why a PDF could not be read: its size and first bytes (a real PDF
/// starts with "%PDF"; an error page or a cut-off download does not).
Future<void> _logUnreadable(String path, int pages) async {
  try {
    final f = File(path);
    final size = await f.length();
    final raf = await f.open();
    final head = await raf.read(16);
    await raf.close();
    final shown = String.fromCharCodes([for (final b in head) b >= 32 && b < 127 ? b : 46]);
    DiagLog.log('files', 'pdf not readable (${pages < 0 ? 'no answer in 8 s' : '$pages pages'}): $size bytes, starts "$shown", name .${path.split('.').last}');
  } catch (e) {
    DiagLog.log('files', 'pdf not readable, file not there: $e');
  }
}

String _ext(String name) {
  final i = name.lastIndexOf('.');
  return i < 0 ? '' : name.substring(i + 1).toLowerCase();
}

/// Shown here as text (CSV / TSV as a table).
const textKinds = {'txt', 'md', 'log', 'csv', 'tsv', 'json', 'xml', 'ini', 'srt', 'vtt'};

/// Native help (channel localroll/files): the iPhone's system preview and
/// opening a web address in the browser.
class FileOpener {
  FileOpener._();

  static const MethodChannel _ch = MethodChannel('localroll/files');

  /// iPhone: shown in the system preview (false: it can't show this kind).
  static Future<bool> preview(String path) async {
    try {
      return await _ch.invokeMethod<bool>('preview', {'path': path}) ?? false;
    } catch (e) {
      DiagLog.log('files', 'preview failed: $e');
      return false;
    }
  }

  /// iPhone: the system's picture of [path]'s first page (PNG, about
  /// [size] pixels), or null (Android, or the system has none).
  static Future<Uint8List?> thumbnail(String path, {int size = 240}) async {
    if (!Platform.isIOS) return null;
    try {
      return await _ch.invokeMethod<Uint8List>('thumb', {'path': path, 'size': size.toDouble()});
    } catch (e) {
      DiagLog.log('files', 'thumbnail failed: $e');
      return null;
    }
  }

  static Future<bool> openUrl(String url) async {
    try {
      return await _ch.invokeMethod<bool>('openUrl', {'url': url}) ?? false;
    } catch (e) {
      DiagLog.log('files', 'open url failed: $e');
      return false;
    }
  }
}

/// UTF-8 (with or without BOM) or UTF-16 with BOM; anything else as UTF-8
/// with unreadable bytes replaced.
String decodeTextBytes(List<int> b) {
  if (b.length >= 3 && b[0] == 0xEF && b[1] == 0xBB && b[2] == 0xBF) return utf8.decode(b.sublist(3), allowMalformed: true);
  if (b.length >= 2 && ((b[0] == 0xFF && b[1] == 0xFE) || (b[0] == 0xFE && b[1] == 0xFF))) {
    final le = b[0] == 0xFF;
    return String.fromCharCodes([
      for (var i = 2; i + 1 < b.length; i += 2) le ? b[i] | (b[i + 1] << 8) : (b[i] << 8) | b[i + 1],
    ]);
  }
  return utf8.decode(b, allowMalformed: true);
}

/// Simple CSV: quotes, doubled quotes, separators and line breaks inside
/// quotes.
List<List<String>> parseCsv(String text, {String sep = ',', int maxRows = 5000}) {
  final rows = <List<String>>[];
  var row = <String>[];
  final cell = StringBuffer();
  var quoted = false;
  for (var i = 0; i < text.length; i++) {
    final c = text[i];
    if (quoted) {
      if (c == '"') {
        if (i + 1 < text.length && text[i + 1] == '"') {
          cell.write('"');
          i++;
        } else {
          quoted = false;
        }
      } else {
        cell.write(c);
      }
    } else if (c == '"') {
      quoted = true;
    } else if (c == sep) {
      row.add(cell.toString());
      cell.clear();
    } else if (c == '\n' || c == '\r') {
      if (c == '\r' && i + 1 < text.length && text[i + 1] == '\n') i++;
      row.add(cell.toString());
      cell.clear();
      rows.add(row);
      row = <String>[];
      if (rows.length >= maxRows) return rows;
    } else {
      cell.write(c);
    }
  }
  if (cell.isNotEmpty || row.isNotEmpty) {
    row.add(cell.toString());
    rows.add(row);
  }
  return rows;
}

Future<void> _shareFile(BuildContext buttonContext, String path) async {
  final box = buttonContext.findRenderObject() as RenderBox?;
  await SharePlus.instance.share(ShareParams(
    files: [XFile(path)],
    sharePositionOrigin: box == null ? null : box.localToGlobal(Offset.zero) & box.size,
  ));
}

Widget _shareAction(String path) => Builder(
      builder: (c) => IconButton(
        tooltip: tr('open.other_app'),
        onPressed: () => _shareFile(c, path),
        icon: const Icon(Icons.ios_share_rounded),
      ),
    );

/// A text file (or a CSV table), read only; long-press to select and copy.
class TextViewPage extends StatefulWidget {
  const TextViewPage({super.key, required this.path, required this.name, this.table = false});

  final String path;
  final String name;
  final bool table;

  @override
  State<TextViewPage> createState() => _TextViewPageState();
}

class _TextViewPageState extends State<TextViewPage> {
  String? _text;
  List<List<String>>? _rows;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final text = decodeTextBytes(await File(widget.path).readAsBytes());
      List<List<String>>? rows;
      if (widget.table) rows = parseCsv(text, sep: widget.name.toLowerCase().endsWith('.tsv') ? '\t' : ',');
      if (mounted) {
        setState(() {
          _text = text;
          _rows = rows;
        });
      }
    } catch (e) {
      DiagLog.error('files', e);
      if (mounted) setState(() => _failed = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final rows = _rows;
    final text = _text;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.name, overflow: TextOverflow.ellipsis),
        actions: [
          if (text != null)
            IconButton(
              tooltip: tr('open.copy_all'),
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: text));
                if (!context.mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('open.copied'))));
              },
              icon: const Icon(Icons.copy_rounded),
            ),
          _shareAction(widget.path),
        ],
      ),
      body: _failed
          ? Center(child: Text(tr('mylib.cannot_open'), style: const TextStyle(color: LrColors.muted)))
          : text == null
              ? const Center(child: CircularProgressIndicator())
              : rows != null
                  ? _table(rows)
                  : SingleChildScrollView(
                      padding: const EdgeInsets.all(16),
                      child: SelectableText(text, style: const TextStyle(fontSize: 15, height: 1.45)),
                    ),
    );
  }

  Widget _table(List<List<String>> rows) {
    final cols = rows.fold<int>(0, (m, r) => r.length > m ? r.length : m);
    return InteractiveViewer(
      constrained: false,
      minScale: 0.4,
      maxScale: 3,
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Table(
          defaultColumnWidth: const IntrinsicColumnWidth(),
          border: TableBorder.all(color: LrColors.line),
          children: [
            for (var r = 0; r < rows.length; r++)
              TableRow(
                decoration: BoxDecoration(color: r == 0 ? LrColors.raised : null),
                children: [
                  for (var c = 0; c < cols; c++)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 260),
                        child: Text(c < rows[r].length ? rows[r][c] : '',
                            style: TextStyle(fontSize: 13, fontWeight: r == 0 ? FontWeight.w600 : FontWeight.w400)),
                      ),
                    ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

/// A Google Docs / Sheets / Slides shortcut: the document itself is online.
class _GoogleDocPage extends StatefulWidget {
  const _GoogleDocPage({required this.path, required this.name, required this.ext});

  final String path;
  final String name;
  final String ext;

  @override
  State<_GoogleDocPage> createState() => _GoogleDocPageState();
}

class _GoogleDocPageState extends State<_GoogleDocPage> {
  String? _url;
  bool _read = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    String? url;
    try {
      final f = File(widget.path);
      if (await f.length() <= 64 * 1024) url = googleShortcutUrl(await f.readAsString(), widget.ext);
    } catch (_) {}
    if (mounted) {
      setState(() {
        _url = url;
        _read = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final url = _url;
    return Scaffold(
      appBar: AppBar(title: Text(widget.name, overflow: TextOverflow.ellipsis)),
      body: !_read
          ? const Center(child: CircularProgressIndicator())
          : ListView(padding: const EdgeInsets.all(24), children: [
              const Icon(Icons.cloud_outlined, size: 64, color: LrColors.safelight),
              const SizedBox(height: 16),
              Text(tr('open.google_title'), textAlign: TextAlign.center, style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 10),
              Text(tr('open.google_body'), textAlign: TextAlign.center, style: const TextStyle(color: LrColors.muted)),
              const SizedBox(height: 24),
              if (url != null)
                FilledButton.icon(
                  onPressed: () async {
                    final ok = await FileOpener.openUrl(url);
                    if (!ok && context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('mylib.cannot_open'))));
                    }
                  },
                  icon: const Icon(Icons.open_in_browser_rounded),
                  label: Text(tr('open.google_open')),
                )
              else
                Text(tr('open.google_no_link'), textAlign: TextAlign.center, style: const TextStyle(color: LrColors.muted)),
            ]),
    );
  }
}

/// Anything the phone can't show itself: what it is, and what can be done.
class FileInfoPage extends StatelessWidget {
  const FileInfoPage({super.key, required this.path, required this.name, required this.size, this.onSend});

  final String path;
  final String name;
  final int size;
  final Future<void> Function()? onSend;

  static (IconData, String) kindOf(String name) {
    final e = _ext(name);
    if (const {'doc', 'docx', 'odt', 'rtf', 'pages', 'wps'}.contains(e)) return (Icons.description_rounded, 'open.kind_word');
    if (const {'xls', 'xlsx', 'ods', 'numbers', 'et'}.contains(e)) return (Icons.table_chart_rounded, 'open.kind_excel');
    if (const {'ppt', 'pptx', 'odp', 'key', 'dps'}.contains(e)) return (Icons.slideshow_rounded, 'open.kind_ppt');
    if (const {'zip', 'rar', '7z', 'tar', 'gz'}.contains(e)) return (Icons.folder_zip_rounded, 'open.kind_zip');
    if (const {'mp3', 'm4a', 'wav', 'flac', 'aac', 'ogg'}.contains(e)) return (Icons.audio_file_rounded, 'open.kind_audio');
    if (const {'apk', 'exe', 'msi', 'ipa'}.contains(e)) return (Icons.apps_rounded, 'open.kind_app');
    return (Icons.insert_drive_file_rounded, 'open.kind_other');
  }

  @override
  Widget build(BuildContext context) {
    final (icon, kind) = kindOf(name);
    final ext = _ext(name);
    return Scaffold(
      appBar: AppBar(title: Text(name, overflow: TextOverflow.ellipsis)),
      body: ListView(padding: const EdgeInsets.all(24), children: [
        Icon(icon, size: 72, color: LrColors.safelight),
        const SizedBox(height: 14),
        Text(name, textAlign: TextAlign.center, style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 6),
        Text([tr(kind), if (ext.isNotEmpty) '.$ext', formatSize(size)].join(' · '),
            textAlign: TextAlign.center, style: const TextStyle(color: LrColors.muted)),
        const SizedBox(height: 18),
        Text(tr('open.cant_here'), textAlign: TextAlign.center),
        const SizedBox(height: 24),
        Builder(
          builder: (c) => FilledButton.icon(
            onPressed: () => _shareFile(c, path),
            icon: const Icon(Icons.open_in_new_rounded),
            label: Text(tr('open.other_app')),
          ),
        ),
        if (onSend != null) ...[
          const SizedBox(height: 10),
          OutlinedButton.icon(
            onPressed: onSend,
            icon: const Icon(Icons.send_rounded),
            label: Text(tr('open.send_pc')),
          ),
        ],
      ]),
    );
  }
}
