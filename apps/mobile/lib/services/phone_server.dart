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

import 'background_transfer.dart';
import 'media_saver.dart';
import 'tls_identity.dart';

/// What the receiver needs to know about this phone (MobileSettings).
abstract interface class PhoneIdentity {
  String get deviceId;
  String get deviceName;
}

class _TooLarge implements Exception {
  const _TooLarge();
}

/// What the person on this phone answered to "X wants to send you …".
class IncomingReply {
  const IncomingReply({required this.accept, this.reason});

  final bool accept;

  /// Declined with a reason the sender sees (plain text, short).
  final String? reason;
}

/// Someone nearby wants to send: the UI asks "Accept / Decline".
class IncomingAsk {
  IncomingAsk(this.from, this.count, {this.verified = false});

  final DeviceInfo from;

  /// A PC paired with this phone, proven by the secret it was given over
  /// its encrypted link. Anything else only *says* who it is (its name and
  /// id are visible on the Wi‑Fi), so the dialog warns.
  final bool verified;

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

  /// Whose "Accept" this transfer runs under (kept alive while it goes on).
  String key = '';
}

class _InSession {
  _InSession(this.from, this.offers);

  final DeviceInfo from;
  final Map<String, FileOffer> offers;
}

/// Most "Accept / Decline" questions open at once (nobody can fill the
/// screen with dialogs by sending under ever new names).
const int maxOpenAsks = 3;

/// Phones can receive too (every device is equal): while LocalRoll is open,
/// this phone listens on the Wi-Fi (HTTPS, its own certificate) and shows
/// up for nearby phones. Every transfer to a phone needs "Accept" here.
///
/// Same protocol as the PC (sessions, chunks, SHA-256 check, resume), so
/// any LocalRoll can send to it. Photos and videos go to the photo library
/// (album "LocalRoll"), other files to Files / Download.
class PhoneServer extends ChangeNotifier {
  PhoneServer(
    this.settings, {
    MediaSaver? saver,
    Future<Directory> Function()? dataDir,
    Future<Directory> Function()? tempDir,
    this.advertise = true,
    List<int>? ports,
    Future<int> Function()? freeSpace,
  })  : saver = saver ?? MediaSaver(),
        _freeSpace = freeSpace ?? BackgroundTransfer.freeSpace,
        _dataDir = dataDir ?? getApplicationSupportDirectory,
        _tempDir = tempDir ?? getTemporaryDirectory,
        _ports = ports ?? [LrProtocol.defaultPort, ...LrProtocol.fallbackPorts, 0];

  /// Where the certificate is kept / partial downloads go (tests: a temp folder).
  final Future<Directory> Function() _dataDir;
  final Future<Directory> Function() _tempDir;

  /// Free bytes on this phone (-1 = can't tell; then no check).
  final Future<int> Function() _freeSpace;

  /// Kept free beyond what arrives, for the system and other apps.
  static const int keepFree = 300 * 1024 * 1024;

  /// Show up for nearby phones (mDNS); off in tests.
  final bool advertise;
  final List<int> _ports;

  final PhoneIdentity settings;
  final MediaSaver saver;

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

  /// Accepted (until), per sender — a verified PC by its id; anyone else by
  /// id and address, so a look-alike can't ride on someone else's "Accept".
  final Map<String, DateTime> _acceptedUntil = {};

  /// PCs this phone asked to send ("save to my phone"): taken without
  /// asking for a while — only when the PC proves who it is.
  final Map<String, DateTime> _expected = {};

  /// One secret per paired PC, handed to it over its encrypted, signed-in
  /// live link (new each app start). A PC sending to this phone shows it.
  final Map<String, String> _pcTokens = {};

  /// The secret for PC [pcId] (made on first use).
  String receiveTokenFor(String pcId) => _pcTokens.putIfAbsent(pcId, () => _randomId(32));

  /// Does this request come from paired PC [sender] (its secret matches)?
  bool _verified(HttpRequest req, String sender) {
    final mine = _pcTokens[sender];
    final theirs = req.headers.value(LrProtocol.headerToken);
    return mine != null && theirs != null && theirs.isNotEmpty && sameSecret(mine, theirs);
  }

