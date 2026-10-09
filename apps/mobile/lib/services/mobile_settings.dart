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
    this.icon,
    this.color,
    this.avatar = 0,
    this.changesSinceMs = 0,
  });

  final String id;
  String name;
  List<String> hosts;
  int port;
  final String token;

  /// Address that worked last time; tried first.
  String? lastHost;

  /// The PC's look (refreshed from /info whenever we connect).
  String? icon;
  int? color;
  int avatar;

  /// Last time we asked the PC what was deleted there.
  int changesSinceMs;

  /// URL of the PC's own picture, or null.
  String? get avatarUrl {
    final h = lastHost ?? (hosts.isEmpty ? null : hosts.first);
    if (avatar == 0 || h == null) return null;
    return 'http://$h:$port${LrProtocol.pathAvatar}?v=$avatar';
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'hosts': hosts,
        'port': port,
        'token': token,
        'lastHost': lastHost,
        if (icon != null) 'icon': icon,
        if (color != null) 'color': color,
        'avatar': avatar,
        'changesSinceMs': changesSinceMs,
      };

  factory PairedDesktop.fromJson(Map<String, dynamic> j) => PairedDesktop(
        id: j['id'] as String,
        name: j['name'] as String? ?? 'PC',
        hosts: (j['hosts'] as List? ?? const []).cast<String>(),
        port: (j['port'] as num?)?.toInt() ?? LrProtocol.defaultPort,
        token: j['token'] as String,
        lastHost: j['lastHost'] as String?,
        icon: j['icon'] as String?,
        color: (j['color'] as num?)?.toInt(),
        avatar: (j['avatar'] as num?)?.toInt() ?? 0,
        changesSinceMs: (j['changesSinceMs'] as num?)?.toInt() ?? 0,
      );
}

class MobileSettings extends ChangeNotifier {
  MobileSettings._(this._prefs);

  final SharedPreferences _prefs;

  late String deviceId;
  late String deviceName;
  final List<PairedDesktop> desktops = [];
  String? currentDesktopId;

  /// UI language code (see supportedLanguages); null = follow the phone.
  String? language;

  /// Auto-send: photos/videos taken after [autoSendSinceMs] go to the current
  /// PC by themselves whenever it is reachable.
  bool autoSend = false;
  int autoSendSinceMs = 0;
  final Map<String, Set<String>> _sent = {};

  static Future<MobileSettings> load() async {
    final prefs = await SharedPreferences.getInstance();
    final s = MobileSettings._(prefs);
    s.deviceId = prefs.getString('deviceId') ?? _randomId(16);
    s.deviceName = prefs.getString('deviceName') ?? (Platform.isIOS ? 'iPhone' : 'Android');
    s.language = prefs.getString('language');
    s.autoSend = prefs.getBool('autoSend') ?? false;
    s.autoSendSinceMs = prefs.getInt('autoSendSinceMs') ?? 0;
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

  Future<void> setLanguage(String? code) async {
    language = code;
    await _save();
    notifyListeners();
  }

  /// The PC was renamed or changed its icon/picture.
  Future<void> updateLook(PairedDesktop d, DeviceInfo info) async {
    if (d.name == info.name && d.icon == info.icon && d.color == info.color && d.avatar == info.avatar) return;
    d
      ..name = info.name
      ..icon = info.icon
      ..color = info.color
      ..avatar = info.avatar;
    await _save();
    notifyListeners();
  }

  Future<void> rememberHost(PairedDesktop d, String host) async {
    d.lastHost = host;
    await _save();
  }

  /// Turning auto-send on starts from "now": the existing library is not sent
  /// unasked.
  Future<void> setAutoSend(bool on) async {
    autoSend = on;
    if (on) autoSendSinceMs = DateTime.now().millisecondsSinceEpoch;
    await _save();
    notifyListeners();
  }

  /// Items deleted on the PC that are still on this phone: no backup any
  /// more. Shown as a warning on the home screen until re-sent or dismissed.
  Set<String> lostOn(String desktopId) =>
      _lost.putIfAbsent(desktopId, () => (_prefs.getStringList('lost_$desktopId') ?? const []).toSet());
  final Map<String, Set<String>> _lost = {};

  Future<void> addLost(String desktopId, Iterable<String> ids) async {
    final set = lostOn(desktopId)..addAll(ids);
    await _prefs.setStringList('lost_$desktopId', set.toList());
    notifyListeners();
  }

  Future<void> clearLost(String desktopId, [Iterable<String>? ids]) async {
    final set = lostOn(desktopId);
    ids == null ? set.clear() : set.removeAll(ids);
    await _prefs.setStringList('lost_$desktopId', set.toList());
    notifyListeners();
  }

  Future<void> saveDesktop() async => _save();

  /// The PC no longer has these (deleted or changed there): drop the ✓ so
  /// they count as not backed up again.
  Future<void> unmarkSent(String desktopId, Iterable<String> assetIds) async {
    final set = sentTo(desktopId);
    final before = set.length;
    set.removeAll(assetIds);
    if (set.length != before) {
      await _prefs.setStringList('sent_$desktopId', set.toList());
      notifyListeners();
    }
  }

  /// Asset ids already delivered to [desktopId] (shown with a ✓ badge).
  Set<String> sentTo(String desktopId) =>
      _sent.putIfAbsent(desktopId, () => (_prefs.getStringList('sent_$desktopId') ?? const []).toSet());

  Future<void> markSent(String desktopId, String assetId) async {
    final lost = lostOn(desktopId);
    if (lost.remove(assetId)) await _prefs.setStringList('lost_$desktopId', lost.toList());
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
    await _prefs.setBool('autoSend', autoSend);
    await _prefs.setInt('autoSendSinceMs', autoSendSinceMs);
    if (language == null) {
      await _prefs.remove('language');
    } else {
      await _prefs.setString('language', language!);
    }
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
