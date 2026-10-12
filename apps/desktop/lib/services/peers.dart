// apps/desktop/lib/services/peers.dart
import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:localroll_core/localroll_core.dart';

import '../server/transfer_server.dart';
import 'keep_awake.dart';
import 'library_index.dart';
import 'network.dart';
import 'settings.dart';

/// Another LocalRoll PC seen on the network right now.
class FoundPc {
  FoundPc({required this.id, required this.name, required this.hosts, required this.port, this.info});

  final String id;
  String name;
  List<String> hosts;
  int port;
  DeviceInfo? info;
}

/// Finds other LocalRoll PCs (mDNS + a scan of the local network) and keeps
/// track of which paired PCs are reachable.
class PeerDirectory extends ChangeNotifier {
  PeerDirectory({required this.settings, required this.server});

  final AppSettings settings;
  final TransferServer server;

  final Map<String, FoundPc> _scanned = {};

  /// Paired PCs that answered recently: id -> where.
  final Map<String, FoundPc> _reachable = {};
  bool scanning = false;
  Timer? _timer;
  int _users = 0;

  /// PCs seen right now (paired or not), never this one.
  List<FoundPc> get found {
    final all = <String, FoundPc>{..._scanned, ..._reachable};
    all.remove(settings.deviceId);
    return all.values.toList()..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  }

  bool isOnline(String id) => found.any((f) => f.id == id);
  FoundPc? where(String id) => found.where((f) => f.id == id).firstOrNull;

  /// The Send page is open: look actively. Balanced by [release].
  void acquire() {
    _users++;
    if (_users > 1) return;
    // No mDNS browsing on Windows: the plugin resolves services on the
    // window's own thread, which can freeze the whole app. Paired PCs are
    // checked at their known address and others are found by [scan].
    unawaited(checkPaired());
    _timer = Timer.periodic(const Duration(seconds: 20), (_) => checkPaired());
  }

  void release() {
    _users = max(0, _users - 1);
    if (_users > 0) return;
    _timer?.cancel();
    _timer = null;
  }

  /// Asks each paired PC (last known address first) whether it is there,
  /// and picks up its new name / look / address.
  Future<void> checkPaired() async {
    await Future.wait([
      for (final p in settings.peers.values.toList())
        _checkOne(p).timeout(const Duration(seconds: 12), onTimeout: () {}),
    ]);
    notifyListeners();
  }

  Future<void> _checkOne(PeerPc p) async {
    final m = _scanned[p.id];
    final candidates = <(String, int)>{
      for (final h in p.tryHosts) (h, p.port),
      if (m != null) for (final h in m.hosts) (h, m.port),
    };
    for (final (host, port) in candidates) {
      final c = LrClient(host: host, port: port);
      try {
        final info = await c.info(timeout: const Duration(seconds: 2));
        if (info.id != p.id) continue;
        _reachable[p.id] = FoundPc(id: p.id, name: info.name, hosts: [host], port: port, info: info);
        // Still paired over there? (It may have unpaired while we were off.)
        if (!await _stillPaired(p, host, port)) return;
        if (p.lastHost != host || p.port != port || p.name != info.name || p.icon != info.icon || p.color != info.color) {
          await settings.update((s) {
            p
              ..lastHost = host
              ..port = port
              ..name = info.name
              ..icon = info.icon
              ..color = info.color
              ..avatar = info.avatar;
            if (!p.hosts.contains(host)) p.hosts = [host, ...p.hosts];
            s.trusted[p.id]?.name = info.name;
          });
        }
        return;
      } catch (_) {
      } finally {
        c.close();
      }
    }
    _reachable.remove(p.id);
  }

  /// False (and the pairing removed here too) when the other PC answers
  /// "not paired" — it disconnected or forgot us while we could not hear it.
  Future<bool> _stillPaired(PeerPc p, String host, int port) async {
    LrClient? c;
    try {
      c = await openPeer(settings, p, host, port);
      if (c == null) return true;
      await c.ping();
      return true;
    } on LrHttpError catch (e) {
      if (e.status != 401) return true;
      await settings.update((s) {
        s.peers.remove(p.id);
        s.trusted.remove(p.id);
      });
      _reachable.remove(p.id);
      return false;
    } catch (_) {
      return true; // network trouble: decide another time
    } finally {
      c?.close();
    }
  }

