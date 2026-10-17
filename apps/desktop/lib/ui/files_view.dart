// apps/desktop/lib/ui/files_view.dart
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:localroll_core/localroll_core.dart';

import '../app_services.dart';
import '../l10n/l10n.dart';
import '../services/file_actions.dart';
import '../services/network.dart';
import 'format.dart';
import 'theme.dart';
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
                        leading: !e.isDir && isPdfPath(e.entity.path)
                            ? PdfThumb(path: e.entity.path, cacheDir: widget.services.library.cacheDir)
                            : SizedBox(
                                width: 48,
                                child: Icon(_icon(e), color: e.isDir ? LrColors.safelight : LrColors.muted, size: 30),
                              ),
                        title: Text(e.name, overflow: TextOverflow.ellipsis),
                        subtitle: Text([
                          formatDate(e.modified),
                          formatBytes(e.size),
                          if (e.isDir) tr('files.items', {'count': e.children}),
                        ].join(' · ')),
                        // A PDF opens in LocalRoll's reader, a text file in its text
                        // window; anything else with the program Windows uses for it.
                        onTap: () {
                          if (!e.isDir && isPdfPath(e.entity.path)) {
                            Navigator.of(context).push(MaterialPageRoute(builder: (_) => PdfViewerPage(path: e.entity.path)));
                          } else if (!e.isDir && isPlainTextPath(e.entity.path) && e.size <= 4 * 1024 * 1024) {
                            showTextFile(context, widget.services, e.entity.path);
                          } else {
                            Process.run('explorer.exe', [e.entity.path]);
                          }
                        },
                        trailing: Row(mainAxisSize: MainAxisSize.min, children: [
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
