// apps/desktop/lib/services/remote_control.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:localroll_core/localroll_core.dart';

import '../app_services.dart';
import 'pc_files.dart';
import 'remote_page.dart';
import 'settings.dart';

/// How long the PC allows a phone.
enum RemoteGrant { once, hour, always, no }

/// A phone controlling this PC (for now: finding, looking at and taking
/// "Other files on this PC"). The PC allows each phone once — this time,
/// for an hour, or always (until 30 days unused) — and then the phone just
/// does things, nothing asked again. Every request is written to the log;
/// while a phone is at it the PC shows who, with a button to stop it.
class RemoteControl extends ChangeNotifier {
  RemoteControl(this.s);

  final AppServices s;

  /// Small picture of a file anywhere on this PC (set by AppServices).
  Future<File?> Function(String path)? thumb;

  /// Asks on this PC (set by the UI): may [name] control it, and how long.
  Future<RemoteGrant> Function(String name)? ask;

  /// Allowed this time / for an hour (not kept after Keepnear closes).
  final Map<String, DateTime> _until = {};
  final Map<String, DateTime> _refused = {};

  /// Stopped on this PC: shut out for 10 minutes, even when always allowed.
  final Map<String, DateTime> _stopped = {};
  final Map<String, Future<RemoteGrant>> _asking = {};

  /// The phone at it now (a request in the last 2 minutes), and its name.
  String? activeId, activeName;
  DateTime _lastAt = DateTime.fromMillisecondsSinceEpoch(0);
  Timer? _idle;

  static const Duration unused = Duration(days: 30);

  AppSettings get _settings => s.settings;

