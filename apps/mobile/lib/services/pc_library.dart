// apps/mobile/lib/services/pc_library.dart
import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:localroll_core/localroll_core.dart';
import 'package:path_provider/path_provider.dart';

import '../l10n/l10n.dart';
import 'discovery.dart';
import 'live_service.dart';
import 'media_saver.dart';
import 'mobile_settings.dart';
import 'my_library.dart';
import 'phone_server.dart';

/// The PC's library as seen from this phone: pages of items (newest first),
/// pictures, and what the PC lets this phone do (look / delete).
///
/// Everything goes over the same pinned HTTPS link as transfers. Videos are
/// played through a small relay on this phone (127.0.0.1 only) that signs
/// in and checks the PC's certificate — the system player can't do either.
class PcLibrary extends ChangeNotifier {
  PcLibrary({required this.settings, required this.discovery, required this.desktop, required this.server}) {
    discovery.addListener(_onDiscovery);
    _addedSub = LiveService.added.where((id) => id == desktop.id).listen((_) => _onAdded());
    _changedSub = LiveService.libraryChanged.where((id) => id == desktop.id).listen((_) => _onChanged());
  }

  StreamSubscription<String>? _addedSub;
  StreamSubscription<String>? _changedSub;
  Timer? _changedSoon;

  /// Who may see what changed, or something was deleted: loaded again at
  /// once, wherever the person is (hidden items must not stay on screen).
  void _onChanged() {
    _changedSoon?.cancel();
    _changedSoon = Timer(const Duration(milliseconds: 300), () {
      if (!_disposed) unawaited(reload(keep: true));
    });
  }
  Timer? _addedSoon;

  /// The PC got something new (told over the live link). Looking at the
  /// top (only the first page loaded) and not holding a place: the list
  /// is loaded again in place. Otherwise [newer] shows a "new — tap to
  /// refresh" note, so nothing moves under the person's finger.
  void _onAdded() {
    _addedSoon?.cancel();
    _addedSoon = Timer(const Duration(milliseconds: 600), () {
      if (_disposed) return;
      if (hold || items.length > _pageSize || loading) {
        newer = true;
        notifyListeners();
      } else {
        unawaited(reload());
      }
    });
  }

  /// Something new on the PC since this list was loaded.
  bool newer = false;

  /// Set while one item is open full screen (the list must not change).
  bool hold = false;

  bool _disposed = false;
  static const int _pageSize = 300;

  /// The PC changed what this phone may do (told over the live link): the
  /// delete button appears / goes without a pull-down.
  void _onDiscovery() {
    final a = discovery.accessAt[desktop.id];
    if (a == null || a == access) return;
    final wasNone = access == LibraryAccess.none;
    access = a;
    if (a == LibraryAccess.none || wasNone) {
      unawaited(refresh());
    } else {
      notifyListeners();
    }
  }

  final MobileSettings settings;
  final DesktopDiscovery discovery;
  final PairedDesktop desktop;
  final PhoneServer server;

  final List<RemoteItem> items = [];
  int total = 0;
  int? _next = 0;
  bool loading = false;
  String? error;
  LibraryAccess access = LibraryAccess.view;

  /// Shown: everything (null), photos, videos or files ([MediaKind.other]).
  MediaKind? kind;

  /// Newest arrival first (false: newest taken first).
  bool byReceived = false;

  /// Only what has these words in its text (read on the PC) or name.
  String query = '';

  /// How many arrived on the PC in the last day (0: none, or an older PC).
  int recent = 0;

  bool get hasMore => _next != null;
  bool get canDelete => access == LibraryAccess.manage;

  LrClient? _client;

  Future<LrClient> _connect() async {
    final c = _client;
    if (c != null) return c;
    final d = await connectToDesktop(settings, desktop, discovered: discovery.found);
    try {
      // Browsing is HTTPS only (an old plain pairing must be renewed first).
      if (!d.secure || d.pin == null) throw const _Plain();
      return _client = LrClient(
        host: d.host,
        port: d.port,
        deviceId: settings.deviceId,
        token: d.token,
        secure: true,
        pin: d.pin,
      );
    } finally {
      d.close();
    }
  }

  void _drop() {
    _client?.close();
    _client = null;
  }

  /// From the top again (after a filter change or a pull-down).
  Future<void> refresh() async {
    items.clear();
    total = 0;
    _next = 0;
    error = null;
    newer = false;
    notifyListeners();
    await loadMore();
  }

