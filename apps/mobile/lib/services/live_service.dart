// apps/mobile/lib/services/live_service.dart
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:localroll_core/localroll_core.dart';

import 'discovery.dart';
import 'mobile_settings.dart';

/// Someone came online / went offline (as this phone sees it).
class PresenceEvent {
  const PresenceEvent(this.id, this.name, {required this.pc, required this.online, this.again = false});

  final String id;
  final String name;
  final bool pc;
  final bool online;

  /// Closed and opened again quickly (never seen offline in between).
  final bool again;
}

/// Live links from this phone to each paired PC (see core live.dart):
///  * a PC is online exactly while its link is open;
///  * each PC tells us at once who else comes and goes (other phones too);
///  * closing the links when the app leaves the screen is our "goodbye",
///    and if the app is killed, the system closes them for us.
/// Results go into [DesktopDiscovery] (so every screen sees the same
/// state) and [events] (one note per change).
class LiveService extends ChangeNotifier {
  LiveService(this.settings, this.discovery);

  final MobileSettings settings;
  final DesktopDiscovery discovery;

  final Map<String, LiveLink> _links = {};
  final Map<String, Map<String, OnlineDevice>> _heard = {};

  final StreamController<PresenceEvent> _events = StreamController.broadcast();
  Stream<PresenceEvent> get events => _events.stream;

  bool _running = false;
  String _session = '';

  /// Where this phone receives (port and certificate), told to each PC so
  /// it can send here.
  Map<String, String> Function()? receiveInfo;

  /// Others online as last reported (to tell what changed).
  Map<String, OnlineDevice> _others = {};

  bool get running => _running;

  /// App on screen: (re)connect everything, as a new visit.
  /// Right after this phone comes on (app opened or back on screen) it
  /// finds devices that were already on: shown online, not announced as
  /// "came online" — they didn't, we did.
  DateTime _quietUntil = DateTime.fromMillisecondsSinceEpoch(0);
  bool get _quiet => DateTime.now().isBefore(_quietUntil);

  /// Just came on: what is found now was already there (no notes).
  bool get quiet => _quiet;

  /// PC [pcId] says photos were deleted there: ask it for /changes now.
  void Function(String pcId)? onChanged;

  void start() {
    _quietUntil = DateTime.now().add(const Duration(seconds: 15));
    _session = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
    _running = true;
    sync();
  }

  /// App left the screen: close every link (the PCs see us leave at once).
  Future<void> stop() async {
    _running = false;
    final links = _links.values.toList();
    _links.clear();
    await Future.wait([for (final l in links) l.stop()]);
  }

  /// Paired PCs changed: one link each.
  void sync() {
    if (!_running) return;
    for (final id in _links.keys.toList()) {
      if (settings.byId(id) == null) unawaited(_links.remove(id)!.stop());
    }
    for (final d in settings.desktops) {
      if (_links.containsKey(d.id)) continue;
      final id = d.id;
      final link = LiveLink(
        deviceId: settings.deviceId,
        onMessage: (m) => _onMessage(id, m),
        onConnected: (up) => _onConnected(id, up),
      )
        ..session = _session
        ..extraQuery = receiveInfo
        ..target = () async {
          final pc = settings.byId(id);
          if (pc == null || pc.token.isEmpty) return null;
          final seen = discovery.found.where((f) => f.id == id).firstOrNull;
          final host = pc.lastHost ?? seen?.hosts.firstOrNull ?? pc.hosts.firstOrNull;
          if (host == null) return null;
          return LiveTarget(
            host: host,
            port: pc.port,
            token: pc.token,
            secure: pc.fingerprint != null,
            pin: pc.fingerprint,
          );
        };
      _links[id] = link;
      link.start();
    }
  }

  /// Address learned (Wi-Fi search found the PC): try now.
  void kick() {
    for (final l in _links.values) {
      l.kick();
    }
  }

  void _onConnected(String pcId, bool up) {
    final name = settings.byId(pcId)?.name ?? '';
    final was = discovery.isOnline(pcId);
    discovery.live(pcId, up);
    if (!up) _heard.remove(pcId);
    if (was != up) DiagLog.log('live', '$name ${up ? 'linked' : 'lost'}');
    // A PC found while we are just coming on was already there.
    if (was != up && _running && !(up && _quiet)) _events.add(PresenceEvent(pcId, name, pc: true, online: up));
    // Losing the link to a PC doesn't mean the devices it told us about
    // went away: no notes for them.
    _recompute(quiet: !up);
    notifyListeners();
  }

  void _onMessage(String pcId, LiveMessage m) {
    switch (m.type) {
      case 'hello':
        final f = m.family;
        if (f != null) _family(pcId, f);
        final a = m.access;
        if (a != null) discovery.setAccessAt(pcId, a);
        _heard[pcId] = {for (final d in m.online) d.id: d};
        // Who was already on when we connected: shown, not announced.
        _recompute(quiet: true);
        notifyListeners();
        return;
      case 'up':
        final d = m.device;
        if (d == null) break;
        final known = _others.containsKey(d.id);
        (_heard[pcId] ??= {})[d.id] = d;
        // Already online here: it was closed and opened again.
        if (known && !_quiet && d.id != settings.deviceId && settings.byId(d.id) == null) {
          _events.add(PresenceEvent(d.id, d.name, pc: d.isDesktop, online: true, again: true));
        }
      case 'down':
        final id = m.id;
        if (id != null) _heard[pcId]?.remove(id);
      case 'you':
        final f = m.family;
        if (f != null) _family(pcId, f);
        final a = m.access;
        if (a != null) discovery.setAccessAt(pcId, a);
      case 'changed':
        onChanged?.call(pcId);
        return;
    }
    _recompute();
    notifyListeners();
  }

  /// Our place at PC [pcId] (family / guest): shown, and remembered (auto-
  /// send only goes to PCs where we are family).
  void _family(String pcId, bool family) {
    discovery.setFamilyAt(pcId, family);
    final d = settings.byId(pcId);
    if (d != null && d.family != family) {
      d.family = family;
      unawaited(settings.saveDesktop());
    }
  }

  /// Everyone the connected PCs see (minus us and our own PCs, which have
  /// their own links); one note per device that came or went.
  void _recompute({bool quiet = false}) {
    final now = <String, OnlineDevice>{};
    for (final e in _heard.entries) {
      for (final d in e.value.values) {
        if (d.id == settings.deviceId || settings.byId(d.id) != null) continue;
        now[d.id] = d;
      }
    }
    if (!quiet && !_quiet) {
      for (final d in now.values) {
        if (!_others.containsKey(d.id)) _events.add(PresenceEvent(d.id, d.name, pc: d.isDesktop, online: true));
      }
      for (final d in _others.values) {
        if (!now.containsKey(d.id)) _events.add(PresenceEvent(d.id, d.name, pc: d.isDesktop, online: false));
      }
    }
    _others = now;
    discovery.liveOthers(now.values.toList());
  }
}
