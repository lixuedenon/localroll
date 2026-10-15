// apps/desktop/lib/app_services.dart
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:localroll_core/localroll_core.dart';

import 'server/transfer_server.dart';
import 'services/converter.dart';
import 'services/ffmpeg.dart';
import 'services/library_index.dart';
import 'services/network.dart';
import 'services/peers.dart';
import 'services/phone_formats.dart';
import 'services/receive_hub.dart';
import 'services/settings.dart';
import 'services/tls_identity.dart';

/// A paired device came online / went offline.
class PresenceEvent {
  const PresenceEvent(this.id, {required this.online, this.again = false});

  final String id;
  final bool online;

  /// Closed and opened again before it counted as gone.
  final bool again;
}

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

  /// A paired phone or PC is reachable right now: it said "I'm here" or
  /// checked in within the last ~2.5 min (devices do every minute while
  /// LocalRoll is open, and say "I'm leaving" when it closes), or we
  /// reached it ourselves (other PCs).
  bool isOnline(String deviceId) => server.isOnline(deviceId) || peers.isOnline(deviceId);

  /// Paired devices online now, by id.
  Set<String> get onlineDevices => {
        for (final id in {...settings.trusted.keys, ...settings.peers.keys})
          if (isOnline(id)) id,
      };

  // ------------------------------------------------------------- presence

  final StreamController<PresenceEvent> _presence = StreamController.broadcast();

  /// Every change, one by one: a device came online, went offline, or was
  /// closed and opened again quickly ([PresenceEvent.again]).
  Stream<PresenceEvent> get presenceEvents => _presence.stream;
  Set<String> _onlineSeen = {};

  void _recomputePresence() {
    final now = onlineDevices;
    for (final id in now.difference(_onlineSeen)) {
      _presence.add(PresenceEvent(id, online: true));
    }
    for (final id in _onlineSeen.difference(now)) {
      _presence.add(PresenceEvent(id, online: false));
    }
    _onlineSeen = now;
  }

  /// A paired phone that can receive right now (LocalRoll open on it, new
  /// enough), as a send target; null otherwise.
  PeerPc? phoneTarget(String id) {
    final t = settings.trusted[id];
    final ep = server.phoneEndpoint(id);
    if (t == null || ep == null) return null;
    return PeerPc(
      id: id,
      name: t.name,
      hosts: [ep.host],
      port: ep.port,
      token: '',
      pairedMs: t.pairedMs,
      lastHost: ep.host,
      fingerprint: ep.fingerprint,
    );
  }

  /// Paired phones, those that can receive now first.
  List<TrustedDevice> get phones => settings.trusted.values.where((t) => !isDesktopPlatform(t.platform)).toList()
    ..sort((a, b) {
      final on = (server.phoneEndpoint(b.id) != null ? 1 : 0) - (server.phoneEndpoint(a.id) != null ? 1 : 0);
      return on != 0 ? on : a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });

  /// Name to show for a paired device.
  String deviceName(String id) => settings.peers[id]?.name ?? settings.trusted[id]?.name ?? id;

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
    // Presence: another PC said "I'm here" / "I'm leaving" — update the PC
    // list at once; phones get the full "who is online" list back.
    server.onPresence = (id, online) {
      if (!settings.peers.containsKey(id)) return;
      if (online) {
        unawaited(s.peers.checkNow(id));
      } else {
        s.peers.markGone(id);
      }
    };
    server.onlineNow = () => s.onlineDevices;
    s.sender.phoneTarget = s.phoneTarget;
    s.sender.formatter = PhoneFormatter(ffmpeg);
    // Changes are compared on every notification (each link opening or
    // closing notifies on its own), so quick off/on is not lost.
    server.addListener(s._recomputePresence);
    s.peers.addListener(s._recomputePresence);
    server.arrivals.listen((id) => s._presence.add(PresenceEvent(id, online: true, again: true)));
    await s.startNetworking();
    // Keep in touch with paired PCs all the time (not only on the Send
    // page), so both sides know who is online.
    s.peers.acquire();
    s._onlineSeen = s.onlineDevices;
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

    await Future.wait([
      capped(library.flush, 3000),
      capped(peers.sayBye, 1300), // other PCs show us offline at once
    ]);
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