  /// The first page again, swapped in when it arrives (no blank list in
  /// between); on failure the old list stays.
  Future<void> reload({bool keep = false}) async {
    if (loading) {
      // Asked again when the page being loaded is in.
      if (keep) _onChanged();
      return;
    }
    loading = true;
    newer = false;
    notifyListeners();
    try {
      final c = await _connect();
      // [keep]: as many as are loaded now, so the list doesn't jump.
      final limit = keep ? items.length.clamp(_pageSize, LrProtocol.libraryPageMax) : _pageSize;
      final page = await c.library(offset: 0, limit: limit, kind: kind, byReceived: byReceived, query: query);
      items
        ..clear()
        ..addAll(page.items);
      _take(page);
    } catch (_) {
      newer = true;
      _drop();
    } finally {
      loading = false;
      if (!_disposed) notifyListeners();
    }
  }

  void _take(LibraryPage page) {
    total = page.total;
    recent = page.recent;
    access = page.access;
    discovery.accessAt[desktop.id] = page.access;
    _next = page.next;
    error = null;
  }

  Future<void> loadMore() async {
    final at = _next;
    if (loading || at == null) return;
    loading = true;
    notifyListeners();
    try {
      final c = await _connect();
      final page = await c.library(offset: at, limit: _pageSize, kind: kind, byReceived: byReceived, query: query);
      items.addAll(page.items);
      _take(page);
    } catch (e) {
      error = describe(e);
      _drop();
    } finally {
      loading = false;
      if (!_disposed) notifyListeners();
    }
  }

  /// Something the person can read.
  String describe(Object e) {
    if (e is _Plain) return tr('pclib.need_update');
    if (e is LrHttpError) {
      return switch (e.code) {
        'no_access' => tr('pclib.no_access', {'pc': desktop.name}),
        'library_offline' => tr('err.library_offline'),
        'upgrade_required' => tr('pclib.need_update'),
        'phone_closed' => tr('pclib.phone_closed'),
        // An older PC has no such page.
        'not_found' => tr('pclib.pc_too_old', {'pc': desktop.name}),
        _ => serverError(e.code),
      };
    }
    final s = e.toString();
    return s.startsWith('Exception: ') ? s.substring(11) : s;
  }

  static String serverError(String code) => translator.has('err.$code') ? tr('err.$code') : code;

  // ---------------------------------------------------------- pictures

  /// Recently used thumbnails (a few hundred), so scrolling back is instant.
  final LinkedHashMap<String, Future<Uint8List?>> _thumbs = LinkedHashMap();

  Future<Uint8List?> thumb(String path) {
    final hit = _thumbs.remove(path);
    if (hit != null) return _thumbs[path] = hit; // most recent last
    final f = () async {
      try {
        return await (await _connect()).libraryThumb(path);
      } catch (_) {
        _thumbs.remove(path); // try again next time
        return null;
      }
    }();
    _thumbs[path] = f;
    while (_thumbs.length > 600) {
      _thumbs.remove(_thumbs.keys.first);
    }
    return f;
  }

  /// A picture for the screen (any format, made into a JPEG on the PC).
  Future<Uint8List> view(String path) async => (await _connect()).libraryView(path);

  // ---------------------------------------------------------- files

  /// Largest file fetched just to draw its first page.
  static const int maxThumbFile = 30 * 1024 * 1024;

  final Map<String, Future<String>> _fetching = {};

  /// A copy of the received file [item] on this phone (kept a few days in
  /// the app's temporary folder, so it opens again at once): to draw its
  /// first page and to open it. Only over the same signed-in HTTPS link.
  Future<String> fetch(RemoteItem item) {
    final key = '${item.path}|${item.size}|${item.receivedMs}';
    return _fetching[key] ??= _fetch(item).whenComplete(() => _fetching.remove(key));
  }

  static Directory? _cacheDir;

  static Future<Directory> _cache() async {
    final known = _cacheDir;
    if (known != null) return known;
    final d = Directory('${(await getTemporaryDirectory()).path}/lr_pcfiles');
    await d.create(recursive: true);
    // Copies older than a few days go.
    try {
      final old = DateTime.now().subtract(const Duration(days: 3));
      await for (final e in d.list()) {
        try {
          if ((await e.stat()).modified.isBefore(old)) await e.delete(recursive: true);
        } catch (_) {}
      }
    } catch (_) {}
    return _cacheDir = d;
  }

  Future<String> _fetch(RemoteItem item) async {
    final id = Object.hash(desktop.id, item.path, item.size, item.receivedMs).toUnsigned(32).toRadixString(16);
    final dir = Directory('${(await _cache()).path}/$id');
    final name = item.name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    final f = File('${dir.path}/${name.isEmpty ? 'file' : name}');
    if (await f.exists() && await f.length() == item.size) return f.path;
    await dir.create(recursive: true);
    final c = await _connect();
    final res = await c.open(c.libraryFileUri(item.path));
    if (res.statusCode != 200) {
      await res.drain<void>();
      throw LrHttpError(res.statusCode, {'error': res.statusCode == 404 ? 'not_found' : 'HTTP ${res.statusCode}'});
    }
    final part = File('${f.path}.part');
    final sink = part.openWrite();
    try {
      await sink.addStream(res);
    } finally {
      await sink.close();
    }
    await part.rename(f.path);
    return f.path;
  }