  /// Asks every address of this PC's local networks on the usual ports.
  Future<void> scan() async {
    if (scanning) return;
    scanning = true;
    notifyListeners();
    try {
      final ports = <int>{LrProtocol.defaultPort, ...LrProtocol.fallbackPorts, for (final p in settings.peers.values) p.port};
      final all = await localIPv4Addresses();
      final mine = all.toSet();
      // The real network only (virtual adapters are listed last).
      final prefixes = {for (final ip in all.take(1)) ip.substring(0, ip.lastIndexOf('.'))};
      final targets = <(String, int)>[
        for (final pre in prefixes)
          for (var i = 1; i < 255; i++)
            if (!mine.contains('$pre.$i'))
              for (final p in ports) ('$pre.$i', p),
      ];
      const batch = 64;
      final until = DateTime.now().add(const Duration(seconds: 25));
      for (var i = 0; i < targets.length && DateTime.now().isBefore(until); i += batch) {
        await Future.wait([
          for (final (h, p) in targets.sublist(i, min(i + batch, targets.length))) _probe(h, p),
        ]).timeout(const Duration(seconds: 6), onTimeout: () => const []);
      }
      await checkPaired().timeout(const Duration(seconds: 15), onTimeout: () {});
    } catch (_) {
    } finally {
      scanning = false;
      notifyListeners();
    }
  }

  Future<void> _probe(String host, int port) async {
    try {
      final sock = await Socket.connect(host, port, timeout: const Duration(milliseconds: 350));
      sock.destroy();
    } catch (_) {
      return;
    }
    final c = LrClient(host: host, port: port);
    try {
      final info = await c.info(timeout: const Duration(seconds: 2));
      if (info.id == settings.deviceId || !isDesktopPlatform(info.platform)) return;
      _scanned[info.id] = FoundPc(id: info.id, name: info.name, hosts: [host], port: port, info: info);
      notifyListeners();
    } catch (_) {
    } finally {
      c.close();
    }
  }

  /// Tap-to-pair with another PC. One "Allow" there pairs both ways:
  /// we send a token it can use to send back to us.
  /// [onWaiting] gets the three symbols both screens show.
  Future<PeerPc?> pair(
    FoundPc pc, {
    required void Function(List<String> emoji) onWaiting,
    required bool Function() cancelled,
  }) async {
    final back = randomId(40);
    final grant = PeerGrant(
      token: back,
      hosts: await localIPv4Addresses(),
      port: server.port,
      tlsPort: settings.tlsFingerprint == null ? null : server.port,
      fingerprint: settings.tlsFingerprint,
    );
    Object? lastError;
    for (final host in pc.hosts) {
      LrClient? c;
      try {
        // Does it speak HTTPS? Then ask over HTTPS and bind the symbols to
        // the certificate we see (someone in between would change them).
        final probe = LrClient(host: host, port: pc.port);
        final DeviceInfo info;
        try {
          info = await probe.info();
        } finally {
          probe.close();
        }
        final first = info.fingerprint != null
            ? LrClient(host: host, port: info.tlsPort ?? pc.port, secure: true)
            : LrClient(host: host, port: pc.port);
        c = first;
        var st = await first.requestApproval(settings.deviceInfo, peer: grant);
        final seen = first.secure ? first.seenFingerprint : null;
        if (first.secure && seen == null) throw const PeerError('cannot_reach');
        onWaiting(pairingEmoji(st.requestId, fingerprint: seen));
        // From now on only that certificate.
        if (seen != null) {
          first.close();
          c = LrClient(host: host, port: info.tlsPort ?? pc.port, secure: true, pin: seen);
        }
        final until = DateTime.now().add(LrProtocol.pairApprovalTimeout + const Duration(seconds: 5));
        while (st.status == PairApprovalStatus.pending) {
          if (cancelled()) return null;
          if (DateTime.now().isAfter(until)) throw const PeerError('pair_expired');
          await Future<void>.delayed(const Duration(seconds: 1));
          st = await c.approvalStatus(st.requestId);
        }
        if (st.status == PairApprovalStatus.denied) throw const PeerError('pair_denied');
        if (st.status != PairApprovalStatus.approved || st.token == null || st.desktop == null) {
          throw const PeerError('pair_expired');
        }
        final d = st.desktop!;
        final peer = PeerPc(
          id: d.id,
          name: d.name,
          hosts: pc.hosts,
          port: pc.port,
          token: st.token!,
          pairedMs: DateTime.now().millisecondsSinceEpoch,
          lastHost: host,
          icon: d.icon,
          color: d.color,
          avatar: d.avatar,
          fingerprint: seen,
        );
        await settings.update((s) {
          s.peers[d.id] = peer;
          // The other PC sends to us with the token we gave it.
          s.trusted[d.id] = TrustedDevice(
            id: d.id,
            name: d.name,
            platform: d.platform,
            token: back,
            pairedMs: DateTime.now().millisecondsSinceEpoch,
            // It will send to us over HTTPS (it got our certificate above).
            secure: seen != null && settings.tlsFingerprint != null,
          );
        });
        _reachable[d.id] = FoundPc(id: d.id, name: d.name, hosts: [host], port: pc.port, info: d);
        notifyListeners();
        return peer;
      } on PeerError {
        rethrow;
      } on LrHttpError catch (e) {
        throw PeerError(e.code);
      } catch (e) {
        lastError = e;
      } finally {
        c?.close();
      }
    }
    throw PeerError('cannot_reach', '$lastError');
  }

