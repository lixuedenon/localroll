// apps/desktop/lib/services/library_index.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:localroll_core/localroll_core.dart';

/// One received file in the library.
class MediaItem {
  MediaItem({
    required this.relPath,
    required this.name,
    required this.size,
    required this.kind,
    required this.captureMs,
    required this.receivedMs,
    this.sha256,
    this.deviceId,
    this.deviceName,
    this.assetId,
    this.private = false,
  });

  /// Path relative to the library root, always with '/' separators.
  /// Changes when the file is moved inside the library (in Explorer).
  String relPath;
  String name;
  final int size;
  final MediaKind kind;
  final int captureMs;
  final int receivedMs;
  final String? sha256;
  final String? deviceId;
  final String? deviceName;
  final String? assetId;

  /// Family group: "only me" — hidden from the family view.
  bool private;

  DateTime get captureTime => DateTime.fromMillisecondsSinceEpoch(captureMs);
  String get extension => extensionOf(name);

  Map<String, dynamic> toJson() => {
        'relPath': relPath,
        'name': name,
        'size': size,
        'kind': kind.name,
        'captureMs': captureMs,
        'receivedMs': receivedMs,
        if (sha256 != null) 'sha256': sha256,
        if (deviceId != null) 'deviceId': deviceId,
        if (deviceName != null) 'deviceName': deviceName,
        if (assetId != null) 'assetId': assetId,
        if (private) 'private': true,
      };

  factory MediaItem.fromJson(Map<String, dynamic> j) => MediaItem(
        relPath: j['relPath'] as String,
        name: j['name'] as String,
        size: (j['size'] as num).toInt(),
        kind: MediaKind.parse(j['kind'] as String?),
        captureMs: (j['captureMs'] as num).toInt(),
        receivedMs: (j['receivedMs'] as num?)?.toInt() ?? 0,
        sha256: j['sha256'] as String?,
        deviceId: j['deviceId'] as String?,
        deviceName: j['deviceName'] as String?,
        assetId: j['assetId'] as String?,
        private: j['private'] == true,
      );
}

/// JSON index of everything in the library folder.
///
/// Layout of the library root:
///   2026/10/IMG_1234.HEIC        received originals, by capture month
///   _converted/<preset>/...      conversion outputs
///   .localroll/index.json        this index
///   .localroll/incoming/         partial uploads (resumable)
///   .localroll/cache/            thumbnails and HEIC previews
///
/// The folder is watched while the app runs, so changes made in Explorer
/// show up right away:
///   * deleted → phones are told "no backup any more" (many at once: ask first);
///   * moved / renamed inside the library → same item, new path;
///   * restored from the Recycle Bin → the item comes back as it was;
///   * copied in from elsewhere → added to the library.
/// "Can't find it" is never taken as "deleted" when the whole folder is
/// unreachable (external drive unplugged): see [offline].
class LibraryIndex extends ChangeNotifier {
  LibraryIndex(this.rootPath, {this.stateFile});

  String rootPath;

  /// Remembers (outside the library) how many items each library folder
  /// had, so a missing folder is recognised as "unplugged", not "new".
  final File? stateFile;
  final List<MediaItem> _items = [];

  /// Items that were in the library and are gone now (deleted in LocalRoll
  /// or in Explorer). Phones ask for theirs to warn the user; a file that
  /// comes back (Recycle Bin) is matched here and restored.
  final List<_Tombstone> _deleted = [];
  Timer? _saveTimer;

  /// device|assetId -> item, rebuilt whenever the list changes.
  Map<String, MediaItem>? _byAssetCache;

  /// The library folder can't be reached (external drive unplugged, folder
  /// moved or renamed). Nothing is received and nothing is marked deleted
  /// until it is back.
  bool offline = false;

  /// Many files vanished at once (folder moved? mistake?): they wait here,
  /// hidden, until the user confirms. Phones are not told before that.
  List<MediaItem> pendingMissing = const [];

  /// More missing files than this in one go → ask before treating as deleted.
  static const int askAbove = 30;

