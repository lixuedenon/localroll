// apps/desktop/lib/ui/files_view.dart
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:localroll_core/localroll_core.dart';

import '../app_services.dart';
import '../l10n/l10n.dart';
import '../services/file_actions.dart';
import '../services/library_index.dart';
import '../services/network.dart';
import 'first_page_view.dart';
import 'format.dart';
import 'theme.dart';
import 'office_view.dart';
import 'pdf_thumb.dart';
import 'pdf_viewer_page.dart';
import 'text_window.dart';

/// Library tabs "Documents" / "Other": the files other PCs sent that are not
/// photos or videos, straight from their folders (newest first).
class FilesView extends StatefulWidget {
  const FilesView({super.key, required this.services, required this.document});

  final AppServices services;

  /// true: the Documents folder; false: Other files.
  final bool document;

  @override
  State<FilesView> createState() => _FilesViewState();
}

class _Entry {
  _Entry(this.entity, this.modified, this.size, this.children);

  final FileSystemEntity entity;
  final DateTime modified;
  final int size;

  /// For folders: how many files inside (all levels).
  final int children;

  bool get isDir => entity is Directory;
  String get name => entity.path.split(Platform.pathSeparator).last;
}

class _FilesViewState extends State<FilesView> {
  String? _dir;
  List<_Entry>? _entries;
  int _seen = -1;

  @override
  void initState() {
    super.initState();
    widget.services.hub.addListener(_onHub);
    _load();
  }

  @override
  void didUpdateWidget(FilesView old) {
    super.didUpdateWidget(old);
    if (old.document != widget.document) _load();
  }

  @override
  void dispose() {
    widget.services.hub.removeListener(_onHub);
    super.dispose();
  }

  /// New files arrived: show them.
  void _onHub() {
    final n = widget.services.hub.savedFiles.length;
    if (n != _seen) {
      _seen = n;
      _load();
    }
  }

  Future<void> _load() async {
    final dir = await widget.services.server.folderPath(document: widget.document);
    final out = <_Entry>[];
    try {
      await for (final e in Directory(dir).list(followLinks: false)) {
        final name = e.path.split(Platform.pathSeparator).last;
        if (name.startsWith('.') || name.toLowerCase() == 'desktop.ini') continue;
        final st = await e.stat();
        var size = st.size;
        var children = 0;
        if (e is Directory) {
          size = 0;
          try {
            await for (final f in e.list(recursive: true, followLinks: false)) {
              if (f is File) {
                children++;
                size += await f.length();
              }
            }
          } catch (_) {}
        }
        out.add(_Entry(e, st.modified, size, children));
      }
    } catch (_) {}
    out.sort((a, b) => b.modified.compareTo(a.modified));
    if (!mounted) return;
    setState(() {
      _dir = dir;
      _entries = out;
    });
  }

  IconData _icon(_Entry e) {
    if (e.isDir) return Icons.folder_rounded;
    final ext = extensionOf(e.name);
    if (ext == 'pdf') return Icons.picture_as_pdf_rounded;
    if (googleShortcutKinds.containsKey(ext)) return Icons.cloud_outlined;
    if (const {'doc', 'docx', 'odt', 'rtf', 'pages', 'wps'}.contains(ext)) return Icons.description_rounded;
    if (const {'xls', 'xlsx', 'ods', 'csv', 'numbers', 'et'}.contains(ext)) return Icons.table_chart_rounded;
    if (const {'ppt', 'pptx', 'odp', 'key', 'dps'}.contains(ext)) return Icons.slideshow_rounded;
    if (const {'txt', 'md'}.contains(ext)) return Icons.notes_rounded;
    if (const {'zip', 'rar', '7z', 'tar', 'gz', 'bz2', 'xz'}.contains(ext)) return Icons.folder_zip_rounded;
    if (const {'mp3', 'm4a', 'wav', 'flac', 'aac', 'ogg'}.contains(ext)) return Icons.audio_file_rounded;
    if (const {'exe', 'msi', 'apk', 'ipa'}.contains(ext)) return Icons.apps_rounded;
    return Icons.insert_drive_file_rounded;
  }