  final Map<String, DateTime> _declinedUntil = {};
  final Map<String, IncomingReply> _lastDecline = {};
  final Map<String, IncomingAsk> _asking = {};
  final Map<String, _InSession> _sessions = {};
  Timer? _quiet;

  /// Somebody is sending to us now (keep listening a little after leaving).
  bool get busy => receiving != null;

  /// Start / stop run one at a time (leaving and coming back quickly must
  /// not end with the server stopped while the app is on screen).
  Future<void> _turn = Future.value();
  Future<void> _serial(Future<void> Function() f) => _turn = _turn.then((_) => f()).catchError((Object e) {
        debugPrint('phone server: $e');
      });

  Future<void> start() => _serial(_start);
  Future<void> stop() => _serial(_stop);

  Future<void> _start() async {
    if (_http != null) return;
    try {
      _tls ??= await TlsIdentity.load(await _dataDir());
    } catch (e) {
      debugPrint('phone certificate unavailable: $e');
      return;
    }
    for (final p in _ports) {
      try {
        final s = await HttpServer.bindSecure(InternetAddress.anyIPv4, p, _tls!.context);
        s.idleTimeout = const Duration(minutes: 2);
        s.listen(_handle, onError: (Object e) => debugPrint('phone server: $e'));
        _http = s;
        port = s.port;
        break;
      } catch (_) {}
    }
    DiagLog.log('receiver', _http == null ? 'could not listen' : 'listening on $port');
    unawaited(_tidyInbox());
    if (_http == null) return;
    // Show up for nearby phones (PCs ignore entries marked as phones).
    if (advertise) {
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
    }
    notifyListeners();
  }

  /// App left the screen: stop being visible (iPhone can't listen in the
  /// background anyway). Waiting questions count as "no answer".
  Future<void> _stop() async {
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

  /// This phone asked PC [id] to send something ("save to my phone" while
  /// browsing it): take what it sends for a while without asking.
  void expectFrom(String id, {Duration within = const Duration(minutes: 10)}) {
    _declinedUntil.remove(id);
    _expected[id] = DateTime.now().add(within);
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
        return await _createSession(req, sender, verified: _verified(req, sender), ip: remote.address);
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
    } on _TooLarge {
      try {
        await _json(res, 413, {'error': 'too_large'});
      } catch (_) {}
    } on FormatException {
      try {
        await _json(res, 400, {'error': 'bad_request'});
      } catch (_) {}
    } on TypeError {
      try {
        await _json(res, 400, {'error': 'bad_request'});
      } catch (_) {}
    } catch (e, st) {
      DiagLog.error('receiver', e, st);
      try {
        await _json(res, 500, {'error': '$e'});
      } catch (_) {}
    }
  }