  StreamSubscription<FileSystemEvent>? _watch;
  final Set<String> _dirtyDirs = {};
  Timer? _debounce;
  Timer? _offlineRetry;
  bool _reconciling = false;
  bool _again = false;

  /// What the library shows. The video half of a Live Photo is not listed on
  /// its own — it belongs to its photo (see [liveFor]). Files waiting for the
  /// "were these deleted?" answer are hidden.
  List<MediaItem> get items {
    final pending = pendingMissing.toSet();
    return List.unmodifiable(_items.where((i) =>
        !pending.contains(i) && (i.assetId == null || !isLiveCompanion(i.assetId!) || _orphan(i))));
  }

  /// A Live Photo video whose photo is gone is shown as a normal video.
  bool _orphan(MediaItem companion) => findByAsset(companion.deviceId ?? '', livePhotoIdOf(companion.assetId!)) == null;

  /// The Live Photo video that belongs to [photo], if it was received.
  MediaItem? liveFor(MediaItem photo) {
    if (photo.kind != MediaKind.image || photo.deviceId == null || photo.assetId == null) return null;
    return findByAsset(photo.deviceId!, liveCompanionId(photo.assetId!));
  }

  /// [items] plus their Live Photo videos (for delete / export).
  List<MediaItem> withLive(Iterable<MediaItem> items) => [
        for (final i in items) ...[i, ?liveFor(i)],
      ];

  String get _sep => Platform.pathSeparator;
  String get metaDir => '$rootPath$_sep.localroll';
  String get incomingDir => '$metaDir${_sep}incoming';
  String get cacheDir => '$metaDir${_sep}cache';
  File get _indexFile => File('$metaDir${_sep}index.json');

  /// Absolute path of an item.
  String absPath(MediaItem item) => _abs(item.relPath);
  String _abs(String rel) => '$rootPath$_sep${rel.replaceAll('/', _sep)}';

  Future<void> load() async {
    await _stopWatching();
    _items.clear();
    _deleted.clear();
    pendingMissing = const [];
    _byAssetCache = null;
    if (!await _rootUsable()) {
      _goOffline();
      return;
    }
    offline = false;
    _offlineRetry?.cancel();
    await Directory(incomingDir).create(recursive: true);
    await Directory(cacheDir).create(recursive: true);
    if (await _indexFile.exists()) {
      try {
        final j = jsonDecode(await _indexFile.readAsString()) as Map<String, dynamic>;
        for (final e in (j['items'] as List? ?? const [])) {
          _items.add(MediaItem.fromJson(e as Map<String, dynamic>));
        }
        for (final e in (j['deleted'] as List? ?? const [])) {
          _deleted.add(_Tombstone.fromJson(e as Map<String, dynamic>));
        }
      } catch (e) {
        debugPrint('index.json unreadable, starting empty: $e');
      }
    }
    _sort();
    // Catch up with what changed while the app was closed.
    await reconcile();
    _startWatching();
    notifyListeners();
  }

  /// Switches to another library folder.
  Future<void> changeRoot(String newRoot) async {
    if (!offline) await flush();
    rootPath = newRoot;
    await load();
  }