  /// Unpair a PC on both sides (the other side is told if it is reachable;
  /// if not, it finds out the next time it tries). [hide]: "Forget" — also
  /// stop listing it under "Nearby".
  Future<void> forget(PeerPc p, {bool hide = false}) async {
    final at = where(p.id);
    for (final host in {...?at?.hosts, ...p.tryHosts}) {
      LrClient? c;
      try {
        c = await openPeer(settings, p, host, at?.port ?? p.port);
        await c?.unpair();
        if (c != null) break;
      } catch (_) {
      } finally {
        c?.close();
      }
    }
    await settings.update((s) {
      s.peers.remove(p.id);
      s.trusted.remove(p.id);
      if (hide) s.hiddenPeers.add(p.id);
    });
    _reachable.remove(p.id);
    notifyListeners();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}

/// A stable error code for the UI ('pair_denied', 'not_paired', …).
class PeerError implements Exception {
  const PeerError(this.code, [this.detail]);

  final String code;
  final String? detail;

  @override
  String toString() => detail == null ? code : '$code: $detail';
}

/// An authenticated client for a paired PC at [host]:[port], or null if
/// another (or no) LocalRoll answers there.
///
/// * Paired with HTTPS: only its pinned certificate is accepted; a different
///   one means it was reinstalled (or someone is in between): 'cert_changed'.
/// * Paired before encryption and it now offers HTTPS: move over once (new
///   token over HTTPS, the old one stops working), then pin.
/// * It has no HTTPS yet (older version): plain HTTP as before.
Future<LrClient?> openPeer(AppSettings settings, PeerPc p, String host, int port) async {
  final probe = LrClient(host: host, port: port);
  final DeviceInfo info;
  try {
    info = await probe.info(timeout: const Duration(seconds: 3));
  } finally {
    probe.close();
  }
  if (info.id != p.id) return null;
  final tlsPort = info.tlsPort ?? port;
  final pinned = p.fingerprint;
  if (pinned != null) {
    if (info.fingerprint != null && info.fingerprint != pinned) throw const PeerError('cert_changed');
    return LrClient(host: host, port: tlsPort, secure: true, pin: pinned, deviceId: settings.deviceId, token: p.token);
  }
  final offered = info.fingerprint;
  if (offered == null) return LrClient(host: host, port: port, deviceId: settings.deviceId, token: p.token);
  final up = LrClient(host: host, port: tlsPort, secure: true, pin: offered, deviceId: settings.deviceId, token: p.token);
  final String token;
  try {
    token = await up.upgrade();
  } finally {
    up.close();
  }
  await settings.update((_) {
    p
      ..token = token
      ..fingerprint = offered;
  });
  return LrClient(host: host, port: tlsPort, secure: true, pin: offered, deviceId: settings.deviceId, token: token);
}

// ------------------------------------------------------------------ sending

/// One file to send to another PC.
class SendFile {
  SendFile({
    required this.path,
    required this.name,
    required this.assetId,
    required this.kind,
    required this.createdMs,
    required this.modifiedMs,
    required this.size,
    this.target,
    this.relPath,
    this.private = false,
  });

