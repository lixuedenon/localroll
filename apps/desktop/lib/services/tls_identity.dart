// apps/desktop/lib/services/tls_identity.dart
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:basic_utils/basic_utils.dart';
import 'package:localroll_core/localroll_core.dart';

/// This PC's own certificate for HTTPS (made once, kept next to settings).
///
/// Phones and other PCs remember its fingerprint when pairing and then
/// accept only this certificate, so nobody else on the network can read
/// or change what is sent.
class TlsIdentity {
  TlsIdentity._(this.certPem, this.keyPem) : fingerprint = certFingerprint(pemToDer(certPem));

  final String certPem;
  final String keyPem;

  /// Lower-case hex SHA-256 of the certificate.
  final String fingerprint;

  SecurityContext get context => SecurityContext(withTrustedRoots: false)
    ..useCertificateChainBytes(utf8.encode(certPem))
    ..usePrivateKeyBytes(utf8.encode(keyPem));

  /// Loads tls_cert.pem / tls_key.pem from [dir], creating them the first
  /// time. A damaged pair is replaced (paired devices then have to pair
  /// again — they see "certificate changed").
  static Future<TlsIdentity> load(Directory dir) async {
    final sep = Platform.pathSeparator;
    final certFile = File('${dir.path}${sep}tls_cert.pem');
    final keyFile = File('${dir.path}${sep}tls_key.pem');
    if (await certFile.exists() && await keyFile.exists()) {
      try {
        final id = TlsIdentity._(await certFile.readAsString(), await keyFile.readAsString());
        id.context; // throws if unusable
        return id;
      } catch (_) {}
    }
    // RSA key generation in pure Dart takes a few seconds: not on the UI thread.
    final (cert, key) = await Isolate.run(_generate);
    await dir.create(recursive: true);
    await keyFile.writeAsString(key, flush: true);
    await certFile.writeAsString(cert, flush: true);
    return TlsIdentity._(cert, key);
  }

  static (String, String) _generate() {
    final pair = CryptoUtils.generateRSAKeyPair(keySize: 2048);
    final priv = pair.privateKey as RSAPrivateKey;
    final pub = pair.publicKey as RSAPublicKey;
    final csr = X509Utils.generateRsaCsrPem({'CN': 'LocalRoll'}, priv, pub);
    // Long-lived on purpose: it is pinned, not checked against a date chain.
    final cert = X509Utils.generateSelfSignedCertificate(priv, csr, 365 * 30);
    return (cert, CryptoUtils.encodeRSAPrivateKeyToPem(priv));
  }
}

/// DER bytes of the first PEM block in [pem].
List<int> pemToDer(String pem) {
  final m = RegExp(r'-----BEGIN [^-]+-----([\s\S]*?)-----END [^-]+-----').firstMatch(pem);
  if (m == null) throw const FormatException('not PEM');
  return base64.decode(m.group(1)!.replaceAll(RegExp(r'\s'), ''));
}
