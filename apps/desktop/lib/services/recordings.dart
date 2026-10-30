// apps/desktop/lib/services/recordings.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:localroll_core/localroll_core.dart';

import '../l10n/l10n.dart';
import 'library_index.dart';
import 'peers.dart';
import 'player_memory.dart';

/// What kind of thing was recorded.
enum RecKind { screen, narration, clip, shot }

/// One thing recorded or saved in LocalRoll: a screen recording, an
/// explanation, a clip, a screenshot. Where its file is, what it came from
/// (the original video's name, or the program recorded), when it was made,
/// who it was sent to.
class Recording {
  Recording({
    required this.id,
    required this.kind,
    required this.path,
    required this.source,
    this.sourcePath,
    required this.createdMs,
    this.lengthMs = 0,
    this.size = 0,
    this.narrationId,
    List<String>? sentTo,
  }) : sentTo = sentTo ?? [];

  final String id;
  final RecKind kind;
  String path;

  /// What it came from: the original's name without extension ("Trip"), or
  /// the program / "Whole screen" / "Area" for screen recordings.
  final String source;

  /// The original file (explanations, clips, screenshots).
  final String? sourcePath;
  final int createdMs;
  final int lengthMs;
  int size;

  /// An explanation: its recording (voice, marks), to make it again.
  final String? narrationId;

  /// Names of the devices it was sent to.
  final List<String> sentTo;

  String get name => path.split(Platform.pathSeparator).last;
  bool get video => kind != RecKind.shot;
  bool get exists => File(path).existsSync();

  Map<String, dynamic> toJson() => {
        'id': id,
        'kind': kind.name,
        'path': path,
        'source': source,
        if (sourcePath != null) 'sourcePath': sourcePath,
        'created': createdMs,
        if (lengthMs > 0) 'length': lengthMs,
        'size': size,
        if (narrationId != null) 'narration': narrationId,
        if (sentTo.isNotEmpty) 'sent': sentTo,
      };

  static Recording? fromJson(Map<String, dynamic> j) {
    final kind = RecKind.values.where((k) => k.name == j['kind']).firstOrNull;
    final path = j['path'] as String?;
    if (kind == null || path == null) return null;
    return Recording(
      id: j['id'] as String? ?? randomId(10),
      kind: kind,
      path: path,
      source: j['source'] as String? ?? '',
      sourcePath: j['sourcePath'] as String?,
      createdMs: (j['created'] as num?)?.toInt() ?? 0,
      lengthMs: (j['length'] as num?)?.toInt() ?? 0,
      size: (j['size'] as num?)?.toInt() ?? 0,
      narrationId: j['narration'] as String?,
      sentTo: [for (final x in (j['sent'] as List?) ?? const []) if (x is String) x],
    );
  }
}

/// Everything recorded in LocalRoll, kept in one folder ("LocalRoll
/// recordings", in the library — else in Windows' Videos) with a folder
/// for each kind, and a list of its own (so they are found even when the
/// library is offline).
class Recordings extends ChangeNotifier {
  Recordings({required this.library, required this.dataDir, required this.memory});

  final LibraryIndex library;
  final Directory dataDir;
  final PlayerMemory memory;

  final List<Recording> _items = [];

  /// Phones (ids) that may see the recordings when they look at this
  /// library; others don't (they may show the screen, chats, work…).
  final Set<String> seenBy = {};

  String? _folder;
  final Map<RecKind, String> _subs = {};
  bool _moved = false;

  static final String _sep = Platform.pathSeparator;
  File get _file => File('${dataDir.path}${_sep}recordings.json');

  /// Newest first; files that were deleted are left out (see [missing]).
  List<Recording> get items => [for (final r in _items) if (r.exists) r];

  /// Recorded, but the file is gone (an explanation can be made again).
  List<Recording> get missing => [for (final r in _items) if (!r.exists) r];

