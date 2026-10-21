// apps/desktop/lib/server/transfer_server.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:localroll_core/localroll_core.dart';

import '../services/file_actions.dart';
import '../services/keep_awake.dart';
import '../services/tls_identity.dart';
import '../services/library_index.dart';
import '../services/receive_hub.dart';
import '../services/library_trash.dart';
import '../services/received_files.dart';
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

/// A paired guest asks to join the family group; the UI asks the user.
class MembershipAsk {
  MembershipAsk(this.device);

  final TrustedDevice device;
  final Completer<bool> answer = Completer<bool>();
}

/// Where a linked phone receives (it listens only while LocalRoll is open).
class PhoneEndpoint {
  const PhoneEndpoint(this.host, this.port, this.fingerprint, [this.token]);

  final String host;
  final int port;

  /// Its certificate: the only one accepted when sending there.
  final String fingerprint;

  /// The secret the phone gave us (over the encrypted, signed-in link):
  /// shown when sending there, so the phone knows it is really us. Null
  /// from older phones.
  final String? token;
}

class _LiveConn {
  _LiveConn(this.ws, this.session);

  final WebSocket ws;
  final String session;
}

/// What the user answered to "X wants to send …".
class AskAnswer {
  const AskAnswer({required this.accept, this.reason, this.quiet = false, this.timedOut = false});

  final bool accept;

  /// Nobody answered within 2 minutes.
  final bool timedOut;

  /// Declined with a reason the sender sees (plain text, short).
  final String? reason;

  /// Accepted: don't ask again for 30 minutes (paired guests).
  final bool quiet;
}

/// A guest device wants to send: the UI asks "Accept / Decline".
class IncomingAsk {
  IncomingAsk(this.device, this.count, this.bytes);

  final TrustedDevice device;
  final int count;
  final int bytes;
  final Completer<AskAnswer> answer = Completer<AskAnswer>();
}

/// A request body bigger than [TransferServer.maxJson].
class _TooLarge implements Exception {
  const _TooLarge();
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
  TransferServer({
    required this.settings,
    required this.library,
    required this.hub,
    this.tls,
    Future<int?> Function(String path)? freeSpace,
  }) : _freeSpace = freeSpace ?? ((p) async => (await diskSpace(p))?.free);

  /// Free bytes on the library's drive (null = can't tell; then no check).
  final Future<int?> Function(String path) _freeSpace;

  /// Largest JSON request accepted (a session of 200 files is ~60 KB).
  static const int maxJson = 4 * 1024 * 1024;

  /// Kept free on the library drive: a transfer that would leave less is
  /// refused up front ("not enough space on the PC") instead of failing
  /// half-way with a full disk.
  static const int keepFree = 256 * 1024 * 1024;

  /// Free space, asked at most every 20 s (on Windows it starts a process);
  /// what was accepted since is subtracted meanwhile.
  int? _free;
  DateTime _freeAt = DateTime.fromMillisecondsSinceEpoch(0);

  Future<int?> _freeNow() async {
    if (DateTime.now().difference(_freeAt) > const Duration(seconds: 20)) {
      try {
        _free = await _freeSpace(library.rootPath);
      } catch (_) {
        _free = null;
      }
      _freeAt = DateTime.now();
    }
    return _free;
  }

  final AppSettings settings;
  final LibraryIndex library;
  final ReceiveHub hub;

  /// Documents / other files received (Documents and Other folders), and who
  /// sent each.
  late final ReceivedFiles files = ReceivedFiles(library, folderPath);

  /// LocalRoll's "Recently deleted" (30 days): every deletion goes there,
  /// from this PC or from a phone allowed to manage the library.
  late final LibraryTrash trash = LibraryTrash(library, files);

  /// Something new arrived: linked phones browsing the library refresh
  /// (many arrivals in a row are told once).
  Timer? _addedSoon;

  void _announceAdded() {
    _addedSoon?.cancel();
    _addedSoon = Timer(const Duration(milliseconds: 1500), () {
      final msg = LiveMessage.added();
      for (final list in _live.values) {
        for (final c in list) {
          try {
            c.ws.add(msg);
          } catch (_) {}
        }
      }
    });
  }

  /// This PC's certificate; null only if it could not be made (then plain
  /// HTTP only, as before).
  final TlsIdentity? tls;

  PortMux? _mux;
  HttpServer? _plainHttp;
  HttpServer? _secureHttp;

  /// Auto-receive off: devices accepted (until) / declined (until).
  final Map<String, DateTime> _acceptedUntil = {};
  final Map<String, DateTime> _declinedUntil = {};
  final Map<String, IncomingAsk> _asking = {};

  /// Open "Accept / Decline" questions (the UI shows a dialog for each).
  final ValueNotifier<List<IncomingAsk>> incomingAsks = ValueNotifier(const []);

  static const Duration _acceptWindow = Duration(minutes: 30);

  /// The answer to the last decline per device (sent back with every
  /// refused request until it may ask again).
  final Map<String, AskAnswer> _lastDecline = {};

