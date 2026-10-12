// apps/desktop/lib/app_services.dart
import 'package:flutter/foundation.dart';

import 'server/transfer_server.dart';
import 'services/converter.dart';
import 'services/ffmpeg.dart';
import 'services/library_index.dart';
import 'services/network.dart';
import 'services/peers.dart';
import 'services/receive_hub.dart';
import 'services/settings.dart';
import 'services/tls_identity.dart';

/// Owns every long-lived service; created once in main().
class AppServices {
  AppServices._({
    required this.settings,
    required this.library,
    required this.hub,
    required this.server,
    required this.ffmpeg,
    required this.converter,
  });

  final AppSettings settings;
  final LibraryIndex library;
  final ReceiveHub hub;
  final TransferServer server;
  final FfmpegService ffmpeg;
  final ConverterService converter;
  final MdnsAdvertiser mdns = MdnsAdvertiser();

  /// Other PCs: finding, pairing, sending.
  late final PeerDirectory peers = PeerDirectory(settings: settings, server: server);
  late final PeerSender sender = PeerSender(settings: settings, peers: peers);

  /// LAN addresses shown in the QR code; refreshed on the receive page.
  final ValueNotifier<List<String>> addresses = ValueNotifier(const []);

  static Future<AppServices> create() async {
    final settings = await AppSettings.load();
    final library = LibraryIndex(settings.libraryPath, stateFile: settings.libraryStateFile);
    // Documents / other files from PCs live beside the photos, not in the library view.
    library.ignoredFolders = {?settings.docsFolder, ?settings.otherFolder};
    await library.load();
    final hub = ReceiveHub();
    // HTTPS certificate (made on first start, a few seconds once).
    TlsIdentity? tls;
    try {
      tls = await TlsIdentity.load(settings.dataDir);
      settings.tlsFingerprint = tls.fingerprint;
    } catch (e) {
      debugPrint('TLS certificate unavailable, plain HTTP only: $e');
    }
    final server = TransferServer(settings: settings, library: library, hub: hub, tls: tls);
    final ffmpeg = FfmpegService(settings, library);
    final converter = ConverterService(ffmpeg, library);
    final s = AppServices._(
      settings: settings,
      library: library,
      hub: hub,
      server: server,
      ffmpeg: ffmpeg,
      converter: converter,
    );
    await s.startNetworking();
    await ffmpeg.locate();
    return s;
  }

  Future<void> startNetworking() async {
    await server.start();
    await refreshAddresses();
    if (server.running) {
      await mdns.start(name: settings.deviceName, deviceId: settings.deviceId, port: server.port);
    }
  }

  Future<void> refreshAddresses() async {
    try {
      addresses.value = await localIPv4Addresses();
    } catch (_) {
      addresses.value = const [];
    }
  }

  /// Name / icon / colour / picture changed: save and re-announce on the LAN
  /// (phones read the new look from /info and /avatar).
  Future<void> updateIdentity({
    String? name,
    String? icon,
    int? color,
    Uint8List? avatarPng,
    bool removeAvatar = false,
  }) async {
    if (avatarPng != null) await settings.avatarFile.writeAsBytes(avatarPng, flush: true);
    if (removeAvatar && await settings.avatarFile.exists()) await settings.avatarFile.delete();
    await settings.update((s) {
      if (name != null && name.trim().isNotEmpty) s.deviceName = name.trim();
      if (icon != null) s.iconKey = icon;
      if (color != null) s.colorValue = color;
      if (avatarPng != null) s.avatarVersion = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      if (removeAvatar) s.avatarVersion = 0;
    });
    if (server.running) {
      await mdns.start(name: settings.deviceName, deviceId: settings.deviceId, port: server.port);
    }
  }

  /// Clean exit: unregister from mDNS (so phones don't see a stale PC) and
  /// close the listening socket.
  /// Quick, in parallel, each step capped: the window is already hidden
  /// when this runs, so the user never waits on it. The library index is
  /// saved first (a pending save must not be lost on exit).
  Future<void> shutdown() async {
    Future<void> capped(Future<void> Function() f, int ms) async {
      try {
        await f().timeout(Duration(milliseconds: ms));
      } catch (_) {}
    }

    await capped(library.flush, 3000);
    peers.release();
    await Future.wait([
      capped(mdns.stop, 800),
      capped(server.stop, 800),
    ]);
  }

  Future<void> changeLibrary(String path) async {
    await settings.update((s) => s.libraryPath = path);
    await library.changeRoot(path);
  }
}
