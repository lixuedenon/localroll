// apps/mobile/lib/services/media_saver.dart
import 'dart:async';
import 'dart:io';

import 'package:localroll_core/localroll_core.dart';
import 'package:path_provider/path_provider.dart';
import 'package:photo_manager/photo_manager.dart';

import 'my_library.dart';

/// Where a received file ended up.
enum SavedTo { album, files }

/// Who sent it (shown in "My files"; one album / folder each).
class Sender {
  const Sender(this.id, this.name);

  final String id;
  final String name;
}

/// Puts received files where people look for them, sorted by sender:
///  * photos and videos → the phone's photo library, album
///    "LocalRoll · <sender>" (capture date and place travel inside the file);
///  * a Live Photo (photo + its MOV, sent one after the other) → one Live
///    Photo on iPhone;
///  * anything else → LocalRoll's folder (iPhone: Files › On My iPhone ›
///    LocalRoll; Android: Download/LocalRoll), in <category>/<sender>/.
/// Each is also listed in "My files" ([MyLibrary]).
class MediaSaver {
  MediaSaver() {
    MyLibrary.rootDir ??= filesFolder;
  }

  static const String albumName = 'LocalRoll';

  /// Album / folder name for photos from [from].
  static String albumFor(Sender from) => '$albumName · ${MyFolders.safe(from.name)}';

  /// Photos that may still get their Live Photo video (iPhone): held for a
  /// moment, saved alone if no video follows.
  final Map<String, _Held> _held = {};

  final Map<String, AssetPathEntity> _albums = {};
  bool _albumOk = false;
  PermissionState? _access;

  /// Saves [file] (a finished download named like the original) for [offer]
  /// from [from]. [file] is moved or deleted afterwards.
  Future<SavedTo> save(File file, FileOffer offer, {Sender from = const Sender('', '')}) async {
    var kind = offer.kind;
    if (kind == MediaKind.other) kind = MediaKind.fromName(offer.name);
    if (kind != MediaKind.image && kind != MediaKind.video) return _toFiles(file, offer, from);
    if (!await _mayWriteLibrary()) return _toFiles(file, offer, from);

    // The moving part of a Live Photo whose photo is waiting: save them as one.
    if (isLiveCompanion(offer.assetId)) {
      final held = _held.remove(livePhotoIdOf(offer.assetId));
      if (held != null) {
        held.timer.cancel();
        var paired = false;
        try {
          final a = await PhotoManager.editor.darwin
              .saveLivePhoto(imageFile: held.file, videoFile: file, title: held.offer.name);
          await _intoAlbum(a, from);
          await _list(a, held.offer.name, MyKind.photo, from);
          paired = true;
        } catch (_) {
          // Could not pair them: keep both as separate items (video below).
          try {
            await _saveImage(held.file, held.offer, held.from);
          } catch (_) {}
        } finally {
          await _delete(held.file);
        }
        if (paired) {
          await _delete(file);
          return SavedTo.album;
        }
      }
    }

    // iPhone: a photo may be followed by its Live Photo video — wait briefly.
    if (Platform.isIOS && kind == MediaKind.image && !isLiveCompanion(offer.assetId)) {
      final key = offer.assetId;
      _held.remove(key)?.timer.cancel();
      _held[key] = _Held(file, offer, from, Timer(const Duration(seconds: 20), () => unawaited(_flush(key))));
      return SavedTo.album;
    }

    try {
      if (kind == MediaKind.image) {
        await _saveImage(file, offer, from);
      } else {
        final a = await PhotoManager.editor.saveVideo(
          file,
          title: offer.name,
          relativePath: Platform.isAndroid ? 'Pictures/${albumFor(from)}' : null,
          creationDate: DateTime.fromMillisecondsSinceEpoch(offer.createdMs),
        );
        await _intoAlbum(a, from);
        await _list(a, offer.name, MyKind.video, from);
      }
      return SavedTo.album;
    } catch (_) {
      // The library would not take it (format, permission): keep the file.
      return _toFiles(file, offer, from);
    } finally {
      await _delete(file);
    }
  }

  /// Save whatever is still held (end of a transfer, app leaving).
  Future<void> flushAll() async {
    for (final k in _held.keys.toList()) {
      await _flush(k);
    }
  }

  Future<void> _flush(String key) async {
    final h = _held.remove(key);
    if (h == null) return;
    h.timer.cancel();
    try {
      await _saveImage(h.file, h.offer, h.from);
    } catch (_) {
      await _toFiles(h.file, h.offer, h.from);
    } finally {
      await _delete(h.file);
    }
  }

  Future<void> _saveImage(File file, FileOffer offer, Sender from) async {
    final a = await PhotoManager.editor.saveImageWithPath(
      file.path,
      title: offer.name,
      relativePath: Platform.isAndroid ? 'Pictures/${albumFor(from)}' : null,
      creationDate: DateTime.fromMillisecondsSinceEpoch(offer.createdMs),
    );
    await _intoAlbum(a, from);
    await _list(a, offer.name, MyKind.photo, from);
  }

