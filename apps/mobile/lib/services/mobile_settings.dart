// apps/mobile/lib/services/mobile_settings.dart
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:localroll_core/localroll_core.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A PC this phone has paired with.
class PairedDesktop {
  PairedDesktop({
    required this.id,
    required this.name,
    required this.hosts,
    required this.port,
    required this.token,
    this.lastHost,
  });

  final String id;
  String name;
  List<String> hosts;
  int port;
  final String token;

  /// Address that worked last time; tried first.
  String? lastHost;

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'hosts': hosts,
        'port': port,
        'token': token,
        'lastHost': lastHost,
      };

  factory PairedDesktop.fromJson(Map<String, dynamic> j) => PairedDesktop(
        id: j['id'] as String,
        name: j['name'] as String? ?? 'PC',
        hosts: (j['hosts'] as List? ?? const []).cast<String>(),
        port: (j['port'] as num?)?.toInt() ?? LrProtocol.defaultPort,
        token: j['token'] as String,
        lastHost: j['lastHost'] as String?,
      );
}

class MobileSettings extends ChangeNotifier {
  MobileSettings._(this._prefs);

  final SharedPreferences _prefs;

  late String deviceId;
  late String deviceName;
  final List<PairedDesktop> desktops = [];
  String? currentDesktopId;
  final Map<String, Set<String>> _sent = {};

  static Future<MobileSettings> load() async {
    final prefs = await SharedPreferences.getInstance();
    final s = MobileSettings._(prefs);
    s.deviceId = prefs.getString('deviceId') ?? _randomId(16);
    s.deviceName = prefs.getString('deviceName') ?? (Platform.isIOS ? 'iPhone' : 'Android 手机');
    final raw = prefs.getString('desktops');
    if (raw != null) {
      try {
        for (final e in jsonDecode(raw) as List) {
          s.desktops.add(PairedDesktop.fromJson(e as Map<String, dynamic>));
        }
      } catch (_) {}
    }
    s.currentDesktopId = prefs.getString('currentDesktopId');
    if (s.current == null && s.desktops.isNotEmpty) s.currentDesktopId = s.desktops.first.id;
    await s._save();
    return s;
  }

  DeviceInfo get deviceInfo => DeviceInfo(
        id: deviceId,
        name: deviceName,
        platform: Platform.operatingSystem,
        protocolVersion: LrProtocol.version,
      );

  PairedDesktop? get current {
    for (final d in desktops) {
      if (d.id == currentDesktopId) return d;
    }
    return null;
  }

  PairedDesktop? byId(String id) {
    for (final d in desktops) {
      if (d.id == id) return d;
    }
    return null;
  }

  Future<void> upsertDesktop(PairedDesktop d, {bool makeCurrent = true}) async {
    desktops.removeWhere((x) => x.id == d.id);
    desktops.insert(0, d);
    if (makeCurrent) currentDesktopId = d.id;
    await _save();
    notifyListeners();
  }

  Future<void> selectDesktop(String id) async {
    currentDesktopId = id;
    await _save();
    notifyListeners();
  }

  Future<void> removeDesktop(String id) async {
    desktops.removeWhere((x) => x.id == id);
    if (currentDesktopId == id) currentDesktopId = desktops.isEmpty ? null : desktops.first.id;
    await _prefs.remove('sent_$id');
    _sent.remove(id);
    await _save();
    notifyListeners();
  }

  Future<void> rememberHost(PairedDesktop d, String host) async {
    d.lastHost = host;
    await _save();
  }

  /// Asset ids already delivered to [desktopId] (shown with a ✓ badge).
  Set<String> sentTo(String desktopId) =>
      _sent.putIfAbsent(desktopId, () => (_prefs.getStringList('sent_$desktopId') ?? const []).toSet());

  Future<void> markSent(String desktopId, String assetId) async {
    final set = sentTo(desktopId);
    if (set.add(assetId)) {
      await _prefs.setStringList('sent_$desktopId', set.toList());
      notifyListeners();
    }
  }

  Future<void> _save() async {
    await _prefs.setString('deviceId', deviceId);
    await _prefs.setString('deviceName', deviceName);
    await _prefs.setString('desktops', jsonEncode(desktops.map((d) => d.toJson()).toList()));
    if (currentDesktopId == null) {
      await _prefs.remove('currentDesktopId');
    } else {
      await _prefs.setString('currentDesktopId', currentDesktopId!);
    }
  }

  static String _randomId(int length) {
    const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
    final r = Random.secure();
    return List.generate(length, (_) => chars[r.nextInt(chars.length)]).join();
  }
}
