// packages/core/lib/src/models.dart
import 'media_kind.dart';
import 'protocol.dart';

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
    this.owner,
    this.tlsPort,
    this.fingerprint,
  });

  final String id;
  final String name;

  /// PC only: HTTPS port and certificate fingerprint. Learned over plain
  /// HTTP, so only trusted when confirmed (QR code, symbols, or an earlier
  /// pairing) — see tls.dart.
  final int? tlsPort;
  final String? fingerprint;

  /// Family group: the person this phone belongs to ("Mum"), as typed on the
  /// phone. Phones with the same owner are one family member on the PC.
  final String? owner;

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
        if (owner != null && owner!.isNotEmpty) 'owner': owner,
        if (tlsPort != null) 'tlsPort': tlsPort,
        if (fingerprint != null) 'fingerprint': fingerprint,
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
        owner: j['owner'] as String?,
        tlsPort: (j['tlsPort'] as num?)?.toInt(),
        fingerprint: j['fingerprint'] as String?,
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
    this.sizeHint,
    this.private = false,
    this.target,
    this.relPath,
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

  /// Byte size if already known (exact: the receiver refuses more).
  final int? size;

  /// Expected size when the exact one is not known yet (a phone's photo
  /// before its original is exported). Only used to check for room up
  /// front; never as a limit.
  final int? sizeHint;

  /// Family group: "only me" — not shown to other family members.
  final bool private;

  /// Where the receiver keeps it: null = the photo library (by capture
  /// date); [LrProtocol.targetFiles] = an ordinary file, saved under the
  /// "Received files" folder at [relPath] (PC → PC).
  final String? target;

  /// For [LrProtocol.targetFiles]: path inside the sent selection with '/'
  /// separators ("Trip/day 1/notes.pdf"), so folders arrive as folders.
  final String? relPath;

  bool get isPlainFile => target == LrProtocol.targetFiles;

  Map<String, dynamic> toJson() => {
        'id': id,
        'assetId': assetId,
        'name': name,
        'kind': kind.name,
        'createdMs': createdMs,
        'modifiedMs': modifiedMs,
        if (size != null) 'size': size,
        if (sizeHint != null) 'sizeHint': sizeHint,
        if (private) 'private': true,
        if (target != null) 'target': target,
        if (relPath != null) 'relPath': relPath,
      };

  factory FileOffer.fromJson(Map<String, dynamic> j) => FileOffer(
        id: j['id'] as String,
        assetId: j['assetId'] as String,
        name: j['name'] as String,
        kind: MediaKind.parse(j['kind'] as String?),
        createdMs: (j['createdMs'] as num).toInt(),
        modifiedMs: (j['modifiedMs'] as num?)?.toInt() ?? 0,
        size: (j['size'] as num?)?.toInt(),
        sizeHint: (j['sizeHint'] as num?)?.toInt(),
        private: j['private'] == true,
        target: j['target'] as String?,
        relPath: j['relPath'] as String?,
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
  const SessionRequest({required this.files, this.owner, this.from, this.batch});

  final List<FileOffer> files;

  /// The phone's current owner name (family group); the PC keeps it in sync.
  final String? owner;

  /// Sending to a device we are not paired with (phone ↔ phone): who we
  /// are, for its "X wants to send you …" question.
  final DeviceInfo? from;

  /// How many items this whole transfer has (each file is its own session).
  final int? batch;

  Map<String, dynamic> toJson() => {
        'files': files.map((f) => f.toJson()).toList(),
        if (owner != null) 'owner': owner,
        if (from != null) 'from': from!.toJson(),
        if (batch != null) 'batch': batch,
      };

  factory SessionRequest.fromJson(Map<String, dynamic> j) => SessionRequest(
        files: (j['files'] as List)
            .map((e) => FileOffer.fromJson(e as Map<String, dynamic>))
            .toList(),
        owner: j['owner'] as String?,
        from: j['from'] is Map<String, dynamic> ? DeviceInfo.fromJson(j['from'] as Map<String, dynamic>) : null,
        batch: (j['batch'] as num?)?.toInt(),
      );
}

