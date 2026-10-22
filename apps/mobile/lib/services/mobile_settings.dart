// apps/mobile/lib/services/mobile_settings.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:localroll_core/localroll_core.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'backup_plan.dart';
import 'secure_store.dart';
import 'phone_server.dart' show PhoneIdentity;

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
    this.fingerprint,
    this.family,
    this.libraryId,
  });

  final String id;

  /// Id of the PC's library last time we asked. When it changes the PC's
  /// library was rebuilt (lost folder made anew, another folder chosen), so
  /// what this phone thinks is backed up there is checked again.
  String? libraryId;

  /// This phone's place at that PC: family member (sends go straight in —
  /// auto-send works) or guest (each transfer waits for "Accept" there).
  /// Null = not told yet (older PC).
  bool? family;
  String name;
  List<String> hosts;
  int port;
  String token;

  /// The PC's certificate (HTTPS). Null for a pairing made before
  /// encryption; moved over automatically on the next contact.
  String? fingerprint;

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
        if (fingerprint != null) 'fingerprint': fingerprint,
        if (family != null) 'family': family,
        if (libraryId != null) 'libraryId': libraryId,
      };

  factory PairedDesktop.fromJson(Map<String, dynamic> j) => PairedDesktop(
        id: j['id'] as String,
        name: j['name'] as String? ?? 'PC',
        hosts: (j['hosts'] as List? ?? const []).cast<String>(),
        port: (j['port'] as num?)?.toInt() ?? LrProtocol.defaultPort,
        // Kept in the keychain since beta.22 (filled in by MobileSettings.load).
        token: j['token'] as String? ?? '',
        lastHost: j['lastHost'] as String?,
        icon: j['icon'] as String?,
        color: (j['color'] as num?)?.toInt(),
        avatar: (j['avatar'] as num?)?.toInt() ?? 0,
        changesSinceMs: (j['changesSinceMs'] as num?)?.toInt() ?? 0,
        fingerprint: j['fingerprint'] as String?,
        family: j['family'] as bool?,
        libraryId: j['libraryId'] as String?,
      );
}

class MobileSettings extends ChangeNotifier implements PhoneIdentity {
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
  /// Asset ids already on each PC. Kept in one small file per PC with one id
  /// per line, appended as items arrive — fast even for 50 000 photos
  /// (re-writing a big preferences list after every photo was not).
  final Map<String, Set<String>> _sent = {};
  late Directory _sentDir;
  Timer? _notifyTimer;

  /// Family group: whose phone this is ("Mum"). Phones with the same name
  /// are one family member on the PC ("Mum 1", "Mum 2").
  String ownerName = '';

  /// Family group: new uploads are visible to the family (true) or
  /// "only me" (false). Each item can be changed later.
  bool shareWithFamily = true;

  /// PCs still to be told "everything I sent: [shareWithFamily]" (they
  /// were off when it was changed); told when they are linked again.
  final Set<String> visibilityPending = {};

  /// Simple mode for elders: big text, one big "send" button, auto-send on.
  bool simpleMode = false;

  /// The backup conditions used last time (remembered).
  BackupFilter backupFilter = BackupFilter();

