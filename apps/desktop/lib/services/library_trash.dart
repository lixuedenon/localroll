// apps/desktop/lib/services/library_trash.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:localroll_core/localroll_core.dart';

import 'library_index.dart';
import 'received_files.dart';

/// What was deleted.
enum TrashKind {
  /// A library photo / video (or a Live Photo's video, with its photo).
  media,

  /// A received file (Documents / Other).
  file,

  /// A converted copy (_converted); the original is still there.
  copy,
}

/// One deleted file in "Recently deleted".
class TrashEntry {
  TrashEntry({
    required this.id,
    required this.rel,
    required this.size,
    required this.deletedMs,
    required this.kind,
    String? group,
    this.item,
    this.owner,
  }) : group = group ?? id;

  final String id;

  /// Where it was in the library ("2024/05/IMG_1.HEIC", '/' separators).
  final String rel;
  final int size;
  final int deletedMs;
  final TrashKind kind;

  /// Deleted together and restored together (a photo and its Live Photo
  /// video): the id of the one shown.
  final String group;

  /// The library item as it was (media).
  final Map<String, dynamic>? item;

  /// Who sent it (received files).
  final Map<String, dynamic>? owner;

  String get name => rel.substring(rel.lastIndexOf('/') + 1);
  bool get shown => group == id;
  DateTime get deleted => DateTime.fromMillisecondsSinceEpoch(deletedMs);

  /// Captured (media) or deleted, for the list.
  int get takenMs => (item?['captureMs'] as num?)?.toInt() ?? deletedMs;

  Map<String, dynamic> toJson() => {
        'id': id,
        'rel': rel,
        'size': size,
        'at': deletedMs,
        'kind': kind.name,
        if (group != id) 'group': group,
        if (item != null) 'item': item,
        if (owner != null) 'owner': owner,
      };

  static TrashEntry? fromJson(Object? o) {
    if (o is! Map<String, dynamic>) return null;
    final id = o['id'];
    final rel = o['rel'];
    if (id is! String || rel is! String || id.isEmpty || rel.isEmpty) return null;
    return TrashEntry(
      id: id,
      rel: rel,
      size: (o['size'] as num?)?.toInt() ?? 0,
      deletedMs: (o['at'] as num?)?.toInt() ?? 0,
      kind: TrashKind.values.firstWhere((k) => k.name == o['kind'], orElse: () => TrashKind.file),
      group: o['group'] as String?,
      item: o['item'] as Map<String, dynamic>?,
      owner: o['owner'] as Map<String, dynamic>?,
    );
  }
}

/// LocalRoll's own "Recently deleted": deleted files are moved into the
/// library's hidden .localroll/trash folder (same drive: instant, nothing
/// copied) and kept [keep] days, restorable to where they were. After that
/// — or when emptied by hand — they are gone for good.
class LibraryTrash extends ChangeNotifier {
  LibraryTrash(this.library, this.files);

  final LibraryIndex library;
  final ReceivedFiles files;

  static const Duration keep = Duration(days: 30);

  final List<TrashEntry> _entries = [];
  String? _loadedFor;
  Future<void>? _loading;

  String get _sep => Platform.pathSeparator;
  String get _dir => '${library.metaDir}${_sep}trash';
  File get _indexFile => File('${library.metaDir}${_sep}trash.json');

  /// The file of [e] while it is in the trash.
  String storedPath(TrashEntry e) => '$_dir$_sep${e.id}$_sep${e.name}';

  /// Shown entries (one per photo / file), newest deletion first.
  List<TrashEntry> get entries => [for (final e in _entries.reversed) if (e.shown) e];

  /// Everything in the trash, Live Photo videos included.
  int get totalSize => _entries.fold(0, (a, e) => a + e.size);

  /// Size of [e] with what goes with it.
  int sizeOf(TrashEntry e) => _entries.where((x) => x.group == e.group).fold(0, (a, x) => a + x.size);

  Future<void> load() {
    if (_loadedFor != library.rootPath) _loading = null;
    return _loading ??= _load();
  }

