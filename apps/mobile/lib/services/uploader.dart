// apps/mobile/lib/services/uploader.dart
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:localroll_core/localroll_core.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../l10n/l10n.dart';
import 'background_transfer.dart';
import 'desktop_client.dart';
import 'mobile_settings.dart';
import '../ui/cleanup_page.dart' show formatSize;

enum UploadState { waiting, preparing, uploading, verifying, done, skipped, failed }

class UploadItem {
  UploadItem(this.asset);

  final AssetEntity asset;
  String name = '';
  UploadState state = UploadState.waiting;
  int sent = 0;
  int total = 0;
  String? error;

  /// Not sent because the phone had no room for the temporary copy.
  bool noSpace = false;

  double? get fraction => total > 0 ? (sent / total).clamp(0.0, 1.0) : null;
}

/// Sends assets one by one in [LrProtocol.chunkSize] chunks.
///
/// Every chunk is its own HTTP request, the desktop keeps partial files, and
/// the final SHA-256 is checked on the PC — so Wi-Fi drops just resume.
class Uploader extends ChangeNotifier {
  Uploader({
    required this.client,
    required this.settings,
    required this.desktop,
    required List<AssetEntity> assets,
  }) : items = assets.map(UploadItem.new).toList();

  final DesktopClient client;
  final MobileSettings settings;
  final PairedDesktop desktop;
  final List<UploadItem> items;

  bool running = false;
  bool finished = false;
  bool _cancelled = false;

  /// iOS took the background time back; the rest can be resumed later.
  bool _expired = false;

  /// How the transfer survives leaving the app (shown on the transfer page).
  BackgroundMode backgroundMode = BackgroundMode.none;
  int _current = 0;

  int get doneCount => items.where((i) => i.state == UploadState.done).length;
  int get skippedCount => items.where((i) => i.state == UploadState.skipped).length;
  int get failedCount => items.where((i) => i.state == UploadState.failed).length;
  int get noSpaceCount => items.where((i) => i.noSpace).length;

  /// Finished one way or another (for the overall progress and time left).
  int get processedCount => doneCount + skippedCount + failedCount;

  DateTime? _startedAt;
  int _bytesSent = 0;

  /// Bytes per second over this run (0 until something was sent).
  double get speed {
    final t = _startedAt;
    if (t == null) return 0;
    final secs = DateTime.now().difference(t).inMilliseconds / 1000;
    return secs < 1 ? 0 : _bytesSent / secs;
  }

  /// Rough time left, from the average time per item so far.
  Duration? get timeLeft {
    final t = _startedAt;
    final n = processedCount;
    if (t == null || n < 3 || finished) return null;
    final per = DateTime.now().difference(t).inMilliseconds / n;
    return Duration(milliseconds: (per * (items.length - n)).round());
  }

  void cancel() => _cancelled = true;

  Future<void> run() async {
    if (running) return;
    running = true;
    _startedAt = DateTime.now();
    notifyListeners();
    try {
      await WakelockPlus.enable();
    } catch (_) {}
    BackgroundTransfer.onExpired = () {
      _expired = true;
      _cancelled = true;
    };
    backgroundMode = await BackgroundTransfer.start(
      channel: tr('bg.channel'),
      title: tr('bg.title'),
      text: tr('bg.progress', {'done': 1, 'total': items.length, 'name': ''}),
    );
    notifyListeners();
    try {
      for (var i = 0; i < items.length && !_cancelled; i++) {
        _current = i;
        await _sendOne(items[i], i);
      }
    } finally {
      await BackgroundTransfer.stop(success: failedCount == 0 && !_cancelled);
      BackgroundTransfer.onExpired = null;
      try {
        await WakelockPlus.disable();
      } catch (_) {}
      try {
        // photo_manager copies originals into a cache on iOS; free that space.
        await PhotoManager.clearFileCache();
      } catch (_) {}
      running = false;
      finished = true;
      notifyListeners();
    }
  }

