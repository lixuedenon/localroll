// apps/desktop/lib/server/transfer_server.dart
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:localroll_core/localroll_core.dart';

import '../services/library_index.dart';
import '../services/receive_hub.dart';
import '../services/settings.dart';

class _UploadSession {
  _UploadSession(this.id, this.device, this.offers);

  final String id;
  final TrustedDevice device;
  final Map<String, FileOffer> offers;
  DateTime lastSeen = DateTime.now();
}

/// HTTP receiver phones upload to. Plain dart:io so request bodies stream
/// straight to disk — a 10 GB video never sits in memory.
///
/// Flow (see docs/ARCHITECTURE.md):
///   GET  /api/v1/info                                  no auth
///   POST /api/v1/pair            {device, pin}         -> {token}
///   POST /api/v1/sessions        {files:[FileOffer]}   -> per file: duplicate | ready@offset
///   GET  /api/v1/sessions/S/files/F                    -> {offset}
///   PUT  /api/v1/sessions/S/files/F?offset=N  <bytes>  -> {offset}
///   POST /api/v1/sessions/S/files/F/complete {size, sha256} -> saved
class TransferServer extends ChangeNotifier {
  TransferServer({required this.settings, required this.library, required this.hub});

  final AppSettings settings;
  final LibraryIndex library;
  final ReceiveHub hub;

  HttpServer? _server;
  String? error;
  final Map<String, _UploadSession> _sessions = {};

  /// PIN currently shown on screen; changes after every successful pairing.
  final ValueNotifier<String> pin = ValueNotifier(randomPin());
  int _failedPinAttempts = 0;

  bool get running => _server != null;
  int get port => _server?.port ?? settings.port;

  /// Ports tried in order. Windows reserves whole blocks of ports for
  /// Hyper-V / WSL / Docker ("excluded port ranges", usually inside
  /// 49152–65535), so fall back to ports outside that range and finally to
  /// any free port. Phones learn the actual port from the QR code / mDNS.
  List<int> get _candidatePorts => {
        settings.port,
        LrProtocol.defaultPort,
        41530,
        31530,
        21530,
        8530,
        0, // let the OS pick
      }.toList();

  Future<void> start() async {
    await stop();
    final failures = <String>[];
    for (final p in _candidatePorts) {
      try {
        final server = await HttpServer.bind(InternetAddress.anyIPv4, p);
        server.idleTimeout = const Duration(minutes: 2);
        server.listen(_handle, onError: (Object e) => debugPrint('server error: $e'));
        _server = server;
        error = null;
        if (server.port != settings.port) {
          // Remember the working port so it stays stable across restarts.
          await settings.update((s) => s.port = server.port);
        }
        break;
      } on SocketException catch (e) {
        final code = e.osError?.errorCode;
        failures.add('$p${code != null ? ' (错误 $code)' : ''}');
      }
    }
    if (_server == null) {
      error = '没有可用的端口（已尝试 ${failures.join('、')}）。'
          '请检查是否有安全软件阻止 LocalRoll 联网。';
    }
    notifyListeners();
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
  }

  void rotatePin() {
    pin.value = randomPin();
    _failedPinAttempts = 0;
  }

