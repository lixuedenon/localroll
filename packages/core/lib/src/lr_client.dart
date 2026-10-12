// packages/core/lib/src/lr_client.dart
import 'dart:convert';
import 'dart:io';

import 'models.dart';
import 'protocol.dart';
import 'tls.dart';

/// The other side answered with an error. [code] is the stable error code
/// ('not_paired', 'library_offline', …) or 'HTTP <status>'.
class LrHttpError implements Exception {
  LrHttpError(this.status, this.body);

  final int status;
  final Map<String, dynamic> body;

  String get code => body['error'] as String? ?? 'HTTP $status';

  @override
  String toString() => code;
}

/// HTTP client for a LocalRoll receiver (plain dart:io). Used PC → PC; the
/// phone app has its own copy with translated errors.
class LrClient {
  /// Plain HTTP unless [secure]. Over HTTPS, [pin] is the only certificate
  /// accepted; without a pin (first contact while pairing) the certificate
  /// seen is reported to [onCertificate] and kept in [seenFingerprint].
  LrClient({
    required this.host,
    required this.port,
    this.deviceId,
    this.token,
    this.secure = false,
    this.pin,
    void Function(String fingerprint)? onCertificate,
  }) {
    _http = secure
        ? lrHttpClient(
            pin: pin,
            onCertificate: (fp) {
              seenFingerprint = fp;
              onCertificate?.call(fp);
            },
          )
        : (HttpClient()
          ..connectionTimeout = const Duration(seconds: 4)
          ..idleTimeout = const Duration(seconds: 30));
  }

  final String host;
  final int port;
  final String? deviceId;
  final String? token;
  final bool secure;
  final String? pin;

  /// Fingerprint of the certificate the server showed (HTTPS only).
  String? seenFingerprint;

  late final HttpClient _http;

  void close() => _http.close(force: true);

  Future<Map<String, dynamic>> _send(
    String method,
    String path, {
    Object? json,
    List<int>? bytes,
    Map<String, String>? query,
    Duration timeout = const Duration(seconds: 20),
  }) async {
    var uri = Uri(scheme: secure ? 'https' : 'http', host: host, port: port, path: path);
    if (query != null) uri = uri.replace(queryParameters: query);
    final req = await _http.openUrl(method, uri).timeout(timeout);
    if (deviceId != null) req.headers.set(LrProtocol.headerDeviceId, deviceId!);
    if (token != null) req.headers.set(LrProtocol.headerToken, token!);
    if (json != null) {
      final b = utf8.encode(jsonEncode(json));
      req.headers.contentType = ContentType.json;
      req.contentLength = b.length;
      req.add(b);
    } else if (bytes != null) {
      req.headers.contentType = ContentType.binary;
      req.contentLength = bytes.length;
      req.add(bytes);
    } else {
      req.contentLength = 0;
    }
    final res = await req.close().timeout(timeout);
    final text = await utf8.decoder.bind(res).join().timeout(timeout);
    Map<String, dynamic> body;
    try {
      body = text.isEmpty ? <String, dynamic>{} : jsonDecode(text) as Map<String, dynamic>;
    } catch (_) {
      body = {'error': 'HTTP ${res.statusCode}'};
    }
    if (res.statusCode >= 400) throw LrHttpError(res.statusCode, body);
    return body;
  }

  Future<DeviceInfo> info({Duration timeout = const Duration(seconds: 3)}) async =>
      DeviceInfo.fromJson(await _send('GET', LrProtocol.pathInfo, timeout: timeout));

  Future<void> unpair() async => _send('DELETE', LrProtocol.pathPair, timeout: const Duration(seconds: 3));

  Future<PairApprovalState> requestApproval(DeviceInfo me, {PeerGrant? peer}) async => PairApprovalState.fromJson(
      await _send('POST', LrProtocol.pathPairRequest, json: PairApprovalRequest(device: me, peer: peer).toJson()));

  Future<PairApprovalState> approvalStatus(String requestId) async {
    try {
      return PairApprovalState.fromJson(await _send(
          'GET', '${LrProtocol.pathPairRequest}/${Uri.encodeComponent(requestId)}',
          timeout: const Duration(seconds: 5)));
    } on LrHttpError catch (e) {
      if (e.status == 404) return PairApprovalState(requestId: requestId, status: PairApprovalStatus.expired);
      rethrow;
    }
  }

  /// Shows [text] in a small text window on the other side.
  Future<void> sendText(String text) async => _send('POST', LrProtocol.pathText, json: {'text': text});

  /// Cheap signed-in request: fails with 401 when the other side no longer
  /// knows us.
  Future<void> ping() async =>
      _send('GET', LrProtocol.pathChanges, query: {'since': '${DateTime.now().millisecondsSinceEpoch}'}, timeout: const Duration(seconds: 5));

  /// HTTPS only: trade a token from an old plain-HTTP pairing for a new one.
  Future<String> upgrade() async =>
      (await _send('POST', LrProtocol.pathUpgrade, json: const <String, dynamic>{}))['token'] as String;

  Future<SessionResponse> createSession(SessionRequest request) async => SessionResponse.fromJson(
      await _send('POST', LrProtocol.pathSessions, json: request.toJson(), timeout: const Duration(minutes: 1)));

  Future<int> status(String sessionId, String fileId) async {
    final j = await _send('GET', LrProtocol.filePath(sessionId, fileId));
    return (j['offset'] as num).toInt();
  }

  /// Uploads one chunk; returns the receiver's new offset.
  Future<int> putChunk(String sessionId, String fileId, int offset, int total, List<int> chunk) async {
    final j = await _send(
      'PUT',
      LrProtocol.filePath(sessionId, fileId),
      bytes: chunk,
      query: {'offset': '$offset', 'total': '$total'},
      timeout: const Duration(minutes: 2),
    );
    return (j['offset'] as num).toInt();
  }

  /// The receiver re-hashes the whole file, so allow time for big videos.
  Future<CompleteResponse> complete(String sessionId, String fileId, CompleteRequest request) async =>
      CompleteResponse.fromJson(await _send(
        'POST',
        LrProtocol.completePath(sessionId, fileId),
        json: request.toJson(),
        timeout: const Duration(minutes: 10),
      ));
}
