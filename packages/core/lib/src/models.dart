// packages/core/lib/src/models.dart
import 'media_kind.dart';

/// Identity of an app instance (desktop or phone).
class DeviceInfo {
  const DeviceInfo({
    required this.id,
    required this.name,
    required this.platform,
    this.appVersion = '0.1.0',
    this.protocolVersion = 1,
    this.icon,
    this.color,
    this.avatar = 0,
  });

  final String id;
  final String name;

  /// 'windows', 'ios', 'android', ...
  final String platform;
  final String appVersion;
  final int protocolVersion;

  /// Look of the device: a key from [DeviceLook.icons], an ARGB colour, and a
  /// custom picture version (0 = none; otherwise GET /api/v1/avatar?v=N).
  final String? icon;
  final int? color;
  final int avatar;

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'platform': platform,
        'appVersion': appVersion,
        'protocolVersion': protocolVersion,
        if (icon != null) 'icon': icon,
        if (color != null) 'color': color,
        if (avatar != 0) 'avatar': avatar,
      };

  factory DeviceInfo.fromJson(Map<String, dynamic> j) => DeviceInfo(
        id: j['id'] as String,
        name: j['name'] as String? ?? 'Unknown',
        platform: j['platform'] as String? ?? 'unknown',
        appVersion: j['appVersion'] as String? ?? '',
        protocolVersion: (j['protocolVersion'] as num?)?.toInt() ?? 1,
        icon: j['icon'] as String?,
        color: (j['color'] as num?)?.toInt(),
        avatar: (j['avatar'] as num?)?.toInt() ?? 0,
      );
}

/// Phone -> desktop: "I want to pair, here is the PIN shown on your screen".
class PairRequest {
  const PairRequest({required this.device, required this.pin});

  final DeviceInfo device;
  final String pin;

  Map<String, dynamic> toJson() => {'device': device.toJson(), 'pin': pin};

  factory PairRequest.fromJson(Map<String, dynamic> j) => PairRequest(
        device: DeviceInfo.fromJson(j['device'] as Map<String, dynamic>),
        pin: j['pin'] as String? ?? '',
      );
}

/// Desktop -> phone: long-lived token for this phone.
class PairResponse {
  const PairResponse({required this.token, required this.desktop});

  final String token;
  final DeviceInfo desktop;

  Map<String, dynamic> toJson() => {'token': token, 'desktop': desktop.toJson()};

  factory PairResponse.fromJson(Map<String, dynamic> j) => PairResponse(
        token: j['token'] as String,
        desktop: DeviceInfo.fromJson(j['desktop'] as Map<String, dynamic>),
      );
}

/// One file the phone offers to send. Sent before any bytes so the desktop
/// can say "already have it" (dedupe) or "resume from offset N".
class FileOffer {
  const FileOffer({
    required this.id,
    required this.assetId,
    required this.name,
    required this.kind,
    required this.createdMs,
    required this.modifiedMs,
    this.size,
  });

  /// Unique within the session (client generated).
  final String id;

  /// Stable id of the asset in the phone's photo library
  /// (PHAsset.localIdentifier on iOS, MediaStore id on Android).
  final String assetId;

  /// Original file name, e.g. IMG_1234.HEIC.
  final String name;
  final MediaKind kind;

  /// Capture time (ms since epoch, UTC).
  final int createdMs;

  /// Last edit time; part of the resume key so an edited photo is re-sent.
  final int modifiedMs;

  /// Byte size if already known.
  final int? size;

  Map<String, dynamic> toJson() => {
        'id': id,
        'assetId': assetId,
        'name': name,
        'kind': kind.name,
        'createdMs': createdMs,
        'modifiedMs': modifiedMs,
        if (size != null) 'size': size,
      };

  factory FileOffer.fromJson(Map<String, dynamic> j) => FileOffer(
        id: j['id'] as String,
        assetId: j['assetId'] as String,
        name: j['name'] as String,
        kind: MediaKind.parse(j['kind'] as String?),
        createdMs: (j['createdMs'] as num).toInt(),
        modifiedMs: (j['modifiedMs'] as num?)?.toInt() ?? 0,
        size: (j['size'] as num?)?.toInt(),
      );
}

enum OfferStatus {
  /// Desktop wants the file; upload starting at [OfferResult.offset].
  ready,

  /// Desktop already has this asset; skip it.
  duplicate;

  static OfferStatus parse(String? v) =>
      OfferStatus.values.firstWhere((s) => s.name == v, orElse: () => OfferStatus.ready);
}

class OfferResult {
  const OfferResult({required this.status, this.offset = 0});

  final OfferStatus status;
  final int offset;

  Map<String, dynamic> toJson() => {'status': status.name, 'offset': offset};

  factory OfferResult.fromJson(Map<String, dynamic> j) => OfferResult(
        status: OfferStatus.parse(j['status'] as String?),
        offset: (j['offset'] as num?)?.toInt() ?? 0,
      );
}

class SessionRequest {
  const SessionRequest({required this.files});

  final List<FileOffer> files;

  Map<String, dynamic> toJson() => {'files': files.map((f) => f.toJson()).toList()};

