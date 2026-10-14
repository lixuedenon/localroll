// apps/mobile/lib/services/phone_server.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:localroll_core/localroll_core.dart';
import 'package:nsd/nsd.dart' as nsd;
import 'package:path_provider/path_provider.dart';

import 'media_saver.dart';
import 'mobile_settings.dart';
import 'tls_identity.dart';

/// What the person on this phone answered to "X wants to send you …".
class IncomingReply {
  const IncomingReply({required this.accept, this.reason});

  final bool accept;

  /// Declined with a reason the sender sees (plain text, short).
  final String? reason;
}

/// Someone nearby wants to send: the UI asks "Accept / Decline".
class IncomingAsk {
  IncomingAsk(this.from, this.count);

  final DeviceInfo from;

  /// Items in the whole transfer (when the sender says).
  final int count;
  final Completer<IncomingReply> answer = Completer<IncomingReply>();
}

/// Progress of what is arriving right now (one sender at a time is usual).
class Receiving {
  Receiving(this.from, this.total);

  final DeviceInfo from;
  int total;
  int done = 0;
  int toAlbum = 0;
  int toFiles = 0;
  String? file;
  int bytes = 0;
  int size = 0;
  DateTime last = DateTime.now();
}

class _InSession {
  _InSession(this.from, this.offers);

  final DeviceInfo from;
  final Map<String, FileOffer> offers;
}

/// Phones can receive too (every device is equal): while LocalRoll is open,
/// this phone listens on the Wi-Fi (HTTPS, its own certificate) and shows
/// up for nearby phones. Every transfer to a phone needs "Accept" here.
///
/// Same protocol as the PC (sessions, chunks, SHA-256 check, resume), so
/// any LocalRoll can send to it. Photos and videos go to the photo library
/// (album "LocalRoll"), other files to Files / Download.
class PhoneServer extends ChangeNotifier {
  PhoneServer(this.settings);

  final MobileSettings settings;
  final MediaSaver saver = MediaSaver();

  HttpServer? _http;
  nsd.Registration? _mdns;
  TlsIdentity? _tls;
  int port = 0;

  bool get running => _http != null;

  /// This phone's certificate (senders pin it).
  String? get fingerprint => _tls?.fingerprint;

  /// Open "Accept / Decline" questions (the UI shows a dialog for each).
  final ValueNotifier<List<IncomingAsk>> asks = ValueNotifier(const []);

  /// Arriving now (null when idle).
  Receiving? receiving;

  /// A transfer finished (nothing arrived for a few seconds): for "Received
  /// N items" on screen.
  final StreamController<Receiving> _finished = StreamController.broadcast();
  Stream<Receiving> get finished => _finished.stream;

  final Map<String, DateTime> _acceptedUntil = {};
  final Map<String, DateTime> _declinedUntil = {};
  final Map<String, IncomingReply> _lastDecline = {};
  final Map<String, IncomingAsk> _asking = {};
  final Map<String, _InSession> _sessions = {};
  Timer? _quiet;

  /// Somebody is sending to us now (keep listening a little after leaving).
  bool get busy => receiving != null;

  Future<void> start() async {
    if (_http != null) return;
    try {
      _tls ??= await TlsIdentity.load(await getApplicationSupportDirectory());
    } catch (e) {
      debugPrint('phone certificate unavailable: $e');
      return;
    }
    for (final p in [LrProtocol.defaultPort, ...LrProtocol.fallbackPorts, 0]) {
      try {
        final s = await HttpServer.bindSecure(InternetAddress.anyIPv4, p, _tls!.context);
        s.idleTimeout = const Duration(minutes: 2);
        s.listen(_handle, onError: (Object e) => debugPrint('phone server: $e'));
        _http = s;
        port = s.port;
        break;
      } catch (_) {}
    }
    if (_http == null) return;
    // Show up for nearby phones (PCs ignore entries marked as phones).
    try {
      _mdns = await nsd.register(nsd.Service(
        name: settings.deviceName,
        type: LrProtocol.serviceType,
        port: port,
        txt: {
          'id': Uint8List.fromList(utf8.encode(settings.deviceId)),
          LrProtocol.txtKind: Uint8List.fromList(utf8.encode(LrProtocol.kindPhone)),
          'platform': Uint8List.fromList(utf8.encode(Platform.operatingSystem)),
        },
      ));
    } catch (e) {
      debugPrint('phone mDNS failed: $e');
    }
    notifyListeners();
  }

  /// App left the screen: stop being visible (iPhone can't listen in the
  /// background anyway). Waiting questions count as "no answer".
  Future<void> stop() async {
    final r = _mdns;
    _mdns = null;
    if (r != null) {
      try {
        await nsd.unregister(r);
      } catch (_) {}
    }
    final s = _http;
    _http = null;
    await s?.close(force: true);
    for (final a in asks.value) {
      if (!a.answer.isCompleted) a.answer.complete(const IncomingReply(accept: false));
    }
    await saver.flushAll();
    notifyListeners();
  }