  final String path;
  final String name;
  final String assetId;
  final MediaKind kind;
  final int createdMs;
  final int modifiedMs;
  final int size;
  final String? target;
  final String? relPath;
  final bool private;

  FileOffer offer(String id) => FileOffer(
        id: id,
        assetId: assetId,
        name: name,
        kind: kind,
        createdMs: createdMs,
        modifiedMs: modifiedMs,
        size: size,
        private: private,
        target: target,
        relPath: relPath,
      );

  /// Ordinary file (or a file inside a chosen folder): arrives as a file.
  /// [toLibrary]: a single photo or video lands in the other PC's library
  /// (by its file date) instead of the "Received files" folder.
  static SendFile? plain(File f, String relPath, {bool toLibrary = false}) {
    try {
      final st = f.statSync();
      if (st.type != FileSystemEntityType.file) return null;
      final name = relPath.split('/').last;
      final mtime = st.modified.millisecondsSinceEpoch;
      return SendFile(
        path: f.path,
        name: name,
        assetId: 'file:${shortKey('${f.absolute.path}|${st.size}|$mtime')}',
        kind: MediaKind.fromName(name),
        createdMs: mtime,
        modifiedMs: mtime,
        size: st.size,
        target: toLibrary ? null : LrProtocol.targetFiles,
        relPath: toLibrary ? null : relPath,
      );
    } catch (_) {
      return null;
    }
  }

  /// A library item: lands in the other PC's library, by capture date.
  static SendFile? fromLibrary(LibraryIndex lib, MediaItem i) {
    final f = File(lib.absPath(i));
    try {
      final st = f.statSync();
      if (st.type != FileSystemEntityType.file) return null;
      // Same id every time, so sending again is recognised as a duplicate;
      // a Live Photo video keeps the '#live' ending of its photo's id.
      final id = i.assetId != null
          ? 'o:${i.deviceId ?? ''}|${i.assetId}'
          : i.sha256 != null
              ? 'h:${i.sha256}'
              : 'p:${shortKey('${i.relPath}|${i.size}')}';
      return SendFile(
        path: f.path,
        name: i.name,
        assetId: id,
        kind: i.kind,
        createdMs: i.captureMs,
        modifiedMs: st.modified.millisecondsSinceEpoch,
        size: st.size,
        private: i.private,
      );
    } catch (_) {
      return null;
    }
  }
}

/// Every file inside [dir] (sub-folders included), as "<folder>/<path>".
Future<List<SendFile>> filesInFolder(String dir) async {
  final root = Directory(dir);
  final sep = Platform.pathSeparator;
  final top = root.absolute.path.replaceAll(RegExp(r'[\\/]+$'), '');
  final base = top.split(sep).last;
  final out = <SendFile>[];
  await for (final e in root.list(recursive: true, followLinks: false)) {
    if (e is! File) continue;
    final name = e.path.split(sep).last;
    final lower = name.toLowerCase();
    // Windows housekeeping files and Office lock files.
    if (lower == 'desktop.ini' || lower == 'thumbs.db' || name.startsWith(r'~$')) continue;
    final rel = e.absolute.path.substring(top.length + 1).replaceAll(sep, '/');
    final f = SendFile.plain(e, '$base/$rel');
    if (f != null) out.add(f);
  }
  return out;
}

enum SendJobState { waiting, connecting, sending, done, failed, cancelled }

class SendJob {
  SendJob(this.peer, this.files, this.title)
      : id = randomId(10),
        totalBytes = files.fold(0, (a, f) => a + f.size);

  final String id;
  final PeerPc peer;
  final List<SendFile> files;