  /// May [device] send now? Family members: yes. Guests: the user is asked;
  /// an Accept covers this transfer (each file is its own request) — or 30
  /// minutes when they ticked "don't ask again". Null = yes; otherwise the
  /// answer that refused it.
  Future<AskAnswer?> _mayReceive(TrustedDevice device, List<FileOffer> files) async {
    if (device.familyMember) return null;
    final now = DateTime.now();
    final ok = _acceptedUntil[device.id];
    if (ok != null && ok.isAfter(now)) {
      _acceptedUntil[device.id] = now.add(_quietAccept[device.id] == true ? _acceptWindow : const Duration(minutes: 2));
      return null;
    }
    final no = _declinedUntil[device.id];
    if (no != null && no.isAfter(now)) return _lastDecline[device.id] ?? const AskAnswer(accept: false);
    final ask = _asking[device.id] ??= () {
      final a = IncomingAsk(device, files.length, files.fold(0, (s, f) => s + (f.size ?? 0)));
      incomingAsks.value = [...incomingAsks.value, a];
      return a;
    }();
    AskAnswer a;
    try {
      a = await ask.answer.future
          .timeout(const Duration(minutes: 2), onTimeout: () => const AskAnswer(accept: false, timedOut: true));
    } finally {
      _asking.remove(device.id);
      incomingAsks.value = incomingAsks.value.where((x) => x != ask).toList();
    }
    // Timed out: close the dialog too.
    if (!ask.answer.isCompleted) ask.answer.complete(a);
    if (a.accept) {
      _quietAccept[device.id] = a.quiet;
      // The rest of this batch arrives as separate requests: a short window
      // (or 30 minutes when asked not to ask again).
      _acceptedUntil[device.id] = DateTime.now().add(a.quiet ? _acceptWindow : const Duration(minutes: 2));
      return null;
    }
    // Declined: the same sender can't ask again for a minute.
    _lastDecline[device.id] = a;
    _declinedUntil[device.id] = DateTime.now().add(const Duration(minutes: 1));
    return a;
  }

  final Map<String, bool> _quietAccept = {};

  /// Called by the Accept / Decline dialog.
  void answerIncoming(IncomingAsk ask, AskAnswer answer) {
    if (!ask.answer.isCompleted) ask.answer.complete(answer);
  }

  /// Last signed-in request from each paired device. Devices say "I'm
  /// here" when LocalRoll opens, check in once a minute while it is open and
  /// say "I'm leaving" when it closes; this is how the PC knows who is online.
  final Map<String, DateTime> lastSeen = {};

  /// No word for this long = gone (closed without saying so — an iPhone
  /// app swiped away gets no chance to — Wi-Fi lost, phone asleep). Phones
  /// check in every 10 s while LocalRoll is on screen, PCs every 60 s.
  static const Duration phoneWindow = Duration(seconds: 30);
  static const Duration pcWindow = Duration(seconds: 90);

  bool isOnline(String deviceId) {
    // A live link open: there (closed the moment the app ends).
    if (_live[deviceId]?.isNotEmpty ?? false) return true;
    final t = lastSeen[deviceId];
    if (t == null) return false;
    final pc = isDesktopPlatform(settings.trusted[deviceId]?.platform ?? '');
    return DateTime.now().difference(t) < (pc ? pcWindow : phoneWindow);
  }

  // ------------------------------------------------------------ live links

  /// Open live links per device (normally one; briefly two while a phone
  /// reconnects).
  final Map<String, List<_LiveConn>> _live = {};

  bool hasLiveLink(String deviceId) => _live[deviceId]?.isNotEmpty ?? false;

  /// Phones that told us (over their live link) where they receive.
  final Map<String, PhoneEndpoint> _phoneAt = {};

  /// Where phone [id] receives now, or null (app closed / older version).
  PhoneEndpoint? phoneEndpoint(String id) => hasLiveLink(id) ? _phoneAt[id] : null;

  OnlineDevice? _describe(String id) {
    final t = settings.trusted[id];
    if (t == null) return null;
    final ep = phoneEndpoint(id);
    return OnlineDevice(id: id, name: t.name, platform: t.platform, host: ep?.host, port: ep?.port, fingerprint: ep?.fingerprint);
  }

  /// Tell every other linked device that [id] came / went.
  void _broadcast(String id, {required bool online}) {
    final d = _describe(id);
    final msg = online ? (d == null ? null : LiveMessage.up(d)) : LiveMessage.down(id);
    if (msg == null) return;
    for (final e in _live.entries) {
      if (e.key == id) continue;
      for (final c in e.value) {
        try {
          c.ws.add(msg);
        } catch (_) {}
      }
    }
  }

  Future<void> _openLive(HttpRequest req, TrustedDevice device, {required bool wasOnline, required bool secure}) async {
    final session = req.uri.queryParameters['session'] ?? '';
    // A phone says where it receives (PC → phone sending), and — only over
    // HTTPS — the secret to show when sending there.
    final rport = int.tryParse(req.uri.queryParameters['rport'] ?? '');
    final rfp = req.uri.queryParameters['rfp'];
    final rtk = secure ? req.uri.queryParameters['rtk'] : null;
    final host = req.connectionInfo?.remoteAddress.address;
    final WebSocket ws;
    try {
      ws = await WebSocketTransformer.upgrade(req);
    } catch (_) {
      return;
    }
    ws.pingInterval = livePingInterval;
    final list = _live.putIfAbsent(device.id, () => []);
    // An older link of the same device is stale (the app was closed and
    // opened again before that link died): drop it. A different session
    // means it really left and came back — announce it again.
    final before = _presenceSession[device.id];
    final again = wasOnline && before != null && before != session;
    for (final old in list.toList()) {
      list.remove(old);
      unawaited(old.ws.close(WebSocketStatus.goingAway).catchError((_) {}));
    }
    final conn = _LiveConn(ws, session);
    list.add(conn);
    if (rport != null && rfp != null && rfp.isNotEmpty && host != null && !isDesktopPlatform(device.platform)) {
      _phoneAt[device.id] = PhoneEndpoint(host, rport, rfp, (rtk == null || rtk.isEmpty || rtk.length > 128) ? null : rtk);
    }
    _presenceSession[device.id] = session;
    lastSeen[device.id] = DateTime.now();
    final others = onlineNow?.call() ?? {for (final id in lastSeen.keys) if (isOnline(id)) id};
    ws.add(LiveMessage.hello(
      family: device.familyMember,
      access: device.libraryAccess,
      online: [
        for (final id in others)
          if (id != device.id) ?_describe(id),
      ],
    ));
    if (!wasOnline) {
      notifyListeners();
      onPresence?.call(device.id, true);
      _broadcast(device.id, online: true);
    } else if (again) {
      _arrivals.add(device.id);
      _broadcast(device.id, online: true);
    }
    ws.listen((_) {}, onDone: () => _closedLive(device.id, conn), onError: (_) => _closedLive(device.id, conn), cancelOnError: true);
  }

