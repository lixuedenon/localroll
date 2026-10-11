// packages/core/lib/src/tls.dart
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;

/// Encrypted LAN transfers.
///
/// Every PC has its own self-signed certificate. A certificate signed by
/// nobody proves nothing by itself, so the phone (or the other PC) remembers
/// the certificate's fingerprint when pairing and from then on talks only to
/// a PC that presents exactly that certificate ("pinning"):
///   * QR code: the fingerprint is in the code itself;
///   * tap-to-pair: the three symbols both screens show are computed from
///     the fingerprint too, so someone in the middle would change them.

/// Lower-case hex SHA-256 of a certificate (DER bytes).
String certFingerprint(List<int> der) => crypto.sha256.convert(der).toString();

/// For people: the first 16 hex digits in groups of four ("3F2A 91C0 …").
String shortFingerprint(String fp) {
  final s = fp.toUpperCase();
  final head = s.length > 16 ? s.substring(0, 16) : s;
  return [for (var i = 0; i < head.length; i += 4) head.substring(i, (i + 4).clamp(0, head.length))].join(' ');
}

/// An HttpClient for LocalRoll peers.
///
/// With [pin], only a server whose certificate has that fingerprint is
/// accepted. Without it (first contact while pairing) any certificate is
/// accepted and reported to [onCertificate], so the caller can show it in
/// the pairing check and remember it.
HttpClient lrHttpClient({String? pin, void Function(String fingerprint)? onCertificate}) {
  final c = HttpClient()
    ..connectionTimeout = const Duration(seconds: 4)
    ..idleTimeout = const Duration(seconds: 30);
  c.badCertificateCallback = (X509Certificate cert, String host, int port) {
    final fp = certFingerprint(cert.der);
    onCertificate?.call(fp);
    return pin == null ? onCertificate != null : fp == pin.toLowerCase();
  };
  return c;
}

/// Addresses LocalRoll answers: this computer, home/office networks, and
/// "100.64.x.x" overlay networks (Tailscale & co.). Anything else is the
/// open internet (e.g. a forwarded router port) and is refused.
bool isLanAddress(InternetAddress a) {
  if (a.isLoopback || a.isLinkLocal) return true;
  final b = a.rawAddress;
  if (a.type == InternetAddressType.IPv4) {
    if (b[0] == 10) return true;
    if (b[0] == 172 && b[1] >= 16 && b[1] <= 31) return true;
    if (b[0] == 192 && b[1] == 168) return true;
    if (b[0] == 100 && b[1] >= 64 && b[1] <= 127) return true;
    return false;
  }
  if (a.type == InternetAddressType.IPv6) {
    // IPv4-mapped (::ffff:a.b.c.d).
    final mapped = b.sublist(0, 10).every((x) => x == 0) && b[10] == 0xff && b[11] == 0xff;
    if (mapped) return isLanAddress(InternetAddress.fromRawAddress(b.sublist(12)));
    // Unique local fc00::/7.
    if ((b[0] & 0xfe) == 0xfc) return true;
    return false;
  }
  return false;
}
