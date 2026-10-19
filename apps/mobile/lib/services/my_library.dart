// apps/mobile/lib/services/my_library.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:localroll_core/localroll_core.dart';
import 'package:path_provider/path_provider.dart';
import 'package:photo_manager/photo_manager.dart';

import '../l10n/l10n.dart';

/// What kind of item (decides the filter tab and how it opens).
enum MyKind {
  photo,
  video,
  document,
  scan,
  other;

  static MyKind parse(Object? v) => MyKind.values.firstWhere((k) => k.name == v, orElse: () => MyKind.other);

  /// For a received file, by its name.
  static MyKind ofName(String name) {
    switch (MediaKind.fromName(name)) {
      case MediaKind.image:
        return MyKind.photo;
      case MediaKind.video:
        return MyKind.video;
      case MediaKind.other:
        return isDocumentName(name) ? MyKind.document : MyKind.other;
    }
  }

  bool get isMedia => this == photo || this == video;
}

/// One thing in "My files": a photo or video in the phone's photo library
/// ([assetId]), or a file in LocalRoll's folder ([rel], relative to
/// [MyLibrary.root] — the app's folder moves on iPhone updates).
class MyItem {
  MyItem({
    required this.id,
    required this.kind,
    required this.name,
    required this.fromId,
    required this.fromName,
    required this.addedMs,
    this.size = 0,
    this.assetId,
    this.rel,
    this.deletedMs,
    this.trash,
  });

  final String id;
  final MyKind kind;
  String name;
  final String fromId;
  final String fromName;
  final int addedMs;
  int size;
  final String? assetId;
  String? rel;

  /// In "Recently deleted" since then (files only; photos go to the
  /// phone's own "Recently Deleted").
  int? deletedMs;

  /// Where the deleted file waits (relative to the trash folder).
  String? trash;

  bool get isAsset => assetId != null;

  Map<String, dynamic> toJson() => {
        'id': id,
        'k': kind.name,
        'n': name,
        'fi': fromId,
        'fn': fromName,
        'at': addedMs,
        if (size > 0) 's': size,
        'a': ?assetId,
        'r': ?rel,
        'd': ?deletedMs,
        't': ?trash,
      };

  factory MyItem.fromJson(Map<String, dynamic> j) => MyItem(
        id: j['id'] as String,
        kind: MyKind.parse(j['k']),
        name: j['n'] as String? ?? '',
        fromId: j['fi'] as String? ?? '',
        fromName: j['fn'] as String? ?? '',
        addedMs: (j['at'] as num?)?.toInt() ?? 0,
        size: (j['s'] as num?)?.toInt() ?? 0,
        assetId: j['a'] as String?,
        rel: j['r'] as String?,
        deletedMs: (j['d'] as num?)?.toInt(),
        trash: j['t'] as String?,
      );
}

/// "My files": everything that arrived on this phone (and its own scans),
/// sorted by who sent it — like the PC's library.
///
/// The files themselves stay where the phone wants them: photos and videos
/// in the photo library (one album per sender, "LocalRoll · <sender>"),
/// everything else in LocalRoll's folder (Files › On My iPhone › LocalRoll,
/// or Download/LocalRoll), in <category>/<sender>/. This is the list of them.
class MyLibrary extends ChangeNotifier {
  MyLibrary._();

  static final MyLibrary instance = MyLibrary._();

  final List<MyItem> _items = [];
  bool _loaded = false;

  /// Older files (from before "My files") were taken in.
  bool imported = false;
  Future<void>? _loading;
  Timer? _saveSoon;

  /// LocalRoll's folder for files (set by MediaSaver).
  static Future<Directory> Function()? rootDir;
  static Future<Directory> root() async {
    final f = rootDir;
    if (f == null) throw StateError('MyLibrary.rootDir not set');
    return f();
  }

  /// Shown (not deleted), newest first.
  List<MyItem> get items {
    final l = _items.where((i) => i.deletedMs == null).toList()..sort((a, b) => b.addedMs.compareTo(a.addedMs));
    return l;
  }

  /// "Recently deleted" (files), newest first.
  List<MyItem> get trash {
    final l = _items.where((i) => i.deletedMs != null).toList()..sort((a, b) => b.deletedMs!.compareTo(a.deletedMs!));
    return l;
  }