  void answer(IncomingAsk ask, IncomingReply reply) {
    if (!ask.answer.isCompleted) ask.answer.complete(reply);
  }

  DeviceInfo get _me => DeviceInfo(
        id: settings.deviceId,
        name: settings.deviceName,
        platform: Platform.operatingSystem,
        protocolVersion: LrProtocol.version,
        tlsPort: port,
        fingerprint: _tls?.fingerprint,
      );

  // ---------------------------------------------------------------- routes

  Future<void> _handle(HttpRequest req) async {
    final res = req.response;
    try {
      final remote = req.connectionInfo?.remoteAddress;
      if (remote == null || !isLanAddress(remote)) {
        await req.drain<void>();
        return _json(res, 403, {'error': 'not_lan'});
      }
      final path = req.uri.path;
      final segs = req.uri.pathSegments;
      if (req.method == 'GET' && path == LrProtocol.pathInfo) {
        return _json(res, 200, _me.toJson());
      }
      final sender = req.headers.value(LrProtocol.headerDeviceId);
      if (sender == null || sender.isEmpty) {
        await req.drain<void>();
        return _json(res, 401, {'error': 'not_paired'});
      }
      if (req.method == 'POST' && path == LrProtocol.pathSessions) {
        return await _createSession(req, sender);
      }
      // /api/v1/sessions/{sid}/files/{fid}[/complete]
      if (segs.length >= 6 && segs[0] == 'api' && segs[1] == 'v1' && segs[2] == 'sessions' && segs[4] == 'files') {
        final session = _sessions[segs[3]];
        final offer = session?.offers[segs[5]];
        if (session == null || offer == null || session.from.id != sender) {
          await req.drain<void>();
          return _json(res, 404, {'error': 'unknown_session'});
        }
        if (segs.length == 6 && req.method == 'GET') {
          final part = await _part(session, offer);
          return _json(res, 200, {'offset': await part.exists() ? await part.length() : 0});
        }
        if (segs.length == 6 && req.method == 'PUT') return await _chunk(req, session, offer);
        if (segs.length == 7 && segs[6] == 'complete' && req.method == 'POST') {
          return await _complete(req, session, offer);
        }
      }
      await req.drain<void>();
      return _json(res, 404, {'error': 'not_found'});
    } catch (e) {
      try {
        await _json(res, 500, {'error': '$e'});
      } catch (_) {}
    }
  }

  Future<void> _createSession(HttpRequest req, String sender) async {
    final body = SessionRequest.fromJson(await _readJson(req));
    final from = body.from ?? DeviceInfo(id: sender, name: '?', platform: 'unknown');
    if (from.id != sender) return _json(req.response, 400, {'error': 'bad_request'});
    final refused = await _mayReceive(from, body.batch ?? body.files.length);
    if (refused != null) {
      final reason = refused.reason?.trim();
      return _json(req.response, 403, {
        'error': refused.accept ? 'no_answer' : 'declined',
        if (reason != null && reason.isNotEmpty) 'reason': reason.length > 200 ? reason.substring(0, 200) : reason,
      });
    }
    final sid = _randomId(24);
    final s = _InSession(from, {for (final f in body.files) f.id: f});
    _sessions[sid] = s;
    if (_sessions.length > 200) _sessions.remove(_sessions.keys.first);
    final r = receiving;
    if (r == null || r.from.id != from.id) {
      receiving = Receiving(from, body.batch ?? body.files.length);
    } else if (body.batch != null && body.batch! > r.total) {
      r.total = body.batch!;
    }
    _touch();
    final results = <String, OfferResult>{};
    for (final f in body.files) {
      final part = await _part(s, f);
      results[f.id] = OfferResult(status: OfferStatus.ready, offset: await part.exists() ? await part.length() : 0);
    }
    return _json(req.response, 200, SessionResponse(sessionId: sid, results: results).toJson());
  }