  Future<void> _delete(_Entry e) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(tr('files.delete_title', {'name': e.name})),
        content: Text(tr('files.delete_body')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: Text(tr('common.cancel'))),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: Text(tr('lib.delete'))),
        ],
      ),
    );
    if (ok != true) return;
    await moveToRecycleBin([e.entity.path]);
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final list = _entries;
    final dir = _dir;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
        child: Row(children: [
          Expanded(
            child: Text(dir ?? '', overflow: TextOverflow.ellipsis, style: theme.textTheme.bodySmall?.copyWith(color: LrColors.muted)),
          ),
          TextButton.icon(
            onPressed: dir == null ? null : () => Process.run('explorer.exe', [dir]),
            icon: const Icon(Icons.folder_open_rounded, size: 18),
            label: Text(tr('library.open_folder')),
          ),
          IconButton(tooltip: tr('receive.refresh'), onPressed: _load, icon: const Icon(Icons.refresh_rounded)),
        ]),
      ),
      Expanded(
        child: list == null
            ? const Center(child: CircularProgressIndicator())
            : list.isEmpty
                ? Center(
                    child: Text(tr(widget.document ? 'files.empty_docs' : 'files.empty_other'),
                        textAlign: TextAlign.center, style: const TextStyle(color: LrColors.muted)),
                  )
                : ListView.separated(
                    padding: const EdgeInsets.fromLTRB(8, 0, 8, 24),
                    itemCount: list.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (context, i) {
                      final e = list[i];
                      return ListTile(
                        leading: FileThumb(
                          path: e.entity.path,
                          size: e.size,
                          modified: e.modified,
                          services: widget.services,
                          box: 48,
                          icon: SizedBox(
                            width: 48,
                            child: Icon(_icon(e), color: e.isDir ? LrColors.safelight : LrColors.muted, size: 30),
                          ),
                          isDir: e.isDir,
                        ),
                        title: Text(e.name, overflow: TextOverflow.ellipsis),
                        subtitle: Text([
                          formatDate(e.modified),
                          formatBytes(e.size),
                          if (e.isDir) tr('files.items', {'count': e.children}),
                        ].join(' · ')),
                        // A PDF opens in LocalRoll's reader, a text file in its text
                        // window; anything else with the program Windows uses for it.
                        onTap: () => e.isDir
                            ? Process.run('explorer.exe', [e.entity.path])
                            : openReceivedFile(context, widget.services, e.entity.path),
                        trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                          if (!e.isDir && OfficeViewPage.canShow(e.name))
                            IconButton(
                              tooltip: tr('office.preview'),
                              icon: const Icon(Icons.visibility_outlined),
                              onPressed: () => previewOffice(context, e.entity.path),
                            ),
                          IconButton(
                            tooltip: tr('common.show_in_folder'),
                            icon: const Icon(Icons.drive_folder_upload_rounded),
                            onPressed: () => revealInExplorer(e.entity.path),
                          ),
                          IconButton(
                            tooltip: tr('lib.delete'),
                            icon: const Icon(Icons.delete_outline_rounded),
                            onPressed: () => _delete(e),
                          ),
                        ]),
                      );
                    },
                  ),
      ),
    ]);
  }
}

/// Opens a received file the way LocalRoll does everywhere: a PDF in its
/// reader, a text file in its text window, Word / Excel / PowerPoint with
/// the PC's own program (or LocalRoll's simple look inside), a Google
/// shortcut as a link; anything else with the program Windows uses for it.
Future<void> openReceivedFile(BuildContext context, AppServices services, String path) async {
  final name = path.split(Platform.pathSeparator).last;
  var size = 0;
  try {
    size = await File(path).length();
  } catch (_) {}
  if (!context.mounted) return;
  if (isPdfPath(path)) {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => PdfViewerPage(path: path)));
  } else if (googleShortcutKinds.containsKey(extensionOf(name))) {
    await _openGoogle(context, path, size);
  } else if (OfficeViewPage.canShow(name)) {
    if (await hasProgramFor(extensionOf(name))) {
      await Process.run('explorer.exe', [path]);
    } else if (context.mounted) {
      previewOffice(context, path);
    }
  } else if (isPlainTextPath(path) && size <= 4 * 1024 * 1024) {
    await showTextFile(context, services, path);
  } else {
    await Process.run('explorer.exe', [path]);
  }
}

/// LocalRoll's simple look inside a Word / Excel / PowerPoint file.
void previewOffice(BuildContext context, String path) {
  Navigator.of(context).push(MaterialPageRoute(
    builder: (_) => OfficeViewPage(
      path: path,
      name: path.split(Platform.pathSeparator).last,
      actions: [
        TextButton.icon(
          onPressed: () => Process.run('explorer.exe', [path]),
          icon: const Icon(Icons.open_in_new_rounded, size: 18),
          label: Text(tr('office.open_with')),
        ),
        const SizedBox(width: 8),
      ],
    ),
  ));
}

/// A Google Docs / Sheets / Slides shortcut: the document is online.
Future<void> _openGoogle(BuildContext context, String path, int size) async {
  String? url;
  try {
    if (size <= 64 * 1024) url = googleShortcutUrl(await File(path).readAsString(), extensionOf(path));
  } catch (_) {}
  if (!context.mounted) return;
  final link = url;
  await showDialog<void>(
    context: context,
    builder: (c) => AlertDialog(
      icon: const Icon(Icons.cloud_outlined, size: 36, color: LrColors.safelight),
      title: Text(tr('open.google_title')),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460),
        child: Text(link == null ? tr('open.google_no_link') : tr('open.google_body')),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c), child: Text(tr('common.close'))),
        if (link != null)
          FilledButton.icon(
            onPressed: () {
              Navigator.pop(c);
              Process.start('explorer.exe', [link]);
            },
            icon: const Icon(Icons.open_in_browser_rounded),
            label: Text(tr('open.google_open')),
          ),
      ],
    ),
  );
}