  Future<void> _load() async {
    _loadedFor = library.rootPath;
    _entries.clear();
    try {
      if (await _indexFile.exists()) {
        final j = jsonDecode(await _indexFile.readAsString());
        if (j is Map<String, dynamic> && j['entries'] is List) {
          for (final o in j['entries'] as List) {
            final e = TrashEntry.fromJson(o);
            if (e != null) _entries.add(e);
          }
        }
      }
    } catch (e) {
      DiagLog.log('trash', 'trash.json unreadable: $e');
    }
    // Files that are no longer there (emptied by hand in Explorer).
    _entries.removeWhere((e) => !File(storedPath(e)).existsSync());
    notifyListeners();
  }

  /// One save at a time (they share the temporary file).
  Future<void> _saving = Future.value();

  Future<void> _save() => _saving = _saving.then((_) async {
        try {
          await Directory(library.metaDir).create(recursive: true);
          final tmp = File('${_indexFile.path}.tmp');
          await tmp.writeAsString(jsonEncode({'version': 1, 'entries': [for (final e in _entries) e.toJson()]}));
          await tmp.rename(_indexFile.path);
        } catch (e) {
          DiagLog.log('trash', 'trash.json not saved: $e');
        }
      });

  static int _seq = 0;

  static String _newId() =>
      '${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}${(_seq++ % 1296).toRadixString(36).padLeft(2, '0')}'
      '${Random().nextInt(1 << 16).toRadixString(36)}';

  /// Moves [from] into the trash as [id]; false if it can't be moved (in
  /// use, gone).
  Future<bool> _moveIn(String from, String id, String name) async {
    final dir = Directory('$_dir$_sep$id');
    try {
      await dir.create(recursive: true);
      final to = '${dir.path}$_sep$name';
      try {
        await File(from).rename(to);
      } on FileSystemException {
        // Another drive (shouldn't happen: the trash is inside the library).
        await File(from).copy(to);
        await File(from).delete();
      }
      return true;
    } catch (e) {
      DiagLog.log('trash', 'not moved to the trash: $e');
      try {
        await dir.delete();
      } catch (_) {}
      return false;
    }
  }

  /// Deletes library photos / videos (Live Photo videos go with their
  /// photo) into the trash; phones are told, as with any deletion.
  /// [onProgress]: files handled so far of all. Returns the entries made
  /// (shown ones), for "Undo".
  Future<List<TrashEntry>> putMedia(List<MediaItem> items, {void Function(int done, int total)? onProgress}) async {
    await load();
    if (library.offline || items.isEmpty) return const [];
    final now = DateTime.now().millisecondsSinceEpoch;
    final all = library.withLive(items);
    final videoOf = {for (final i in items) i: library.liveFor(i)};
    // Out of the index first: the folder watcher must not see hundreds of
    // files vanish and ask whether they were deleted.
    library.removeItems(all);
    final kept = <MediaItem>[];
    final shown = <TrashEntry>[];
    var done = 0;
    for (final i in items) {
      final id = _newId();
      final video = videoOf[i];
      if (await _moveIn(library.absPath(i), id, i.name)) {
        final e = TrashEntry(id: id, rel: i.relPath, size: i.size, deletedMs: now, kind: TrashKind.media, item: i.toJson());
        _entries.add(e);
        shown.add(e);
        if (video != null) {
          final vid = _newId();
          if (await _moveIn(library.absPath(video), vid, video.name)) {
            _entries.add(TrashEntry(
                id: vid, rel: video.relPath, size: video.size, deletedMs: now, kind: TrashKind.media, group: id, item: video.toJson()));
          } else {
            kept.add(video);
          }
        }
      } else {
        kept.addAll([i, ?video]);
      }
      done += video == null ? 1 : 2;
      onProgress?.call(min(done, all.length), all.length);
    }
    // In use, or gone already: back in the index if still there.
    final still = [for (final i in kept) if (File(library.absPath(i)).existsSync()) i];
    if (still.isNotEmpty) library.undelete(still);
    await _save();
    notifyListeners();
    return shown;
  }

