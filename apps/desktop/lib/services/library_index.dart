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
  });

  /// Path relative to the library root, always with '/' separators.
  final String relPath;
  final String name;
  final int size;
  final MediaKind kind;
  final int captureMs;
  final int receivedMs;
  final String? sha256;
  final String? deviceId;
  final String? deviceName;
  final String? assetId;

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
class LibraryIndex extends ChangeNotifier {
  LibraryIndex(this.rootPath);

  String rootPath;
  final List<MediaItem> _items = [];
  Timer? _saveTimer;

  List<MediaItem> get items => List.unmodifiable(_items);

  String get _sep => Platform.pathSeparator;
  String get metaDir => '$rootPath$_sep.localroll';
  String get incomingDir => '$metaDir${_sep}incoming';
  String get cacheDir => '$metaDir${_sep}cache';
  File get _indexFile => File('$metaDir${_sep}index.json');

  /// Absolute path of an item.
  String absPath(MediaItem item) => '$rootPath$_sep${item.relPath.replaceAll('/', _sep)}';

  Future<void> load() async {
    await Directory(incomingDir).create(recursive: true);
    await Directory(cacheDir).create(recursive: true);
    _items.clear();
    if (await _indexFile.exists()) {
      try {
        final j = jsonDecode(await _indexFile.readAsString()) as Map<String, dynamic>;
        for (final e in (j['items'] as List? ?? const [])) {
          _items.add(MediaItem.fromJson(e as Map<String, dynamic>));
        }
      } catch (e) {
        debugPrint('index.json unreadable, starting empty: $e');
      }
    }
    // Drop entries whose file was deleted outside the app.
    _items.removeWhere((i) => !File(absPath(i)).existsSync());
    _sort();
    notifyListeners();
  }

  /// Switches to another library folder.
  Future<void> changeRoot(String newRoot) async {
    await flush();
    rootPath = newRoot;
    await load();
  }

  MediaItem? findByAsset(String deviceId, String assetId) {
    for (final i in _items) {
      if (i.deviceId == deviceId && i.assetId == assetId) return i;
    }
    return null;
  }

  void add(MediaItem item) {
    _items.removeWhere((i) => i.relPath == item.relPath);
    _items.add(item);
    _sort();
    _scheduleSave();
    notifyListeners();
  }

  void _sort() => _items.sort((a, b) => b.captureMs.compareTo(a.captureMs));

  void _scheduleSave() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 500), flush);
  }

  Future<void> flush() async {
    _saveTimer?.cancel();
    _saveTimer = null;
    await Directory(metaDir).create(recursive: true);
    final tmp = File('${_indexFile.path}.tmp');
    await tmp.writeAsString(jsonEncode({
      'version': 1,
      'items': _items.map((i) => i.toJson()).toList(),
    }));
    await tmp.rename(_indexFile.path);
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