  /// Senders, by name (for the filter).
  List<(String, String)> get sources {
    final m = <String, String>{};
    for (final i in items) {
      m[i.fromId] = i.fromName;
    }
    final l = m.entries.map((e) => (e.key, e.value)).toList()..sort((a, b) => a.$2.compareTo(b.$2));
    return l;
  }

  Future<File> _indexFile() async {
    final d = await getApplicationSupportDirectory();
    return File('${d.path}/my_library.json');
  }

  Future<Directory> _trashDir() async {
    final d = await getApplicationSupportDirectory();
    return Directory('${d.path}/my_trash');
  }

  Future<void> load() => _loading ??= _load();

  Future<void> _load() async {
    try {
      final f = await _indexFile();
      if (await f.exists()) {
        final j = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
        imported = j['imported'] == true;
        for (final e in (j['items'] as List? ?? const [])) {
          _items.add(MyItem.fromJson(e as Map<String, dynamic>));
        }
      }
    } catch (e) {
      DiagLog.error('mylib', e);
    }
    _loaded = true;
    notifyListeners();
  }

  void _scheduleSave() {
    _saveSoon?.cancel();
    _saveSoon = Timer(const Duration(milliseconds: 400), () => unawaited(_save()));
  }

  Future<void> _save() async {
    try {
      final f = await _indexFile();
      final tmp = File('${f.path}.tmp');
      await tmp.writeAsString(jsonEncode({'v': 1, 'imported': imported, 'items': [for (final i in _items) i.toJson()]}));
      await tmp.rename(f.path);
    } catch (e) {
      DiagLog.error('mylib', e);
    }
  }

  static String _newId() => DateTime.now().microsecondsSinceEpoch.toRadixString(36);

  /// A photo or video saved into the photo library.
  Future<void> addAsset(String assetId, String name, MyKind kind, {required String fromId, required String fromName, int size = 0}) async {
    await load();
    if (_items.any((i) => i.assetId == assetId)) return;
    _items.add(MyItem(
      id: _newId(),
      kind: kind,
      name: name,
      fromId: fromId,
      fromName: fromName,
      addedMs: DateTime.now().millisecondsSinceEpoch,
      size: size,
      assetId: assetId,
    ));
    _scheduleSave();
    notifyListeners();
  }

  /// A file saved into LocalRoll's folder ([path] absolute).
  Future<void> addFile(String path, MyKind kind, {required String fromId, required String fromName}) async {
    await load();
    final rel = await _relOf(path);
    if (rel == null) return;
    if (_items.any((i) => i.rel == rel && i.deletedMs == null)) return;
    var size = 0;
    try {
      size = await File(path).length();
    } catch (_) {}
    _items.add(MyItem(
      id: _newId(),
      kind: kind,
      name: path.split('/').last,
      fromId: fromId,
      fromName: fromName,
      addedMs: DateTime.now().millisecondsSinceEpoch,
      size: size,
      rel: rel,
    ));
    _scheduleSave();
    notifyListeners();
  }

  Future<String?> _relOf(String path) async {
    final r = (await root()).path;
    if (!path.startsWith('$r/')) return null;
    return path.substring(r.length + 1);
  }

  /// Full path of a file item (null for photos / videos).
  Future<String?> pathOf(MyItem i) async {
    final rel = i.rel;
    if (rel == null) return null;
    return '${(await root()).path}/$rel';
  }

  /// The file to open / share / send: a file item's own file, or a
  /// photo's original (iPhone: a temporary copy).
  Future<File?> fileOf(MyItem i) async {
    if (i.assetId != null) {
      final a = await AssetEntity.fromId(i.assetId!);
      return a?.originFile;
    }
    final p = await pathOf(i);
    return p == null ? null : File(p);
  }