/// A received file (Documents / Other, at any depth), for the library's
/// "All" timeline.
class ReceivedFile {
  const ReceivedFile(this.path, this.size, this.modified, this.arrived);

  final String path;
  final int size;
  final DateTime modified;

  /// When it arrived here (Windows keeps when the file was made).
  final DateTime arrived;

  String get name => path.split(Platform.pathSeparator).last;

  /// Every file in the Documents and Other folders, newest arrival first.
  static Future<List<ReceivedFile>> scan(AppServices s) async {
    final out = <ReceivedFile>[];
    for (final doc in [true, false]) {
      final String dir;
      try {
        dir = await s.server.folderPath(document: doc);
      } catch (_) {
        continue;
      }
      try {
        await for (final e in Directory(dir).list(recursive: true, followLinks: false)) {
          if (e is! File) continue;
          final rel = e.path.substring(dir.length);
          final name = rel.split(Platform.pathSeparator).last;
          if (rel.split(Platform.pathSeparator).any((p) => p.startsWith('.')) || name.toLowerCase() == 'desktop.ini') continue;
          try {
            final st = await e.stat();
            // On Windows "changed" is when the file was created here; the
            // modified time is the sender's.
            out.add(ReceivedFile(e.path, st.size, st.modified, Platform.isWindows ? st.changed : st.modified));
          } catch (_) {}
        }
      } catch (_) {}
    }
    out.sort((a, b) => b.arrived.compareTo(a.arrived));
    return out;
  }
}

/// A file's first page / picture: PDFs their first page; Word, Excel,
/// PowerPoint, text and CSV drawn from their content; photos and videos
/// (sent inside folders) from ffmpeg like the library's own. [icon] while
/// it is made, and for anything else. [box]: a square of that size; null
/// = fills its parent.
class FileThumb extends StatelessWidget {
  const FileThumb({
    super.key,
    required this.path,
    required this.size,
    required this.modified,
    required this.services,
    required this.icon,
    this.isDir = false,
    this.box,
  });

  final String path;
  final int size;
  final DateTime modified;
  final AppServices services;
  final Widget icon;
  final bool isDir;
  final double? box;

  /// A picture [File] (PDFs, photos, videos) or a [FirstPage] (documents),
  /// per file version. A file that just arrived can be busy for a moment
  /// (a virus scanner reading it): tried again, and a failure is not
  /// remembered for good.
  static final SoftCache<Object> _cache = SoftCache(max: 600);

  Future<Object?> _load() => _cache.get('$path|$size|${modified.millisecondsSinceEpoch}', () => retryWhileNull(_make));

  Future<Object?> _make() async {
    final name = path.split(Platform.pathSeparator).last;
    if (isPdfPath(path)) return PdfThumbs.of(path, services.library.cacheDir);
    final kind = MediaKind.fromName(name);
    if (kind == MediaKind.image || kind == MediaKind.video) {
      final lib = services.library;
      final root = '${lib.rootPath}${Platform.pathSeparator}';
      if (!services.ffmpeg.available || !path.toLowerCase().startsWith(root.toLowerCase())) return null;
      final rel = path.substring(root.length).replaceAll(Platform.pathSeparator, '/');
      // Not in the library list; described just enough for ffmpeg's cache.
      return services.ffmpeg.thumbnail(MediaItem(
        relPath: rel,
        name: name,
        size: size,
        kind: kind,
        captureMs: modified.millisecondsSinceEpoch,
        receivedMs: 0,
      ));
    }
    return FirstPages.of(path);
  }

  @override
  Widget build(BuildContext context) {
    if (isDir) return icon;
    return FutureBuilder<Object?>(
      future: _load(),
      builder: (context, s) {
        final d = s.data;
        final Widget pic;
        if (d is File) {
          pic = Container(
            color: Colors.white,
            child: Image.file(d,
                fit: BoxFit.cover,
                alignment: Alignment.topCenter,
                cacheWidth: box == null ? 360 : (box! * 2).round(),
                gaplessPlayback: true,
                errorBuilder: (_, _, _) => icon),
          );
        } else if (d is FirstPage) {
          pic = FirstPageView(page: d);
        } else {
          return icon;
        }
        final framed = ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: DecoratedBox(
            position: DecorationPosition.foreground,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(4),
              border: Border.all(color: LrColors.muted.withValues(alpha: 0.3)),
            ),
            child: pic,
          ),
        );
        return box == null ? framed : SizedBox(width: box, height: box, child: framed);
      },
    );
  }
}