  /// What was sent ("3 files", "Trip", "12 photos").
  final String title;
  final int totalBytes;

  SendJobState state = SendJobState.waiting;
  int sentFiles = 0;
  int skippedFiles = 0;
  int failedFiles = 0;
  int sentBytes = 0;
  String? current;
  String? error;
  DateTime? started;
  DateTime? finished;
  bool _cancel = false;

  int get processed => sentFiles + skippedFiles + failedFiles;
  bool get active => state == SendJobState.connecting || state == SendJobState.sending;
  bool get over => state == SendJobState.done || state == SendJobState.failed || state == SendJobState.cancelled;

  double get fraction => totalBytes == 0 ? (files.isEmpty ? 1 : processed / files.length) : (sentBytes / totalBytes).clamp(0, 1);

  /// Bytes per second since the start.
  double get speed {
    final s = started;
    if (s == null || sentBytes == 0) return 0;
    final secs = (finished ?? DateTime.now()).difference(s).inMilliseconds / 1000;
    return secs <= 0 ? 0 : sentBytes / secs;
  }
}

/// Sends files to paired PCs, one job at a time, with resume: an interrupted
/// file continues from what the other PC already has.
class PeerSender extends ChangeNotifier {
  PeerSender({required this.settings, required this.peers});

  final AppSettings settings;
  final PeerDirectory peers;

  final List<SendJob> jobs = [];
  bool _running = false;
  DateTime _lastNotify = DateTime.fromMillisecondsSinceEpoch(0);

  bool get busy => jobs.any((j) => j.active || j.state == SendJobState.waiting);

  SendJob add(PeerPc peer, List<SendFile> files, String title) {
    final j = SendJob(peer, files, title);
    jobs.insert(0, j);
    while (jobs.length > 50 && jobs.last.over) {
      jobs.removeLast();
    }
    notifyListeners();
    unawaited(_pump());
    return j;
  }

  void cancel(SendJob j) {
    j._cancel = true;
    if (j.state == SendJobState.waiting) {
      j.state = SendJobState.cancelled;
      j.finished = DateTime.now();
    }
    notifyListeners();
  }

  /// Sends a piece of text; null when it arrived, else an error code.
  Future<String?> sendText(PeerPc p, String text) async {
    LrClient? c;
    try {
      c = await _connect(p);
      if (c == null) return 'peer_offline';
      await c.sendText(text);
      return null;
    } on PeerError catch (e) {
      return e.code;
    } on LrHttpError catch (e) {
      return e.status == 401 ? 'not_paired' : e.code;
    } catch (_) {
      return 'peer_offline';
    } finally {
      c?.close();
    }
  }

  void clearFinished() {
    jobs.removeWhere((j) => j.over);
    notifyListeners();
  }

  void _tick({bool force = false}) {
    final now = DateTime.now();
    if (force || now.difference(_lastNotify).inMilliseconds > 150) {
      _lastNotify = now;
      notifyListeners();
    }
  }

  Future<void> _pump() async {
    if (_running) return;
    _running = true;
    try {
      while (true) {
        final next = jobs.reversed.where((j) => j.state == SendJobState.waiting).firstOrNull;
        if (next == null) break;
        await _run(next);
      }
    } finally {
      _running = false;
      _tick(force: true);
    }
  }

  /// Where the PC answers now: last address, then what discovery saw.
  Future<LrClient?> _connect(PeerPc p) async {
    final seen = peers.where(p.id);
    final candidates = <(String, int)>{
      if (seen != null) for (final h in seen.hosts) (h, seen.port),
      for (final h in p.tryHosts) (h, p.port),
    };
    for (final (host, port) in candidates) {
      try {
        final c = await openPeer(settings, p, host, port);
        if (c == null) continue;
        if (p.lastHost != host || p.port != port) {
          await settings.update((_) {
            p
              ..lastHost = host
              ..port = port;
          });
        }
        return c;
      } on PeerError {
        rethrow; // certificate changed: don't try elsewhere
      } catch (_) {}
    }
    return null;
  }