  void _closedLive(String id, _LiveConn conn) {
    final list = _live[id];
    if (list == null || !list.remove(conn)) return; // replaced by a newer link
    if (list.isEmpty) _live.remove(id);
    if (hasLiveLink(id)) return;
    _phoneAt.remove(id);
    // Gone now (not after the usual quiet time).
    lastSeen.remove(id);
    notifyListeners();
    onPresence?.call(id, false);
    _broadcast(id, online: false);
  }

  /// A device's family membership changed: tell it.
  void _tellMembership(TrustedDevice d) {
    for (final c in _live[d.id] ?? const <_LiveConn>[]) {
      try {
        c.ws.add(LiveMessage.you(family: d.familyMember, access: d.libraryAccess));
      } catch (_) {}
    }
  }

  /// Move a paired device in or out of the family group (from the UI).
  Future<void> setFamily(String id, bool family) async {
    // Becoming a guest also drops what it may do with the library back to
    // the guest default (can't look); back in the family it may look again.
    await settings.update((s) {
      final d = s.trusted[id];
      if (d == null) return;
      if (!family && d.familyMember) d.access = null;
      d.familyMember = family;
    });
    final d = settings.trusted[id];
    if (d != null) _tellMembership(d);
    if (family) {
      _acceptedUntil.remove(id);
    }
  }

  /// What a paired device may do with the library (from the UI): saved,
  /// and the device is told at once (its delete button appears / goes).
  Future<void> setAccess(String id, LibraryAccess? access) async {
    await settings.update((s) => s.trusted[id]?.access = access);
    final d = settings.trusted[id];
    if (d != null) _tellMembership(d);
  }

  /// Photos were deleted from the library: every linked device asks for
  /// /changes now (a phone shows "not backed up any more" without waiting).
  /// Many deletions in a row are told once.
  Timer? _changedSoon;
  int _deletionsSeen = 0;

  void _onLibraryDeletions() {
    if (library.deletions.value == _deletionsSeen) return;
    _deletionsSeen = library.deletions.value;
    _changedSoon?.cancel();
    _changedSoon = Timer(const Duration(milliseconds: 800), () {
      final msg = LiveMessage.changed();
      var n = 0;
      for (final list in _live.values) {
        for (final c in list) {
          try {
            c.ws.add(msg);
            n++;
          } catch (_) {}
        }
      }
      if (n > 0) DiagLog.log('live', 'told $n linked device(s): library changed');
    });
  }

  /// "Make me a family member" requests waiting for the user here.
  final ValueNotifier<List<MembershipAsk>> membershipAsks = ValueNotifier(const []);

  void answerMembership(MembershipAsk ask, {required bool allow}) {
    if (!ask.answer.isCompleted) ask.answer.complete(allow);
  }

  Future<void> _membership(HttpRequest req, TrustedDevice device) async {
    final body = await _readJson(req);
    final want = body['family'] == true;
    // Leaving is always allowed (it only adds questions for the leaver).
    if (!want || device.familyMember) {
      if (device.familyMember != want) await setFamily(device.id, want);
      return _json(req.response, 200, {'family': device.familyMember});
    }
    if (membershipAsks.value.any((a) => a.device.id == device.id)) {
      return _json(req.response, 429, {'error': 'too_many_attempts'});
    }
    final ask = MembershipAsk(device);
    membershipAsks.value = [...membershipAsks.value, ask];
    bool yes;
    try {
      yes = await ask.answer.future.timeout(const Duration(minutes: 2), onTimeout: () => false);
    } finally {
      membershipAsks.value = membershipAsks.value.where((a) => a != ask).toList();
    }
    if (!ask.answer.isCompleted) ask.answer.complete(false); // timed out: close the dialog
    if (yes) await setFamily(device.id, true);
    return _json(req.response, 200, {'family': settings.trusted[device.id]?.familyMember ?? false});
  }

  /// Each app start (or return after leaving) has its own id: a new one from
  /// a device we still thought online means it was closed and opened again
  /// in between — announced as "online" again.
  final Map<String, String> _presenceSession = {};

  /// Devices that go quiet drop offline by time alone: look every 3 s and
  /// tell the listeners (dots, notes) when the set changed.
  Timer? _presenceTick;
  Set<String> _onlineBefore = const {};

  void _tickPresence() {
    final now = {for (final id in lastSeen.keys) if (isOnline(id)) id};
    if (now.length != _onlineBefore.length || !now.containsAll(_onlineBefore)) {
      _onlineBefore = now;
      notifyListeners();
    }
  }

