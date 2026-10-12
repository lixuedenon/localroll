// apps/desktop/lib/server/transfer_server.dart
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:localroll_core/localroll_core.dart';

import '../services/keep_awake.dart';
import '../services/tls_identity.dart';
import '../services/library_index.dart';
import '../services/receive_hub.dart';
import '../services/settings.dart';
import '../l10n/l10n.dart';
import 'port_mux.dart';

/// A phone waiting for someone to click Allow / Deny on this PC.
class PendingPair {
  PendingPair(this.id, this.device, {this.peer, this.fingerprint});

  final String id;
  final DeviceInfo device;

  /// Asked over HTTPS: this PC's certificate fingerprint, mixed into the
  /// symbols (the asking side mixes in the certificate it saw). Null for
  /// older phones that still use plain HTTP.
  final String? fingerprint;
  bool get secure => fingerprint != null;

  /// Set when another PC asks: allowing also lets this PC send to it.
  final PeerGrant? peer;
  bool get fromPc => peer != null && isDesktopPlatform(device.platform);
  final DateTime created = DateTime.now();
  PairApprovalStatus status = PairApprovalStatus.pending;
  String? token;

  List<String> get emoji => pairingEmoji(id, fingerprint: fingerprint);
  bool get expired => DateTime.now().difference(created) > LrProtocol.pairApprovalTimeout;
}

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
  TransferServer({required this.settings, required this.library, required this.hub, this.tls});

  final AppSettings settings;
  final LibraryIndex library;
  final ReceiveHub hub;

  /// This PC's certificate; null only if it could not be made (then plain
  /// HTTP only, as before).
  final TlsIdentity? tls;

  PortMux? _mux;
  HttpServer? _plainHttp;
  HttpServer? _secureHttp;

  /// Failed sign-ins per address, to slow down guessing.
  final Map<String, List<DateTime>> _failures = {};
  String? error;
  final Map<String, _UploadSession> _sessions = {};

  /// Ordinary files (PC → PC) finished in this run, by device|asset, so a
  /// retried "complete" whose answer was lost still gets "saved".
  final Map<String, String> _doneFiles = {};

  /// PIN currently shown on screen; changes after every successful pairing.
  final ValueNotifier<String> pin = ValueNotifier(randomPin());

  /// A second LocalRoll was started: bring this window to the front.
  void Function()? onShowRequested;
  int _failedPinAttempts = 0;

  /// Tap-to-pair requests; the UI shows an Allow / Deny dialog for each.
  final ValueNotifier<List<PendingPair>> pairRequests = ValueNotifier(const []);
  final Map<String, PendingPair> _pairs = {};

  bool get running => _mux != null;
  int get port => _mux?.port ?? settings.port;

  /// Ports tried in order. Windows reserves whole blocks of ports for
  /// Hyper-V / WSL / Docker ("excluded port ranges", usually inside
  /// 49152–65535), so fall back to ports outside that range and finally to
  /// any free port. Phones learn the actual port from the QR code / mDNS.
  List<int> get _candidatePorts => {
        settings.port,
        LrProtocol.defaultPort,
        ...LrProtocol.fallbackPorts,
        0, // let the OS pick
      }.toList();

  Future<void> start() async {
    await stop();
    final failures = <String>[];
    for (final p in _candidatePorts) {
      try {
        // One port for both: HTTPS for updated devices, plain HTTP for
        // older phones (see port_mux.dart).
        final mux = await PortMux.bind(InternetAddress.anyIPv4, p, tls?.context);
        final plain = HttpServer.listenOn(mux.plain)..idleTimeout = const Duration(minutes: 2);
        plain.listen((r) => _handle(r, secure: false), onError: (Object e) => debugPrint('server error: $e'));
        final secure = HttpServer.listenOn(mux.secure)..idleTimeout = const Duration(minutes: 2);
        secure.listen((r) => _handle(r, secure: true), onError: (Object e) => debugPrint('server error: $e'));
        _mux = mux;
        _plainHttp = plain;
        _secureHttp = secure;
        error = null;
        if (mux.port != settings.port) {
          // Remember the working port so it stays stable across restarts.
          await settings.update((s) => s.port = mux.port);
        }
        break;
      } on SocketException catch (e) {
        final code = e.osError?.errorCode;
        failures.add('$p${code != null ? ' (${tr('receive.port_error', {'code': code})})' : ''}');
      }
    }
    if (_mux == null) {
      error = tr('receive.no_port', {'ports': failures.join(', ')});
    }
    notifyListeners();
  }

  Future<void> stop() async {
    await _plainHttp?.close(force: true);
    await _secureHttp?.close(force: true);
    await _mux?.close();
    _plainHttp = null;
    _secureHttp = null;
    _mux = null;
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

  /// Too many failed sign-ins from [ip] in the last 10 minutes.
  bool _blocked(String ip) {
    final list = _failures[ip];
    if (list == null) return false;
    list.removeWhere((t) => DateTime.now().difference(t) > const Duration(minutes: 10));
    if (list.isEmpty) _failures.remove(ip);
    return (list.length) >= 20;
  }

  void _failed(String ip) {
    (_failures[ip] ??= []).add(DateTime.now());
    if (_failures.length > 1000) _failures.remove(_failures.keys.first);
  }

  Future<void> _handle(HttpRequest req, {required bool secure}) async {
    final res = req.response;
    try {
      final path = req.uri.path;
      final segs = req.uri.pathSegments;
      final remote = req.connectionInfo?.remoteAddress;
      final ip = remote?.address ?? '';

      // Home / office networks only: a port forwarded from the internet
      // must not expose the library.
      if (remote == null || !isLanAddress(remote)) {
        await req.drain<void>();
        return _json(res, 403, {'error': 'not_lan'});
      }

      if (req.method == 'POST' && path == LrProtocol.pathLocalShow) {
        // Only from this computer.
        final local = req.connectionInfo?.remoteAddress.isLoopback ?? false;
        await req.drain<void>();
        if (local) onShowRequested?.call();
        return _json(res, local ? 200 : 403, {'ok': local});
      }
      if (req.method == 'GET' && path == LrProtocol.pathInfo) {
        return _json(res, 200, settings.deviceInfo.toJson());
      }
      if (_blocked(ip)) {
        await req.drain<void>();
        return _json(res, 429, {'error': 'too_many_attempts'});
      }
      if (req.method == 'POST' && path == LrProtocol.pathPair) {
        return await _pair(req, secure: secure, ip: ip);
      }
      if (req.method == 'GET' && path == LrProtocol.pathAvatar) {
        return await _avatar(req);
      }
      if (req.method == 'POST' && path == LrProtocol.pathPairRequest) {
        return await _pairRequest(req, secure: secure);
      }
      if (req.method == 'GET' && segs.length == 4 && '/${segs.take(3).join('/')}' == LrProtocol.pathPairRequest) {
        return await _pairRequestStatus(req, segs[3]);
      }

      final device = await _authenticate(req);
      if (device == null) {
        _failed(ip);
        await req.drain<void>();
        return _json(res, 401, {'error': 'not_paired'});
      }
      // Paired over HTTPS (or already moved to it): plain HTTP is refused,
      // so a token seen on the network earlier is of no use.
      if (device.secure && !secure) {
        await req.drain<void>();
        return _json(res, 426, {'error': 'upgrade_required'});
      }
      // Older pairing, now over HTTPS: hand out a new token and stop
      // accepting plain HTTP from this device.
      if (req.method == 'POST' && path == LrProtocol.pathUpgrade) {
        await req.drain<void>();
        if (!secure) return _json(res, 426, {'error': 'upgrade_required'});
        final token = randomId(40);
        await settings.update((s) {
          final d = s.trusted[device.id];
          if (d == null) return;
          d.token = token;
          d.secure = true;
        });
        return _json(res, 200, {'token': token});
      }

      if (req.method == 'POST' && path == LrProtocol.pathSessions) {
        return await _createSession(req, device);
      }
      // The phone chose "Forget this PC": stop trusting it here too.
      if (req.method == 'DELETE' && path == LrProtocol.pathPair) {
        await settings.update((s) {
          s.trusted.remove(device.id);
          s.peers.remove(device.id); // another PC: no sending back either
        });
        return _json(res, 200, {'ok': true});
      }
      if (req.method == 'POST' && path == LrProtocol.pathVerify) {
        return await _verify(req, device);
      }
      if (req.method == 'POST' && path == LrProtocol.pathVisibility) {
        final body = VisibilityRequest.fromJson(await _readJson(req));
        final items = [
          for (final id in body.assetIds) ?library.findByAsset(device.id, id),
        ];
        library.setPrivate(items, body.private);
        return _json(res, 200, {'updated': items.length});
      }
      if (req.method == 'GET' && path == LrProtocol.pathChanges) {
        final since = int.tryParse(req.uri.queryParameters['since'] ?? '') ?? 0;
        return _json(
          res,
          200,
          ChangesResponse(
            deleted: library.deletedSince(device.id, since),
            now: DateTime.now().millisecondsSinceEpoch,
          ).toJson(),
        );
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
          return _json(res, 404, {'error': 'unknown_session'});
        }
        session.lastSeen = DateTime.now();
        if (segs.length == 6 && req.method == 'GET') return await _status(req, device, offer);
        if (segs.length == 6 && req.method == 'PUT') {
          KeepAwake.instance.ping(); // don't let Windows sleep mid-transfer
          return await _chunk(req, device, offer);
        }
        if (segs.length == 7 && segs[6] == 'complete' && req.method == 'POST') {
          return await _complete(req, device, offer);
        }
      }

      await req.drain<void>();
      return _json(res, 404, {'error': 'not_found'});
    } catch (e, st) {
      debugPrint('request failed: $e\n$st');
      try {
        await _json(res, 500, {'error': e.toString()});
      } catch (_) {
        // Response already started or socket gone.
      }
    }
  }

  Future<TrustedDevice?> _authenticate(HttpRequest req) async {
    final id = req.headers.value(LrProtocol.headerDeviceId);
    final token = req.headers.value(LrProtocol.headerToken);
    if (id == null || token == null) return null;
    var d = settings.trusted[id];
    if (d == null || d.token != token) {
      // The pairing may have been saved after we loaded settings.json; re-read once.
      await settings.reloadTrusted();
      d = settings.trusted[id];
    }
    return (d != null && d.token == token) ? d : null;
  }

  // --------------------------------------------------------------- handlers

  Future<void> _pair(HttpRequest req, {required bool secure, required String ip}) async {
    final body = PairRequest.fromJson(await _readJson(req));
    if (_failedPinAttempts >= 5) {
      // Too many wrong guesses: invalidate the PIN on screen.
      rotatePin();
      return _json(req.response, 429, {'error': 'too_many_attempts'});
    }
    if (body.pin.trim() != pin.value) {
      _failedPinAttempts++;
      _failed(ip);
      return _json(req.response, 403, {'error': 'wrong_pin'});
    }
    final token = randomId(40);
    await settings.update((s) {
      s.trusted[body.device.id] = TrustedDevice(
        id: body.device.id,
        name: body.device.name,
        platform: body.device.platform,
        token: token,
        pairedMs: DateTime.now().millisecondsSinceEpoch,
        owner: body.device.owner,
        // Paired again (e.g. after "Forget"): keep the member chosen here.
        memberName: s.trusted[body.device.id]?.memberName,
        secure: secure,
      );
    });
    rotatePin();
    return _json(
      req.response,
      200,
      PairResponse(token: token, desktop: settings.deviceInfo).toJson(),
    );
  }

  Future<void> _avatar(HttpRequest req) async {
    final f = settings.avatarFile;
    if (settings.avatarVersion == 0 || !await f.exists()) {
      return _json(req.response, 404, {'error': 'not_found'});
    }
    req.response
      ..statusCode = 200
      ..headers.contentType = ContentType('image', 'png')
      ..headers.set(HttpHeaders.cacheControlHeader, 'max-age=86400');
    await req.response.addStream(f.openRead());
    await req.response.close();
  }

  void _prunePairs() {
    // Answered requests are kept a little longer so the phone can read the answer.
    _pairs.removeWhere((_, p) => DateTime.now().difference(p.created) > LrProtocol.pairApprovalTimeout * 2);
    for (final p in _pairs.values) {
      if (p.status == PairApprovalStatus.pending && p.expired) p.status = PairApprovalStatus.expired;
    }
    pairRequests.value = _pairs.values.where((p) => p.status == PairApprovalStatus.pending).toList();
  }

  Future<void> _pairRequest(HttpRequest req, {required bool secure}) async {
    final body = PairApprovalRequest.fromJson(await _readJson(req));
    _prunePairs();
    // A few open requests at most, so nobody can flood the screen with dialogs.
    if (_pairs.values.where((p) => p.status == PairApprovalStatus.pending).length >= 3) {
      return _json(req.response, 429, {'error': 'too_many_attempts'});
    }
    final p = PendingPair(
      randomId(24),
      body.device,
      peer: body.peer,
      fingerprint: secure ? tls?.fingerprint : null,
    );
    _pairs[p.id] = p;
    pairRequests.value = [...pairRequests.value, p];
    return _json(
      req.response,
      200,
      PairApprovalState(requestId: p.id, status: PairApprovalStatus.pending).toJson(),
    );
  }

  Future<void> _pairRequestStatus(HttpRequest req, String id) async {
    _prunePairs();
    final p = _pairs[id];
    if (p == null) {
      await _json(req.response, 404, PairApprovalState(requestId: id, status: PairApprovalStatus.expired).toJson());
      return;
    }
    await _json(
      req.response,
      200,
      PairApprovalState(
        requestId: id,
        status: p.status,
        token: p.status == PairApprovalStatus.approved ? p.token : null,
        desktop: p.status == PairApprovalStatus.approved ? settings.deviceInfo : null,
      ).toJson(),
    );
    // The token is handed out once.
    if (p.status != PairApprovalStatus.pending) _pairs.remove(id);
  }

  /// Called by the Allow / Deny dialog.
  Future<void> answerPair(PendingPair p, {required bool allow}) async {
    if (p.status != PairApprovalStatus.pending) return;
    if (p.expired) {
      p.status = PairApprovalStatus.expired;
    } else if (allow) {
      final token = randomId(40);
      await settings.update((s) {
        s.trusted[p.device.id] = TrustedDevice(
          id: p.device.id,
          name: p.device.name,
          platform: p.device.platform,
          token: token,
          pairedMs: DateTime.now().millisecondsSinceEpoch,
          owner: p.device.owner,
          // Paired again (e.g. after "Forget"): keep the member chosen here.
          memberName: s.trusted[p.device.id]?.memberName,
          secure: p.secure,
        );
        // Another PC: one click pairs both ways.
        final g = p.peer;
        if (p.fromPc && g != null) {
          s.peers[p.device.id] = PeerPc(
            id: p.device.id,
            name: p.device.name,
            hosts: g.hosts,
            port: g.port,
            token: g.token,
            pairedMs: DateTime.now().millisecondsSinceEpoch,
            // Came over HTTPS from a PC the user just confirmed: trusted.
            fingerprint: p.secure ? g.fingerprint : null,
            icon: p.device.icon,
            color: p.device.color,
            avatar: p.device.avatar,
          );
        }
      });
      p.token = token;
      p.status = PairApprovalStatus.approved;
    } else {
      p.status = PairApprovalStatus.denied;
    }
    pairRequests.value = _pairs.values.where((x) => x.status == PairApprovalStatus.pending).toList();
  }

  Future<void> _createSession(HttpRequest req, TrustedDevice device) async {
    final body = SessionRequest.fromJson(await _readJson(req));
    // Library folder unreachable (external drive unplugged): don't accept
    // files we could not store; the phone shows why and keeps them queued.
    if (library.offline) {
      return _json(req.response, 503, {'error': 'library_offline'});
    }
    // Family group: the phone tells us whose phone it is (editable there).
    final owner = body.owner?.trim();
    if (owner != null && owner != (device.owner ?? '')) {
      await settings.update((s) => s.trusted[device.id]?.owner = owner.isEmpty ? null : owner);
    }
    _sessions.removeWhere(
      (_, s) => DateTime.now().difference(s.lastSeen) > const Duration(hours: 6),
    );

    final sessionId = randomId(20);
    final offers = {for (final f in body.files) f.id: f};
    _sessions[sessionId] = _UploadSession(sessionId, device, offers);

    final results = <String, OfferResult>{};
    for (final f in body.files) {
      if (f.isPlainFile && _doneFiles.containsKey(_hubKey(device, f))) {
        results[f.id] = const OfferResult(status: OfferStatus.duplicate);
        continue;
      }
      final existing = f.isPlainFile ? null : library.findByAsset(device.id, f.assetId);
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

  /// Safe cleanup: re-hash what we hold for each asset right now, so the
  /// phone deletes only files that are provably intact on this PC.
  Future<void> _verify(HttpRequest req, TrustedDevice device) async {
    final body = VerifyRequest.fromJson(await _readJson(req));
    // Unplugged library: "can't find it" must not read as "not backed up".
    if (library.offline) return _json(req.response, 503, {'error': 'library_offline'});
    final items = <VerifiedAsset>[];
    for (final id in body.assetIds.take(LrProtocol.verifyBatch)) {
      final m = library.findByAsset(device.id, id);
      if (m == null) {
        items.add(VerifiedAsset(assetId: id, ok: false, reason: 'missing'));
        continue;
      }
      final f = File(library.absPath(m));
      if (!await f.exists()) {
        items.add(VerifiedAsset(assetId: id, ok: false, reason: 'missing'));
        continue;
      }
      if (m.sha256 == null) {
        items.add(VerifiedAsset(assetId: id, ok: false, size: m.size, reason: 'unverified'));
        continue;
      }
      final same = await f.length() == m.size && await sha256OfFile(f) == m.sha256;
      items.add(VerifiedAsset(assetId: id, ok: same, size: m.size, reason: same ? null : 'changed'));
    }
    return _json(req.response, 200, VerifyResponse(items: items).toJson());
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
    if (library.offline) return _json(req.response, 503, {'error': 'library_offline'});
    final part = File(_partPath(device, offer));

    if (!await part.exists()) {
      final done = _doneFiles[_hubKey(device, offer)];
      if (done != null) return _json(req.response, 200, CompleteResponse(saved: true, path: done).toJson());
      // Retry of a request that already succeeded (response was lost).
      final existing = library.findByAsset(device.id, offer.assetId);
      if (existing != null) {
        return _json(req.response, 200, CompleteResponse(saved: true, path: existing.relPath).toJson());
      }
      return _json(req.response, 404, const CompleteResponse(saved: false, error: 'no_data').toJson());
    }

    final t = hub.track(_hubKey(device, offer), device.name, offer.name, body.size);
    final length = await part.length();
    if (length != body.size) {
      return _json(req.response, 409, {'offset': length, 'error': 'size_mismatch'});
    }

    hub.setState(t, TransferState.verifying);
    final hash = await sha256OfFile(part);
    if (hash != body.sha256.toLowerCase()) {
      await part.delete();
      hub.setState(t, TransferState.failed, error: tr('transfer.verify_failed'));
      return _json(req.response, 422, const CompleteResponse(saved: false, error: 'sha256_mismatch').toJson());
    }

    // A file from another PC: photos and videos (recognised by name, or by
    // content when the name says nothing) go into the library like any
    // other; documents and everything else into their own folders.
    var srcName = offer.name;
    var srcKind = offer.kind == MediaKind.other ? MediaKind.fromName(offer.name) : offer.kind;
    if (offer.isPlainFile) {
      final inFolder = (offer.relPath ?? '').contains('/');
      var isDoc = isDocumentName(offer.name);
      if (!inFolder && srcKind == MediaKind.other && !isDoc) {
        final sniff = sniffFileType(await _head(part));
        if (sniff != null) {
          srcName = '${offer.name}.${sniff.ext}';
          srcKind = sniff.kind;
          isDoc = sniff.ext == 'pdf';
        }
      }
      if (inFolder || srcKind == MediaKind.other) {
        return _savePlainFile(req, device, offer, part, t, name: srcName, document: !inFolder && isDoc);
      }
    }

    final captured = DateTime.fromMillisecondsSinceEpoch(offer.createdMs);
    final sep = Platform.pathSeparator;
    // Family group option: one folder per person (<member>/<year>/<month>).
    final member = settings.folderPerMember ? settings.family.memberOf(device.id) : null;
    final base = member == null ? library.rootPath : '${library.rootPath}$sep${sanitizeFileName(member)}';
    var folder = '$base$sep${captured.year}$sep${captured.month.toString().padLeft(2, '0')}';
    var fileName = sanitizeFileName(srcName);
    // Live Photo video: next to its photo, same name (IMG_1234.HEIC + IMG_1234.MOV),
    // the way iPhone exports pair them.
    if (isLiveCompanion(offer.assetId)) {
      final photo = library.findByAsset(device.id, livePhotoIdOf(offer.assetId));
      if (photo != null) {
        final photoPath = library.absPath(photo);
        folder = File(photoPath).parent.path;
        final base = photoPath.substring(folder.length + 1);
        final dot = base.lastIndexOf('.');
        final ext = fileName.lastIndexOf('.') > 0 ? fileName.substring(fileName.lastIndexOf('.')) : '.MOV';
        fileName = '${dot > 0 ? base.substring(0, dot) : base}$ext';
      }
    }
    await Directory(folder).create(recursive: true);
    final dest = LibraryIndex.uniquePath(folder, fileName);
    await part.rename(dest);
    try {
      // Explorer and Windows Photos sort by this; make it the capture time.
      await File(dest).setLastModified(captured);
    } catch (_) {}

    final rel = dest.substring(library.rootPath.length + 1).replaceAll(sep, '/');
    library.add(MediaItem(
      relPath: rel,
      name: rel.substring(rel.lastIndexOf('/') + 1),
      size: length,
      kind: srcKind,
      captureMs: offer.createdMs,
      receivedMs: DateTime.now().millisecondsSinceEpoch,
      sha256: hash,
      deviceId: device.id,
      deviceName: device.name,
      assetId: offer.assetId,
      private: offer.private,
    ));
    hub.progress(t, length);
    t.savedPath = dest;
    hub.setState(t, TransferState.saved);
    return _json(req.response, 200, CompleteResponse(saved: true, path: rel).toJson());
  }

  /// PC → PC ordinary file: into the "Received files" folder, keeping the
  /// sender's folder structure. Not added to the photo library.
  Future<void> _savePlainFile(
    HttpRequest req,
    TrustedDevice device,
    FileOffer offer,
    File part,
    TransferProgress t, {
    required String name,
    required bool document,
  }) async {
    final sep = Platform.pathSeparator;
    final inFolder = (offer.relPath ?? '').contains('/');
    final segs = [
      for (final p in (inFolder ? offer.relPath! : name).split('/'))
        if (p.trim().isNotEmpty && p != '.' && p != '..') sanitizeFileName(p),
    ];
    if (segs.isEmpty) segs.add(sanitizeFileName(name));
    final root = '${library.rootPath}$sep${await _folderName(document: document)}';
    final folder = [root, ...segs.take(segs.length - 1)].join(sep);
    await Directory(folder).create(recursive: true);
    final dest = LibraryIndex.uniquePath(folder, segs.last);
    await part.rename(dest);
    try {
      if (offer.modifiedMs > 0) await File(dest).setLastModified(DateTime.fromMillisecondsSinceEpoch(offer.modifiedMs));
    } catch (_) {}
    final rel = dest.substring(root.length + 1).replaceAll(sep, '/');
    _doneFiles[_hubKey(device, offer)] = rel;
    hub.progress(t, await File(dest).length());
    t.savedPath = dest;
    hub.setState(t, TransferState.saved);
    hub.fileSaved(dest);
    return _json(req.response, 200, CompleteResponse(saved: true, path: rel).toJson());
  }

  // ---------------------------------------------------------------- helpers

  /// "Documents" / "Other files" inside the library root: named the first
  /// time in the current language, then kept.
  Future<String> _folderName({required bool document}) async {
    var name = document ? settings.docsFolder : settings.otherFolder;
    if (name == null) {
      name = sanitizeFileName(tr(document ? 'folders.docs' : 'folders.other'));
      final n = name;
      await settings.update((s) => document ? s.docsFolder = n : s.otherFolder = n);
      library.ignoredFolders = {?settings.docsFolder, ?settings.otherFolder};
    }
    return name;
  }

  /// First bytes of a file (to recognise photos/videos without extension).
  Future<List<int>> _head(File f) async {
    final raf = await f.open();
    try {
      return await raf.read(16);
    } finally {
      await raf.close();
    }
  }

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