  static Future<MobileSettings> load() async {
    final prefs = await SharedPreferences.getInstance();
    final s = MobileSettings._(prefs);
    // The keychain first: on an iPhone it survives deleting the app, so a
    // reinstall keeps the same identity on the PCs.
    final secrets = await SecureStore.readAll();
    s._keychain = secrets != null;
    s._inKeychain.addAll({
      for (final e in (secrets ?? const <String, String>{}).entries)
        if (e.key == 'deviceId' || e.key.startsWith('token.')) e.key: e.value,
    });
    s.deviceId = secrets?['deviceId'] ?? prefs.getString('deviceId') ?? _randomId(16);
    s.deviceName = prefs.getString('deviceName') ?? (Platform.isIOS ? 'iPhone' : 'Android');
    s.language = prefs.getString('language');
    s.autoSend = prefs.getBool('autoSend') ?? false;
    s.autoSendSinceMs = prefs.getInt('autoSendSinceMs') ?? 0;
    s.ownerName = prefs.getString('ownerName') ?? '';
    s.shareWithFamily = prefs.getBool('shareWithFamily') ?? true;
    s.visibilityPending.addAll(prefs.getStringList('visibilityPending') ?? const []);
    s.simpleMode = prefs.getBool('simpleMode') ?? false;
    try {
      final raw = prefs.getString('backupFilter');
      if (raw != null) s.backupFilter = BackupFilter.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {}
    final raw = prefs.getString('desktops');
    if (raw != null) {
      try {
        for (final e in jsonDecode(raw) as List) {
          s.desktops.add(PairedDesktop.fromJson(e as Map<String, dynamic>));
        }
      } catch (_) {}
    }
    // Tokens: from the keychain; older versions kept them in preferences
    // (moved over by the save below).
    for (final d in s.desktops) {
      final t = secrets?['token.${d.id}'];
      if (t != null && t.isNotEmpty) d.token = t;
    }
    s._sentDir = Directory('${(await getApplicationSupportDirectory()).path}${Platform.pathSeparator}sent');
    await s._sentDir.create(recursive: true);
    for (final d in s.desktops) {
      await s._loadSent(d.id);
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
        owner: ownerName.trim().isEmpty ? null : ownerName.trim(),
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
    _sent.remove(id);
    try {
      await _sentFile(id).delete();
    } catch (_) {}
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

  /// This phone's own name (shown on PCs and other phones).
  Future<void> setDeviceName(String name) async {
    final t = name.trim();
    if (t.isEmpty || t == deviceName) {
      return;
    }
    deviceName = t.length > 40 ? t.substring(0, 40) : t;
    await _save();
    notifyListeners();
  }

  /// Still the plain name it started with ("iPhone" / "Android").
  bool get hasPlainName => deviceName == 'iPhone' || deviceName == 'Android';

  Future<void> setOwnerName(String name) async {
    ownerName = name.trim();
    await _save();
    notifyListeners();
  }

  /// [everything]: also what was sent already, on every paired PC (see
  /// [visibilityPending]).
  Future<void> setShareWithFamily(bool share, {bool everything = false}) async {
    shareWithFamily = share;
    if (everything) {
      visibilityPending
        ..clear()
        ..addAll(desktops.map((d) => d.id));
    }
    await _save();
    notifyListeners();
  }

  /// A PC was told the new visibility of everything.
  Future<void> visibilityDone(String pcId) async {
    if (visibilityPending.remove(pcId)) await _save();
  }

  Future<void> setBackupFilter(BackupFilter f) async {
    backupFilter = f;
    await _save();
  }

  /// When the last send to this PC finished, and how many items it sent.
  ({DateTime time, int count})? lastBackup(String desktopId) {
    final raw = _prefs.getString('lastBackup_$desktopId');
    if (raw == null) return null;
    try {
      final j = jsonDecode(raw) as Map<String, dynamic>;
      return (
        time: DateTime.fromMillisecondsSinceEpoch((j['t'] as num).toInt()),
        count: (j['n'] as num).toInt(),
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> recordBackup(String desktopId, int count) async {
    if (count <= 0) return;
    await _prefs.setString(
      'lastBackup_$desktopId',
      jsonEncode({'t': DateTime.now().millisecondsSinceEpoch, 'n': count}),
    );
    notifyListeners();
  }

  /// Simple mode also switches auto-send on: nothing to remember.

  Future<void> setSimpleMode(bool on) async {
    simpleMode = on;
    if (on && !autoSend) {
      autoSend = true;
      autoSendSinceMs = DateTime.now().millisecondsSinceEpoch;
    }
    await _save();
    notifyListeners();
  }

  /// Items deleted on the PC that are still on this phone: no backup any
  /// more. Shown as a warning on the home screen until re-sent or dismissed.
  Set<String> lostOn(String desktopId) =>
      _lost.putIfAbsent(desktopId, () => (_prefs.getStringList('lost_$desktopId') ?? const []).toSet());
  final Map<String, Set<String>> _lost = {};

  Future<void> addLost(String desktopId, Iterable<String> ids) async {
    final set = lostOn(desktopId);
    final fresh = [for (final id in ids) if (!set.contains(id)) id];
    set.addAll(ids);
    await _prefs.setStringList('lost_$desktopId', set.toList());
    notifyListeners();
    if (fresh.isNotEmpty) _lostAdded.add(LostNews(desktopId, fresh));
  }

  /// Items the PC just deleted (only the new ones each time): the phone
  /// shows them at once, with pictures.
  final StreamController<LostNews> _lostAdded = StreamController.broadcast();
  Stream<LostNews> get lostAdded => _lostAdded.stream;

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
      await _rewriteSent(desktopId);
      notifyListeners();
    }
  }

  /// Asset ids already delivered to [desktopId] (shown with a ✓ badge).
  Set<String> sentTo(String desktopId) => _sent.putIfAbsent(desktopId, () => <String>{});

  Future<void> markSent(String desktopId, String assetId) async {
    final lost = lostOn(desktopId);
    if (lost.remove(assetId)) await _prefs.setStringList('lost_$desktopId', lost.toList());
    final set = sentTo(desktopId);
    if (set.add(assetId)) {
      try {
        await _sentFile(desktopId).writeAsString('$assetId\n', mode: FileMode.append, flush: true);
      } catch (_) {}
      // Many photos per second during a big backup: redraw at most ~3×/s.
      _notifyTimer ??= Timer(const Duration(milliseconds: 300), () {
        _notifyTimer = null;
        notifyListeners();
      });
    }
  }

  File _sentFile(String desktopId) =>
      File('${_sentDir.path}${Platform.pathSeparator}${base64Url.encode(utf8.encode(desktopId))}.txt');

  Future<void> _loadSent(String desktopId) async {
    final set = sentTo(desktopId);
    final f = _sentFile(desktopId);
    try {
      if (await f.exists()) {
        for (final line in await f.readAsLines()) {
          if (line.isNotEmpty) set.add(line);
        }
      }
    } catch (_) {}
    // Older versions kept the list in preferences: move it over once.
    final legacy = _prefs.getStringList('sent_$desktopId');
    if (legacy != null) {
      set.addAll(legacy);
      await _rewriteSent(desktopId);
      await _prefs.remove('sent_$desktopId');
    }
  }

  /// Whole-file rewrite (removals are rare): write a temp file, then swap.
  Future<void> _rewriteSent(String desktopId) async {
    final f = _sentFile(desktopId);
    final tmp = File('${f.path}.tmp');
    try {
      await tmp.writeAsString(sentTo(desktopId).map((id) => '$id\n').join(), flush: true);
      await tmp.rename(f.path);
    } catch (_) {}
  }

  /// The keychain could be read at start-up (else secrets stay where they were).
  bool _keychain = false;

  /// What is in the keychain now (to write only changes).
  final Map<String, String> _inKeychain = {};

  /// Tokens and the phone id to the keychain; true when all of it is there.
  Future<bool> _saveSecrets() async {
    if (!_keychain) return false;
    final want = <String, String>{
      'deviceId': deviceId,
      for (final d in desktops)
        if (d.token.isNotEmpty) 'token.${d.id}': d.token,
    };
    var ok = true;
    for (final e in want.entries) {
      if (_inKeychain[e.key] == e.value) continue;
      if (await SecureStore.write(e.key, e.value)) {
        _inKeychain[e.key] = e.value;
      } else {
        ok = false;
      }
    }
    for (final k in _inKeychain.keys.where((k) => k.startsWith('token.') && !want.containsKey(k)).toList()) {
      await SecureStore.delete(k);
      _inKeychain.remove(k);
    }
    return ok;
  }

  Future<void> _save() async {
    final secured = await _saveSecrets();
    await _prefs.setString('deviceId', deviceId);
    await _prefs.setString('deviceName', deviceName);
    await _prefs.setString(
      'desktops',
      jsonEncode([
        for (final d in desktops)
          // In the keychain: not in plain preferences. If the keychain can't
          // be used, keep it here so nothing is lost.
          d.toJson()..removeWhere((k, _) => k == 'token' && (secured || d.token.isEmpty)),
      ]),
    );
    await _prefs.setBool('autoSend', autoSend);
    await _prefs.setInt('autoSendSinceMs', autoSendSinceMs);
    await _prefs.setString('ownerName', ownerName);
    await _prefs.setBool('shareWithFamily', shareWithFamily);
    await _prefs.setStringList('visibilityPending', visibilityPending.toList());
    await _prefs.setBool('simpleMode', simpleMode);
    await _prefs.setString('backupFilter', jsonEncode(backupFilter.toJson()));
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

/// PC [desktopId] just deleted these items (asset ids on this phone).
class LostNews {
  const LostNews(this.desktopId, this.ids);

  final String desktopId;
  final List<String> ids;
}