  Future<void> _createSession(HttpRequest req, String sender, {required bool verified, required String ip}) async {
    final body = SessionRequest.fromJson(await _readJson(req));
    final from = body.from ?? DeviceInfo(id: sender, name: '?', platform: 'unknown');
    if (from.id != sender) return _json(req.response, 400, {'error': 'bad_request'});
    // Asked once per transfer: a new transfer from the same PC asks again.
    final t = body.transfer;
    final key = (verified ? 'pc|$sender' : '$sender|$ip') + (t == null || t.isEmpty ? '' : '|${t.length > 40 ? t.substring(0, 40) : t}');
    // Not enough room on this phone: say so now (before anyone is asked),
    // not half-way through filling it up.
    var need = 0;
    for (final f in body.files) {
      final part = await _part(_InSession(from, const {}), f);
      final have = await part.exists() ? await part.length() : 0;
      need += max(0, (f.size ?? f.sizeHint ?? 0) - have);
    }
    if (need > 0) {
      final free = await _freeSpace();
      if (free >= 0 && need > free - keepFree) {
        DiagLog.log('receiver', '${from.name}: refused, phone full (need $need, free $free)');
        return _json(req.response, 507, {'error': 'phone_full', 'free': max(0, free - keepFree), 'need': need});
      }
    }
    if (!_asking.containsKey(key) && _asking.length >= maxOpenAsks && !_mayGoAhead(key, sender, verified)) {
      return _json(req.response, 429, {'error': 'too_many_attempts'});
    }
    final refused = await _mayReceive(from, body.batch ?? body.files.length, key: key, verified: verified);
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
      receiving = Receiving(from, body.batch ?? body.files.length)..key = key;
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
  /// Already allowed without a question (accepted a moment ago, or asked for).
  bool _mayGoAhead(String key, String sender, bool verified) {
    final now = DateTime.now();
    final ok = _acceptedUntil[key];
    if (ok != null && ok.isAfter(now)) return true;
    final asked = _expected[sender];
    return verified && asked != null && asked.isAfter(now);
  }

  Future<IncomingReply?> _mayReceive(DeviceInfo from, int count, {required String key, required bool verified}) async {
    final now = DateTime.now();
    if (_mayGoAhead(key, from.id, verified)) {
      // The rest of an accepted transfer (each file is its own request).
      _acceptedUntil[key] = now.add(const Duration(minutes: 2));
      return null;
    }
    final no = _declinedUntil[key];
    if (no != null && no.isAfter(now)) return _lastDecline[key] ?? const IncomingReply(accept: false);
    final ask = _asking[key] ??= () {
      final a = IncomingAsk(from, count, verified: verified);
      asks.value = [...asks.value, a];
      return a;
    }();
    IncomingReply? reply;
    try {
      reply = await ask.answer.future.timeout(const Duration(minutes: 2));
    } on TimeoutException {
      reply = null;
    } finally {
      _asking.remove(key);
      asks.value = asks.value.where((x) => x != ask).toList();
    }
    if (!ask.answer.isCompleted) ask.answer.complete(const IncomingReply(accept: false));
    DiagLog.log('receiver',
        '${from.name}${verified ? '' : ' (not verified)'}: ${reply == null ? 'no answer' : reply.accept ? 'accepted' : 'declined'}');
    if (reply == null) return const IncomingReply(accept: true); // no answer
    if (reply.accept) {
      _acceptedUntil[key] = DateTime.now().add(const Duration(minutes: 2));
      return null;
    }
    _lastDecline[key] = reply;
    _declinedUntil[key] = DateTime.now().add(const Duration(minutes: 1));
    return reply;
  }

  /// Half-received files nobody resumed for a week take room for nothing.
  Future<void> _tidyInbox() async {
    try {
      final now = DateTime.now();
      await for (final e in (await _inbox()).list()) {
        if (e is File && now.difference(await e.lastModified()) > const Duration(days: 7)) await e.delete();
      }
    } catch (_) {}
  }

  Future<Directory> _inbox() async {
    final d = Directory('${(await _tempDir()).path}/lr_in');
    await d.create(recursive: true);
    return d;
  }

  /// Partial download, stable across sessions (so a dropped Wi-Fi resumes).
  Future<File> _part(_InSession s, FileOffer f) async =>
      File('${(await _inbox()).path}/${shortKey('${s.from.id}|${f.assetId}|${f.modifiedMs}|${f.name}')}.part');

  /// One writer per half-received file (see [_chunk]).
  final Map<String, Future<void>> _partLocks = {};

  Future<T> _withPart<T>(String path, Future<T> Function() fn) async {
    final prev = _partLocks[path];
    final done = Completer<void>();
    final mine = done.future;
    _partLocks[path] = mine;
    try {
      if (prev != null) await prev;
      return await fn();
    } finally {
      done.complete();
      if (identical(_partLocks[path], mine)) _partLocks.remove(path);
    }
  }

  /// One chunk, received in full first and only then appended (as on the
  /// PC): a chunk cut off by a lost Wi‑Fi leaves nothing behind, and two
  /// requests never write the same file at once.
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
    // Never more than the file said it is (a broken or hostile sender
    // can't fill the phone), and never more than two chunks in one request.
    final cap = offer.size ?? (total > 0 ? total : null);
    final room = min(cap == null ? LrProtocol.chunkSize * 2 : cap - offset, LrProtocol.chunkSize * 2);
    final buf = BytesBuilder(copy: false);
    var over = false;
    try {
      await for (final data in req) {
        if (over) continue; // drain the rest
        if (buf.length + data.length > room) {
          over = true;
          continue;
        }
        buf.add(data);
        if (r != null) r.bytes = offset + buf.length;
        _touch();
      }
    } catch (_) {
      // Connection lost in the middle: keep nothing of this chunk.
      DiagLog.log('receiver', '${s.from.name}: chunk at $offset cut off (${buf.length} bytes dropped)');
      return;
    }
    if (over) return _json(req.response, 413, {'error': 'too_large', 'offset': current});
    final declared = req.contentLength;
    if (declared >= 0 && buf.length != declared) {
      return _json(req.response, 400, {'error': 'bad_request', 'offset': current});
    }
    final bytes = buf.takeBytes();
    var full = false;
    final at = await _withPart(part.path, () async {
      final now = await part.exists() ? await part.length() : 0;
      if (now != offset) return now;
      final raf = await part.open(mode: FileMode.append);
      try {
        await raf.writeFrom(bytes);
        await raf.flush();
      } on FileSystemException catch (e) {
        final code = e.osError?.errorCode;
        if (code != 28 && code != 112) rethrow; // ENOSPC
        try {
          await raf.truncate(offset);
        } catch (_) {}
        full = true;
        return offset;
      } finally {
        await raf.close();
      }
      return offset + bytes.length;
    });
    if (full) {
      DiagLog.log('receiver', '${s.from.name}: phone full while writing ${offer.name}');
      return _json(req.response, 507, {'error': 'phone_full', 'offset': current});
    }
    if (at != offset + bytes.length) return _json(req.response, 409, {'offset': at});
    return _json(req.response, 200, {'offset': at});
  }

