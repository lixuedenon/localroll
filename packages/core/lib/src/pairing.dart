// packages/core/lib/src/pairing.dart
import 'dart:convert';

/// Content of the QR code shown by the desktop app.
///
/// Encoded as `LOCALROLL:` + base64url(JSON) so the phone can recognise it
/// and ignore unrelated QR codes.
class PairingPayload {
  const PairingPayload({
    required this.deviceId,
    required this.name,
    required this.hosts,
    required this.port,
    required this.pin,
    this.protocolVersion = 1,
  });

  static const String prefix = 'LOCALROLL:';

  final String deviceId;
  final String name;

  /// All LAN IPv4 addresses of the desktop; the phone tries each in order.
  final List<String> hosts;
  final int port;
  final String pin;
  final int protocolVersion;

  String encode() {
    final json = jsonEncode({
      'v': protocolVersion,
      'id': deviceId,
      'name': name,
      'hosts': hosts,
      'port': port,
      'pin': pin,
    });
    return prefix + base64Url.encode(utf8.encode(json));
  }

  /// Returns null when [text] is not a LocalRoll pairing code.
  static PairingPayload? tryDecode(String? text) {
    if (text == null || !text.startsWith(prefix)) return null;
    try {
      final raw = utf8.decode(base64Url.decode(base64Url.normalize(text.substring(prefix.length))));
      final j = jsonDecode(raw) as Map<String, dynamic>;
      return PairingPayload(
        deviceId: j['id'] as String,
        name: j['name'] as String? ?? 'PC',
        hosts: (j['hosts'] as List).cast<String>(),
        port: (j['port'] as num).toInt(),
        pin: j['pin'] as String,
        protocolVersion: (j['v'] as num?)?.toInt() ?? 1,
      );
    } catch (_) {
      return null;
    }
  }
}
