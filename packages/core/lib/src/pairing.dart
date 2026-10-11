// packages/core/lib/src/pairing.dart
import 'dart:convert';

import 'package:crypto/crypto.dart' as crypto;

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
    this.tlsPort,
    this.fingerprint,
  });

  static const String prefix = 'LOCALROLL:';

  final String deviceId;
  final String name;

  /// All LAN IPv4 addresses of the desktop; the phone tries each in order.
  final List<String> hosts;
  final int port;
  final String pin;
  final int protocolVersion;

  /// HTTPS port and certificate fingerprint (newer PCs): the phone pairs
  /// over HTTPS and trusts only this certificate.
  final int? tlsPort;
  final String? fingerprint;

  String encode() {
    final json = jsonEncode({
      'v': protocolVersion,
      'id': deviceId,
      'name': name,
      'hosts': hosts,
      'port': port,
      'pin': pin,
      if (tlsPort != null) 'tls': tlsPort,
      if (fingerprint != null) 'fp': fingerprint,
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
        tlsPort: (j['tls'] as num?)?.toInt(),
        fingerprint: j['fp'] as String?,
      );
    } catch (_) {
      return null;
    }
  }
}

/// Three emoji derived from a pairing request id. Both the phone and the PC
/// show them, so the user can check they are approving their own phone.
/// Over HTTPS the PC's certificate [fingerprint] is mixed in: a device in
/// the middle with its own certificate makes the two screens differ.
List<String> pairingEmoji(String requestId, {String? fingerprint}) {
  final input = fingerprint == null ? 'localroll-pair|$requestId' : 'localroll-pair|$requestId|${fingerprint.toLowerCase()}';
  final h = crypto.sha256.convert(utf8.encode(input)).bytes;
  return [for (var i = 0; i < 3; i++) _emoji[h[i] % _emoji.length]];
}

// Distinct at a glance, no flags/faces/hands (skin tones, cultural meaning).
const List<String> _emoji = [
  '🍊', '🍋', '🍉', '🍇', '🍓', '🍒', '🥝', '🍍', '🥥', '🌽', '🥕', '🍄',
  '🌵', '🌲', '🌻', '🌷', '🍀', '🌙', '⭐', '☀️', '🌈', '❄️', '🔥', '💧',
  '⚓', '🚲', '🚀', '⛵', '🚂', '🎈', '🎁', '🎨', '🎸', '🎺', '🥁', '🎲',
  '🧩', '🪁', '🔔', '🔑', '💡', '📷', '📚', '✏️', '🧭', '⏰', '☂️', '🧸',
  '🐚', '🦋', '🐢', '🐬', '🦉', '🐝', '🦊', '🐧', '🐼', '🦒', '🐙', '🦜',
  '🏔️', '🏝️', '🌋', '🏰',
];
