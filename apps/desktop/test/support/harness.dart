// apps/desktop/test/support/harness.dart
//
// A real PC receiver for tests: settings, certificate and library in a
// temporary folder, listening on a free port, driven over pinned HTTPS.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:localroll_core/localroll_core.dart';
import 'package:localroll_desktop/server/transfer_server.dart';
import 'package:localroll_desktop/services/library_index.dart';
import 'package:localroll_desktop/services/receive_hub.dart';
import 'package:localroll_desktop/services/settings.dart';
import 'package:localroll_desktop/services/tls_identity.dart';

/// One PC under test.
class TestPc {
  TestPc._(this.tmp, this.settings, this.tls, this.library, this.server);

  final Directory tmp;
  final AppSettings settings;
  final TlsIdentity tls;
  final LibraryIndex library;
  final TransferServer server;

  /// What the fake disk reports as free (bytes).
  static int free = 100 * 1024 * 1024 * 1024;

  static Future<TestPc> start() async {
    final tmp = await Directory.systemTemp.createTemp('lr_server_test');
    final sep = Platform.pathSeparator;
    final settings = await AppSettings.loadFrom(Directory('${tmp.path}${sep}data'));
    settings.port = 0; // any free port
    settings.libraryPath = '${tmp.path}${sep}Library';
    final tls = await TlsIdentity.load(settings.dataDir);
    settings.tlsFingerprint = tls.fingerprint;
    final library = LibraryIndex(settings.libraryPath, stateFile: settings.libraryStateFile);
    await library.load();
    final server = TransferServer(
      settings: settings,
      library: library,
      hub: ReceiveHub(),
      tls: tls,
      freeSpace: (_) async => free,
    );
    await server.start();
    expect(server.running, isTrue, reason: server.error);
    return TestPc._(tmp, settings, tls, library, server);
  }

  Future<void> close() async {
    await server.stop();
    server.dispose();
    library.dispose();
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  }

  int get port => server.port;

  /// A raw request (for routes the client has no method for, and for
  /// things a well-behaved client never sends).
  Future<(int, Map<String, dynamic>)> call(
    String method,
    String path, {
    Object? json,
    List<int>? bytes,
    String? id,
    String? token,
    bool secure = true,
    Map<String, String>? query,
  }) async {
    final client = secure ? lrHttpClient(pin: tls.fingerprint) : HttpClient();
    try {
      final uri = Uri(
        scheme: secure ? 'https' : 'http',
        host: '127.0.0.1',
        port: port,
        path: path,
        queryParameters: query,
      );
      final req = await client.openUrl(method, uri);
      if (id != null) req.headers.set(LrProtocol.headerDeviceId, id);
      if (token != null) req.headers.set(LrProtocol.headerToken, token);
      if (json != null) {
        req.headers.contentType = ContentType.json;
        req.add(utf8.encode(jsonEncode(json)));
      }
      if (bytes != null) req.add(bytes);
      final res = await req.close();
      final text = await utf8.decoder.bind(res).join();
      return (res.statusCode, text.isEmpty ? <String, dynamic>{} : jsonDecode(text) as Map<String, dynamic>);
    } finally {
      client.close(force: true);
    }
  }

  /// Pairs a phone with the PIN on screen (over HTTPS); returns its client.
  Future<TestPhone> pairPhone({String id = 'phone1', String name = 'Test iPhone', String platform = 'ios'}) async {
    final (status, body) = await call('POST', LrProtocol.pathPair,
        json: PairRequest(device: DeviceInfo(id: id, name: name, platform: platform), pin: server.pin.value).toJson());
    expect(status, 200, reason: '$body');
    final token = body['token'] as String;
    return TestPhone(this, id, token);
  }

  String abs(String rel) => '${library.rootPath}${Platform.pathSeparator}${rel.replaceAll('/', Platform.pathSeparator)}';
}

class TestPhone {
  TestPhone(this.pc, this.id, this.token)
      : client = LrClient(host: '127.0.0.1', port: pc.port, deviceId: id, token: token, secure: true, pin: pc.tls.fingerprint);

  final TestPc pc;
  final String id;
  final String token;
  final LrClient client;

  Future<(int, Map<String, dynamic>)> call(String method, String path, {Object? json, List<int>? bytes, Map<String, String>? query}) =>
      pc.call(method, path, json: json, bytes: bytes, query: query, id: id, token: token);

  /// Offers one file and sends it completely (as the phone does).
  Future<CompleteResponse> upload(
    String asset,
    List<int> data, {
    String name = 'IMG_0001.JPG',
    MediaKind kind = MediaKind.image,
    DateTime? captured,
    bool private = false,
  }) async {
    final at = (captured ?? DateTime(2024, 5, 17, 10, 30)).millisecondsSinceEpoch;
    final offer = FileOffer(
      id: 'f1',
      assetId: asset,
      name: name,
      kind: kind,
      createdMs: at,
      modifiedMs: at,
      size: data.length,
      private: private,
    );
    final s = await client.createSession(SessionRequest(files: [offer]));
    final r = s.results['f1']!;
    if (r.status == OfferStatus.duplicate) return const CompleteResponse(saved: true);
    var off = r.offset;
    if (off < data.length) off = await client.putChunk(s.sessionId, 'f1', off, data.length, data.sublist(off));
    expect(off, data.length);
    return client.complete(s.sessionId, 'f1', CompleteRequest(size: data.length, sha256: await sha(data)));
  }
}

Future<String> sha(List<int> data) async {
  final dir = await Directory.systemTemp.createTemp('lr_sha');
  try {
    final f = File('${dir.path}${Platform.pathSeparator}x');
    await f.writeAsBytes(data);
    return await sha256OfFile(f);
  } finally {
    await dir.delete(recursive: true);
  }
}

List<int> bytesOf(int n, [int seed = 1]) => List.generate(n, (i) => (i * 31 + seed) & 0xff);

/// Waits until [check] holds (presence changes arrive asynchronously).
Future<void> eventually(bool Function() check, {Duration within = const Duration(seconds: 5)}) async {
  final end = DateTime.now().add(within);
  while (!check()) {
    if (DateTime.now().isAfter(end)) throw StateError('Error: condition not met within $within');
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
}

