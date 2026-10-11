// apps/mobile/lib/services/backup_plan.dart
import 'dart:io';

import 'package:photo_manager/photo_manager.dart';

import 'background_transfer.dart';

enum BackupOrder { newest, oldest, largest }

/// What to back up and when to stop. Every field is optional; together they
/// narrow the selection (AND). Remembered between runs.
class BackupFilter {
  BackupFilter({
    this.fromMs,
    this.toMs,
    this.maxCount,
    this.photos = true,
    this.videos = true,
    this.liveOnly = false,
    this.skipScreenshots = false,
    this.favoritesOnly = false,
    this.localOnly = false,
    List<String>? albumIds,
    this.minFileMb,
    this.maxFileMb,
    this.order = BackupOrder.newest,
    this.stopAfterMb,
    this.stopAfterMinutes,
    this.pauseOnLowBattery = true,
  }) : albumIds = albumIds ?? [];

  /// Capture date range (inclusive), ms since epoch.
  int? fromMs;
  int? toMs;

  /// At most this many items (after ordering): "the latest 50".
  int? maxCount;

  bool photos;
  bool videos;
  bool liveOnly;
  bool skipScreenshots;
  bool favoritesOnly;

  /// iPhone: skip originals that are only in iCloud (they need downloading).
  bool localOnly;

  /// Only these albums (empty = whole library).
  List<String> albumIds;

  /// Single-file size limits, MB.
  int? minFileMb;
  int? maxFileMb;
  BackupOrder order;

  /// Stop after sending this much (MB) / after this long.
  int? stopAfterMb;
  int? stopAfterMinutes;

  /// Pause when the battery is under 20 % and not charging.
  bool pauseOnLowBattery;

  bool get needsSizes => minFileMb != null || maxFileMb != null || order == BackupOrder.largest || stopAfterMb != null;

  Map<String, dynamic> toJson() => {
        if (fromMs != null) 'fromMs': fromMs,
        if (toMs != null) 'toMs': toMs,
        if (maxCount != null) 'maxCount': maxCount,
        'photos': photos,
        'videos': videos,
        'liveOnly': liveOnly,
        'skipScreenshots': skipScreenshots,
        'favoritesOnly': favoritesOnly,
        'localOnly': localOnly,
        'albumIds': albumIds,
        if (minFileMb != null) 'minFileMb': minFileMb,
        if (maxFileMb != null) 'maxFileMb': maxFileMb,
        'order': order.name,
        if (stopAfterMb != null) 'stopAfterMb': stopAfterMb,
        if (stopAfterMinutes != null) 'stopAfterMinutes': stopAfterMinutes,
        'pauseOnLowBattery': pauseOnLowBattery,
      };

  factory BackupFilter.fromJson(Map<String, dynamic> j) => BackupFilter(
        fromMs: (j['fromMs'] as num?)?.toInt(),
        toMs: (j['toMs'] as num?)?.toInt(),
        maxCount: (j['maxCount'] as num?)?.toInt(),
        photos: j['photos'] != false,
        videos: j['videos'] != false,
        liveOnly: j['liveOnly'] == true,
        skipScreenshots: j['skipScreenshots'] == true,
        favoritesOnly: j['favoritesOnly'] == true,
        localOnly: j['localOnly'] == true,
        albumIds: (j['albumIds'] as List?)?.cast<String>(),
        minFileMb: (j['minFileMb'] as num?)?.toInt(),
        maxFileMb: (j['maxFileMb'] as num?)?.toInt(),
        order: BackupOrder.values.firstWhere((o) => o.name == j['order'], orElse: () => BackupOrder.newest),
        stopAfterMb: (j['stopAfterMb'] as num?)?.toInt(),
        stopAfterMinutes: (j['stopAfterMinutes'] as num?)?.toInt(),
        pauseOnLowBattery: j['pauseOnLowBattery'] != false,
      );

  BackupFilter copy() => BackupFilter.fromJson(toJson());
}

/// The result of applying a [BackupFilter] to the library.
class BackupPlan {
  const BackupPlan(this.assets, this.totalBytes, {this.sizesKnown = true});

  final List<AssetEntity> assets;

  /// Sum of original sizes (0 if unknown).
  final int totalBytes;
  final bool sizesKnown;
}

/// Turns a filter into the list of assets to send, newest/oldest/largest
/// first, skipping what the PC already has.
class BackupPlanner {
  BackupPlanner._();

  static const int _mb = 1024 * 1024;

  /// Screenshots: iOS marks them (PHAssetMediaSubtypePhotoScreenshot);
  /// Android keeps them in a "Screenshots" folder.
  static bool isScreenshot(AssetEntity a) {
    if (Platform.isIOS) return a.subtype & 4 == 4;
    final path = (a.relativePath ?? '').toLowerCase();
    final title = (a.title ?? '').toLowerCase();
    return path.contains('screenshot') || title.startsWith('screenshot');
  }