  Future<void> load() async {
    try {
      final j = jsonDecode(await _file.readAsString()) as Map<String, dynamic>;
      _items
        ..clear()
        ..addAll([for (final x in (j['items'] as List?) ?? const []) if (x is Map<String, dynamic>) ?Recording.fromJson(x)]);
      _folder = j['folder'] as String?;
      final subs = j['subs'];
      if (subs is Map) {
        for (final k in RecKind.values) {
          final v = subs[k.name];
          if (v is String && v.isNotEmpty) _subs[k] = v;
        }
      }
      seenBy
        ..clear()
        ..addAll([for (final x in (j['seenBy'] as List?) ?? const []) if (x is String) x]);
      _moved = j['moved'] == true;
    } catch (_) {}
    _sort();
    _findMoved();
  }

  void _sort() => _items.sort((a, b) => b.createdMs.compareTo(a.createdMs));

  Future<void> _saving = Future.value();

  void _save() {
    final data = jsonEncode({
      'folder': _folder,
      'subs': {for (final e in _subs.entries) e.key.name: e.value},
      'seenBy': seenBy.toList(),
      'moved': _moved,
      'items': [for (final r in _items) r.toJson()],
    });
    _saving = _saving.then((_) async {
      try {
        final tmp = File('${_file.path}.tmp');
        await tmp.writeAsString(data, flush: true);
        await tmp.rename(_file.path);
      } catch (e) {
        DiagLog.log('recordings', 'not saved: $e');
      }
    });
  }

  Future<void> flush() => _saving;

  // ---------------------------------------------------------------- where

  bool get _libraryOk => library.rootPath.isNotEmpty && !library.offline && Directory(library.rootPath).existsSync();

  /// The folder's own name ("LocalRoll recordings"), chosen once.
  String get folderName {
    if (_folder == null) {
      _folder = sanitizeFileName(tr('recs.folder'));
      _save();
    }
    return _folder!;
  }

  /// In the library (else in Windows' Videos, until the library is back).
  bool get inLibrary => _libraryOk;

  String get root {
    if (_libraryOk) return '${library.rootPath}$_sep$folderName';
    final home = Platform.environment['USERPROFILE'] ?? Directory.systemTemp.path;
    return '$home${_sep}Videos$_sep$folderName';
  }

  /// Where one kind goes.
  String folder(RecKind k) {
    final sub = _subs[k] ??= () {
      final v = sanitizeFileName(tr('recs.sub_${k.name}'));
      _save();
      return v;
    }();
    return '$root$_sep$sub';
  }

  // ------------------------------------------------------------------ add

  /// Made just now: in the list (and in the library when it is there).
  Recording add(File f, {required RecKind kind, required String source, String? sourcePath, int lengthMs = 0, String? narrationId}) {
    final now = DateTime.now().millisecondsSinceEpoch;
    var size = 0;
    try {
      size = f.lengthSync();
    } catch (_) {}
    final r = Recording(
      id: randomId(10),
      kind: kind,
      path: f.path,
      source: source,
      sourcePath: sourcePath,
      createdMs: now,
      lengthMs: lengthMs,
      size: size,
      narrationId: narrationId,
    );
    _items.insert(0, r);
    _save();
    notifyListeners();
    DiagLog.log('recordings', '${kind.name} saved');
    return r;
  }

  Recording? byPath(String path) {
    final p = path.toLowerCase();
    return _items.where((r) => r.path.toLowerCase() == p).firstOrNull;
  }

  /// Made from [path] (an original video / photo).
  List<Recording> madeFrom(String path) {
    final p = path.toLowerCase();
    return [for (final r in items) if (r.sourcePath?.toLowerCase() == p) r];
  }

  /// The library's item for a recording (null: not in the library).
  MediaItem? itemOf(Recording r) {
    final rootPath = '${library.rootPath}$_sep';
    if (library.rootPath.isEmpty || !r.path.toLowerCase().startsWith(rootPath.toLowerCase())) return null;
    return library.findByRel(r.path.substring(rootPath.length).replaceAll(_sep, '/'));
  }