  /// A device came back while still counted online (see [_presenceSession]).
  final StreamController<String> _arrivals = StreamController.broadcast();
  Stream<String> get arrivals => _arrivals.stream;

  /// Set by AppServices: a paired device said it is here / leaving (lets
  /// the PC list react at once).
  void Function(String deviceId, bool online)? onPresence;

  /// Set by AppServices: every paired device online now (phones and PCs).
  Set<String> Function()? onlineNow;

  // ------------------------------------------------- browsing (set by AppServices)

  /// Small JPEG for the grid / JPEG for the screen (made with ffmpeg).
  Future<File?> Function(MediaItem item)? thumbnail;
  Future<File?> Function(MediaItem item)? display;

  /// Small picture of a received file (PDF first page, photo, video frame),
  /// or null when there is none (Office files: the phone draws those).
  Future<File?> Function(String path)? fileThumbnail;

  /// Deletes library items; how many are gone. Default: into [trash]
  /// ("Recently deleted", 30 days).
  Future<int> Function(List<MediaItem> items)? deleter;

  /// Send [items] to phone [d] the usual way (converted, it saves them);
  /// how many were queued. Throws [StateError] when it can't receive now.
  Future<int> Function(TrustedDevice d, List<MediaItem> items)? sendToPhone;

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
    _presenceTick ??= Timer.periodic(const Duration(seconds: 3), (_) => _tickPresence());
    if (!_watchingDeletions) {
      _watchingDeletions = true;
      _deletionsSeen = library.deletions.value;
      library.deletions.addListener(_onLibraryDeletions);
    }
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
      DiagLog.log('server', 'no port: ${failures.join(', ')}');
    } else {
      DiagLog.log('server', 'listening on ${_mux!.port} (https: ${tls != null})');
    }
    notifyListeners();
  }

  Future<void> stop() async {
    // Close live links first: the other devices see us leave at once.
    for (final list in _live.values.toList()) {
      for (final c in list.toList()) {
        try {
          await c.ws.close(WebSocketStatus.goingAway).timeout(const Duration(milliseconds: 300));
        } catch (_) {}
      }
    }
    _live.clear();
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

  bool _watchingDeletions = false;

  @override
  void dispose() {
    _presenceTick?.cancel();
    _changedSoon?.cancel();
    _addedSoon?.cancel();
    if (_watchingDeletions) library.deletions.removeListener(_onLibraryDeletions);
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
      final wasOnline = isOnline(device.id);
      lastSeen[device.id] = DateTime.now();
      if (!wasOnline && !(path == LrProtocol.pathLive)) notifyListeners(); // came online
      try {
        return await _signedIn(req, res, device, path, segs, secure: secure, wasOnline: wasOnline);
      } finally {
        // Still here when it ends (unless this was its "I'm leaving").
        if (lastSeen.containsKey(device.id)) lastSeen[device.id] = DateTime.now();
      }
    } on _TooLarge {
      try {
        await _json(res, 413, {'error': 'too_large'});
      } catch (_) {}
    } on FormatException {
      try {
        await _json(res, 400, {'error': 'bad_request'});
      } catch (_) {}
    } on TypeError {
      // A field of the wrong type in the request.
      try {
        await _json(res, 400, {'error': 'bad_request'});
      } catch (_) {}
    } catch (e, st) {
      DiagLog.error('server', e, st);
      debugPrint('request failed: $e\n$st');
      try {
        await _json(res, 500, {'error': e.toString()});
      } catch (_) {
        // Response already started or socket gone.
      }
    }
  }

  /// Requests from a paired device (already signed in).
  Future<void> _signedIn(
    HttpRequest req,
    HttpResponse res,
    TrustedDevice device,
    String path,
    List<String> segs, {
    required bool secure,
    required bool wasOnline,
  }) async {
    {
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
          d.setToken(token);
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
      if (req.method == 'POST' && path == LrProtocol.pathText) {
        final body = await _readJson(req);
        final text = body['text'];
        if (text is! String || text.isEmpty) return _json(res, 400, {'error': 'bad_request'});
        if (text.length > LrProtocol.maxText) return _json(res, 413, {'error': 'too_large'});
        hub.textReceived(device.name, text);
        return _json(res, 200, {'ok': true});
      }
      if (path == LrProtocol.pathLive && WebSocketTransformer.isUpgradeRequest(req)) {
        if (!secure && device.secure) return _json(res, 426, {'error': 'upgrade_required'});
        return await _openLive(req, device, wasOnline: wasOnline, secure: secure);
      }
      if (req.method == 'POST' && path == LrProtocol.pathMembership) {
        return await _membership(req, device);
      }
      if (req.method == 'POST' && path == LrProtocol.pathPresence) {
        final body = await _readJson(req);
        final online = body['online'] != false;
        final session = body['session'];
        if (session is String) {
          final before = _presenceSession[device.id];
          _presenceSession[device.id] = session;
          // Closed and opened again before we noticed it was gone.
          if (online && wasOnline && before != null && before != session) _arrivals.add(device.id);
        }
        if (!online && !hasLiveLink(device.id)) {
          lastSeen.remove(device.id);
          notifyListeners();
          _broadcast(device.id, online: false);
        }
        onPresence?.call(device.id, online);
        if (!online) return _json(res, 200, {'online': const []});
        // Who else is here: the phone shows them too (it can't ask other
        // phones itself). Names only, and only to paired devices.
        final ids = onlineNow?.call() ?? {for (final id in lastSeen.keys) if (isOnline(id)) id};
        return _json(res, 200, {
          'online': [
            for (final id in ids)
              if (id != device.id) ?_describe(id)?.toJson(),
          ],
        });
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
            library: library.libraryId.isEmpty ? null : library.libraryId,
          ).toJson(),
        );
      }

      if (path == LrProtocol.pathLibrary || path.startsWith('${LrProtocol.pathLibrary}/')) {
        return await _browse(req, device, path, secure: secure);
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
    }
  }

  // ------------------------------------------------------------- browsing

  /// A phone looks at (or manages) this PC's library. Only what the PC
  /// allows that device, only over HTTPS, and never another phone's
  /// "only me" items.
  Future<void> _browse(HttpRequest req, TrustedDevice device, String path, {required bool secure}) async {
    final res = req.response;
    if (!secure) {
      await req.drain<void>();
      return _json(res, 426, {'error': 'upgrade_required'});
    }
    final access = device.libraryAccess;
    if (access == LibraryAccess.none) {
      await req.drain<void>();
      return _json(res, 403, {'error': 'no_access'});
    }
    if (library.offline) {
      await req.drain<void>();
      return _json(res, 503, {'error': 'library_offline'});
    }
    final get = req.method == 'GET' || req.method == 'HEAD';
    if (get && path == LrProtocol.pathLibrary) return _libraryPage(req, device, access);
    if (get && (path == LrProtocol.pathLibraryThumb || path == LrProtocol.pathLibraryView || path == LrProtocol.pathLibraryFile)) {
      final item = _visibleItem(device, req.uri.queryParameters['p']);
      if (item == null) {
        // A received file (document, scan…): the file itself only; the
        // phone draws its first page.
        final f = await _visibleFile(device, req.uri.queryParameters['p']);
        if (f == null) return _json(res, 404, {'error': 'not_found'});
        if (path == LrProtocol.pathLibraryThumb) {
          // The first page of a PDF, a frame of a video, a photo: made here.
          final make = fileThumbnail;
          final t = make == null ? null : await make(f.path);
          if (t == null || !await t.exists()) return _json(res, 404, {'error': 'no_picture'});
          res.headers.set(HttpHeaders.cacheControlHeader, 'private, max-age=86400');
          return _serveFile(req, t, t.path.toLowerCase().endsWith('.png') ? 'image/png' : 'image/jpeg');
        }
        if (path != LrProtocol.pathLibraryFile) return _json(res, 404, {'error': 'no_picture'});
        return _serveFile(req, File(f.path), _contentType(f.name));
      }
      if (path == LrProtocol.pathLibraryFile) {
        final f = File(library.absPath(item));
        if (!await f.exists()) return _json(res, 404, {'error': 'not_found'});
        return _serveFile(req, f, _contentType(item.name));
      }
      final make = path == LrProtocol.pathLibraryThumb ? thumbnail : display;
      final f = make == null ? null : await make(item);
      if (f == null || !await f.exists()) return _json(res, 404, {'error': 'no_picture'});
      res.headers.set(HttpHeaders.cacheControlHeader, 'private, max-age=86400');
      return _serveFile(req, f, 'image/jpeg');
    }
    if (req.method == 'POST' &&
        (path == LrProtocol.pathLibrarySend || path == LrProtocol.pathLibraryDelete || path == LrProtocol.pathLibraryVisibility)) {
      final body = await _readJson(req);
      final paths = (body['paths'] as List? ?? const []).whereType<String>().take(5000).toList();
      final items = [for (final p in paths) ?_visibleItem(device, p)];
      if (path == LrProtocol.pathLibrarySend) {
        final send = sendToPhone;
        if (send == null) return _json(res, 501, {'error': 'not_supported'});
        try {
          final n = await send(device, items);
          DiagLog.log('browse', '${device.name}: asked for $n items');
          return _json(res, 200, {'queued': n});
        } on StateError {
          return _json(res, 409, {'error': 'phone_closed'});
        }
      }
      if (path == LrProtocol.pathLibraryDelete) {
        if (access != LibraryAccess.manage) return _json(res, 403, {'error': 'no_access'});
        var n = items.isEmpty ? 0 : await (deleter ?? (List<MediaItem> x) async => (await trash.putMedia(x)).length)(items);
        // Received files among them.
        final known = {for (final i in items) i.relPath};
        final gone = <String>[
          for (final p in paths)
            if (!known.contains(p)) ?(await _visibleFile(device, p))?.path,
        ];
        if (gone.isNotEmpty) {
          n += (await (fileDeleter ?? (List<String> x) async => [for (final e in await trash.putFiles(x)) e.rel])(gone)).length;
          files.forget();
        }
        DiagLog.log('browse', '${device.name}: deleted $n of ${items.length} items (to Recently deleted)');
        return _json(res, 200, {'deleted': n});
      }
      // Visibility: only of what this device sent itself.
      final own = items.where((i) => i.ownedBy(device.id)).toList();
      library.setPrivate(own, body['private'] == true);
      final known = {for (final i in items) i.relPath};
      final others = [for (final p in paths) if (!known.contains(p)) p];
      final n = others.isEmpty ? 0 : await files.setPrivate(others, device.id, body['private'] == true);
      return _json(res, 200, {'updated': own.length + n});
    }
    await req.drain<void>();
    return _json(res, 404, {'error': 'not_found'});
  }

  /// Deletes received files; returns what is gone. Default: into [trash].
  Future<List<String>> Function(List<String> paths)? fileDeleter;

  /// The received file at [rel] if [device] may see it: one it sent, or one
  /// not marked "only me" (files from before beta.59 have no sender: shown).
  Future<ReceivedFile?> _visibleFile(TrustedDevice device, String? rel) async {
    if (rel == null || rel.isEmpty) return null;
    final f = await files.find(rel);
    if (f == null) return null;
    final o = f.owner;
    if (o != null && o.private && o.deviceId != device.id) return null;
    return f;
  }

  /// [rel] if it is in the library and [device] may see it.
  MediaItem? _visibleItem(TrustedDevice device, String? rel) {
    if (rel == null || rel.isEmpty) return null;
    final item = library.findByRel(rel);
    if (item == null) return null;
    if (item.private && !item.ownedBy(device.id)) return null; // someone else's "only me"
    return item;
  }

  Future<void> _libraryPage(HttpRequest req, TrustedDevice device, LibraryAccess access) async {
    final q = req.uri.queryParameters;
    final offset = max(0, int.tryParse(q['offset'] ?? '') ?? 0);
    final limit = (int.tryParse(q['limit'] ?? '') ?? 200).clamp(1, LrProtocol.libraryPageMax);
    final kind = q['kind'];
    final byReceived = q['sort'] == 'received';
    final family = settings.family;
    // Photos / videos, then received files (documents, scans…) — newest
    // taken (files: arrived) or newest arrival first.
    final entries = <(int, int, RemoteItem)>[]; // (order time, arrival, item)
    if (kind == null || kind == MediaKind.image.name || kind == MediaKind.video.name) {
      for (final i in library.items) {
        if ((kind == null || i.kind.name == kind) &&
            (i.kind == MediaKind.image || i.kind == MediaKind.video) &&
            !(i.private && !i.ownedBy(device.id))) {
          entries.add((
            byReceived ? i.receivedMs : i.captureMs,
            i.receivedMs,
            RemoteItem(
              path: i.relPath,
              name: i.name,
              kind: i.kind,
              takenMs: i.captureMs,
              size: i.size,
              live: library.liveFor(i)?.relPath,
              private: i.private,
              mine: i.ownedBy(device.id),
              from: i.deviceId == null ? null : (family.labelOf(i.deviceId!) ?? i.deviceName),
              receivedMs: i.receivedMs,
            ),
          ));
        }
      }
    }
    if (kind == null || kind == MediaKind.other.name) {
      for (final f in await files.list()) {
        final o = f.owner;
        if (o != null && o.private && o.deviceId != device.id) continue;
        final rel = files.relOf(f.path);
        if (rel == null) continue;
        final at = f.arrived.millisecondsSinceEpoch;
        entries.add((
          at,
          at,
          RemoteItem(
            path: rel,
            name: f.name,
            kind: MediaKind.other,
            takenMs: at,
            size: f.size,
            private: o?.private ?? false,
            mine: o?.deviceId == device.id,
            from: o == null ? null : (family.labelOf(o.deviceId) ?? o.deviceName),
            receivedMs: at,
            file: true,
          ),
        ));
      }
    }
    entries.sort((a, b) => b.$1.compareTo(a.$1));
    final since = DateTime.now().subtract(const Duration(hours: 24)).millisecondsSinceEpoch;
    return _json(
      req.response,
      200,
      LibraryPage(
        items: [for (final e in entries.skip(offset).take(limit)) e.$3],
        total: entries.length,
        access: access,
        next: offset + limit < entries.length ? offset + limit : null,
        library: library.libraryId.isEmpty ? null : library.libraryId,
        recent: entries.where((e) => e.$2 > since).length,
      ).toJson(),
    );
  }

  /// A file, whole or the asked-for part (players read videos piece by piece).
  Future<void> _serveFile(HttpRequest req, File f, String contentType) async {
    final res = req.response;
    await req.drain<void>();
    final len = await f.length();
    res.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
    res.headers.contentType = ContentType.parse(contentType);
    var start = 0;
    var end = len - 1;
    final range = req.headers.value(HttpHeaders.rangeHeader);
    if (range != null) {
      final m = RegExp(r'^bytes=(\d*)-(\d*)$').firstMatch(range.trim());
      if (m != null && (m[1]!.isNotEmpty || m[2]!.isNotEmpty)) {
        if (m[1]!.isEmpty) {
          start = max(0, len - int.parse(m[2]!)); // the last N bytes
        } else {
          start = int.parse(m[1]!);
          if (m[2]!.isNotEmpty) end = min(int.parse(m[2]!), len - 1);
        }
        if (start >= len || start > end) {
          res
            ..statusCode = 416
            ..headers.set(HttpHeaders.contentRangeHeader, 'bytes */$len');
          return res.close();
        }
        res
          ..statusCode = 206
          ..headers.set(HttpHeaders.contentRangeHeader, 'bytes $start-$end/$len');
      }
    }
    res.contentLength = len == 0 ? 0 : end - start + 1;
    if (req.method == 'HEAD' || len == 0) return res.close();
    await res.addStream(f.openRead(start, end + 1));
    await res.close();
  }

  static String _contentType(String name) => switch (extensionOf(name)) {
        'jpg' || 'jpeg' => 'image/jpeg',
        'png' => 'image/png',
        'gif' => 'image/gif',
        'webp' => 'image/webp',
        'heic' => 'image/heic',
        'heif' => 'image/heif',
        'avif' => 'image/avif',
        'mp4' => 'video/mp4',
        'm4v' => 'video/x-m4v',
        'mov' => 'video/quicktime',
        'mkv' => 'video/x-matroska',
        'webm' => 'video/webm',
        'avi' => 'video/x-msvideo',
        _ => 'application/octet-stream',
      };

  Future<TrustedDevice?> _authenticate(HttpRequest req) async {
    final id = req.headers.value(LrProtocol.headerDeviceId);
    final token = req.headers.value(LrProtocol.headerToken);
    if (id == null || token == null) return null;
    var d = settings.trusted[id];
    if (d == null || !d.signsIn(token)) {
      // The pairing may have been saved after we loaded settings.json; re-read once.
      await settings.reloadTrusted();
      d = settings.trusted[id];
    }
    return (d != null && d.signsIn(token)) ? d : null;
  }

  // --------------------------------------------------------------- handlers

  Future<void> _pair(HttpRequest req, {required bool secure, required String ip}) async {
    // Pairing only over HTTPS (the PIN and the new token must not be seen
    // on the Wi‑Fi). Plain only if this PC has no certificate at all.
    if (!secure && tls != null) {
      await req.drain<void>();
      return _json(req.response, 426, {'error': 'upgrade_required'});
    }
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
    if (!secure && tls != null) {
      await req.drain<void>();
      return _json(req.response, 426, {'error': 'upgrade_required'});
    }
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
  /// [family]: join the family group (its transfers need no "Accept");
  /// otherwise a guest.
  Future<void> answerPair(PendingPair p, {required bool allow, bool family = true}) async {
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
          familyMember: family,
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
      DiagLog.log('pair', 'allowed ${p.device.name} (${p.device.platform}, family: $family)');
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
      DiagLog.log('receive', '${device.name}: refused, library offline');
      return _json(req.response, 503, {'error': 'library_offline'});
    }
    final refused = await _mayReceive(device, body.files);
    if (refused != null) {
      DiagLog.log('receive', '${device.name}: ${refused.timedOut ? 'no answer' : 'declined'}');
      final reason = refused.reason?.trim();
      return _json(req.response, 403, {
        'error': refused.timedOut ? 'no_answer' : 'declined',
        if (reason != null && reason.isNotEmpty) 'reason': reason.length > 200 ? reason.substring(0, 200) : reason,
      });
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
    var need = 0;
    for (final f in body.files) {
      // Already received in this run — and still there (if it was deleted
      // since, take it again).
      final done = f.isPlainFile ? _doneFiles[_hubKey(device, f)] : null;
      if (done != null && !File(done).existsSync()) _doneFiles.remove(_hubKey(device, f));
      if (done != null && File(done).existsSync()) {
        results[f.id] = const OfferResult(status: OfferStatus.duplicate);
        hub.alreadyHad(_hubKey(device, f), device.name, f.name, f.size ?? 0);
        continue;
      }
      final existing = f.isPlainFile ? null : library.findByAsset(device.id, f.assetId);
      if (existing != null && File(library.absPath(existing)).existsSync()) {
        results[f.id] = const OfferResult(status: OfferStatus.duplicate);
        hub.alreadyHad(_hubKey(device, f), device.name, f.name, f.size ?? 0);
        continue;
      }
      final part = File(_partPath(device, f));
      final offset = await part.exists() ? await part.length() : 0;
      results[f.id] = OfferResult(status: OfferStatus.ready, offset: offset);
      // Phones send an expected size for photos (the exact one is known
      // only once the original is exported).
      need += max(0, (f.size ?? f.sizeHint ?? 0) - offset);
    }
    // Not enough room on this PC: say so now, not half-way through.
    if (need > 0) {
      final free = await _freeNow();
      if (free != null && need > free - keepFree) {
        _sessions.remove(sessionId);
        DiagLog.log('receive', '${device.name}: refused, disk full (need $need, free $free)');
        return _json(req.response, 507, {'error': 'disk_full', 'free': max(0, free - keepFree), 'need': need});
      }
      if (free != null) _free = free - need;
    }
    DiagLog.log('receive', '${device.name}: session, ${body.files.length} files, ${results.values.where((r) => r.status == OfferStatus.duplicate).length} already here');
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

  /// [_chunk]'s answer when the drive filled up while writing.
  static const int _diskFull = -(1 << 62);

  /// "Not enough space on the disk" (Windows 112 / 39, POSIX ENOSPC 28).
  static bool isDiskFull(FileSystemException e) {
    final code = e.osError?.errorCode;
    return code == 112 || code == 39 || code == 28;
  }

  /// One writer per half-received file: a chunk is appended, or the file
  /// checked and saved, only while no other request touches it.
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

  /// One chunk. It is received in full first and only then appended: a
  /// chunk cut off by a lost Wi-Fi leaves nothing behind, so a resumed send
  /// (on a new connection) can never be mixed with the remains of the old.
  Future<void> _chunk(HttpRequest req, TrustedDevice device, FileOffer offer) async {
    final path = _partPath(device, offer);
    final part = File(path);
    final current = await part.exists() ? await part.length() : 0;
    final offset = int.tryParse(req.uri.queryParameters['offset'] ?? '') ?? -1;
    if (offset != current) {
      await req.drain<void>();
      return _json(req.response, 409, {'offset': current});
    }
    final total = int.tryParse(req.uri.queryParameters['total'] ?? '') ?? (offer.size ?? 0);
    final t = hub.track(_hubKey(device, offer), device.name, offer.name, total);
    // Never more than the file said it is (a broken or hostile sender
    // can't fill the disk), and never more than two chunks in one request.
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
        hub.progress(t, offset + buf.length);
      }
    } catch (e) {
      // Connection lost in the middle: keep nothing of this chunk.
      DiagLog.log('receive', '${device.name}: chunk at $offset cut off (${buf.length} bytes dropped)');
      return;
    }
    if (over) return _json(req.response, 413, {'error': 'too_large', 'offset': current});
    final declared = req.contentLength;
    if (declared >= 0 && buf.length != declared) {
      return _json(req.response, 400, {'error': 'bad_request', 'offset': current});
    }
    final bytes = buf.takeBytes();
    final at = await _withPart(path, () async {
      // Another request may have written meanwhile: append only where we
      // were told to.
      final now = await part.exists() ? await part.length() : 0;
      if (now != offset) return -now - 1;
      final raf = await part.open(mode: FileMode.append);
      try {
        await raf.writeFrom(bytes);
        await raf.flush();
      } on FileSystemException catch (e) {
        if (!isDiskFull(e)) rethrow;
        // Cut what was half written: the file stays a clean prefix.
        try {
          await raf.truncate(offset);
        } catch (_) {}
        return _diskFull;
      } finally {
        await raf.close();
      }
      return offset + bytes.length;
    });
    if (at == _diskFull) {
      _freeAt = DateTime.fromMillisecondsSinceEpoch(0); // ask again next time
      DiagLog.log('receive', '${device.name}: disk full while writing ${offer.name}');
      return _json(req.response, 507, {'error': 'disk_full', 'offset': current});
    }
    if (at < 0) return _json(req.response, 409, {'offset': -at - 1});
    return _json(req.response, 200, {'offset': at});
  }

  Future<void> _complete(HttpRequest req, TrustedDevice device, FileOffer offer) async {
    final body = CompleteRequest.fromJson(await _readJson(req));
    if (library.offline) return _json(req.response, 503, {'error': 'library_offline'});
    // Not while a chunk of the same file is being written.
    return _withPart(_partPath(device, offer), () => _completeNow(req, device, offer, body));
  }

  Future<void> _completeNow(HttpRequest req, TrustedDevice device, FileOffer offer, CompleteRequest body) async {
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
      DiagLog.log('receive', '${device.name}: checksum mismatch, file dropped (${body.size} bytes)');
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

    // Exactly these bytes are here already (sent from another phone, from
    // a new iPhone after a restore, or sent to a phone and backed up from
    // there): keep one file; this phone's photo now points at it.
    final same = library.findSame(length, hash);
    if (same != null) {
      await part.delete();
      library.addAlias(same, device.id, offer.assetId);
      hub.progress(t, length);
      t.savedPath = library.absPath(same);
      hub.setState(t, TransferState.alreadyHad);
      DiagLog.log('receive', '${device.name}: ${offer.name} is already here as ${same.relPath} (same content), kept once');
      return _json(req.response, 200, CompleteResponse(saved: true, path: same.relPath).toJson());
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
    await _renameRetry(part, dest);
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
    _announceAdded();
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
    await _renameRetry(part, dest);
    try {
      if (offer.modifiedMs > 0) await File(dest).setLastModified(DateTime.fromMillisecondsSinceEpoch(offer.modifiedMs));
    } catch (_) {}
    final rel = dest.substring(root.length + 1).replaceAll(sep, '/');
    _doneFiles[_hubKey(device, offer)] = dest;
    await files.received(dest, FileOwner(device.id, device.name, private: offer.private));
    _announceAdded();
    hub.progress(t, await File(dest).length());
    t.savedPath = dest;
    hub.setState(t, TransferState.saved);
    hub.fileSaved(dest);
    return _json(req.response, 200, CompleteResponse(saved: true, path: rel).toJson());
  }

  // ---------------------------------------------------------------- helpers

  /// Full path of the Documents / Other files folder (created if needed).
  Future<String> folderPath({required bool document}) async {
    final p = '${library.rootPath}${Platform.pathSeparator}${await _folderName(document: document)}';
    await Directory(p).create(recursive: true);
    return p;
  }

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
  /// Windows may still hold the just-written file for a moment (virus
  /// scanner, indexer): "in use by another program". Try again a few times
  /// before giving up.
  static Future<void> _renameRetry(File part, String dest) async {
    for (var attempt = 1;; attempt++) {
      try {
        await part.rename(dest);
        return;
      } on FileSystemException catch (e) {
        if (attempt >= 8) rethrow;
        if (attempt == 1) DiagLog.log('receive', 'file busy, retrying: ${e.osError?.message ?? e.message}');
        await Future<void>.delayed(Duration(milliseconds: 250 * attempt));
      }
    }
  }

  String _partPath(TrustedDevice device, FileOffer offer) =>
      '${library.incomingDir}${Platform.pathSeparator}'
      '${shortKey('${device.id}|${offer.assetId}|${offer.modifiedMs}')}.part';

  String _hubKey(TrustedDevice device, FileOffer offer) => '${device.id}|${offer.assetId}';

  Future<Map<String, dynamic>> _readJson(HttpRequest req) async {
    final declared = req.contentLength;
    if (declared > maxJson) {
      await req.drain<void>();
      throw const _TooLarge();
    }
    final bytes = BytesBuilder(copy: false);
    var tooBig = false;
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

  Future<void> _json(HttpResponse res, int status, Object body) async {
    res.statusCode = status;
    res.headers.contentType = ContentType.json;
    res.write(jsonEncode(body));
    await res.close();
  }
}
