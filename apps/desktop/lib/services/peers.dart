// apps/desktop/lib/services/peers.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:localroll_core/localroll_core.dart';
import 'package:nsd/nsd.dart' as nsd;

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

  nsd.Discovery? _discovery;
  final Map<String, FoundPc> _mdns = {};
  final Map<String, FoundPc> _scanned = {};

  /// Paired PCs that answered recently: id -> where.
  final Map<String, FoundPc> _reachable = {};
  bool scanning = false;
  Timer? _timer;
  int _users = 0;

  /// PCs seen right now (paired or not), never this one.
  List<FoundPc> get found {
    final all = <String, FoundPc>{..._scanned, ..._mdns, ..._reachable};
    all.remove(settings.deviceId);
    return all.values.toList()..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  }

  bool isOnline(String id) => found.any((f) => f.id == id);
  FoundPc? where(String id) => found.where((f) => f.id == id).firstOrNull;

  /// The Send page is open: look actively. Balanced by [release].
  void acquire() {
    _users++;
    if (_users > 1) return;
    unawaited(_startMdns());
    unawaited(checkPaired());
    _timer = Timer.periodic(const Duration(seconds: 20), (_) => checkPaired());
  }

  void release() {
    _users = max(0, _users - 1);
    if (_users > 0) return;
    _timer?.cancel();
    _timer = null;
    unawaited(_stopMdns());
  }

  Future<void> _startMdns() async {
    if (_discovery != null) return;
    try {
      _discovery = await nsd.startDiscovery(LrProtocol.serviceType, ipLookupType: nsd.IpLookupType.v4);
      _discovery!.addListener(_onMdns);
    } catch (e) {
      debugPrint('mDNS discovery failed: $e');
    }
  }

  Future<void> _stopMdns() async {
    final d = _discovery;
    _discovery = null;
    if (d == null) return;
    d.removeListener(_onMdns);
    try {
      await nsd.stopDiscovery(d);
    } catch (_) {}
  }

  void _onMdns() {
    _mdns.clear();
    for (final s in _discovery?.services ?? const <nsd.Service>[]) {
      final id = _txt(s, 'id') ?? s.name ?? '';
      if (id.isEmpty || id == settings.deviceId) continue;
      final hosts = [
        ...?s.addresses?.where((a) => a.type == InternetAddressType.IPv4).map((a) => a.address),
        if ((s.addresses == null || s.addresses!.isEmpty) && s.host != null) s.host!,
      ];
      if (hosts.isEmpty) continue;
      _mdns[id] = FoundPc(id: id, name: s.name ?? 'PC', hosts: hosts, port: s.port ?? LrProtocol.defaultPort);
    }
    notifyListeners();
  }

  static String? _txt(nsd.Service s, String key) {
    final v = s.txt?[key];
    if (v == null) return null;
    try {
      return utf8.decode(v);
    } catch (_) {
      return null;
    }
  }

  /// Asks each paired PC (last known address first) whether it is there,
  /// and picks up its new name / look / address.
  Future<void> checkPaired() async {
    await Future.wait([for (final p in settings.peers.values.toList()) _checkOne(p)]);
    notifyListeners();
  }

  Future<void> _checkOne(PeerPc p) async {
    final m = _mdns[p.id] ?? _scanned[p.id];
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

  /// Asks every address of this PC's local networks on the usual ports.
  Future<void> scan() async {
    if (scanning) return;
    scanning = true;
    notifyListeners();
    try {
      final ports = <int>{LrProtocol.defaultPort, ...LrProtocol.fallbackPorts, for (final p in settings.peers.values) p.port};
      final mine = (await localIPv4Addresses()).toSet();
      final prefixes = {for (final ip in mine) ip.substring(0, ip.lastIndexOf('.'))};
      final targets = <(String, int)>[
        // At most two networks (real adapters come first).
        for (final pre in prefixes.take(2))
          for (var i = 1; i < 255; i++)
            if (!mine.contains('$pre.$i'))
              for (final p in ports) ('$pre.$i', p),
      ];
      const batch = 96;
      for (var i = 0; i < targets.length; i += batch) {
        await Future.wait([
          for (final (h, p) in targets.sublist(i, min(i + batch, targets.length))) _probe(h, p),
        ]);
      }
      await checkPaired();
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
    final grant = PeerGrant(token: back, hosts: await localIPv4Addresses(), port: server.port);
    Object? lastError;
    for (final host in pc.hosts) {
      final c = LrClient(host: host, port: pc.port);
      try {
        var st = await c.requestApproval(settings.deviceInfo, peer: grant);
        onWaiting(pairingEmoji(st.requestId));
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
        c.close();
      }
    }
    throw PeerError('cannot_reach', '$lastError');
  }

  /// Forget a PC on both sides (the other side is told if it is reachable).
  Future<void> forget(PeerPc p) async {
    final at = where(p.id);
    for (final host in {...?at?.hosts, ...p.tryHosts}) {
      final c = LrClient(host: host, port: at?.port ?? p.port, deviceId: settings.deviceId, token: p.token);
      try {
        await c.unpair();
        break;
      } catch (_) {
      } finally {
        c.close();
      }
    }
    await settings.update((s) {
      s.peers.remove(p.id);
      s.trusted.remove(p.id);
    });
    _reachable.remove(p.id);
    notifyListeners();
  }

  @override
  void dispose() {
    _timer?.cancel();
    unawaited(_stopMdns());
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
  static SendFile? plain(File f, String relPath) {
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
        target: LrProtocol.targetFiles,
        relPath: relPath,
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
      final probe = LrClient(host: host, port: port);
      try {
        final info = await probe.info(timeout: const Duration(seconds: 3));
        if (info.id != p.id) continue;
        if (p.lastHost != host || p.port != port) {
          await settings.update((_) {
            p
              ..lastHost = host
              ..port = port;
          });
        }
        return LrClient(host: host, port: port, deviceId: settings.deviceId, token: p.token);
      } catch (_) {
      } finally {
        probe.close();
      }
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