  /// Into LocalRoll's own files on this phone (Documents / Other, under
  /// the PC's name), like a file the PC sent.
  Future<void> keepFile(RemoteItem item) async {
    final from = await fetch(item);
    final dir = await MediaSaver.folderFor(MyKind.ofName(item.name), Sender(desktop.id, desktop.name));
    final target = await MediaSaver.freeFile(dir, item.name);
    await File(from).copy(target.path);
    await MyLibrary.instance.addFile(target.path, MyKind.ofName(item.name), fromId: desktop.id, fromName: desktop.name);
  }

  // ---------------------------------------------------------- actions

  /// The PC sends these here, converted to what this phone plays; they
  /// arrive in the album "LocalRoll" (no "Accept" question: we asked).
  Future<int> saveToPhone(List<String> paths) async {
    final want = paths.toSet();
    final files = [for (final i in items) if (i.file && want.contains(i.path)) i];
    final media = [for (final p in paths) if (!files.any((f) => f.path == p)) p];
    var n = 0;
    if (media.isNotEmpty) {
      server.expectFrom(desktop.id);
      n += await (await _connect()).librarySend(media);
    }
    // Files are fetched here directly.
    for (final f in files) {
      await keepFile(f);
      n++;
    }
    return n;
  }

  /// To the PC's Recycle Bin (only when it allows this phone to).
  Future<int> delete(List<String> paths) async {
    final n = await (await _connect()).libraryDelete(paths);
    final gone = paths.toSet();
    final before = items.length;
    items.removeWhere((i) => gone.contains(i.path));
    total -= before - items.length;
    notifyListeners();
    return n;
  }

  /// "Only me" on / off for this phone's own items.
  Future<int> setPrivate(List<String> paths, bool private) async {
    final n = await (await _connect()).libraryVisibility(paths, private: private);
    final changed = paths.toSet();
    for (var k = 0; k < items.length; k++) {
      final i = items[k];
      if (i.mine && changed.contains(i.path)) {
        items[k] = RemoteItem(
          path: i.path,
          name: i.name,
          kind: i.kind,
          takenMs: i.takenMs,
          size: i.size,
          live: i.live,
          private: private,
          mine: true,
          from: i.from,
          receivedMs: i.receivedMs,
          file: i.file,
        );
      }
    }
    notifyListeners();
    return n;
  }

  // ---------------------------------------------------------- video relay

  HttpServer? _relay;

  /// Other apps on this phone can reach 127.0.0.1 too: only addresses
  /// carrying this secret (made fresh each time) are served.
  final String _relayKey = _secret();

  static String _secret() {
    final r = Random.secure();
    return List.generate(32, (_) => r.nextInt(16).toRadixString(16)).join();
  }

  /// A plain local address the system player can open for [path].
  Future<Uri> playable(String path) async {
    final r = _relay ??= await _startRelay();
    return Uri(scheme: 'http', host: '127.0.0.1', port: r.port, path: '/v/$_relayKey', queryParameters: {'p': path});
  }

  Future<HttpServer> _startRelay() async {
    final s = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    s.listen((req) async {
      final res = req.response;
      try {
        final path = req.uri.queryParameters['p'];
        if (path == null || req.uri.path != '/v/$_relayKey') {
          res.statusCode = 404;
          return await res.close();
        }
        final c = await _connect();
        final up = await c.open(c.libraryFileUri(path), range: req.headers.value(HttpHeaders.rangeHeader));
        res.statusCode = up.statusCode;
        if (up.statusCode >= 400) DiagLog.log('pclib', 'video relay: PC answered ${up.statusCode}');
        for (final h in [
          HttpHeaders.contentTypeHeader,
          HttpHeaders.contentRangeHeader,
          HttpHeaders.acceptRangesHeader,
        ]) {
          final v = up.headers.value(h);
          if (v != null) res.headers.set(h, v);
        }
        if (up.contentLength >= 0) res.contentLength = up.contentLength;
        await res.addStream(up);
        await res.close();
      } catch (e) {
        DiagLog.log('pclib', 'video relay: $e');
        try {
          res.statusCode = 502;
          await res.close();
        } catch (_) {}
      }
    });
    return s;
  }

  @override
  void dispose() {
    _disposed = true;
    _addedSoon?.cancel();
    _changedSoon?.cancel();
    unawaited(_addedSub?.cancel());
    unawaited(_changedSub?.cancel());
    discovery.removeListener(_onDiscovery);
    unawaited(_relay?.close(force: true));
    _relay = null;
    _drop();
    super.dispose();
  }
}

class _Plain implements Exception {
  const _Plain();
}