  Future<void> _complete(HttpRequest req, _InSession s, FileOffer offer) async {
    final body = CompleteRequest.fromJson(await _readJson(req));
    final part = await _part(s, offer);
    // Not while a chunk of the same file is being written.
    return _withPart(part.path, () => _completeNow(req, s, offer, body, part));
  }

  Future<void> _completeNow(HttpRequest req, _InSession s, FileOffer offer, CompleteRequest body, File part) async {
    if (!await part.exists()) {
      return _json(req.response, 404, const CompleteResponse(saved: false, error: 'no_data').toJson());
    }
    final length = await part.length();
    if (length != body.size) return _json(req.response, 409, {'offset': length, 'error': 'size_mismatch'});
    if (await sha256OfFile(part) != body.sha256.toLowerCase()) {
      await part.delete();
      DiagLog.log('receiver', '${s.from.name}: checksum mismatch, file dropped');
      return _json(req.response, 422, const CompleteResponse(saved: false, error: 'sha256_mismatch').toJson());
    }
    // Named like the original (the photo library looks at the extension).
    final named = File('${part.parent.path}/${shortKey(part.path)}_${offer.name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_')}');
    await part.rename(named.path);
    final where = await saver.save(named, offer, from: Sender(s.from.id, s.from.name));
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
    // While a transfer keeps going, its "Accept" keeps holding (big files
    // can take longer than the 2 minutes between new sessions).
    final key = receiving?.key;
    if (key != null && _acceptedUntil.containsKey(key)) {
      _acceptedUntil[key] = DateTime.now().add(const Duration(minutes: 2));
    }
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

  /// Largest JSON request accepted.
  static const int maxJson = 4 * 1024 * 1024;

  static Future<Map<String, dynamic>> _readJson(HttpRequest req) async {
    final bytes = BytesBuilder(copy: false);
    var tooBig = req.contentLength > maxJson;
    await for (final data in req) {
      if (tooBig) continue;
      bytes.add(data);
      if (bytes.length > maxJson) tooBig = true;
    }
    if (tooBig) throw const _TooLarge();
    final j = jsonDecode(utf8.decode(bytes.takeBytes()));
    if (j is! Map<String, dynamic>) throw const FormatException('not an object');
    return j;
  }

  static Future<void> _json(HttpResponse res, int status, Object body) async {
    res.statusCode = status;
    res.headers.contentType = ContentType.json;
    res.write(jsonEncode(body));
    await res.close();
  }
}
