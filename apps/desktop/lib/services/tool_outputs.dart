// apps/desktop/lib/services/tool_outputs.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:localroll_core/localroll_core.dart';

import '../app_services.dart';
import '../l10n/l10n.dart';
import '../ui/send_page.dart' show baseNameOf;
import 'library_index.dart';
import 'received_files.dart';

// Where the tools' results go, and the list of what was made from what.
//
// By default a result goes into the library's "Keepnear Tools" folder: a
// photo or video shows in the library, a PDF or other file in its files
// list. Settings can put results beside the original instead, or both.

/// Where a tool's result is kept.
enum ToolSaveTo {
  /// The library's tools folder (one place to find everything).
  library,

  /// Next to the original (a file from the library still goes to the
  /// library: its own folders are kept tidy).
  beside,

  /// The library, and a copy next to the original.
  both;

  static ToolSaveTo of(String? name) => values.firstWhere((v) => v.name == name, orElse: () => library);
}

/// Who a tool result "came from" in the library and files lists.
const String toolsDeviceId = 'tools';

final String _sep = Platform.pathSeparator;

bool _inside(String path, String folder) =>
    folder.isNotEmpty && path.toLowerCase().startsWith('${folder.toLowerCase()}$_sep');

/// The library's tools folder (named once, in the language of the day), or
/// null when the library can't be reached.
String? toolsFolderOf(AppServices s) {
  final root = s.library.rootPath;
  if (root.isEmpty || s.library.offline) return null;
  var name = s.settings.toolsFolder;
  if (name == null) {
    name = sanitizeFileName(tr('folders.tools'));
    final n = name;
    s.settings.toolsFolder = n;
    unawaited(s.settings.update((x) => x.toolsFolder = n));
  }
  return '$root$_sep$name';
}

/// The sources of results made but not yet handed out (see [toolOutPath]).
final Map<String, String> _sourceOf = {};

/// Where a tool's result goes ([suffix] e.g. "-signed"; [ext] without the
/// dot): the library's tools folder, or beside [src] (Settings / the
/// tools' "save to" choice). The original is never changed.
String toolOutPath(AppServices s, String src, String suffix, String ext) {
  final how = ToolSaveTo.of(s.settings.toolSaveTo);
  final tools = toolsFolderOf(s);
  final fromLibrary = _inside(src, s.library.rootPath);
  String? dir;
  if (tools != null && (how != ToolSaveTo.beside || fromLibrary)) {
    dir = tools;
  } else {
    dir = File(src).parent.path;
  }
  try {
    Directory(dir).createSync(recursive: true);
  } catch (_) {
    // The original's folder can't be written (a CD, a phone's folder…).
    dir = tools ?? '${Directory.systemTemp.path}${_sep}Keepnear';
    try {
      Directory(dir).createSync(recursive: true);
    } catch (_) {
      dir = '${Directory.systemTemp.path}${_sep}Keepnear';
      Directory(dir).createSync(recursive: true);
    }
  }
  final name = baseNameOf(src);
  final dot = name.lastIndexOf('.');
  final stem = dot > 0 ? name.substring(0, dot) : name;
  final out = LibraryIndex.uniquePath(dir, sanitizeFileName('$stem$suffix.$ext'));
  _sourceOf[out] = src;
  return out;
}

/// One thing a tool made.
class ToolRecord {
  ToolRecord({required this.ms, required this.tool, required this.out, this.src, this.copy});

  final int ms;

  /// The tool's name (Tool.name), or "convert".
  final String tool;
  final String out;
  final String? src;

  /// The copy put next to the original ("both").
  final String? copy;

  Map<String, dynamic> toJson() => {'t': ms, 'k': tool, 'o': out, 's': ?src, 'c': ?copy};

  static ToolRecord? fromJson(Object? j) {
    if (j is! Map<String, dynamic> || j['o'] is! String) return null;
    return ToolRecord(
      ms: (j['t'] as num?)?.toInt() ?? 0,
      tool: j['k'] as String? ?? '',
      out: j['o'] as String,
      src: j['s'] as String?,
      copy: j['c'] as String?,
    );
  }
}

/// What the tools made, newest first (kept in tools.json beside the
/// settings; the last 500).
class ToolRecords extends ChangeNotifier {
  ToolRecords(this.s);

  final AppServices s;
  final List<ToolRecord> items = [];

  /// The tool being used now (set when a tool is opened).
  String current = '';

  File get _file => File('${s.settings.dataDir.path}${_sep}tools.json');

  Future<void> load() async {
    try {
      if (!await _file.exists()) return;
      final j = jsonDecode(await _file.readAsString());
      if (j is List) items.addAll([for (final x in j) ?ToolRecord.fromJson(x)]);
    } catch (e) {
      DiagLog.log('tools', 'tools.json unreadable: $e');
    }
  }