  /// [sent]: ids already on the PC. [onProgress]: items looked at so far.
  static Future<BackupPlan> plan(
    BackupFilter f,
    Set<String> sent, {
    void Function(int seen)? onProgress,
  }) async {
    if (!f.photos && !f.videos) return const BackupPlan([], 0);
    final type = f.photos && f.videos
        ? RequestType.common
        : f.photos
            ? RequestType.image
            : RequestType.video;
    final filter = FilterOptionGroup(
      orders: [OrderOption(type: OrderOptionType.createDate, asc: f.order == BackupOrder.oldest)],
      createTimeCond: DateTimeCond(
        min: DateTime.fromMillisecondsSinceEpoch(f.fromMs ?? 0),
        max: f.toMs == null ? DateTime.now().add(const Duration(days: 1)) : DateTime.fromMillisecondsSinceEpoch(f.toMs!),
        ignore: f.fromMs == null && f.toMs == null,
      ),
    );
    final paths = await PhotoManager.getAssetPathList(
      type: type,
      hasAll: f.albumIds.isEmpty,
      onlyAll: f.albumIds.isEmpty,
      filterOption: filter,
    );
    final sources = f.albumIds.isEmpty ? paths.take(1) : paths.where((p) => f.albumIds.contains(p.id));

    final seenIds = <String>{};
    final picked = <AssetEntity>[];
    var seen = 0;
    // "Latest N" without size ordering: stop reading once we have N.
    final earlyStop = f.maxCount != null && f.order != BackupOrder.largest && f.albumIds.length <= 1;
    outer:
    for (final path in sources) {
      final count = await path.assetCountAsync;
      for (var start = 0; start < count; start += 500) {
        final page = await path.getAssetListRange(start: start, end: (start + 500).clamp(0, count));
        for (final a in page) {
          seen++;
          if (!seenIds.add(a.id) || sent.contains(a.id)) continue;
          if (f.liveOnly && !a.isLivePhoto) continue;
          if (f.skipScreenshots && a.type == AssetType.image && isScreenshot(a)) continue;
          if (f.favoritesOnly && !a.isFavorite) continue;
          picked.add(a);
        }
        onProgress?.call(seen);
        if (earlyStop && picked.length >= f.maxCount! * 2 && !f.localOnly && !f.needsSizes) break outer;
      }
    }

    // iPhone originals that are only in iCloud.
    if (f.localOnly && Platform.isIOS) {
      final keep = <AssetEntity>[];
      for (final a in picked) {
        try {
          if (await a.isLocallyAvailable(isOrigin: true)) keep.add(a);
        } catch (_) {}
      }
      picked
        ..clear()
        ..addAll(keep);
    }

    // Several albums: merge into one date order.
    if (f.albumIds.length > 1 && f.order != BackupOrder.largest) {
      picked.sort((a, b) => f.order == BackupOrder.oldest
          ? a.createDateTime.compareTo(b.createDateTime)
          : b.createDateTime.compareTo(a.createDateTime));
    }

    // Sizes: for the preview, the size filters, "largest first" and the
    // "stop after X" cut.
    final sizes = <String, int>{};
    for (var i = 0; i < picked.length; i += 2000) {
      sizes.addAll(await BackgroundTransfer.originalSizes([
        for (final a in picked.sublist(i, (i + 2000).clamp(0, picked.length))) a.id,
      ]));
    }
    final sizesKnown = sizes.length >= picked.length * 0.9;
    int sizeOf(AssetEntity a) => sizes[a.id] ?? 0;

    var list = picked;
    if (f.minFileMb != null) list = [for (final a in list) if (sizeOf(a) >= f.minFileMb! * _mb) a];
    if (f.maxFileMb != null) list = [for (final a in list) if (sizes[a.id] == null || sizeOf(a) <= f.maxFileMb! * _mb) a];
    if (f.order == BackupOrder.largest) list.sort((a, b) => sizeOf(b).compareTo(sizeOf(a)));
    if (f.maxCount != null && list.length > f.maxCount!) list = list.sublist(0, f.maxCount);
    if (f.stopAfterMb != null && sizesKnown) {
      final limit = f.stopAfterMb! * _mb;
      var sum = 0;
      final cut = <AssetEntity>[];
      for (final a in list) {
        if (sum >= limit) break;
        cut.add(a);
        sum += sizeOf(a);
      }
      list = cut;
    }
    final total = list.fold<int>(0, (s, a) => s + sizeOf(a));
    return BackupPlan(list, total, sizesKnown: sizesKnown);
  }
}