  Future<void> _run(SendJob j) async {
    j
      ..state = SendJobState.connecting
      ..started = DateTime.now()
      ..error = null;
    _tick(force: true);
    LrClient? c;
    try {
      c = await _connect(j.peer);
      if (c == null) throw const PeerError('peer_offline');
      j.state = SendJobState.sending;
      _tick(force: true);
      const perSession = 200;
      for (var start = 0; start < j.files.length; start += perSession) {
        if (j._cancel) break;
        final batch = j.files.sublist(start, min(start + perSession, j.files.length));
        final offers = [for (var i = 0; i < batch.length; i++) batch[i].offer('f${start + i}')];
        final session = await _retry(() => c!.createSession(SessionRequest(files: offers)));
        for (var i = 0; i < batch.length; i++) {
          if (j._cancel) break;
          final f = batch[i];
          final offer = offers[i];
          final r = session.results[offer.id];
          if (r == null || r.status == OfferStatus.duplicate) {
            j.skippedFiles++;
            j.sentBytes += f.size;
            _tick();
            continue;
          }
          j.current = f.relPath ?? f.name;
          _tick();
          try {
            await _sendFile(c, j, session.sessionId, offer, f, r.offset);
            j.sentFiles++;
          } on PeerError catch (e) {
            if (e.code == 'cancelled') break;
            if (e.code == 'not_paired' || e.code == 'library_offline' || e.code == 'peer_offline') rethrow;
            j.failedFiles++;
            j.error = e.code;
          }
          _tick();
        }
      }
      j.state = j._cancel ? SendJobState.cancelled : (j.failedFiles > 0 ? SendJobState.failed : SendJobState.done);
    } on PeerError catch (e) {
      j
        ..state = SendJobState.failed
        ..error = e.code;
    } on LrHttpError catch (e) {
      j
        ..state = SendJobState.failed
        ..error = e.code;
    } catch (e) {
      j
        ..state = SendJobState.failed
        ..error = 'peer_offline';
      debugPrint('send failed: $e');
    } finally {
      c?.close();
      j
        ..current = null
        ..finished = DateTime.now();
      _tick(force: true);
    }
  }

  /// Network hiccups: try again a few times before giving up.
  Future<T> _retry<T>(Future<T> Function() f) async {
    for (var attempt = 0;; attempt++) {
      try {
        return await f();
      } on LrHttpError catch (e) {
        if (e.status == 401) throw const PeerError('not_paired');
        if (e.code == 'library_offline') throw const PeerError('library_offline');
        rethrow;
      } catch (e) {
        if (attempt >= 4) throw const PeerError('peer_offline');
        await Future<void>.delayed(Duration(seconds: 1 << attempt));
      }
    }
  }

  Future<void> _sendFile(LrClient c, SendJob j, String sessionId, FileOffer offer, SendFile f, int offset) async {
    final file = File(f.path);
    if (!await file.exists()) throw const PeerError('file_missing');
    if (await file.length() != f.size) throw const PeerError('file_changed');
    final before = j.sentBytes;
    var pos = offset;
    j.sentBytes = before + pos;
    final raf = await file.open();
    try {
      while (pos < f.size) {
        if (j._cancel) throw const PeerError('cancelled');
        KeepAwake.instance.ping();
        final n = min(LrProtocol.chunkSize, f.size - pos);
        await raf.setPosition(pos);
        final chunk = await raf.read(n);
        try {
          pos = await _retry(() => c.putChunk(sessionId, offer.id, pos, f.size, chunk));
        } on LrHttpError catch (e) {
          // The other side has a different amount: continue from there.
          if (e.status != 409) rethrow;
          pos = (e.body['offset'] as num?)?.toInt() ?? await _retry(() => c.status(sessionId, offer.id));
        }
        j.sentBytes = before + pos;
        _tick();
      }
    } finally {
      await raf.close();
    }
    final hash = await sha256OfFile(file);
    final CompleteResponse res;
    try {
      res = await _retry(() => c.complete(sessionId, offer.id, CompleteRequest(size: f.size, sha256: hash)));
    } on LrHttpError catch (e) {
      throw PeerError(e.code);
    }
    if (!res.saved) throw PeerError(res.error ?? 'not_saved');
    j.sentBytes = before + f.size;
  }
}
