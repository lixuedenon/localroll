// apps/mobile/lib/services/uploader.dart
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:localroll_core/localroll_core.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'desktop_client.dart';
import 'mobile_settings.dart';

enum UploadState { waiting, preparing, uploading, verifying, done, skipped, failed }

class UploadItem {
  UploadItem(this.asset);

  final AssetEntity asset;
  String name = '';
  UploadState state = UploadState.waiting;
  int sent = 0;
  int total = 0;
  String? error;

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

  int get doneCount => items.where((i) => i.state == UploadState.done).length;
  int get skippedCount => items.where((i) => i.state == UploadState.skipped).length;
  int get failedCount => items.where((i) => i.state == UploadState.failed).length;

  void cancel() => _cancelled = true;

  Future<void> run() async {
    if (running) return;
    running = true;
    notifyListeners();
    try {
      await WakelockPlus.enable();
    } catch (_) {}
    try {
      for (var i = 0; i < items.length && !_cancelled; i++) {
        await _sendOne(items[i], i);
      }
    } finally {
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

      final offer = FileOffer(
        id: '$index',
        assetId: a.id,
        name: it.name,
        kind: a.type == AssetType.video ? MediaKind.video : MediaKind.image,
        createdMs: a.createDateTime.millisecondsSinceEpoch,
        modifiedMs: a.modifiedDateTime.millisecondsSinceEpoch,
      );

      // Ask first: if the PC already has it we skip without reading the file.
      final session = await client.createSession(SessionRequest(files: [offer]));
      final result = session.results[offer.id] ?? const OfferResult(status: OfferStatus.ready);
      if (result.status == OfferStatus.duplicate) {
        it.state = UploadState.skipped;
        await settings.markSent(desktop.id, a.id);
        notifyListeners();
        return;
      }

      // Original bytes, no transcoding. Downloads from iCloud if needed.
      final file = await a.originFile;
      if (file == null) throw Exception('无法读取原片（可能存放在 iCloud 且当前无法下载）');
      it.total = await file.length();
      await _upload(session.sessionId, offer, file, result.offset, it);
      await settings.markSent(desktop.id, a.id);
    } catch (e) {
      it.state = UploadState.failed;
      it.error = e is LrHttpException ? e.message : e.toString().replaceFirst('Exception: ', '');
    }
    notifyListeners();
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
        if (_cancelled) throw Exception('已取消');
        await raf.setPosition(offset);
        final chunk = await raf.read(min(LrProtocol.chunkSize, total - offset));
        try {
          final newOffset = await client.putChunk(sessionId, offer.id, offset, total, chunk);
          if (newOffset == offset + chunk.length) {
            hasher.add(chunk);
            offset = newOffset;
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
      }

      it.state = UploadState.verifying;
      notifyListeners();
      final res = await client.complete(
        sessionId,
        offer.id,
        CompleteRequest(size: total, sha256: hasher.finish()),
      );
      if (!res.saved) throw Exception(res.error ?? '电脑保存失败');
      it.state = UploadState.done;
    } finally {
      await raf.close();
    }
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