  /// Gone elsewhere (deleted in Photos / Files, or moved away): dropped from
  /// the list. "Recently deleted" older than 30 days is emptied.
  Future<void> reconcile() async {
    await load();
    var changed = false;
    final cutoff = DateTime.now().subtract(const Duration(days: 30)).millisecondsSinceEpoch;
    final trashDir = await _trashDir();
    for (final i in _items.toList()) {
      if (i.deletedMs != null) {
        if (i.deletedMs! < cutoff) {
          await _deleteQuietly(File('${trashDir.path}/${i.trash}'));
          _items.remove(i);
          changed = true;
        }
        continue;
      }
      if (i.assetId != null) {
        final a = await AssetEntity.fromId(i.assetId!);
        if (a == null) {
          _items.remove(i);
          changed = true;
        }
      } else {
        final p = await pathOf(i);
        if (p == null || !await File(p).exists()) {
          _items.remove(i);
          changed = true;
        }
      }
    }
    if (changed) {
      _scheduleSave();
      notifyListeners();
    }
  }

  /// Things received before "My files" existed (files in LocalRoll's
  /// folder, photos in the old "LocalRoll" album): taken in once, sender
  /// unknown.
  Future<int> importOld({required String unknownName}) async {
    await load();
    if (imported) return 0;
    var n = 0;
    try {
      final r = await root();
      if (await r.exists()) {
        await for (final e in r.list(recursive: true, followLinks: false)) {
          if (e is! File) continue;
          final rel = await _relOf(e.path);
          if (rel == null || rel.split('/').any((s) => s.startsWith('.'))) continue;
          if (_items.any((i) => i.rel == rel)) continue;
          final name = rel.split('/').last;
          if (name.startsWith('LocalRoll-log-')) continue;
          final st = await e.stat();
          _items.add(MyItem(
            id: _newId(),
            kind: rel.startsWith('${MyFolders.scans}/') || name.startsWith('scan_') ? MyKind.scan : MyKind.ofName(name),
            name: name,
            fromId: '',
            fromName: unknownName,
            addedMs: st.modified.millisecondsSinceEpoch,
            size: st.size,
            rel: rel,
          ));
          n++;
        }
      }
    } catch (e) {
      DiagLog.error('mylib', e);
    }
    try {
      final paths = await PhotoManager.getAssetPathList(hasAll: false, type: RequestType.common);
      for (final p in paths) {
        if (p.name != 'LocalRoll') continue;
        final count = await p.assetCountAsync;
        final assets = await p.getAssetListRange(start: 0, end: count);
        for (final a in assets) {
          if (_items.any((i) => i.assetId == a.id)) continue;
          _items.add(MyItem(
            id: _newId(),
            kind: a.type == AssetType.video ? MyKind.video : MyKind.photo,
            name: a.title ?? '',
            fromId: '',
            fromName: unknownName,
            addedMs: a.createDateTime.millisecondsSinceEpoch,
            assetId: a.id,
          ));
          n++;
        }
      }
    } catch (e) {
      DiagLog.error('mylib', e);
    }
    imported = true;
    _scheduleSave();
    notifyListeners();
    if (n > 0) DiagLog.log('mylib', 'took in $n older items');
    return n;
  }

  /// Delete: files go to "Recently deleted" (30 days); photos and videos
  /// are deleted through the system (it asks once, and keeps them in its own
  /// "Recently Deleted"). Returns how many were deleted.
  Future<int> delete(List<MyItem> list) async {
    var n = 0;
    final assets = [for (final i in list) if (i.assetId != null) i.assetId!];
    if (assets.isNotEmpty) {
      try {
        final gone = (await removeFromPhone(assets)).ids.toSet();
        for (final i in list) {
          if (i.assetId != null && gone.contains(i.assetId)) {
            _items.remove(i);
            n++;
          }
        }
      } catch (e) {
        DiagLog.error('mylib', e);
      }
    }
    final trashDir = await _trashDir();
    await trashDir.create(recursive: true);
    for (final i in list) {
      if (i.assetId != null) continue;
      final p = await pathOf(i);
      if (p == null) continue;
      final t = '${i.id}_${i.name}';
      try {
        await _move(File(p), '${trashDir.path}/$t');
        i
          ..deletedMs = DateTime.now().millisecondsSinceEpoch
          ..trash = t;
        n++;
      } catch (e) {
        DiagLog.error('mylib', e);
      }
    }
    _scheduleSave();
    notifyListeners();
    DiagLog.log('mylib', 'deleted $n of ${list.length}');
    return n;
  }

