// packages/core/lib/src/protocol.dart

/// Constants of the LocalRoll LAN transfer protocol (HTTP/1.1, JSON + raw bytes).
///
/// See docs/ARCHITECTURE.md for the full request flow.
class LrProtocol {
  LrProtocol._();

  /// Bumped on breaking protocol changes.
  static const int version = 1;

  /// Default TCP port of the desktop receiver. Deliberately different from
  /// LocalSend (53317) so both apps can run side by side.
  static const int defaultPort = 53530;

  /// DNS-SD / Bonjour service type advertised by the desktop app.
  static const String serviceType = '_localroll._tcp';

  /// Size of one upload chunk. Each chunk is one HTTP PUT, so a dropped
  /// connection loses at most this much work.
  static const int chunkSize = 8 * 1024 * 1024;

  static const String pathInfo = '/api/v1/info';
  static const String pathPair = '/api/v1/pair';
  static const String pathSessions = '/api/v1/sessions';

  /// Tap-to-pair: POST starts a request, GET /{id} polls it until the user
  /// clicks Allow / Deny on the PC.
  static const String pathPairRequest = '/api/v1/pair-request';

  /// What changed on the PC since `?since=<ms>` for the asking phone (files
  /// deleted there), so the phone can warn that they are no longer backed up.
  static const String pathChanges = '/api/v1/changes';

  /// The PC's custom picture (PNG), if it has one. No auth (like /info).
  static const String pathAvatar = '/api/v1/avatar';

  /// How long a tap-to-pair request waits for a click on the PC.
  static const Duration pairApprovalTimeout = Duration(minutes: 2);

  /// Safe cleanup: the PC re-reads and re-hashes the files it holds for the
  /// given assets so the phone only deletes what is provably on the PC.
  static const String pathVerify = '/api/v1/verify';

  /// POST {assetIds, private}: family visibility of items this phone sent.
  static const String pathVisibility = '/api/v1/visibility';

  /// Assets per verify request (each one is re-hashed on the PC).
  static const int verifyBatch = 100;

  /// Live Photo: the paired video (the MOV) is sent as a file of its own
  /// whose assetId is the photo's assetId plus this suffix. The PC stores it
  /// next to the photo and plays it from the photo's viewer.
  static const String liveSuffix = '#live';

  /// `/api/v1/sessions/{sessionId}/files/{fileId}` — GET status, PUT chunk.
  static String filePath(String sessionId, String fileId) =>
      '$pathSessions/${Uri.encodeComponent(sessionId)}/files/${Uri.encodeComponent(fileId)}';

  /// `/api/v1/sessions/{sessionId}/files/{fileId}/complete` — POST.
  static String completePath(String sessionId, String fileId) =>
      '${filePath(sessionId, fileId)}/complete';

  /// Request headers used for authentication after pairing.
  static const String headerDeviceId = 'x-lr-device';
  static const String headerToken = 'x-lr-token';
}

/// Asset id of the video half of a Live Photo.
String liveCompanionId(String photoAssetId) => '$photoAssetId${LrProtocol.liveSuffix}';

/// True for the video half of a Live Photo.
bool isLiveCompanion(String assetId) => assetId.endsWith(LrProtocol.liveSuffix);

/// The photo's asset id for a Live Photo video (or [assetId] itself).
String livePhotoIdOf(String assetId) => isLiveCompanion(assetId)
    ? assetId.substring(0, assetId.length - LrProtocol.liveSuffix.length)
    : assetId;
