// apps/desktop/lib/services/received_files.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:localroll_core/localroll_core.dart';

import 'library_index.dart';

/// A received file (Documents / Other, at any depth): a document, a scan,
/// anything that is not a library photo or video.
class ReceivedFile {
  const ReceivedFile(this.path, this.size, this.modified, this.arrived, {this.owner});

  final String path;
  final int size;
  final DateTime modified;

  /// When it arrived here (Windows keeps when the file was made).
  final DateTime arrived;

  /// Who sent it, when it was recorded (files received since beta.59).
  final FileOwner? owner;

  String get name => path.split(Platform.pathSeparator).last;
}

/// Who sent a received file, and whether only they may see it remotely.
class FileOwner {
  const FileOwner(this.deviceId, this.deviceName, {this.private = false, this.arrivedMs = 0});

  final String deviceId;
  final String deviceName;
  final bool private;

  /// When it arrived (0: not recorded).
  final int arrivedMs;

  Map<String, dynamic> toJson() => {'d': deviceId, 'n': deviceName, if (private) 'x': true, if (arrivedMs > 0) 'a': arrivedMs};

  factory FileOwner.fromJson(Map<String, dynamic> j) => FileOwner(
        j['d'] as String? ?? '',
        j['n'] as String? ?? '',
        private: j['x'] == true,
        arrivedMs: (j['a'] as num?)?.toInt() ?? 0,
      );
}

/// The files in the library's Documents and Other folders: listed (newest
/// arrival first, kept a few seconds), and who sent each one
/// (.localroll/files.json, by path inside the library).
class ReceivedFiles {
  ReceivedFiles(this.library, this.folderPath);

  final LibraryIndex library;

  /// The Documents (true) / Other (false) folder, made if needed.
  final Future<String> Function({required bool document}) folderPath;

  Map<String, FileOwner>? _owners;
  List<ReceivedFile>? _list;
  DateTime _listedAt = DateTime.fromMillisecondsSinceEpoch(0);

  String get _sep => Platform.pathSeparator;
  File get _ownersFile => File('${library.metaDir}${_sep}files.json');

  /// Path inside the library ("文档/scan.pdf", '/' separators), or null if
  /// [path] is not in it.
  String? relOf(String path) {
    final root = '${library.rootPath}$_sep';
    if (!path.toLowerCase().startsWith(root.toLowerCase())) return null;
    return path.substring(root.length).replaceAll(_sep, '/');
  }

  Future<Map<String, FileOwner>> _loadOwners() async {
    final known = _owners;
    if (known != null) return known;
    final m = <String, FileOwner>{};
    try {
      if (await _ownersFile.exists()) {
        final j = jsonDecode(await _ownersFile.readAsString()) as Map<String, dynamic>;
        for (final e in j.entries) {
          if (e.value is Map<String, dynamic>) m[e.key.toLowerCase()] = FileOwner.fromJson(e.value as Map<String, dynamic>);
        }
      }
    } catch (e) {
      DiagLog.log('files', 'files.json unreadable: $e');
    }
    return _owners = m;
  }

  /// A file arrived from [owner] at [path].
  Future<void> received(String path, FileOwner owner) async {
    final rel = relOf(path);
    if (rel == null) return;
    final m = await _loadOwners();
    m[rel.toLowerCase()] = owner.arrivedMs > 0
        ? owner
        : FileOwner(owner.deviceId, owner.deviceName, private: owner.private, arrivedMs: DateTime.now().millisecondsSinceEpoch);
    await _saveOwners(m);
  }

  /// "Only me" on / off for the files at [rels] that [deviceId] sent;
  /// returns how many changed.
  Future<int> setPrivate(List<String> rels, String deviceId, bool private) async {
    final m = await _loadOwners();
    var n = 0;
    for (final r in rels) {
      final o = m[r.toLowerCase()];
      if (o == null || o.deviceId != deviceId) continue;
      m[r.toLowerCase()] = FileOwner(o.deviceId, o.deviceName, private: private, arrivedMs: o.arrivedMs);
      n++;
    }
    if (n > 0) await _saveOwners(m);
    return n;
  }

  /// One save at a time (they share the temporary file).
  Future<void> _saving = Future.value();

  Future<void> _saveOwners(Map<String, FileOwner> m) {
    _list = null;
    return _saving = _saving.then((_) => _writeOwners(m));
  }

  Future<void> _writeOwners(Map<String, FileOwner> m) async {
    try {
      await Directory(library.metaDir).create(recursive: true);
      final tmp = File('${_ownersFile.path}.tmp');
      await tmp.writeAsString(jsonEncode({for (final e in m.entries) e.key: e.value.toJson()}));
      await tmp.rename(_ownersFile.path);
    } catch (e) {
      DiagLog.log('files', 'files.json not saved: $e');
    }
  }

  /// Something changed in the folders (deleted, renamed…): list again.
  void forget() => _list = null;

  /// Every received file, newest arrival first (listed again after a few
  /// seconds, or after [forget]).
  Future<List<ReceivedFile>> list() async {
    final cached = _list;
    if (cached != null && DateTime.now().difference(_listedAt) < const Duration(seconds: 5)) return cached;
    final owners = await _loadOwners();
    final out = <ReceivedFile>[];
    for (final doc in [true, false]) {
      final String dir;
      try {
        dir = await folderPath(document: doc);
      } catch (_) {
        continue;
      }
      try {
        await for (final e in Directory(dir).list(recursive: true, followLinks: false)) {
          if (e is! File) continue;
          final inside = e.path.substring(dir.length);
          final name = inside.split(_sep).last;
          if (inside.split(_sep).any((p) => p.startsWith('.')) || name.toLowerCase() == 'desktop.ini') continue;
          try {
            final st = await e.stat();
            final rel = relOf(e.path);
            final owner = rel == null ? null : owners[rel.toLowerCase()];
            final at = owner?.arrivedMs ?? 0;
            out.add(ReceivedFile(
              e.path,
              st.size,
              st.modified,
              // Recorded when it arrived; otherwise on Windows "changed" is
              // when the file was made here (the modified time is the
              // sender's).
              at > 0 ? DateTime.fromMillisecondsSinceEpoch(at) : (Platform.isWindows ? st.changed : st.modified),
              owner: owner,
            ));
          } catch (_) {}
        }
      } catch (_) {}
    }
    out.sort((a, b) => b.arrived.compareTo(a.arrived));
    _list = out;
    _listedAt = DateTime.now();
    return out;
  }

  /// The received file at [rel] ("文档/scan.pdf") — only inside the
  /// Documents / Other folders, never anywhere else.
  Future<ReceivedFile?> find(String rel) async {
    if (rel.isEmpty || rel.split('/').any((p) => p.isEmpty || p == '.' || p == '..' || p.startsWith('.'))) return null;
    for (final f in await list()) {
      if (relOf(f.path) == rel) return f;
    }
    return null;
  }
}