  Future<void> _sendOne(UploadItem it, int index) async {
    final a = it.asset;
    try {
      it.state = UploadState.preparing;
      notifyListeners();
      final title = await a.titleAsync;
      it.name = title.isNotEmpty ? title : 'asset_${a.id.hashCode}';
      _reportBackground(it);

      final sentPhoto = await _sendFile(
        it,
        FileOffer(
          id: '$index',
          assetId: a.id,
          name: it.name,
          kind: a.type == AssetType.video ? MediaKind.video : MediaKind.image,
          createdMs: a.createDateTime.millisecondsSinceEpoch,
          modifiedMs: a.modifiedDateTime.millisecondsSinceEpoch,
          private: !settings.shareWithFamily,
        ),
        // Original bytes, no transcoding. Downloads from iCloud if needed.
        () => a.originFile,
      );

      // Live Photo: the moving part is a separate MOV. Without it the PC
      // would hold only a still, and cleanup would delete the motion for good.
      if (a.isLivePhoto) {
        final movName = await a.titleAsyncWithSubtype;
        await _sendFile(
          it,
          FileOffer(
            id: '$index-live',
            assetId: liveCompanionId(a.id),
            name: movName.isNotEmpty && movName != it.name ? movName : _movName(it.name),
            kind: MediaKind.video,
            createdMs: a.createDateTime.millisecondsSinceEpoch,
            modifiedMs: a.modifiedDateTime.millisecondsSinceEpoch,
            private: !settings.shareWithFamily,
          ),
          () => a.originFileWithSubtype,
        );
      }
      await settings.markSent(desktop.id, a.id);
      if (!sentPhoto && it.state != UploadState.done) it.state = UploadState.skipped;
    } on _NoSpace catch (e) {
      it
        ..state = UploadState.failed
        ..noSpace = true
        ..error = e.bytes > 0 ? tr('err.phone_space_size', {'size': formatSize(e.bytes)}) : tr('err.phone_space');
    } catch (e) {
      it.state = UploadState.failed;
      it.error = e is LrHttpException ? e.message : e.toString().replaceFirst('Exception: ', '');
    }
    notifyListeners();
  }

  static String _movName(String photoName) {
    final dot = photoName.lastIndexOf('.');
    return '${dot > 0 ? photoName.substring(0, dot) : photoName}.MOV';
  }

  /// Offers one file and uploads it unless the PC already has it.
  /// Returns false when it was a duplicate (nothing sent).
  Future<bool> _sendFile(UploadItem it, FileOffer offer, Future<File?> Function() open) async {
    // Ask first: if the PC already has it we skip without reading the file.
    final session = await client.createSession(SessionRequest(files: [offer], owner: settings.ownerName));
    final result = session.results[offer.id] ?? const OfferResult(status: OfferStatus.ready);
    if (result.status == OfferStatus.duplicate) return false;

    // iOS first exports the original to a temporary copy, which needs free
    // space. On a nearly full phone check before trying, so one big video
    // is skipped (and named at the end) instead of failing the whole batch.
    if (Platform.isIOS) {
      final live = isLiveCompanion(offer.assetId);
      final need = await BackgroundTransfer.originalSize(livePhotoIdOf(offer.assetId), live: live);
      final free = await BackgroundTransfer.freeSpace();
      if (need > 0 && free >= 0 && free < need + _spareBytes) throw _NoSpace(need);
    }

    File? file;
    try {
      file = await open();
    } catch (e) {
      if (await _phoneIsFull()) throw const _NoSpace(-1);
      rethrow;
    }
    if (file == null) {
      if (await _phoneIsFull()) throw const _NoSpace(-1);
      throw Exception(tr('err.no_original'));
    }
    try {
      it.total = await file.length();
      await _upload(session.sessionId, offer, file, result.offset, it);
    } finally {
      // Free the temporary copy right away: a 5 000-photo backup must never
      // need 5 000 copies' worth of space at once.
      await _discardTemporaryCopy(file);
    }
    return true;
  }