  /// Back from "Recently deleted" to where it was (a free name if taken).
  Future<bool> restore(MyItem i) async {
    final rel = i.rel;
    final t = i.trash;
    if (rel == null || t == null) return false;
    final trashDir = await _trashDir();
    var target = '${(await root()).path}/$rel';
    target = await _free(target);
    try {
      await File(target).parent.create(recursive: true);
      await _move(File('${trashDir.path}/$t'), target);
      i
        ..rel = (await _relOf(target)) ?? rel
        ..name = target.split('/').last
        ..deletedMs = null
        ..trash = null;
      _scheduleSave();
      notifyListeners();
      return true;
    } catch (e) {
      DiagLog.error('mylib', e);
      return false;
    }
  }

  /// Gone for good (from "Recently deleted").
  Future<void> purge(List<MyItem> list) async {
    final trashDir = await _trashDir();
    for (final i in list) {
      if (i.trash != null) await _deleteQuietly(File('${trashDir.path}/${i.trash}'));
      _items.remove(i);
    }
    _scheduleSave();
    notifyListeners();
  }

  /// New name for a file (keeps its extension if none is given).
  Future<bool> rename(MyItem i, String newName) async {
    final p = await pathOf(i);
    if (p == null) return false;
    var name = newName.trim().replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    if (name.isEmpty) return false;
    final dot = i.name.lastIndexOf('.');
    if (dot > 0 && !name.contains('.')) name = '$name${i.name.substring(dot)}';
    final dir = p.substring(0, p.lastIndexOf('/'));
    final target = await _free('$dir/$name');
    try {
      await File(p).rename(target);
      i
        ..name = target.split('/').last
        ..rel = await _relOf(target);
      _scheduleSave();
      notifyListeners();
      return true;
    } catch (e) {
      DiagLog.error('mylib', e);
      return false;
    }
  }

  bool get loaded => _loaded;

  static Future<String> _free(String path) async {
    if (!await File(path).exists()) return path;
    final slash = path.lastIndexOf('/');
    final dot = path.lastIndexOf('.');
    final hasExt = dot > slash + 1;
    final base = hasExt ? path.substring(0, dot) : path;
    final ext = hasExt ? path.substring(dot) : '';
    for (var n = 1;; n++) {
      final c = '$base ($n)$ext';
      if (!await File(c).exists()) return c;
    }
  }

  static Future<void> _move(File f, String to) async {
    try {
      await f.rename(to);
    } catch (_) {
      await f.copy(to);
      await f.delete();
    }
  }

  static Future<void> _deleteQuietly(File f) async {
    try {
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }
}

/// Folder names inside LocalRoll's folder, in the app's language when
/// made: Documents / Scans / Other / Folders, then one folder per sender.
class MyFolders {
  MyFolders._();

  static String get documents => tr('mylib.folder_docs');
  static String get scans => tr('mylib.folder_scans');
  static String get other => tr('mylib.folder_other');
  static String get folders => tr('mylib.folder_folders');

  static String forKind(MyKind k) => switch (k) {
        MyKind.document => documents,
        MyKind.scan => scans,
        _ => other,
      };

  /// A sender's name as a folder / album name.
  static String safe(String name) {
    final s = name.trim().replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    return s.isEmpty ? tr('mylib.unknown') : s;
  }
}

/// Removes photos / videos from this phone's library. Android 11 and later:
/// into the system's Trash (kept 30 days, like iPhone's "Recently
/// Deleted") — [trashed] is true. Older Android: deleted (the system asks
/// first). iPhone: the system keeps them in "Recently Deleted" for 30 days.
/// Returns the ids that are gone (none if the person cancelled).
Future<({List<String> ids, bool trashed})> removeFromPhone(List<String> ids) async {
  if (ids.isEmpty) return (ids: const <String>[], trashed: false);
  if (Platform.isAndroid) {
    try {
      final assets = <AssetEntity>[];
      for (final id in ids) {
        final a = await AssetEntity.fromId(id);
        if (a != null) assets.add(a);
      }
      if (assets.isEmpty) return (ids: const <String>[], trashed: true);
      return (ids: await PhotoManager.editor.android.moveToTrash(assets), trashed: true);
    } on PlatformException catch (e) {
      // Android 10 and older have no Trash: delete as before.
      if (!'${e.code} ${e.message}'.contains('29 or lower')) rethrow;
    }
  }
  return (ids: await PhotoManager.editor.deleteWithIds(ids), trashed: false);
}