  Future<void> _list(AssetEntity a, String name, MyKind kind, Sender from) async {
    try {
      await MyLibrary.instance.addAsset(a.id, name, kind, fromId: from.id, fromName: from.name);
    } catch (e) {
      DiagLog.error('mylib', e);
    }
  }

  /// iPhone: also file it in the sender's album (Android: the folder given
  /// above already is the album).
  Future<void> _intoAlbum(AssetEntity asset, Sender from) async {
    if (!Platform.isIOS) return;
    final name = albumFor(from);
    for (var attempt = 1; attempt <= 2; attempt++) {
      try {
        final album = _albums[name] ?? await _findAlbum(name) ?? await PhotoManager.editor.darwin.createAlbum(name);
        if (album == null) {
          DiagLog.log('album', 'no "$name" album (could not create it; photo access: ${_access?.name})');
          return;
        }
        _albums[name] = album;
        await PhotoManager.editor.copyAssetToPath(asset: asset, pathEntity: album);
        if (!_albumOk) {
          _albumOk = true;
          DiagLog.log('album', 'added to "$name" (photo access: ${_access?.name})');
        }
        return;
      } catch (e) {
        // In the library anyway; the album is a nicety. A stale album
        // (deleted in Photos meanwhile): look it up again once.
        DiagLog.log('album', 'adding to "$name" failed (try $attempt): $e');
        _albums.remove(name);
      }
    }
  }

  Future<AssetPathEntity?> _findAlbum(String name) async {
    final paths = await PhotoManager.getAssetPathList(hasAll: false, type: RequestType.common);
    for (final p in paths) {
      if (p.name == name) return p;
    }
    return null;
  }

  Future<bool> _mayWriteLibrary() async {
    try {
      final p = await PhotoManager.requestPermissionExtend();
      if (_access != p) DiagLog.log('album', 'photo access: ${p.name}');
      _access = p;
      return p.hasAccess;
    } catch (_) {
      return false;
    }
  }

  /// LocalRoll's folder for files that are not photos or videos.
  static Future<Directory> filesFolder() async {
    if (Platform.isAndroid) {
      final d = Directory('/storage/emulated/0/Download/$albumName');
      try {
        await d.create(recursive: true);
        return d;
      } catch (_) {
        final ext = await getExternalStorageDirectory();
        if (ext != null) return Directory('${ext.path}/$albumName')..createSync(recursive: true);
      }
    }
    // iPhone: the app's own folder is what Files shows as
    // On My iPhone › LocalRoll.
    final docs = await getApplicationDocumentsDirectory();
    return docs..createSync(recursive: true);
  }

  /// Folder for [kind] from [from] (made if needed).
  static Future<Directory> folderFor(MyKind kind, Sender from) async {
    final root = await filesFolder();
    final d = Directory('${root.path}/${MyFolders.forKind(kind)}/${MyFolders.safe(from.name)}');
    await d.create(recursive: true);
    return d;
  }

  /// A free name in [dir] for [name] ("x (1).pdf" if taken).
  static Future<File> freeFile(Directory dir, String name) async {
    final safe = name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    var target = File('${dir.path}/$safe');
    final dot = safe.lastIndexOf('.');
    final base = dot > 0 ? safe.substring(0, dot) : safe;
    final ext = dot > 0 ? safe.substring(dot) : '';
    for (var n = 1; await target.exists(); n++) {
      target = File('${dir.path}/$base ($n)$ext');
    }
    return target;
  }

  Future<SavedTo> _toFiles(File file, FileOffer offer, Sender from) async {
    final kind = MyKind.ofName(offer.name);
    final rel = offer.relPath ?? '';
    final Directory dir;
    final String name;
    if (rel.contains('/')) {
      // Part of a folder: Folders/<sender>/<its own folders>.
      final root = await filesFolder();
      final parts = rel.split('/').where((p) => p.isNotEmpty && p != '.' && p != '..').map(MyFolders.safe).toList();
      name = parts.removeLast();
      dir = Directory([root.path, MyFolders.folders, MyFolders.safe(from.name), ...parts].join('/'));
      await dir.create(recursive: true);
    } else {
      dir = await folderFor(kind, from);
      name = offer.name;
    }
    final target = await freeFile(dir, name);
    try {
      await file.rename(target.path);
    } catch (_) {
      await file.copy(target.path);
      await _delete(file);
    }
    try {
      await MyLibrary.instance.addFile(target.path, kind, fromId: from.id, fromName: from.name);
    } catch (e) {
      DiagLog.error('mylib', e);
    }
    return SavedTo.files;
  }

  static Future<void> _delete(File f) async {
    try {
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }
}

class _Held {
  _Held(this.file, this.offer, this.from, this.timer);

  final File file;
  final FileOffer offer;
  final Sender from;
  final Timer timer;
}