  /// Null = go ahead. Otherwise why not: declined (with its reason) or —
  /// `accept: true` used as a marker — nobody answered.
  Future<IncomingReply?> _mayReceive(DeviceInfo from, int count) async {
    final now = DateTime.now();
    final ok = _acceptedUntil[from.id];
    if (ok != null && ok.isAfter(now)) {
      // The rest of an accepted transfer (each file is its own request).
      _acceptedUntil[from.id] = now.add(const Duration(minutes: 2));
      return null;
    }
    final no = _declinedUntil[from.id];
    if (no != null && no.isAfter(now)) return _lastDecline[from.id] ?? const IncomingReply(accept: false);
    final ask = _asking[from.id] ??= () {
      final a = IncomingAsk(from, count);
      asks.value = [...asks.value, a];
      return a;
    }();
    IncomingReply? reply;
    try {
      reply = await ask.answer.future.timeout(const Duration(minutes: 2));
    } on TimeoutException {
      reply = null;
    } finally {
      _asking.remove(from.id);
      asks.value = asks.value.where((x) => x != ask).toList();
    }
    if (!ask.answer.isCompleted) ask.answer.complete(const IncomingReply(accept: false));
    if (reply == null) return const IncomingReply(accept: true); // no answer
    if (reply.accept) {
      _acceptedUntil[from.id] = DateTime.now().add(const Duration(minutes: 2));
      return null;
    }
    _lastDecline[from.id] = reply;
    _declinedUntil[from.id] = DateTime.now().add(const Duration(minutes: 1));
    return reply;
  }

  Future<Directory> _inbox() async {
    final d = Directory('${(await getTemporaryDirectory()).path}/lr_in');
    await d.create(recursive: true);
    return d;
  }

  /// Partial download, stable across sessions (so a dropped Wi-Fi resumes).
  Future<File> _part(_InSession s, FileOffer f) async =>
      File('${(await _inbox()).path}/${shortKey('${s.from.id}|${f.assetId}|${f.modifiedMs}|${f.name}')}.part');

  Future<void> _chunk(HttpRequest req, _InSession s, FileOffer offer) async {
    final part = await _part(s, offer);
    final current = await part.exists() ? await part.length() : 0;
    final offset = int.tryParse(req.uri.queryParameters['offset'] ?? '') ?? -1;
    if (offset != current) {
      await req.drain<void>();
      return _json(req.response, 409, {'offset': current});
    }
    final total = int.tryParse(req.uri.queryParameters['total'] ?? '') ?? (offer.size ?? 0);
    final r = receiving;
    if (r != null) {
      r
        ..file = offer.name
        ..size = total;
    }
    var received = current;
    final sink = part.openWrite(mode: FileMode.append);
    try {
      await for (final data in req) {
        sink.add(data);
        received += data.length;
        if (r != null) r.bytes = received;
        _touch();
      }
      await sink.flush();
    } finally {
      await sink.close();
    }
    return _json(req.response, 200, {'offset': received});
  }

  Future<void> _complete(HttpRequest req, _InSession s, FileOffer offer) async {
    final body = CompleteRequest.fromJson(await _readJson(req));
    final part = await _part(s, offer);
    if (!await part.exists()) {
      return _json(req.response, 404, const CompleteResponse(saved: false, error: 'no_data').toJson());
    }
    final length = await part.length();
    if (length != body.size) return _json(req.response, 409, {'offset': length, 'error': 'size_mismatch'});
    if (await sha256OfFile(part) != body.sha256.toLowerCase()) {
      await part.delete();
      return _json(req.response, 422, const CompleteResponse(saved: false, error: 'sha256_mismatch').toJson());
    }
    // Named like the original (the photo library looks at the extension).
    final named = File('${part.parent.path}/${shortKey(part.path)}_${offer.name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_')}');
    await part.rename(named.path);
    final where = await saver.save(named, offer);
    final r = receiving;
    if (r != null && r.from.id == s.from.id) {
      // A Live Photo's video is part of its photo: count the photo only.
      if (!isLiveCompanion(offer.assetId)) {
        r.done++;
        if (where == SavedTo.album) {
          r.toAlbum++;
        } else {
          r.toFiles++;
        }
      }
      r.file = null;
    }
    _touch();
    return _json(req.response, 200, CompleteResponse(saved: true, path: offer.name).toJson());
  }

  /// Something happened: show it, and call the transfer finished once
  /// nothing more arrives for a few seconds.
  void _touch() {
    receiving?.last = DateTime.now();
    notifyListeners();
    _quiet?.cancel();
    _quiet = Timer(const Duration(seconds: 6), () async {
      final r = receiving;
      if (r == null) return;
      await saver.flushAll();
      receiving = null;
      notifyListeners();
      if (r.done > 0) _finished.add(r);
    });
  }

  // ---------------------------------------------------------------- helpers

  static String _randomId(int length) {
    const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
    final r = Random.secure();
    return List.generate(length, (_) => chars[r.nextInt(chars.length)]).join();
  }

  static Future<Map<String, dynamic>> _readJson(HttpRequest req) async {
    final text = await utf8.decoder.bind(req).join();
    if (text.length > 4 * 1024 * 1024) throw const FormatException('too large');
    return jsonDecode(text) as Map<String, dynamic>;
  }

  static Future<void> _json(HttpResponse res, int status, Object body) async {
    res.statusCode = status;
    res.headers.contentType = ContentType.json;
    res.write(jsonEncode(body));
    await res.close();
  }
}
