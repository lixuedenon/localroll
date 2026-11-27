// apps/mobile/lib/services/remote_pc.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:localroll_core/localroll_core.dart';
import 'package:path_provider/path_provider.dart';

import 'discovery.dart';
import 'mobile_settings.dart';

/// Where the PC stands on this phone controlling it.
enum RemoteState { ok, asking, refused, stopped, plain, offline }

/// This phone controlling a PC (after the PC allowed it once): the PC
/// makes the pages and does the work; this phone only shows them. A small
/// relay here (127.0.0.1 only, behind a fresh secret) passes the page's
/// requests to the PC over the pinned HTTPS link with this phone's sign-in.
class RemotePc {
  RemotePc({required this.settings, required this.discovery, required this.desktop});

  final MobileSettings settings;
  final DesktopDiscovery discovery;
  final PairedDesktop desktop;

  LrClient? _client;
  HttpServer? _relay;
  final String _key = _secret();

  static String _secret() {
    final r = Random.secure();
    return List.generate(32, (_) => r.nextInt(16).toRadixString(16)).join();
  }

  Future<LrClient> _connect() async {
    final c = _client;
    if (c != null) return c;
    final d = await connectToDesktop(settings, desktop, discovered: discovery.found);
    try {
      if (!d.secure || d.pin == null) throw const _Plain();
      return _client = LrClient(host: d.host, port: d.port, deviceId: settings.deviceId, token: d.token, secure: true, pin: d.pin);
    } finally {
      d.close();
    }
  }

  Uri _remote(String what, [Map<String, String>? query]) {
    final c = _client!;
    return Uri(scheme: 'https', host: c.host, port: c.port, path: '${LrProtocol.pathRemote}/$what', queryParameters: query);
  }

  /// Knocks: the first time the PC asks its person, the phone waits.
  Future<RemoteState> hello() async {
    try {
      final c = await _connect();
      final res = await c.open(_remote('hello'));
      final text = await utf8.decoder.bind(res).join();
      if (res.statusCode == 200) return RemoteState.ok;
      final e = (() {
        try {
          return (jsonDecode(text) as Map)['error'];
        } catch (_) {
          return null;
        }
      })();
      return switch (e) {
        'refused' => RemoteState.refused,
        'stopped' => RemoteState.stopped,
        'asking' => RemoteState.asking,
        _ => res.statusCode == 404 ? RemoteState.offline : RemoteState.asking,
      };
    } on _Plain {
      return RemoteState.plain;
    } catch (e) {
      DiagLog.log('remote', 'hello failed: $e');
      _drop();
      return RemoteState.offline;
    }
  }

  /// The page to show (through the relay).
  Future<Uri> page() async {
    final r = _relay ??= await _startRelay();
    return Uri(scheme: 'http', host: '127.0.0.1', port: r.port, path: '/r/$_key/ui');
  }

  /// A file of the PC, for players that read by address (videos).
  Future<Uri> fileUri(String path) async {
    final r = _relay ??= await _startRelay();
    return Uri(scheme: 'http', host: '127.0.0.1', port: r.port, path: '/r/$_key/file', queryParameters: {'p': path});
  }

  /// A copy of the PC's file [path] here (temporary folder).
  Future<File> fetch(String path, String name, {void Function(int got, int all)? progress}) async {
    final c = await _connect();
    final dir = Directory('${(await getTemporaryDirectory()).path}/pcfiles');
    await dir.create(recursive: true);
    final f = File('${dir.path}/${name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_')}');
    final res = await c.open(_remote('file', {'p': path}));
    if (res.statusCode >= 400) {
      await res.drain<void>();
      throw LrHttpError(res.statusCode, const {'error': 'not_fetched'});
    }
    final all = res.contentLength;
    var got = 0;
    final sink = f.openWrite();
    try {
      await for (final chunk in res) {
        sink.add(chunk);
        got += chunk.length;
        progress?.call(got, all);
      }
    } finally {
      await sink.close();
    }
    DiagLog.log('remote', 'fetched .${name.split('.').last}: $got bytes');
    return f;
  }

  Future<HttpServer> _startRelay() async {
    final s = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final prefix = '/r/$_key/';
    s.listen((req) async {
      final res = req.response;
      try {
        // Other apps on this phone can reach 127.0.0.1 too: only addresses
        // with this secret are passed on, and only to the remote pages.
        if (!req.uri.path.startsWith(prefix) || req.method != 'GET') {
          res.statusCode = 404;
          return await res.close();
        }
        final what = req.uri.path.substring(prefix.length);
        final c = await _connect();
        final up = await c.open(_remote(what, req.uri.queryParameters.isEmpty ? null : req.uri.queryParameters),
            range: req.headers.value(HttpHeaders.rangeHeader));
        res.statusCode = up.statusCode;
        for (final h in [
          HttpHeaders.contentTypeHeader,
          HttpHeaders.contentRangeHeader,
          HttpHeaders.acceptRangesHeader,
          HttpHeaders.cacheControlHeader,
        ]) {
          final v = up.headers.value(h);
          if (v != null) res.headers.set(h, v);
        }
        if (up.contentLength >= 0) res.contentLength = up.contentLength;
        await res.addStream(up);
        await res.close();
      } catch (e) {
        DiagLog.log('remote', 'relay: $e');
        _drop();
        try {
          res.statusCode = 502;
          await res.close();
        } catch (_) {}
      }
    });
    return s;
  }

  void _drop() {
    _client?.close();
    _client = null;
  }

  void close() {
    unawaited(_relay?.close(force: true));
    _relay = null;
    _drop();
  }
}

class _Plain implements Exception {
  const _Plain();
}