  bool allowed(String id) {
    final t = _until[id];
    if (t != null && DateTime.now().isBefore(t)) return true;
    final used = _settings.remoteAlways[id];
    if (used == null) return false;
    if (DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(used)) > unused) {
      // 30 days without it: allowed no more.
      unawaited(_settings.update((x) => x.remoteAlways.remove(id)));
      DiagLog.log('remote', '$id: not used for 30 days, no longer allowed');
      return false;
    }
    return true;
  }

  /// Stops [id] now (its "always" too when [forGood]).
  void stop(String id, {bool forGood = false}) {
    _until.remove(id);
    if (forGood) unawaited(_settings.update((x) => x.remoteAlways.remove(id)));
    _stopped[id] = DateTime.now();
    if (activeId == id) {
      activeId = null;
      activeName = null;
    }
    DiagLog.log('remote', '$id: stopped${forGood ? ' (no longer allowed)' : ''}');
    notifyListeners();
  }

  void _seen(TrustedDevice d) {
    final now = DateTime.now();
    if (_settings.remoteAlways.containsKey(d.id) && now.difference(_lastAt) > const Duration(minutes: 10)) {
      unawaited(_settings.update((x) => x.remoteAlways[d.id] = now.millisecondsSinceEpoch));
    }
    _lastAt = now;
    if (activeId != d.id) {
      activeId = d.id;
      activeName = d.name;
      notifyListeners();
    }
    _idle?.cancel();
    _idle = Timer(const Duration(minutes: 2), () {
      activeId = null;
      activeName = null;
      notifyListeners();
    });
  }

  Future<RemoteGrant> _askOnce(TrustedDevice d) {
    final r = _refused[d.id];
    if (r != null && DateTime.now().difference(r) < const Duration(minutes: 1)) return Future.value(RemoteGrant.no);
    return _asking[d.id] ??= () async {
      final a = ask;
      final g = a == null ? RemoteGrant.no : await a(d.name);
      final now = DateTime.now();
      switch (g) {
        case RemoteGrant.once:
          _until[d.id] = now.add(const Duration(minutes: 30));
        case RemoteGrant.hour:
          _until[d.id] = now.add(const Duration(hours: 1));
        case RemoteGrant.always:
          await _settings.update((x) => x.remoteAlways[d.id] = now.millisecondsSinceEpoch);
        case RemoteGrant.no:
          _refused[d.id] = now;
      }
      DiagLog.log('remote', '${d.name}: ${g.name}');
      return g;
    }().whenComplete(() => _asking.remove(d.id));
  }

  /// Answers a phone's request under /api/v1/remote/.
  Future<void> handle(HttpRequest req, TrustedDevice d, String path) async {
    final res = req.response;
    final what = path.substring(LrProtocol.pathRemote.length + 1);
    final stopped = _stopped[d.id];
    if (stopped != null && DateTime.now().difference(stopped) < const Duration(minutes: 10)) {
      await req.drain<void>();
      return _json(res, 403, {'error': 'stopped'});
    }
    if (!allowed(d.id)) {
      await req.drain<void>();
      // The first knock asks on the PC; the phone waits and knocks again.
      if (what == 'hello') unawaited(_askOnce(d));
      final refused = _refused[d.id] != null && DateTime.now().difference(_refused[d.id]!) < const Duration(minutes: 1);
      return _json(res, 403, {'error': refused ? 'refused' : 'asking'});
    }
    _seen(d);
    final q = req.uri.queryParameters;
    switch (what) {
      case 'hello':
        await req.drain<void>();
        return _json(res, 200, {'ok': true, 'pc': _settings.deviceName});
      case 'ui':
        await req.drain<void>();
        res.headers.contentType = ContentType.html;
        res.write(remotePage());
        return res.close();
      case 'files':
        await req.drain<void>();
        return _json(res, 200, await _files(q));
      case 'thumb':
      case 'file':
        await req.drain<void>();
        final p = q['p'] ?? '';
        if (!s.pcFiles.allowed(p)) {
          DiagLog.log('remote', '${d.name}: refused (not a listed file)');
          return _json(res, 404, {'error': 'not_found'});
        }
        if (what == 'file') {
          DiagLog.log('remote', '${d.name}: takes ${p.split(Platform.pathSeparator).last}');
          return s.server.serveFile(req, File(p));
        }
        final t = await thumb?.call(p);
        if (t == null) return _json(res, 404, {'error': 'no_picture'});
        res.headers.contentType = ContentType('image', 'jpeg');
        res.headers.set(HttpHeaders.cacheControlHeader, 'max-age=3600');
        await res.addStream(t.openRead());
        return res.close();
    }
    await req.drain<void>();
    return _json(res, 404, {'error': 'not_found'});
  }

  Future<Map<String, Object?>> _files(Map<String, String> q) async {
    final pc = s.pcFiles;
    await pc.list(fresh: q['fresh'] == '1');
    final words = (q['q'] ?? '').trim();
    List<PcFile> base = pc.files;
    if (q['inside'] == '1' && words.isNotEmpty) base = await pc.searchInside(words) ?? pc.files;
    final kinds = (q['kinds'] ?? '').split(',').where((e) => e.isNotEmpty).toSet();
    final now = DateTime.now();
    bool when(PcFile f) {
      final t = f.when;
      return switch (q['when']) {
        'week' => now.difference(t).inDays < 7,
        'month' => t.year == now.year && t.month == now.month,
        'year' => t.year == now.year,
        'last_year' => t.year == now.year - 1,
        _ => true,
      };
    }

    const mb = 1024 * 1024;
    bool size(PcFile f) => switch (q['size']) {
          'small' => f.size < mb,
          'medium' => f.size >= mb && f.size < 100 * mb,
          'big' => f.size >= 100 * mb && f.size < 1024 * mb,
          'huge' => f.size >= 1024 * mb,
          _ => true,
        };
    final place = (q['place'] ?? '').toLowerCase();
    final w = words.toLowerCase();
    final list = [
      for (final f in base)
        if ((kinds.isEmpty || kinds.contains(f.kind?.name)) &&
            when(f) &&
            size(f) &&
            (place.isEmpty || f.path.toLowerCase().startsWith('$place\\')) &&
            (q['inside'] == '1' || w.isEmpty || f.name.toLowerCase().contains(w)))
          f,
    ];
    switch (q['sort']) {
      case 'oldest':
        list.sort((a, b) => a.when.compareTo(b.when));
      case 'name':
        list.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
      case 'biggest':
        list.sort((a, b) => b.size.compareTo(a.size));
      default:
        list.sort((a, b) => b.when.compareTo(a.when));
    }
    final offset = int.tryParse(q['offset'] ?? '') ?? 0;
    final limit = (int.tryParse(q['limit'] ?? '') ?? 100).clamp(1, 500);
    return {
      'total': list.length,
      'source': pc.source.name,
      'files': [for (final f in list.skip(offset).take(limit)) f.toJson()],
      'places': [
        for (final p in [...PcFiles.usualFolders(), ..._settings.pcFilesExtra]) {'path': p, 'name': p.split(Platform.pathSeparator).last},
      ],
    };
  }

  static Future<void> _json(HttpResponse res, int status, Object body) async {
    res.statusCode = status;
    res.headers.contentType = ContentType.json;
    res.write(jsonEncode(body));
    await res.close();
  }
}
