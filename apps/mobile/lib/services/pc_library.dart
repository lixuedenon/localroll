// apps/mobile/lib/services/pc_library.dart
import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:localroll_core/localroll_core.dart';

import '../l10n/l10n.dart';
import 'discovery.dart';
import 'mobile_settings.dart';
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
  }

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

  /// Shown: everything (null), photos or videos.
  MediaKind? kind;

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
    notifyListeners();
    await loadMore();
  }

  Future<void> loadMore() async {
    final at = _next;
    if (loading || at == null) return;
    loading = true;
    notifyListeners();
    try {
      final c = await _connect();
      final page = await c.library(offset: at, limit: 300, kind: kind);
      items.addAll(page.items);
      total = page.total;
      access = page.access;
      discovery.accessAt[desktop.id] = page.access;
      _next = page.next;
      error = null;
    } catch (e) {
      error = describe(e);
      _drop();
    } finally {
      loading = false;
      notifyListeners();
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

  // ---------------------------------------------------------- actions

  /// The PC sends these here, converted to what this phone plays; they
  /// arrive in the album "LocalRoll" (no "Accept" question: we asked).
  Future<int> saveToPhone(List<String> paths) async {
    server.expectFrom(desktop.id);
    return (await _connect()).librarySend(paths);
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
        );
      }
    }
    notifyListeners();
    return n;
  }

  // ---------------------------------------------------------- video relay

  HttpServer? _relay;

  /// A plain local address the system player can open for [path].
  Future<Uri> playable(String path) async {
    final r = _relay ??= await _startRelay();
    return Uri(scheme: 'http', host: '127.0.0.1', port: r.port, path: '/v', queryParameters: {'p': path});
  }

  Future<HttpServer> _startRelay() async {
    final s = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    s.listen((req) async {
      final res = req.response;
      try {
        final path = req.uri.queryParameters['p'];
        if (path == null || req.uri.path != '/v') {
          res.statusCode = 404;
          return await res.close();
        }
        final c = await _connect();
        final up = await c.open(c.libraryFileUri(path), range: req.headers.value(HttpHeaders.rangeHeader));
        res.statusCode = up.statusCode;
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