  /// Deletes received files and converted copies (absolute paths inside
  /// the library) into the trash.
  Future<List<TrashEntry>> putFiles(List<String> paths, {void Function(int done, int total)? onProgress}) async {
    await load();
    if (library.offline || paths.isEmpty) return const [];
    final out = <TrashEntry>[];
    final owners = {for (final f in await files.list()) f.path.toLowerCase(): f.owner};
    final now = DateTime.now().millisecondsSinceEpoch;
    var done = 0;
    for (final p in paths) {
      final rel = files.relOf(p);
      if (rel != null && !rel.split('/').any((s) => s.isEmpty || s == '..' || s.startsWith('.'))) {
        int size = 0;
        try {
          size = await File(p).length();
        } catch (_) {}
        final id = _newId();
        final name = rel.substring(rel.lastIndexOf('/') + 1);
        if (await _moveIn(p, id, name)) {
          final e = TrashEntry(
            id: id,
            rel: rel,
            size: size,
            deletedMs: now,
            kind: rel.startsWith('_converted/') ? TrashKind.copy : TrashKind.file,
            owner: owners[p.toLowerCase()]?.toJson(),
          );
          _entries.add(e);
          out.add(e);
        }
      }
      onProgress?.call(++done, paths.length);
    }
    files.forget();
    await _save();
    notifyListeners();
    return out;
  }

  List<TrashEntry> _withGroup(Iterable<TrashEntry> list) {
    final groups = {for (final e in list) e.group};
    return [for (final e in _entries) if (groups.contains(e.group)) e];
  }

  /// Back where they were (a free name beside it if that place is taken
  /// now). Returns how many shown entries came back.
  Future<int> restore(List<TrashEntry> list) async {
    await load();
    if (library.offline) return 0;
    final back = <MediaItem>[];
    final done = <TrashEntry>[];
    for (final e in _withGroup(list)) {
      final from = storedPath(e);
      final want = '${library.rootPath}$_sep${e.rel.replaceAll('/', _sep)}';
      final folder = want.substring(0, want.lastIndexOf(_sep));
      try {
        await Directory(folder).create(recursive: true);
        final to = File(want).existsSync() ? LibraryIndex.uniquePath(folder, e.name) : want;
        await File(from).rename(to);
        try {
          await Directory('$_dir$_sep${e.id}').delete();
        } catch (_) {}
        done.add(e);
        final rel = to.substring(library.rootPath.length + 1).replaceAll(_sep, '/');
        final item = e.item;
        if (e.kind == TrashKind.media && item != null) {
          back.add(MediaItem.fromJson(item)
            ..relPath = rel
            ..name = rel.substring(rel.lastIndexOf('/') + 1));
        } else if (e.kind == TrashKind.file && e.owner != null) {
          await files.received(to, FileOwner.fromJson(e.owner!));
        }
      } catch (err) {
        DiagLog.log('trash', 'not restored: $err');
      }
    }
    if (back.isNotEmpty) library.undelete(back);
    files.forget();
    _entries.removeWhere(done.contains);
    await _save();
    notifyListeners();
    return done.where((e) => e.shown).length;
  }

  /// Gone for good (they were confirmed). Returns how many shown entries.
  Future<int> purge(List<TrashEntry> list) async {
    await load();
    final done = <TrashEntry>[];
    for (final e in _withGroup(list)) {
      try {
        final d = Directory('$_dir$_sep${e.id}');
        if (await d.exists()) await d.delete(recursive: true);
        done.add(e);
      } catch (err) {
        DiagLog.log('trash', 'not removed: $err');
      }
    }
    _entries.removeWhere(done.contains);
    await _save();
    notifyListeners();
    return done.where((e) => e.shown).length;
  }

  /// Everything older than [keep] goes for good (at start and once a day).
  Future<int> purgeOld({DateTime? now}) async {
    await load();
    if (library.offline) return 0;
    final cutoff = (now ?? DateTime.now()).subtract(keep).millisecondsSinceEpoch;
    final old = [for (final e in _entries) if (e.shown && e.deletedMs < cutoff) e];
    if (old.isEmpty) return 0;
    final n = await purge(old);
    DiagLog.log('trash', '$n deleted items older than ${keep.inDays} days removed for good');
    return n;
  }

  /// Days left before [e] goes for good.
  int daysLeft(TrashEntry e, {DateTime? now}) {
    final end = e.deleted.add(keep);
    return max(0, end.difference(now ?? DateTime.now()).inHours ~/ 24);
  }
}