  /// Gone from the list (the file is deleted elsewhere).
  void forget(Iterable<Recording> list) {
    final ids = {for (final r in list) r.id};
    _items.removeWhere((r) => ids.contains(r.id));
    _save();
    notifyListeners();
  }

  /// A new name (same folder, same extension). False: not possible.
  Future<bool> rename(Recording r, String name) async {
    final n = sanitizeFileName(name.trim());
    if (n.isEmpty) return false;
    final dot = r.name.lastIndexOf('.');
    final ext = dot > 0 ? r.name.substring(dot) : '';
    final dir = File(r.path).parent.path;
    final to = '$dir$_sep$n$ext';
    if (to.toLowerCase() == r.path.toLowerCase()) return true;
    if (File(to).existsSync()) return false;
    final item = itemOf(r);
    try {
      await File(r.path).rename(to);
    } catch (e) {
      DiagLog.log('recordings', 'not renamed: $e');
      return false;
    }
    r.path = to;
    if (item != null) {
      final rootPath = '${library.rootPath}$_sep';
      library.moved(item, to.substring(rootPath.length).replaceAll(_sep, '/'));
    }
    _save();
    notifyListeners();
    return true;
  }

  /// Files moved in Explorer inside the library: found again by name and
  /// size.
  void _findMoved() {
    if (!_libraryOk) return;
    var changed = false;
    for (final r in _items) {
      if (r.exists) continue;
      final hit = library.items.where((i) => i.name == r.name && (r.size == 0 || i.size == r.size)).firstOrNull;
      if (hit != null) {
        r.path = library.absPath(hit);
        changed = true;
      }
    }
    if (changed) _save();
  }

  // ----------------------------------------------------------- who sees

  void setSeenBy(Set<String> ids) {
    seenBy
      ..clear()
      ..addAll(ids);
    _save();
    notifyListeners();
    library.visibility.value++;
  }

  /// A phone looking at this library doesn't see the recordings unless it
  /// was allowed.
  bool hiddenFrom(MediaItem i, String deviceId) {
    if (seenBy.contains(deviceId) || _folder == null) return false;
    final top = i.relPath.contains('/') ? i.relPath.substring(0, i.relPath.indexOf('/')) : '';
    return top.toLowerCase() == _folder!.toLowerCase();
  }

  // ----------------------------------------------------------- sent to

  final Set<String> _seenJobs = {};

  /// Sent from anywhere in LocalRoll: remembered on the recording.
  void watch(PeerSender sender) {
    sender.addListener(() {
      var changed = false;
      for (final j in sender.jobs) {
        if (j.state != SendJobState.done || _seenJobs.contains(j.id)) continue;
        _seenJobs.add(j.id);
        for (final f in j.files) {
          final r = byPath(f.path);
          if (r != null && !r.sentTo.contains(j.peer.name)) {
            r.sentTo.add(j.peer.name);
            changed = true;
          }
        }
      }
      if (changed) {
        _save();
        notifyListeners();
      }
    });
  }

  // ------------------------------------------------- library back again

  /// Saved in Windows' Videos while the library was offline.
  List<Recording> get outside {
    if (!_libraryOk) return const [];
    final r = '${root.toLowerCase()}$_sep';
    return [for (final x in items) if (!x.path.toLowerCase().startsWith(r)) x];
  }

  /// Moves [outside] into the library's recordings folder.
  Future<int> moveIntoLibrary() async {
    var n = 0;
    for (final r in outside) {
      final dest = folder(r.kind);
      try {
        await Directory(dest).create(recursive: true);
        final to = LibraryIndex.uniquePath(dest, r.name);
        try {
          await File(r.path).rename(to);
        } on FileSystemException {
          // Another drive: copied, then the old one goes.
          await File(r.path).copy(to);
          await File(r.path).delete();
        }
        r.path = to;
        n++;
      } catch (e) {
        DiagLog.log('recordings', 'not moved into the library: $e');
      }
    }
    _save();
    notifyListeners();
    if (n > 0) unawaited(library.reconcile(scopes: {folderName}));
    return n;
  }