/// Phone -> PC: change who may see items this phone sent ("only me" or
/// the whole family). Live Photo videos follow their photo.
class VisibilityRequest {
  const VisibilityRequest({required this.assetIds, required this.private});

  final List<String> assetIds;
  final bool private;

  Map<String, dynamic> toJson() => {'assetIds': assetIds, 'private': private};

  factory VisibilityRequest.fromJson(Map<String, dynamic> j) => VisibilityRequest(
        assetIds: (j['assetIds'] as List).cast<String>(),
        private: j['private'] == true,
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

/// PC → PC pairing: the asking PC also lets the other one send back.
/// [token] is what the other PC will use to send to the asking PC;
/// [hosts]/[port] are where the asking PC listens.
class PeerGrant {
  const PeerGrant({required this.token, required this.hosts, required this.port, this.tlsPort, this.fingerprint});

  final String token;
  final List<String> hosts;
  final int port;

  /// The asking PC's HTTPS port and certificate (sent over HTTPS to a PC
  /// the user just confirmed, so it can be trusted).
  final int? tlsPort;
  final String? fingerprint;

  Map<String, dynamic> toJson() => {
        'token': token,
        'hosts': hosts,
        'port': port,
        if (tlsPort != null) 'tlsPort': tlsPort,
        if (fingerprint != null) 'fingerprint': fingerprint,
      };

  factory PeerGrant.fromJson(Map<String, dynamic> j) => PeerGrant(
        token: j['token'] as String,
        hosts: (j['hosts'] as List? ?? const []).cast<String>(),
        port: (j['port'] as num?)?.toInt() ?? LrProtocol.defaultPort,
        tlsPort: (j['tlsPort'] as num?)?.toInt(),
        fingerprint: j['fingerprint'] as String?,
      );
}

/// Phone → PC: "may I pair?" — approved by a click on the PC instead of a PIN.
/// From another PC, [peer] makes the pairing two-way with the same click.
class PairApprovalRequest {
  const PairApprovalRequest({required this.device, this.peer});

  final DeviceInfo device;
  final PeerGrant? peer;

  Map<String, dynamic> toJson() => {
        'device': device.toJson(),
        if (peer != null) 'peer': peer!.toJson(),
      };

  factory PairApprovalRequest.fromJson(Map<String, dynamic> j) => PairApprovalRequest(
        device: DeviceInfo.fromJson(j['device'] as Map<String, dynamic>),
        peer: j['peer'] is Map<String, dynamic> ? PeerGrant.fromJson(j['peer'] as Map<String, dynamic>) : null,
      );
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
  const ChangesResponse({required this.deleted, required this.now, this.library});

  final List<String> deleted;

  /// Pass back as `since` next time.
  final int now;

  /// Id of the PC's library folder. A different one than last time means the
  /// library was rebuilt (lost folder made anew, another folder chosen):
  /// the phone re-checks what it thinks is backed up there.
  final String? library;

  Map<String, dynamic> toJson() => {'deleted': deleted, 'now': now, if (library != null) 'library': library};

  factory ChangesResponse.fromJson(Map<String, dynamic> j) => ChangesResponse(
        deleted: (j['deleted'] as List? ?? const []).cast<String>(),
        now: (j['now'] as num?)?.toInt() ?? 0,
        library: j['library'] as String?,
      );
}

/// A paired device another LocalRoll PC sees online (presence answer).
class OnlineDevice {
  const OnlineDevice({
    required this.id,
    required this.name,
    required this.platform,
    this.host,
    this.port,
    this.fingerprint,
  });

  final String id;
  final String name;
  final String platform;

  /// A phone with LocalRoll open: where it receives and its certificate, as
  /// the PC knows them — other phones can send to it even when the Wi-Fi
  /// search can't see it (and know it is really that phone).
  final String? host;
  final int? port;
  final String? fingerprint;

  bool get isDesktop => isDesktopPlatform(platform);

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'platform': platform,
        if (host != null) 'host': host,
        if (port != null) 'port': port,
        if (fingerprint != null) 'fp': fingerprint,
      };

  factory OnlineDevice.fromJson(Map<String, dynamic> j) => OnlineDevice(
        id: j['id'] as String? ?? '',
        name: j['name'] as String? ?? '',
        platform: j['platform'] as String? ?? '',
        host: j['host'] as String?,
        port: (j['port'] as num?)?.toInt(),
        fingerprint: j['fp'] as String?,
      );

  static List<OnlineDevice> listFrom(Map<String, dynamic> j) => [
        for (final e in (j['online'] as List? ?? const []))
          if (e is Map<String, dynamic>) OnlineDevice.fromJson(e),
      ];
}

/// What a device may do with this PC's library from afar (set on the PC).
enum LibraryAccess {
  /// Only transfers.
  none,

