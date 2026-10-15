// apps/mobile/lib/services/media_saver.dart
import 'dart:async';
import 'dart:io';

import 'package:localroll_core/localroll_core.dart';
import 'package:path_provider/path_provider.dart';
import 'package:photo_manager/photo_manager.dart';

/// Where a received file ended up.
enum SavedTo { album, files }

/// Puts received files where people look for them:
///  * photos and videos → the phone's photo library, album "LocalRoll"
///    (capture date and place travel inside the file and are kept);
///  * a Live Photo (photo + its MOV, sent one after the other) → one Live
///    Photo on iPhone;
///  * anything else → the Files app (iPhone: On My iPhone › LocalRoll) or
///    Download/LocalRoll (Android).
class MediaSaver {
  static const String albumName = 'LocalRoll';

  /// Photos that may still get their Live Photo video (iPhone): held for a
  /// moment, saved alone if no video follows.
  final Map<String, _Held> _held = {};

  AssetPathEntity? _album;

  /// Saves [file] (a finished download named like the original) for [offer].
  /// [file] is moved or deleted afterwards.
  Future<SavedTo> save(File file, FileOffer offer) async {
    var kind = offer.kind;
    if (kind == MediaKind.other) kind = MediaKind.fromName(offer.name);
    if (kind != MediaKind.image && kind != MediaKind.video) return _toFiles(file, offer.name);
    if (!await _mayWriteLibrary()) return _toFiles(file, offer.name);

    // The moving part of a Live Photo whose photo is waiting: save them as one.
    if (isLiveCompanion(offer.assetId)) {
      final held = _held.remove(livePhotoIdOf(offer.assetId));
      if (held != null) {
        held.timer.cancel();
        var paired = false;
        try {
          final a = await PhotoManager.editor.darwin
              .saveLivePhoto(imageFile: held.file, videoFile: file, title: held.offer.name);
          await _intoAlbum(a);
          paired = true;
        } catch (_) {
          // Could not pair them: keep both as separate items (video below).
          try {
            await _saveImage(held.file, held.offer);
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
      _held[key] = _Held(file, offer, Timer(const Duration(seconds: 20), () => unawaited(_flush(key))));
      return SavedTo.album;
    }

    try {
      if (kind == MediaKind.image) {
        await _saveImage(file, offer);
      } else {
        final a = await PhotoManager.editor.saveVideo(
          file,
          title: offer.name,
          relativePath: Platform.isAndroid ? 'Movies/$albumName' : null,
          creationDate: DateTime.fromMillisecondsSinceEpoch(offer.createdMs),
        );
        await _intoAlbum(a);
      }
      return SavedTo.album;
    } catch (_) {
      // The library would not take it (format, permission): keep the file.
      return _toFiles(file, offer.name);
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
      await _saveImage(h.file, h.offer);
    } catch (_) {
      await _toFiles(h.file, h.offer.name);
    } finally {
      await _delete(h.file);
    }
  }

  Future<void> _saveImage(File file, FileOffer offer) async {
    final a = await PhotoManager.editor.saveImageWithPath(
      file.path,
      title: offer.name,
      relativePath: Platform.isAndroid ? 'Pictures/$albumName' : null,
      creationDate: DateTime.fromMillisecondsSinceEpoch(offer.createdMs),
    );
    await _intoAlbum(a);
  }

  /// iPhone: also file it in the "LocalRoll" album (Android: the folder
  /// given above already is the album).
  Future<void> _intoAlbum(AssetEntity asset) async {
    if (!Platform.isIOS) return;
    for (var attempt = 1; attempt <= 2; attempt++) {
      try {
        _album ??= await _findAlbum() ?? await PhotoManager.editor.darwin.createAlbum(albumName);
        final album = _album;
        if (album == null) {
          DiagLog.log('album', 'no "$albumName" album (could not create it)');
          return;
        }
        await PhotoManager.editor.copyAssetToPath(asset: asset, pathEntity: album);
        return;
      } catch (e) {
        // In the library anyway; the album is a nicety. A stale album
        // (deleted in Photos meanwhile): look it up again once.
        DiagLog.log('album', 'adding to "$albumName" failed (try $attempt): $e');
        _album = null;
      }
    }
  }

  Future<AssetPathEntity?> _findAlbum() async {
    final paths = await PhotoManager.getAssetPathList(hasAll: false, type: RequestType.common);
    for (final p in paths) {
      if (p.name == albumName) return p;
    }
    return null;
  }

  Future<bool> _mayWriteLibrary() async {
    try {
      final p = await PhotoManager.requestPermissionExtend();
      return p.hasAccess;
    } catch (_) {
      return false;
    }
  }

  /// Folder for files that are not photos or videos.
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
    // On My iPhone › LocalRoll — keep files right there, one level deep.
    final docs = await getApplicationDocumentsDirectory();
    return docs..createSync(recursive: true);
  }

  Future<SavedTo> _toFiles(File file, String name) async {
    final dir = await filesFolder();
    final safe = name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    var target = File('${dir.path}/$safe');
    final dot = safe.lastIndexOf('.');
    final base = dot > 0 ? safe.substring(0, dot) : safe;
    final ext = dot > 0 ? safe.substring(dot) : '';
    for (var n = 1; await target.exists(); n++) {
      target = File('${dir.path}/$base ($n)$ext');
    }
    try {
      await file.rename(target.path);
    } catch (_) {
      await file.copy(target.path);
      await _delete(file);
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
  _Held(this.file, this.offer, this.timer);

  final File file;
  final FileOffer offer;
  final Timer timer;
}