  /// A missing folder that used to hold items is "unplugged / moved" — never
  /// re-created empty (that would hide the problem). A missing folder that
  /// never had anything (first run) is created.
  Future<bool> _rootUsable() async {
    if (await Directory(rootPath).exists()) return true;
    if (await _knownCount() > 0) return false;
    try {
      await Directory(rootPath).create(recursive: true);
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<int> _knownCount() async {
    final f = stateFile;
    if (f == null || !await f.exists()) return 0;
    try {
      final j = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      return (j[rootPath.toLowerCase()] as num?)?.toInt() ?? 0;
    } catch (_) {
      return 0;
    }
  }

  Future<void> _saveKnownCount() async {
    final f = stateFile;
    if (f == null) return;
    try {
      Map<String, dynamic> j = {};
      if (await f.exists()) j = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      j[rootPath.toLowerCase()] = _items.length;
      await f.writeAsString(jsonEncode(j));
    } catch (_) {}
  }

  void _goOffline() {
    offline = true;
    _stopWatching();
    // Check again every 20 s; when the drive is back everything resumes.
    _offlineRetry?.cancel();
    _offlineRetry = Timer.periodic(const Duration(seconds: 20), (_) async {
      if (await Directory(rootPath).exists()) {
        _offlineRetry?.cancel();
        await load();
      }
    });
    notifyListeners();
  }

  /// "Try again" from the banner.
  Future<void> retry() async {
    if (offline) {
      await load();
    } else {
      await reconcile();
    }
  }

  @override
  void dispose() {
    _offlineRetry?.cancel();
    _saveTimer?.cancel();
    _stopWatching();
    super.dispose();
  }

  // ------------------------------------------------------------- watching

  void _startWatching() {
    try {
      _watch = Directory(rootPath).watch(recursive: true).listen(
        _onFsEvent,
        onError: (_) => _checkRoot(),
        onDone: _checkRoot,
      );
    } catch (_) {}
  }

  Future<void> _stopWatching() async {
    _debounce?.cancel();
    _dirtyDirs.clear();
    final w = _watch;
    _watch = null;
    await w?.cancel();
  }

  Future<void> _checkRoot() async {
    if (!await Directory(rootPath).exists()) _goOffline();
  }

  void _onFsEvent(FileSystemEvent e) {
    for (final path in [e.path, if (e is FileSystemMoveEvent) e.destination]) {
      if (path == null) continue;
      final rel = _rel(path);
      if (rel == null || _ignored(rel)) continue;
      // Re-check the folder it happened in (a deleted folder's items are
      // all under its parent).
      final slash = rel.lastIndexOf('/');
      _dirtyDirs.add(slash < 0 ? '' : rel.substring(0, slash));
    }
    if (_dirtyDirs.isEmpty) return;
    _debounce?.cancel();
    _debounce = Timer(const Duration(seconds: 2), () {
      final scopes = Set.of(_dirtyDirs);
      _dirtyDirs.clear();
      reconcile(scopes: scopes);
    });
  }

  String? _rel(String path) {
    final prefix = '$rootPath$_sep';
    if (path.length <= prefix.length || !path.toLowerCase().startsWith(prefix.toLowerCase())) return null;
    return path.substring(prefix.length).replaceAll(_sep, '/');
  }

  /// Our own folders and hidden ones are not part of the library.
  static bool _ignored(String rel) =>
      rel.split('/').any((seg) => seg.startsWith('.')) || rel == '_converted' || rel.startsWith('_converted/');

  // ------------------------------------------------------------- reconcile

  /// Brings the index in line with the folder ([scopes]: only these
  /// sub-folders, '' = everything; null = full check).
  Future<void> reconcile({Set<String>? scopes}) async {
    if (_reconciling) {
      _again = true;
      if (scopes != null) _dirtyDirs.addAll(scopes);
      return;
    }
    _reconciling = true;
    try {
      if (!await Directory(rootPath).exists()) {
        _goOffline();
        return;
      }
      final dirs = (scopes == null || scopes.contains('')) ? const <String>[''] : scopes.toList();
      bool inScope(String rel) => dirs.any((s) => s.isEmpty || rel == s || rel.startsWith('$s/'));

      // 1. Indexed files that are gone.
      final missing = [
        for (final i in _items)
          if (inScope(i.relPath) && !File(absPath(i)).existsSync()) i,
      ];

      // 2. Media files in the folder that the index doesn't know.
      final known = {for (final i in _items) i.relPath.toLowerCase()};
      final found = <String>[];
      for (final dir in dirs) {
        final d = Directory(dir.isEmpty ? rootPath : _abs(dir));
        if (!await d.exists()) continue;
        try {
          await for (final e in d.list(recursive: true, followLinks: false)) {
            if (e is! File) continue;
            final rel = _rel(e.path);
            if (rel == null || _ignored(rel) || MediaKind.fromName(rel) == MediaKind.other) continue;
            if (known.add(rel.toLowerCase())) found.add(rel);
          }
        } catch (_) {}
      }

      var changed = false;
      // 3. Moved or renamed inside the library: same name or size → same item.
      for (final rel in List.of(found)) {
        final size = _sizeOf(rel);
        final name = rel.substring(rel.lastIndexOf('/') + 1).toLowerCase();
        MediaItem? match;
        for (final m in missing) {
          if (m.size == size && m.name.toLowerCase() == name) {
            match = m;
            break;
          }
        }
        match ??= missing.where((m) => m.size == size && size > 0).length == 1
            ? missing.firstWhere((m) => m.size == size)
            : null;
        if (match != null) {
          match
            ..relPath = rel
            ..name = rel.substring(rel.lastIndexOf('/') + 1);
          missing.remove(match);
          found.remove(rel);
          changed = true;
        }
      }
      // 4. Restored from the Recycle Bin: back where it was → as it was.
      for (final rel in List.of(found)) {
        final size = _sizeOf(rel);
        for (var k = _deleted.length - 1; k >= 0; k--) {
          final it = _deleted[k].item;
          if (it != null && it.relPath.toLowerCase() == rel.toLowerCase() && it.size == size) {
            _items.add(MediaItem.fromJson(it.toJson())..relPath = rel);
            _deleted.removeAt(k);
            found.remove(rel);
            changed = true;
            break;
          }
        }
      }
      // 5. Copied in from elsewhere: add to the library.
      final now = DateTime.now().millisecondsSinceEpoch;
      for (final rel in found) {
        try {
          final f = File(_abs(rel));
          final stat = await f.stat();
          final name = rel.substring(rel.lastIndexOf('/') + 1);
          _items.add(MediaItem(
            relPath: rel,
            name: name,
            size: stat.size,
            kind: MediaKind.fromName(name),
            captureMs: stat.modified.millisecondsSinceEpoch,
            receivedMs: now,
          ));
          changed = true;
        } catch (_) {}
      }

      // 6. Gone: a few → deleted (phones are told). Many at once → ask first.
      final stillPending = pendingMissing.where((i) => !File(absPath(i)).existsSync() && _items.contains(i)).toList();
      final waiting = {...stillPending, ...missing}.toList();
      if (waiting.length > askAbove || (stillPending.isNotEmpty && missing.isNotEmpty)) {
        pendingMissing = waiting;
      } else {
        pendingMissing = stillPending;
        if (missing.isNotEmpty) {
          _forget(missing);
          changed = true;
        }
      }

      if (changed) {
        _sort();
        _scheduleSave();
      }
      notifyListeners();
    } finally {
      _reconciling = false;
      if (_again) {
        _again = false;
        final scopes = Set.of(_dirtyDirs);
        _dirtyDirs.clear();
        unawaited(reconcile(scopes: scopes.isEmpty ? null : scopes));
      }
    }
  }

  int _sizeOf(String rel) {
    try {
      return File(_abs(rel)).lengthSync();
    } catch (_) {
      return -1;
    }
  }

  /// The user confirmed: the vanished files really were deleted.
  void confirmMissing() {
    final gone = pendingMissing.where((i) => !File(absPath(i)).existsSync()).toList();
    pendingMissing = const [];
    if (gone.isNotEmpty) _forget(gone);
    _scheduleSave();
    notifyListeners();
  }

  MediaItem? findByAsset(String deviceId, String assetId) {
    final map = _byAssetCache ??= {
      for (final i in _items)
        if (i.deviceId != null && i.assetId != null) '${i.deviceId}|${i.assetId}': i,
    };
    return map['$deviceId|$assetId'];
  }

  void add(MediaItem item) {
    // Same path, or the same photo whose old file is gone (sent again after
    // a deletion that is still waiting for confirmation).
    bool replaced(MediaItem i) =>
        i.relPath.toLowerCase() == item.relPath.toLowerCase() ||
        (item.assetId != null &&
            i.deviceId == item.deviceId &&
            i.assetId == item.assetId &&
            !File(absPath(i)).existsSync());
    _items.removeWhere(replaced);
    pendingMissing = pendingMissing.where((i) => !replaced(i)).toList();
    _items.add(item);
    _sort();
    _scheduleSave();
    notifyListeners();
  }

  /// Family group: mark items (and their Live Photo videos) "only me" or
  /// visible to the family.
  void setPrivate(Iterable<MediaItem> items, bool value) {
    for (final i in withLive(items)) {
      i.private = value;
    }
    _scheduleSave();
    notifyListeners();
  }

  /// Removes items from the index (the caller already deleted the files).
  void removeItems(Iterable<MediaItem> items) {
    _forget(items);
    _scheduleSave();
    notifyListeners();
  }

  void _forget(Iterable<MediaItem> items) {
    final set = items.toSet();
    _remember(set);
    _items.removeWhere(set.contains);
    _byAssetCache = null;
  }

  void _remember(Iterable<MediaItem> items) {
    final now = DateTime.now().millisecondsSinceEpoch;
    for (final i in items) {
      _deleted.add(_Tombstone(i.deviceId ?? '', i.assetId ?? '', now, i));
    }
    // Keep the list bounded (a year, at most 10 000 entries).
    final cutoff = now - const Duration(days: 365).inMilliseconds;
    _deleted.removeWhere((t) => t.ms < cutoff);
    if (_deleted.length > 10000) _deleted.removeRange(0, _deleted.length - 10000);
  }

  /// Asset ids of [deviceId] deleted here after [sinceMs] — unless the same
  /// asset was received again since.
  List<String> deletedSince(String deviceId, int sinceMs) => [
        for (final t in _deleted)
          if (t.deviceId == deviceId &&
              t.assetId.isNotEmpty &&
              t.ms > sinceMs &&
              !isLiveCompanion(t.assetId) &&
              findByAsset(deviceId, t.assetId) == null)
            t.assetId,
      ];

  void _sort() {
    _items.sort((a, b) => b.captureMs.compareTo(a.captureMs));
    _byAssetCache = null;
  }

  void _scheduleSave() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 500), flush);
  }

  Future<void> flush() async {
    _saveTimer?.cancel();
    _saveTimer = null;
    if (offline) return; // never write an empty index onto a missing drive
    await Directory(metaDir).create(recursive: true);
    final tmp = File('${_indexFile.path}.tmp');
    await tmp.writeAsString(jsonEncode({
      'version': 1,
      'items': _items.map((i) => i.toJson()).toList(),
      'deleted': _deleted.map((t) => t.toJson()).toList(),
    }));
    await tmp.rename(_indexFile.path);
    await _saveKnownCount();
  }

  /// Picks a free file name inside [folder] (adds " (1)", " (2)" … if needed).
  static String uniquePath(String folder, String fileName) {
    final sep = Platform.pathSeparator;
    var candidate = '$folder$sep$fileName';
    if (!File(candidate).existsSync()) return candidate;
    final dot = fileName.lastIndexOf('.');
    final stem = dot > 0 ? fileName.substring(0, dot) : fileName;
    final ext = dot > 0 ? fileName.substring(dot) : '';
    for (var n = 1;; n++) {
      candidate = '$folder$sep$stem ($n)$ext';
      if (!File(candidate).existsSync()) return candidate;
    }
  }
}

class _Tombstone {
  const _Tombstone(this.deviceId, this.assetId, this.ms, [this.item]);

  final String deviceId;
  final String assetId;
  final int ms;

  /// The item as it was, so a file restored from the Recycle Bin comes back
  /// with its phone, capture time and checksum.
  final MediaItem? item;

  Map<String, dynamic> toJson() => {
        'd': deviceId,
        'a': assetId,
        't': ms,
        if (item != null) 'i': item!.toJson(),
      };

  factory _Tombstone.fromJson(Map<String, dynamic> j) => _Tombstone(
        j['d'] as String? ?? '',
        j['a'] as String? ?? '',
        (j['t'] as num).toInt(),
        j['i'] == null ? null : MediaItem.fromJson(j['i'] as Map<String, dynamic>),
      );
}