  // ------------------------------------------------------------- move in

  /// Once: what was saved before in the old folders ("LocalRoll
  /// explanations", "LocalRoll screen", clips, screenshots — in the library
  /// or in Pictures) moves into the new folders and into the list.
  Future<void> moveOld() async {
    if (_moved) return;
    final home = Platform.environment['USERPROFILE'] ?? '';
    final old = <(String?, String, RecKind)>[
      (memory.screensFolder, 'screen.folder', RecKind.screen),
      (memory.narrationsFolder, 'rec.folder', RecKind.narration),
      (memory.clipsFolder, 'ink.clips_folder', RecKind.clip),
      (memory.shotsFolder, 'ink.shots_folder', RecKind.shot),
    ];
    var n = 0;
    final scopes = <String>{};
    for (final (name, key, kind) in old) {
      final names = {?name, tr(key)};
      for (final nm in names) {
        final clean = sanitizeFileName(nm);
        for (final base in [if (_libraryOk) library.rootPath, if (home.isNotEmpty) '$home${_sep}Pictures']) {
          final dir = Directory('$base$_sep$clean');
          if (!dir.existsSync()) continue;
          final dest = folder(kind);
          await Directory(dest).create(recursive: true);
          for (final e in dir.listSync()) {
            if (e is! File) continue;
            final fileName = e.path.split(_sep).last;
            final kindOf = MediaKind.fromName(fileName);
            if (kindOf != MediaKind.video && kindOf != MediaKind.image) continue;
            final to = LibraryIndex.uniquePath(dest, fileName);
            try {
              final st = e.statSync();
              await e.rename(to);
              final stem = fileName.contains('.') ? fileName.substring(0, fileName.lastIndexOf('.')) : fileName;
              _items.add(Recording(
                id: randomId(10),
                kind: kind,
                path: to,
                source: stem.contains('_') ? stem.substring(0, stem.indexOf('_')) : stem,
                createdMs: st.modified.millisecondsSinceEpoch,
                size: st.size,
              ));
              n++;
            } catch (err) {
              DiagLog.log('recordings', 'not moved: $err');
            }
          }
          try {
            if (dir.listSync().isEmpty) dir.deleteSync();
          } catch (_) {}
          if (base == library.rootPath) scopes.add(clean);
        }
      }
    }
    _moved = true;
    _sort();
    _save();
    notifyListeners();
    if (n > 0) {
      DiagLog.log('recordings', 'moved $n from the old folders');
      if (_libraryOk) unawaited(library.reconcile(scopes: {...scopes, folderName}));
    }
  }
}

/// "ChatGPT - Google Chrome" → "Google Chrome" (the program, as Windows
/// titles end with it).
String programOf(String title) {
  final t = title.trim();
  final i = t.lastIndexOf(' - ');
  final p = i >= 0 ? t.substring(i + 3).trim() : t;
  return p.isEmpty ? t : p;
}

/// A recording's name: [base]_[what]_[extra]_20261030-1405 (parts left out
/// when empty).
String recName(String base, String what, DateTime at, {String extra = ''}) {
  String two(int v) => v.toString().padLeft(2, '0');
  final stamp = '${at.year}${two(at.month)}${two(at.day)}-${two(at.hour)}${two(at.minute)}';
  return [if (base.isNotEmpty) base, what, if (extra.isNotEmpty) extra, stamp].join('_');
}

/// A file's name without its extension.
String stemOf(String name) {
  final n = name.split(Platform.pathSeparator).last;
  return n.contains('.') ? n.substring(0, n.lastIndexOf('.')) : n;
}