  factory SessionRequest.fromJson(Map<String, dynamic> j) => SessionRequest(
        files: (j['files'] as List)
            .map((e) => FileOffer.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
}

class SessionResponse {
  const SessionResponse({required this.sessionId, required this.results});

  final String sessionId;

  /// fileId -> result
  final Map<String, OfferResult> results;

  Map<String, dynamic> toJson() => {
        'sessionId': sessionId,
        'results': results.map((k, v) => MapEntry(k, v.toJson())),
      };

  factory SessionResponse.fromJson(Map<String, dynamic> j) => SessionResponse(
        sessionId: j['sessionId'] as String,
        results: (j['results'] as Map<String, dynamic>).map(
          (k, v) => MapEntry(k, OfferResult.fromJson(v as Map<String, dynamic>)),
        ),
      );
}

/// Phone -> desktop after the last chunk.
class CompleteRequest {
  const CompleteRequest({required this.size, required this.sha256});

  final int size;

  /// Lower-case hex SHA-256 of the whole file.
  final String sha256;

  Map<String, dynamic> toJson() => {'size': size, 'sha256': sha256};

  factory CompleteRequest.fromJson(Map<String, dynamic> j) => CompleteRequest(
        size: (j['size'] as num).toInt(),
        sha256: j['sha256'] as String,
      );
}

class CompleteResponse {
  const CompleteResponse({required this.saved, this.path, this.error});

  final bool saved;

  /// Path relative to the desktop library root.
  final String? path;
  final String? error;

  Map<String, dynamic> toJson() => {
        'saved': saved,
        if (path != null) 'path': path,
        if (error != null) 'error': error,
      };

  factory CompleteResponse.fromJson(Map<String, dynamic> j) => CompleteResponse(
        saved: j['saved'] as bool? ?? false,
        path: j['path'] as String?,
        error: j['error'] as String?,
      );
}

/// Phone → PC: "do you really have these?" (safe cleanup).
class VerifyRequest {
  const VerifyRequest({required this.assetIds});

  final List<String> assetIds;

  Map<String, dynamic> toJson() => {'assetIds': assetIds};

  factory VerifyRequest.fromJson(Map<String, dynamic> j) =>
      VerifyRequest(assetIds: (j['assetIds'] as List? ?? const []).cast<String>());
}

/// One asset's result. [ok] means: the file exists on the PC, has the size
/// it was received with, and its SHA-256 still matches the hash checked at
/// upload time.
class VerifiedAsset {
  const VerifiedAsset({required this.assetId, required this.ok, this.size = 0, this.reason});

  final String assetId;
  final bool ok;
  final int size;

  /// Why not ok: 'missing' | 'changed' | 'unverified'.
  final String? reason;

  Map<String, dynamic> toJson() => {
        'assetId': assetId,
        'ok': ok,
        'size': size,
        if (reason != null) 'reason': reason,
      };

  factory VerifiedAsset.fromJson(Map<String, dynamic> j) => VerifiedAsset(
        assetId: j['assetId'] as String,
        ok: j['ok'] as bool? ?? false,
        size: (j['size'] as num?)?.toInt() ?? 0,
        reason: j['reason'] as String?,
      );
}

class VerifyResponse {
  const VerifyResponse({required this.items});

  final List<VerifiedAsset> items;

  Map<String, dynamic> toJson() => {'items': items.map((e) => e.toJson()).toList()};

  factory VerifyResponse.fromJson(Map<String, dynamic> j) => VerifyResponse(
        items: (j['items'] as List? ?? const [])
            .map((e) => VerifiedAsset.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
}

/// Phone → PC: "may I pair?" — approved by a click on the PC instead of a PIN.
class PairApprovalRequest {
  const PairApprovalRequest({required this.device});

  final DeviceInfo device;

  Map<String, dynamic> toJson() => {'device': device.toJson()};

  factory PairApprovalRequest.fromJson(Map<String, dynamic> j) =>
      PairApprovalRequest(device: DeviceInfo.fromJson(j['device'] as Map<String, dynamic>));
}

enum PairApprovalStatus { pending, approved, denied, expired }

/// PC → phone. [requestId] is secret to the asking phone; both screens show
/// [pairingEmoji] of it so the user can see they approve the right phone.
class PairApprovalState {
  const PairApprovalState({required this.requestId, required this.status, this.token, this.desktop});

  final String requestId;
  final PairApprovalStatus status;
  final String? token;
  final DeviceInfo? desktop;

  Map<String, dynamic> toJson() => {
        'requestId': requestId,
        'status': status.name,
        if (token != null) 'token': token,
        if (desktop != null) 'desktop': desktop!.toJson(),
      };

  factory PairApprovalState.fromJson(Map<String, dynamic> j) => PairApprovalState(
        requestId: j['requestId'] as String,
        status: PairApprovalStatus.values.firstWhere(
          (s) => s.name == j['status'],
          orElse: () => PairApprovalStatus.expired,
        ),
        token: j['token'] as String?,
        desktop: j['desktop'] == null ? null : DeviceInfo.fromJson(j['desktop'] as Map<String, dynamic>),
      );
}

/// PC → phone: assets of this phone that were deleted on the PC since `since`.
class ChangesResponse {
  const ChangesResponse({required this.deleted, required this.now});

  final List<String> deleted;

  /// Pass back as `since` next time.
  final int now;

  Map<String, dynamic> toJson() => {'deleted': deleted, 'now': now};

  factory ChangesResponse.fromJson(Map<String, dynamic> j) => ChangesResponse(
        deleted: (j['deleted'] as List? ?? const []).cast<String>(),
        now: (j['now'] as num?)?.toInt() ?? 0,
      );
}