  /// Keep this much free beyond the file itself, for iOS and other apps.
  static const int _spareBytes = 300 * 1024 * 1024;

  static Future<bool> _phoneIsFull() async {
    final free = await BackgroundTransfer.freeSpace();
    return free >= 0 && free < _spareBytes;
  }

  /// Deletes [file] only if it is a temporary export inside this app's own
  /// temp folder (iOS). Android hands us the real file in the gallery — that
  /// is never touched.
  static Future<void> _discardTemporaryCopy(File file) async {
    if (!Platform.isIOS) return;
    try {
      final tmp = Directory.systemTemp.resolveSymbolicLinksSync();
      final path = file.resolveSymbolicLinksSync();
      if (path.startsWith('$tmp${Platform.pathSeparator}')) await file.delete();
    } catch (_) {}
  }

  Future<void> _upload(String sessionId, FileOffer offer, File file, int startOffset, UploadItem it) async {
    final total = it.total;
    final raf = await file.open();
    try {
      var offset = startOffset > total ? 0 : startOffset;
      var hasher = await _hashPrefix(raf, offset);
      it
        ..state = UploadState.uploading
        ..sent = offset;
      notifyListeners();

      var retries = 0;
      while (offset < total) {
        if (_cancelled) throw Exception(tr(_expired ? 'err.background_expired' : 'err.cancelled'));
        await raf.setPosition(offset);
        final chunk = await raf.read(min(LrProtocol.chunkSize, total - offset));
        try {
          final newOffset = await client.putChunk(sessionId, offer.id, offset, total, chunk);
          if (newOffset == offset + chunk.length) {
            hasher.add(chunk);
            offset = newOffset;
            _bytesSent += chunk.length;
          } else {
            offset = newOffset;
            hasher = await _hashPrefix(raf, offset);
          }
          retries = 0;
        } on LrHttpException catch (e) {
          if (e.status != 409) rethrow;
          // Out of sync (e.g. previous response lost): continue from the PC's offset.
          offset = (e.body['offset'] as num).toInt();
          hasher = await _hashPrefix(raf, offset);
        } catch (e) {
          // Network hiccup: back off, ask the PC where we are, continue.
          if (++retries > 6) rethrow;
          await Future<void>.delayed(Duration(seconds: 2 * retries));
          try {
            offset = await client.status(sessionId, offer.id);
          } catch (_) {}
          hasher = await _hashPrefix(raf, offset);
        }
        it.sent = offset;
        notifyListeners();
        _reportBackground(it);
      }

      it.state = UploadState.verifying;
      notifyListeners();
      final res = await client.complete(
        sessionId,
        offer.id,
        CompleteRequest(size: total, sha256: hasher.finish()),
      );
      if (!res.saved) throw Exception(res.error != null ? serverErrorText(res.error!) : tr('err.save_failed'));
      it.state = UploadState.done;
    } finally {
      await raf.close();
    }
  }

  void _reportBackground(UploadItem it) {
    final n = items.length;
    final overall = n == 0 ? 0.0 : (_current + (it.fraction ?? 0)) / n;
    BackgroundTransfer.update(
      title: tr('bg.title'),
      text: tr('bg.progress', {'done': _current + 1, 'total': n, 'name': it.name}),
      progress: overall,
    );
  }

  /// SHA-256 state of the first [length] bytes (needed when resuming).
  Future<StreamingSha256> _hashPrefix(RandomAccessFile raf, int length) async {
    final h = StreamingSha256();
    if (length <= 0) return h;
    await raf.setPosition(0);
    var done = 0;
    while (done < length) {
      final block = await raf.read(min(4 * 1024 * 1024, length - done));
      if (block.isEmpty) break;
      h.add(block);
      done += block.length;
    }
    return h;
  }
}

/// The phone has no room for the temporary copy of this original.
class _NoSpace implements Exception {
  const _NoSpace(this.bytes);

  /// Size of the original, or -1 if unknown.
  final int bytes;
}
