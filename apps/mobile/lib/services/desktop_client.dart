// apps/mobile/lib/services/desktop_client.dart
import 'dart:convert';
import 'dart:io';

import 'package:localroll_core/localroll_core.dart';

import '../l10n/l10n.dart';

class LrHttpException implements Exception {
  LrHttpException(this.status, this.body);

  final int status;
  final Map<String, dynamic> body;

  /// Localized text for the server's error code ('wrong_pin', …).
  String get message => serverErrorText(body['error'] as String? ?? 'HTTP $status');

  @override
  String toString() => message;
}

/// Thin HTTP client for the desktop receiver (plain dart:io, no extra deps).
class DesktopClient {
  DesktopClient({required this.host, required this.port, this.deviceId, this.token});

  final String host;
  final int port;
  final String? deviceId;
  final String? token;

  final HttpClient _http = HttpClient()
    ..connectionTimeout = const Duration(seconds: 4)
    ..idleTimeout = const Duration(seconds: 30);

  void close() => _http.close(force: true);

  Future<Map<String, dynamic>> _send(
    String method,
    String path, {
    Object? json,
    List<int>? bytes,
    Map<String, String>? query,
    Duration timeout = const Duration(seconds: 20),
  }) async {
    var uri = Uri.parse('http://$host:$port$path');
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
    final body = text.isEmpty ? <String, dynamic>{} : jsonDecode(text) as Map<String, dynamic>;
    if (res.statusCode >= 400) throw LrHttpException(res.statusCode, body);
    return body;
  }

  Future<DeviceInfo> info({Duration timeout = const Duration(seconds: 3)}) async =>
      DeviceInfo.fromJson(await _send('GET', LrProtocol.pathInfo, timeout: timeout));

  Future<PairResponse> pair(DeviceInfo me, String pin) async =>
      PairResponse.fromJson(await _send('POST', LrProtocol.pathPair,
          json: PairRequest(device: me, pin: pin).toJson()));

  Future<SessionResponse> createSession(SessionRequest request) async =>
      SessionResponse.fromJson(await _send('POST', LrProtocol.pathSessions, json: request.toJson()));

  Future<int> status(String sessionId, String fileId) async {
    final j = await _send('GET', LrProtocol.filePath(sessionId, fileId));
    return (j['offset'] as num).toInt();
  }

  /// Uploads one chunk; returns the server's new offset.
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

  /// Safe cleanup: the PC re-hashes each file it holds for these assets.
  Future<VerifyResponse> verify(List<String> assetIds) async => VerifyResponse.fromJson(await _send(
        'POST',
        LrProtocol.pathVerify,
        json: VerifyRequest(assetIds: assetIds).toJson(),
        timeout: const Duration(minutes: 5),
      ));

  /// The desktop re-hashes the whole file here, so allow time for big videos.
  Future<CompleteResponse> complete(String sessionId, String fileId, CompleteRequest request) async =>
      CompleteResponse.fromJson(await _send(
        'POST',
        LrProtocol.completePath(sessionId, fileId),
        json: request.toJson(),
        timeout: const Duration(minutes: 5),
      ));
}

/// The PC answers with stable error codes; show them in the phone's language.
String serverErrorText(String code) => translator.has('err.$code') ? tr('err.$code') : code;