  /// Look, play, save to the phone.
  view,

  /// Also delete (to the PC's Recycle Bin).
  manage;

  static LibraryAccess? parse(Object? v) => switch (v) {
        'none' => none,
        'view' => view,
        'manage' => manage,
        _ => null,
      };
}

/// One library item as a phone sees it when browsing the PC.
class RemoteItem {
  const RemoteItem({
    required this.path,
    required this.name,
    required this.kind,
    required this.takenMs,
    required this.size,
    this.live,
    this.private = false,
    this.mine = false,
    this.from,
    this.receivedMs = 0,
    this.file = false,
  });

  /// Its place in the library ("2024/05/IMG_1.HEIC"): what to ask for.
  final String path;
  final String name;
  final MediaKind kind;
  final int takenMs;
  final int size;

  /// The Live Photo video that goes with it, if any (its path).
  final String? live;

  /// "Only me" (shown only to the phone that sent it).
  final bool private;

  /// Sent by the phone asking (it may change its visibility).
  final bool mine;

  /// Who it came from (family member or device name).
  final String? from;

  /// When it arrived on the PC (0: unknown, older PC).
  final int receivedMs;

  /// A received file (a document, a scan, anything that is not a library
  /// photo / video): [kind] is [MediaKind.other]; the PC has no picture of
  /// it, the phone draws its first page itself.
  final bool file;

  Map<String, dynamic> toJson() => {
        'p': path,
        'n': name,
        'k': kind.name,
        't': takenMs,
        's': size,
        if (live != null) 'l': live,
        if (private) 'x': true,
        if (mine) 'm': true,
        if (from != null) 'f': from,
        if (receivedMs > 0) 'r': receivedMs,
        if (file) 'd': true,
      };

  factory RemoteItem.fromJson(Map<String, dynamic> j) => RemoteItem(
        path: j['p'] as String,
        name: j['n'] as String? ?? '',
        kind: MediaKind.values.firstWhere((k) => k.name == j['k'], orElse: () => MediaKind.other),
        takenMs: (j['t'] as num?)?.toInt() ?? 0,
        size: (j['s'] as num?)?.toInt() ?? 0,
        live: j['l'] as String?,
        private: j['x'] == true,
        mine: j['m'] == true,
        from: j['f'] as String?,
        receivedMs: (j['r'] as num?)?.toInt() ?? 0,
        file: j['d'] == true,
      );
}

/// A page of the PC's library, newest first.
class LibraryPage {
  const LibraryPage({required this.items, required this.total, required this.access, this.next, this.library, this.recent = 0});

  /// How many of all that match arrived in the last 24 hours.
  final int recent;

  final List<RemoteItem> items;

  /// How many match in all.
  final int total;
  final LibraryAccess access;

  /// Offset of the next page; null at the end.
  final int? next;

  /// The PC library's id (changes when it is made anew).
  final String? library;

  Map<String, dynamic> toJson() => {
        'items': [for (final i in items) i.toJson()],
        'total': total,
        'access': access.name,
        if (next != null) 'next': next,
        if (library != null) 'library': library,
        if (recent > 0) 'recent': recent,
      };

  factory LibraryPage.fromJson(Map<String, dynamic> j) => LibraryPage(
        items: [
          for (final e in (j['items'] as List? ?? const []))
            if (e is Map<String, dynamic>) RemoteItem.fromJson(e),
        ],
        total: (j['total'] as num?)?.toInt() ?? 0,
        access: LibraryAccess.parse(j['access']) ?? LibraryAccess.none,
        next: (j['next'] as num?)?.toInt(),
        library: j['library'] as String?,
        recent: (j['recent'] as num?)?.toInt() ?? 0,
      );
}
