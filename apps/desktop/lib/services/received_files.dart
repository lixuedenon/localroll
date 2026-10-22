// apps/desktop/lib/services/received_files.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:localroll_core/localroll_core.dart';

import 'library_index.dart';

/// A received file (Documents / Other, at any depth): a document, a scan,
/// anything that is not a library photo or video.
class ReceivedFile {
  const ReceivedFile(this.path, this.size, this.modified, this.arrived, {this.owner, this.document = false});

  /// In the Documents folder (false: Other files).
  final bool document;

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
  const FileOwner(this.deviceId, this.deviceName, {this.private = false, this.arrivedMs = 0, this.size = 0});

  final String deviceId;
  final String deviceName;
  final bool private;

  /// When it arrived (0: not recorded).
  final int arrivedMs;

  /// Its size when it arrived: finds it again after it was renamed or moved
  /// in Explorer (0: not recorded).
  final int size;

  FileOwner copyWith({bool? private, int? size}) =>
      FileOwner(deviceId, deviceName, private: private ?? this.private, arrivedMs: arrivedMs, size: size ?? this.size);

  Map<String, dynamic> toJson() => {
        'd': deviceId,
        'n': deviceName,
        if (private) 'x': true,
        if (arrivedMs > 0) 'a': arrivedMs,
        if (size > 0) 's': size,
      };

  factory FileOwner.fromJson(Map<String, dynamic> j) => FileOwner(
        j['d'] as String? ?? '',
        j['n'] as String? ?? '',
        private: j['x'] == true,
        arrivedMs: (j['a'] as num?)?.toInt() ?? 0,
        size: (j['s'] as num?)?.toInt() ?? 0,
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
    var size = owner.size;
    if (size == 0) {
      try {
        size = await File(path).length();
      } catch (_) {}
    }
    m[rel.toLowerCase()] = FileOwner(owner.deviceId, owner.deviceName,
        private: owner.private,
        arrivedMs: owner.arrivedMs > 0 ? owner.arrivedMs : DateTime.now().millisecondsSinceEpoch,
        size: size);
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
      m[r.toLowerCase()] = o.copyWith(private: private);
      n++;
    }
    if (n > 0) await _saveOwners(m);
    return n;
  }

  /// One save at a time (they share the temporary file).
  Future<void> _saving = Future.value();

  /// "Only me" on / off for every file [deviceId] sent; how many changed.
  Future<int> setAllPrivate(String deviceId, bool private) async {
    final m = await _loadOwners();
    final rels = [for (final e in m.entries) if (e.value.deviceId == deviceId && e.value.private != private) e.key];
    return rels.isEmpty ? 0 : setPrivate(rels, deviceId, private);
  }

  /// Goes up whenever the list or who sent what changes (arrived,
  /// renamed, deleted, restored, "only me"): pages showing files reload.
  final ValueNotifier<int> changes = ValueNotifier(0);

  /// Files were added / removed by LocalRoll itself: list again, and tell.
  void changed() {
    _list = null;
    changes.value++;
  }

  /// Renames the received file at [path] to [newName] (same folder); who
  /// sent it and "only me" stay. Returns the new path. Throws
  /// [ArgumentError] for a name that can't be used, [StateError] if taken.
  Future<String> rename(String path, String newName) async {
    final name = newName.trim();
    if (name.isEmpty ||
        name.startsWith('.') ||
        name.contains(RegExp(r'[\\/:*?"<>|]')) ||
        name.toLowerCase() == 'desktop.ini' ||
        name.endsWith('.') ||
        name.endsWith(' ')) {
      throw ArgumentError.value(newName, 'newName');
    }
    final oldRel = relOf(path);
    if (oldRel == null) throw ArgumentError.value(path, 'path');
    final folder = path.substring(0, path.lastIndexOf(_sep));
    final to = '$folder$_sep$name';
    if (to == path) return path;
    final sameButCase = to.toLowerCase() == path.toLowerCase();
    if (!sameButCase && FileSystemEntity.typeSync(to) != FileSystemEntityType.notFound) throw StateError('taken');
    await File(path).rename(to);
    final m = await _loadOwners();
    final o = m.remove(oldRel.toLowerCase());
    final newRel = relOf(to);
    if (o != null && newRel != null) m[newRel.toLowerCase()] = o;
    await _saveOwners(m);
    return to;
  }

  Future<void> _saveOwners(Map<String, FileOwner> m) {
    changes.value++;
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
              document: doc,
            ));
          } catch (_) {}
        }
      } catch (_) {}
    }
    // Renamed or moved in Explorer: who sent it goes with it (same size,
    // and only one such file), so an "only me" file never becomes visible
    // to everyone just by a new name.
    final seen = {for (final f in out) ?relOf(f.path)?.toLowerCase()};
    final lost = [for (final e in owners.entries) if (e.value.size > 0 && !seen.contains(e.key)) e];
    if (lost.isNotEmpty) {
      var moved = false;
      for (var k = 0; k < out.length; k++) {
        final f = out[k];
        if (f.owner != null) continue;
        final same = lost.where((e) => e.value.size == f.size).toList();
        final rel = relOf(f.path);
        if (same.length != 1 || rel == null) continue;
        final e = same.single;
        owners.remove(e.key);
        owners[rel.toLowerCase()] = e.value;
        lost.remove(e);
        out[k] = ReceivedFile(f.path, f.size, f.modified,
            e.value.arrivedMs > 0 ? DateTime.fromMillisecondsSinceEpoch(e.value.arrivedMs) : f.arrived,
            owner: e.value, document: f.document);
        moved = true;
      }
      if (moved) unawaited(_saveOwners(owners));
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