  Future<void> _save() async {
    try {
      final tmp = File('${_file.path}.tmp');
      await tmp.writeAsString(jsonEncode([for (final r in items) r.toJson()]));
      await tmp.rename(_file.path);
    } catch (e) {
      DiagLog.log('tools', 'tools.json not saved: $e');
    }
  }

  /// The record of the result at [path] (or its copy), if any.
  ToolRecord? of(String path) {
    final p = path.toLowerCase();
    for (final r in items) {
      if (r.out.toLowerCase() == p || r.copy?.toLowerCase() == p) return r;
    }
    return null;
  }

  void clear() {
    items.clear();
    notifyListeners();
    unawaited(_save());
  }

  void remove(ToolRecord r) {
    items.remove(r);
    notifyListeners();
    unawaited(_save());
  }

  /// Results are ready: into the library / files list, a copy beside the
  /// original if wanted, and into the record.
  Future<void> saved(List<String> outs, {String? tool, Map<String, String> sources = const {}}) async {
    for (final out in outs) {
      final known = _sourceOf.remove(out);
      final src = sources[out] ?? known;
      try {
        if (!await File(out).exists()) continue;
        await register(out);
        String? copy;
        if (src != null && ToolSaveTo.of(s.settings.toolSaveTo) == ToolSaveTo.both && !_inside(src, s.library.rootPath)) {
          try {
            final dir = File(src).parent.path;
            copy = LibraryIndex.uniquePath(dir, baseNameOf(out));
            await File(out).copy(copy);
          } catch (e) {
            copy = null;
            DiagLog.log('tools', 'copy beside the original failed: $e');
          }
        }
        items.insert(0, ToolRecord(ms: DateTime.now().millisecondsSinceEpoch, tool: tool ?? current, out: out, src: src, copy: copy));
      } catch (e) {
        DiagLog.log('tools', 'result not recorded: $e');
      }
    }
    if (items.length > 500) items.removeRange(500, items.length);
    notifyListeners();
    await _save();
  }

  /// [path] in the library's folder: a photo / video into the library, any
  /// other file into the files list (from "Tools").
  Future<void> register(String path) async {
    final root = s.library.rootPath;
    if (!_inside(path, root)) return;
    final rel = path.substring(root.length + 1).replaceAll(_sep, '/');
    final name = rel.substring(rel.lastIndexOf('/') + 1);
    final kind = MediaKind.fromName(name);
    final now = DateTime.now();
    if (kind != MediaKind.other) {
      // The folder watcher may have listed it already (half written): this
      // replaces that entry.
      final st = await File(path).stat();
      s.library.add(MediaItem(
        relPath: rel,
        name: name,
        size: st.size,
        kind: kind,
        // A conversion keeps the photo's own date (set on the file); a new
        // picture is dated now.
        captureMs: st.modified.millisecondsSinceEpoch,
        receivedMs: now.millisecondsSinceEpoch,
        deviceId: toolsDeviceId,
        deviceName: tr('tool.owner'),
        assetId: 'tools-${now.microsecondsSinceEpoch}',
        private: false,
      ));
      DiagLog.log('tools', 'into the library: $rel');
    } else {
      await s.server.files.received(path, FileOwner(toolsDeviceId, tr('tool.owner')));
      s.server.files.changed();
      DiagLog.log('tools', 'into the files list: $rel');
    }
  }

  /// Once: conversions made before beta.115 (in the hidden "_converted"
  /// folder) are shown in the library; the files stay where they are.
  Future<void> showOldConversions() async {
    if (s.settings.convertedShown || s.library.offline || s.library.rootPath.isEmpty) return;
    final dir = Directory('${s.library.rootPath}${_sep}_converted');
    var n = 0;
    try {
      if (await dir.exists()) {
        await for (final e in dir.list(recursive: true, followLinks: false)) {
          if (e is! File || MediaKind.fromName(e.path) == MediaKind.other) continue;
          final rel = e.path.substring(s.library.rootPath.length + 1).replaceAll(_sep, '/');
          if (s.library.findByRel(rel) != null) continue;
          final st = await e.stat();
          final ms = st.modified.millisecondsSinceEpoch;
          s.library.add(MediaItem(
            relPath: rel,
            name: rel.substring(rel.lastIndexOf('/') + 1),
            size: st.size,
            kind: MediaKind.fromName(rel),
            captureMs: ms,
            receivedMs: ms,
            deviceId: toolsDeviceId,
            deviceName: tr('tool.owner'),
            assetId: 'tools-old-$ms-$n',
            private: false,
          ));
          n++;
        }
      }
      await s.settings.update((x) => x.convertedShown = true);
      if (n > 0) DiagLog.log('tools', '$n earlier conversions now shown in the library');
    } catch (e) {
      DiagLog.log('tools', 'earlier conversions not shown: $e');
    }
  }
}
