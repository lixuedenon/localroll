// packages/core/lib/src/live.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'models.dart';
import 'protocol.dart';
import 'tls.dart';

/// Live presence: one long-lived WebSocket from a device to each paired PC
/// (`/api/v1/live`, signed in like any other request).
///
/// While the connection is open both sides know the other is there. When an
/// app ends — closed, swiped away, crashed — its system closes the
/// connection, so the other side knows at once; a lost Wi-Fi is noticed by
/// the ping/pong every few seconds. No polling.
///
/// Messages (JSON, PC → device):
///   {"t":"hello","family":bool,"online":[OnlineDevice…]}  right after connecting
///   {"t":"up","d":OnlineDevice}   another paired device came online
///   {"t":"down","id":"…"}         … went offline
///   {"t":"you","family":bool}     this device was moved in / out of the family group
class LiveMessage {
  const LiveMessage(this.type, this.json);

  final String type;
  final Map<String, dynamic> json;

  static LiveMessage? parse(Object? data) {
    if (data is! String) return null;
    try {
      final j = jsonDecode(data);
      if (j is! Map<String, dynamic>) return null;
      return LiveMessage(j['t'] as String? ?? '', j);
    } catch (_) {
      return null;
    }
  }

  static String hello({required bool family, required List<OnlineDevice> online}) =>
      jsonEncode({'t': 'hello', 'family': family, 'online': [for (final d in online) d.toJson()]});
  static String up(OnlineDevice d) => jsonEncode({'t': 'up', 'd': d.toJson()});
  static String down(String id) => jsonEncode({'t': 'down', 'id': id});
  static String you({required bool family}) => jsonEncode({'t': 'you', 'family': family});

  List<OnlineDevice> get online => OnlineDevice.listFrom(json);
  OnlineDevice? get device {
    final d = json['d'];
    return d is Map<String, dynamic> ? OnlineDevice.fromJson(d) : null;
  }

  String? get id => json['id'] as String?;
  bool? get family => json['family'] as bool?;
}

/// Ping interval on both ends: a dead link (Wi-Fi gone, phone switched off)
/// is closed after about two missed pongs.
const Duration livePingInterval = Duration(seconds: 8);

/// The device side of a live link to one PC: connects, keeps reconnecting
/// while [start]ed (backing off up to 30 s), reports messages and whether it
/// is connected. Pure dart:io (used by the phone and by other PCs).
class LiveLink {
  LiveLink({
    required this.deviceId,
    required this.onMessage,
    required this.onConnected,
  });

  final String deviceId;

  /// A message from the PC.
  final void Function(LiveMessage m) onMessage;

  /// Connected (true) / lost (false). Called on every change.
  final void Function(bool connected) onConnected;

  WebSocket? _ws;
  bool _running = false;
  Timer? _retry;
  int _failures = 0;

  /// Where to connect; asked again before each attempt (the address may
  /// have changed). Null = not known now.
  Future<LiveTarget?> Function()? target;

  /// Sent with each connection; new each time the app opens or comes back.
  String session = '';

  bool get connected => _ws != null;

  void start() {
    if (_running) return;
    _running = true;
    _failures = 0;
    unawaited(_connect());
  }

  /// Closes the link (the PC sees us leave at once) and stops reconnecting.
  Future<void> stop() async {
    _running = false;
    _retry?.cancel();
    _retry = null;
    final ws = _ws;
    _ws = null;
    if (ws != null) {
      onConnected(false);
      try {
        await ws.close(WebSocketStatus.normalClosure).timeout(const Duration(seconds: 1));
      } catch (_) {}
    }
  }

  /// Reconnect now (e.g. the address became known).
  void kick() {
    if (!_running || _ws != null) return;
    _retry?.cancel();
    _failures = 0;
    unawaited(_connect());
  }

  bool _connecting = false;

  Future<void> _connect() async {
    if (_connecting || !_running || _ws != null) return;
    _connecting = true;
    try {
      final t = await target?.call();
      if (t == null) {
        _scheduleRetry();
        return;
      }
      final uri = Uri(
        scheme: t.secure ? 'wss' : 'ws',
        host: t.host,
        port: t.port,
        path: LrProtocol.pathLive,
        queryParameters: {'session': session},
      );
      final client = t.secure ? lrHttpClient(pin: t.pin) : (HttpClient()..connectionTimeout = const Duration(seconds: 4));
      final ws = await WebSocket.connect(
        uri.toString(),
        headers: {LrProtocol.headerDeviceId: deviceId, LrProtocol.headerToken: t.token},
        customClient: client,
      ).timeout(const Duration(seconds: 6));
      if (!_running) {
        await ws.close();
        return;
      }
      ws.pingInterval = livePingInterval;
      _ws = ws;
      _failures = 0;
      onConnected(true);
      ws.listen(
        (data) {
          final m = LiveMessage.parse(data);
          if (m != null) onMessage(m);
        },
        onDone: () => _lost(ws),
        onError: (_) => _lost(ws),
        cancelOnError: true,
      );
    } catch (_) {
      _scheduleRetry();
    } finally {
      _connecting = false;
    }
  }

  void _lost(WebSocket ws) {
    if (_ws != ws) return;
    _ws = null;
    onConnected(false);
    _scheduleRetry();
  }

  void _scheduleRetry() {
    if (!_running) return;
    _failures++;
    final s = [1, 2, 4, 8, 15, 30][_failures.clamp(1, 6) - 1];
    _retry?.cancel();
    _retry = Timer(Duration(seconds: s), () => unawaited(_connect()));
  }
}

class LiveTarget {
  const LiveTarget({required this.host, required this.port, required this.token, this.secure = false, this.pin});

  final String host;
  final int port;
  final String token;
  final bool secure;
  final String? pin;
}
