// apps/desktop/lib/app_services.dart
import 'package:flutter/foundation.dart';

import 'server/transfer_server.dart';
import 'services/converter.dart';
import 'services/ffmpeg.dart';
import 'services/library_index.dart';
import 'services/network.dart';
import 'services/receive_hub.dart';
import 'services/settings.dart';

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

  /// LAN addresses shown in the QR code; refreshed on the receive page.
  final ValueNotifier<List<String>> addresses = ValueNotifier(const []);

  static Future<AppServices> create() async {
    final settings = await AppSettings.load();
    final library = LibraryIndex(settings.libraryPath);
    await library.load();
    final hub = ReceiveHub();
    final server = TransferServer(settings: settings, library: library, hub: hub);
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

  /// Clean exit: unregister from mDNS (so phones don't see a stale PC) and
  /// close the listening socket.
  Future<void> shutdown() async {
    try {
      await mdns.stop().timeout(const Duration(seconds: 2));
    } catch (_) {}
    try {
      await server.stop().timeout(const Duration(seconds: 2));
    } catch (_) {}
  }

  Future<void> changeLibrary(String path) async {
    await settings.update((s) => s.libraryPath = path);
    await library.changeRoot(path);
  }
}