  @override
  void dispose() {
    stop();
    pin.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------- routing

  Future<void> _handle(HttpRequest req) async {
    final res = req.response;
    try {
      final path = req.uri.path;
      final segs = req.uri.pathSegments;

      if (req.method == 'GET' && path == LrProtocol.pathInfo) {
        return _json(res, 200, settings.deviceInfo.toJson());
      }
      if (req.method == 'POST' && path == LrProtocol.pathPair) {
        return await _pair(req);
      }

      final device = _authenticate(req);
      if (device == null) {
        await req.drain<void>();
        return _json(res, 401, {'error': 'not paired'});
      }

      if (req.method == 'POST' && path == LrProtocol.pathSessions) {
        return await _createSession(req, device);
      }

      // /api/v1/sessions/{sid}/files/{fid}[/complete]
      if (segs.length >= 6 &&
          segs[0] == 'api' &&
          segs[1] == 'v1' &&
          segs[2] == 'sessions' &&
          segs[4] == 'files') {
        final session = _sessions[segs[3]];
        final offer = session?.offers[segs[5]];
        if (session == null || offer == null || session.device.id != device.id) {
          await req.drain<void>();
          return _json(res, 404, {'error': 'unknown session or file'});
        }
        session.lastSeen = DateTime.now();
        if (segs.length == 6 && req.method == 'GET') return await _status(req, device, offer);
        if (segs.length == 6 && req.method == 'PUT') return await _chunk(req, device, offer);
        if (segs.length == 7 && segs[6] == 'complete' && req.method == 'POST') {
          return await _complete(req, device, offer);
        }
      }

      await req.drain<void>();
      return _json(res, 404, {'error': 'not found'});
    } catch (e, st) {
      debugPrint('request failed: $e\n$st');
      try {
        await _json(res, 500, {'error': e.toString()});
      } catch (_) {
        // Response already started or socket gone.
      }
    }
  }

  TrustedDevice? _authenticate(HttpRequest req) {
    final id = req.headers.value(LrProtocol.headerDeviceId);
    final token = req.headers.value(LrProtocol.headerToken);
    if (id == null || token == null) return null;
    final d = settings.trusted[id];
    return (d != null && d.token == token) ? d : null;
  }

  // --------------------------------------------------------------- handlers

  Future<void> _pair(HttpRequest req) async {
    final body = PairRequest.fromJson(await _readJson(req));
    if (_failedPinAttempts >= 5) {
      // Too many wrong guesses: invalidate the PIN on screen.
      rotatePin();
      return _json(req.response, 429, {'error': '尝试次数过多，请使用电脑上新显示的配对码'});
    }
    if (body.pin.trim() != pin.value) {
      _failedPinAttempts++;
      return _json(req.response, 403, {'error': '配对码不正确'});
    }
    final token = randomId(40);
    await settings.update((s) {
      s.trusted[body.device.id] = TrustedDevice(
        id: body.device.id,
        name: body.device.name,
        platform: body.device.platform,
        token: token,
        pairedMs: DateTime.now().millisecondsSinceEpoch,
      );
    });
    rotatePin();
    return _json(
      req.response,
      200,
      PairResponse(token: token, desktop: settings.deviceInfo).toJson(),
    );
  }

  Future<void> _createSession(HttpRequest req, TrustedDevice device) async {
    final body = SessionRequest.fromJson(await _readJson(req));
    _sessions.removeWhere(
      (_, s) => DateTime.now().difference(s.lastSeen) > const Duration(hours: 6),
    );

    final sessionId = randomId(20);
    final offers = {for (final f in body.files) f.id: f};
    _sessions[sessionId] = _UploadSession(sessionId, device, offers);

    final results = <String, OfferResult>{};
    for (final f in body.files) {
      final existing = library.findByAsset(device.id, f.assetId);
      if (existing != null && File(library.absPath(existing)).existsSync()) {
        results[f.id] = const OfferResult(status: OfferStatus.duplicate);
        continue;
      }
      final part = File(_partPath(device, f));
      final offset = await part.exists() ? await part.length() : 0;
      results[f.id] = OfferResult(status: OfferStatus.ready, offset: offset);
    }
    return _json(req.response, 200, SessionResponse(sessionId: sessionId, results: results).toJson());
  }

  Future<void> _status(HttpRequest req, TrustedDevice device, FileOffer offer) async {
    final part = File(_partPath(device, offer));
    final offset = await part.exists() ? await part.length() : 0;
    return _json(req.response, 200, {'offset': offset});
  }

  Future<void> _chunk(HttpRequest req, TrustedDevice device, FileOffer offer) async {
    final part = File(_partPath(device, offer));
    final current = await part.exists() ? await part.length() : 0;
    final offset = int.tryParse(req.uri.queryParameters['offset'] ?? '') ?? -1;
    if (offset != current) {
      await req.drain<void>();
      return _json(req.response, 409, {'offset': current});
    }
    final total = int.tryParse(req.uri.queryParameters['total'] ?? '') ?? (offer.size ?? 0);
    final t = hub.track(_hubKey(device, offer), device.name, offer.name, total);

    var received = current;
    final sink = part.openWrite(mode: FileMode.append);
    try {
      await for (final data in req) {
        sink.add(data);
        received += data.length;
        hub.progress(t, received);
      }
      await sink.flush();
    } finally {
      await sink.close();
    }
    return _json(req.response, 200, {'offset': received});
  }

  Future<void> _complete(HttpRequest req, TrustedDevice device, FileOffer offer) async {
    final body = CompleteRequest.fromJson(await _readJson(req));
    final part = File(_partPath(device, offer));

    if (!await part.exists()) {
      // Retry of a request that already succeeded (response was lost).
      final existing = library.findByAsset(device.id, offer.assetId);
      if (existing != null) {
        return _json(req.response, 200, CompleteResponse(saved: true, path: existing.relPath).toJson());
      }
      return _json(req.response, 404, const CompleteResponse(saved: false, error: 'no data received').toJson());
    }

    final t = hub.track(_hubKey(device, offer), device.name, offer.name, body.size);
    final length = await part.length();
    if (length != body.size) {
      return _json(req.response, 409, {'offset': length, 'error': 'size mismatch'});
    }

    hub.setState(t, TransferState.verifying);
    final hash = await sha256OfFile(part);
    if (hash != body.sha256.toLowerCase()) {
      await part.delete();
      hub.setState(t, TransferState.failed, error: '校验失败，请重新发送');
      return _json(req.response, 422, const CompleteResponse(saved: false, error: 'sha256 mismatch').toJson());
    }

    final captured = DateTime.fromMillisecondsSinceEpoch(offer.createdMs);
    final sep = Platform.pathSeparator;
    final folder = '${library.rootPath}$sep${captured.year}$sep${captured.month.toString().padLeft(2, '0')}';
    await Directory(folder).create(recursive: true);
    final dest = LibraryIndex.uniquePath(folder, sanitizeFileName(offer.name));
    await part.rename(dest);
    try {
      // Explorer and Windows Photos sort by this; make it the capture time.
      await File(dest).setLastModified(captured);
    } catch (_) {}

    final rel = dest.substring(library.rootPath.length + 1).replaceAll(sep, '/');
    library.add(MediaItem(
      relPath: rel,
      name: offer.name,
      size: length,
      kind: offer.kind == MediaKind.other ? MediaKind.fromName(offer.name) : offer.kind,
      captureMs: offer.createdMs,
      receivedMs: DateTime.now().millisecondsSinceEpoch,
      sha256: hash,
      deviceId: device.id,
      deviceName: device.name,
      assetId: offer.assetId,
    ));
    hub.progress(t, length);
    hub.setState(t, TransferState.saved);
    return _json(req.response, 200, CompleteResponse(saved: true, path: rel).toJson());
  }

  // ---------------------------------------------------------------- helpers

  /// Partial uploads are keyed by device + asset + edit time, so an
  /// interrupted transfer resumes even from a brand-new session.
  String _partPath(TrustedDevice device, FileOffer offer) =>
      '${library.incomingDir}${Platform.pathSeparator}'
      '${shortKey('${device.id}|${offer.assetId}|${offer.modifiedMs}')}.part';

  String _hubKey(TrustedDevice device, FileOffer offer) => '${device.id}|${offer.assetId}';

  Future<Map<String, dynamic>> _readJson(HttpRequest req) async {
    final text = await utf8.decoder.bind(req).join();
    return jsonDecode(text) as Map<String, dynamic>;
  }

  Future<void> _json(HttpResponse res, int status, Object body) async {
    res.statusCode = status;
    res.headers.contentType = ContentType.json;
    res.write(jsonEncode(body));
    await res.close();
  }
}
