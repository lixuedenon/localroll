// apps/desktop/lib/services/settings.dart
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:localroll_core/localroll_core.dart';
import 'package:path_provider/path_provider.dart';

import 'secret_box.dart';

/// A phone that has paired with this PC.
class TrustedDevice {
  TrustedDevice({
    required this.id,
    required this.name,
    required this.platform,
    String token = '',
    String? hashed,
    required this.pairedMs,
    this.owner,
    this.memberName,
    this.secure = false,
    this.familyMember = true,
    this.access,
  }) : _hash = hashed ?? (token.isEmpty ? '' : tokenHash(token));

  /// Only the SHA-256 of its token is kept: enough to check it, useless
  /// to anyone who copies the settings file.
  String _hash;

  /// A new token for this device (pairing, moving to HTTPS).
  void setToken(String token) => _hash = token.isEmpty ? '' : tokenHash(token);

  /// Is [token] this device's?
  bool signsIn(String token) => _hash.isNotEmpty && token.isNotEmpty && sameSecret(_hash, tokenHash(token));

  /// May it look at / manage this PC's library from afar. Null = the
  /// default: family members may look, guests may not.
  LibraryAccess? access;

  LibraryAccess get libraryAccess => access ?? (familyMember ? LibraryAccess.view : LibraryAccess.none);

  final String id;
  String name;
  final String platform;

  /// Family group (true): what it sends is received straight away — the
  /// family's backups. Guest (false): each transfer waits for "Accept" here.
  bool familyMember;
  final int pairedMs;

  /// Talks to us over HTTPS only (paired that way, or moved to it); plain
  /// HTTP with this device's token is refused.
  bool secure;

  /// Family group: the person's name as typed on the phone.
  String? owner;

  /// Family group: member name chosen on this PC (wins over [owner]).
  String? memberName;

  FamilyDevice get family =>
      FamilyDevice(id: id, deviceName: name, pairedMs: pairedMs, owner: owner, memberOverride: memberName);

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'platform': platform,
        'tokenHash': _hash,
        'pairedMs': pairedMs,
        if (owner != null) 'owner': owner,
        if (memberName != null) 'memberName': memberName,
        if (secure) 'secure': true,
        if (!familyMember) 'guest': true,
        if (access != null) 'access': access!.name,
      };

  factory TrustedDevice.fromJson(Map<String, dynamic> j) => TrustedDevice(
        id: j['id'] as String,
        name: j['name'] as String? ?? 'Phone',
        platform: j['platform'] as String? ?? 'unknown',
        // Older settings kept the token itself: hashed now, dropped on save.
        hashed: j['tokenHash'] as String?,
        token: j['tokenHash'] == null ? (j['token'] as String? ?? '') : '',
        pairedMs: (j['pairedMs'] as num?)?.toInt() ?? 0,
        owner: j['owner'] as String?,
        memberName: j['memberName'] as String?,
        secure: j['secure'] == true,
        // Paired before guests existed: family.
        familyMember: j['guest'] != true,
        access: LibraryAccess.parse(j['access']),
      );
}

/// Another PC this one can send to (PC ↔ PC). [token] is what that PC
/// gave us; it trusts us under our deviceId.
class PeerPc {
  PeerPc({
    required this.id,
    required this.name,
    required this.hosts,
    required this.port,
    required this.token,
    required this.pairedMs,
    this.lastHost,
    this.icon,
    this.color,
    this.avatar = 0,
    this.fingerprint,
  });

  final String id;
  String name;
  List<String> hosts;
  int port;
  String token;

  /// The other PC's certificate (HTTPS); null for a pairing made before
  /// encryption — moved over on the next contact.
  String? fingerprint;
  final int pairedMs;
  String? lastHost;
  String? icon;
  int? color;
  int avatar;

  /// Addresses to try, the one that worked last time first.
  List<String> get tryHosts => {?lastHost, ...hosts}.toList();

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'hosts': hosts,
        'port': port,
        // Sealed by Windows for this account (see SecretBox).
        'tokenSealed': SecretBox.seal(token),
        'pairedMs': pairedMs,
        if (lastHost != null) 'lastHost': lastHost,
        if (icon != null) 'icon': icon,
        if (color != null) 'color': color,
        if (avatar != 0) 'avatar': avatar,
        if (fingerprint != null) 'fingerprint': fingerprint,
      };

  factory PeerPc.fromJson(Map<String, dynamic> j) => PeerPc(
        id: j['id'] as String,
        name: j['name'] as String? ?? 'PC',
        hosts: (j['hosts'] as List? ?? const []).cast<String>(),
        port: (j['port'] as num?)?.toInt() ?? LrProtocol.defaultPort,
        // Unreadable here (settings copied from another account or PC):
        // empty — that PC then has to be paired again.
        token: j['tokenSealed'] is String ? (SecretBox.open(j['tokenSealed'] as String) ?? '') : (j['token'] as String? ?? ''),
        pairedMs: (j['pairedMs'] as num?)?.toInt() ?? 0,
        lastHost: j['lastHost'] as String?,
        icon: j['icon'] as String?,
        color: (j['color'] as num?)?.toInt(),
        avatar: (j['avatar'] as num?)?.toInt() ?? 0,
        fingerprint: j['fingerprint'] as String?,
      );
}

/// Persistent app settings, stored as JSON in the app-support folder.
class AppSettings extends ChangeNotifier {
  AppSettings._(this._file);

  final File _file;

  late String deviceId;
  late String deviceName;
  late String libraryPath;
  int port = LrProtocol.defaultPort;

  /// Optional explicit path to ffmpeg.exe (otherwise auto-detected).
  String? ffmpegPath;

  /// UI language code (see supportedLanguages); null = follow Windows.
  String? language;

  /// How this PC looks on phones: icon key (DeviceLook.icons), colour, and
  /// custom picture version (0 = none, file: avatar.png next to settings).
  late String iconKey;
  late int colorValue;
  int avatarVersion = 0;

  /// How many items each library folder had (kept outside the library, so
  /// an unplugged drive is recognised as such).
  File get libraryStateFile => File('${_file.parent.path}${Platform.pathSeparator}library_state.json');

  File get avatarFile => File('${_file.parent.path}${Platform.pathSeparator}avatar.png');

  /// Windows computer name — the "keep the original name" choice.
  static String get originalName => _defaultDeviceName();
  final Map<String, TrustedDevice> trusted = {};

  /// This PC's certificate fingerprint (set at start-up, not saved here).
  String? tlsFingerprint;

  /// Folder of settings.json (certificate files live next to it).
  Directory get dataDir => _file.parent;

  /// Other PCs this one can send to.
  final Map<String, PeerPc> peers = {};

  /// Files from other PCs that are not photos/videos live in two folders
  /// inside the library root, named once in the language of the day and
  /// then kept (renaming would split them): documents (PDF, Office…) and
  /// everything else (archives, whole folders…). Not part of the photo
  /// library view.
  String? docsFolder;
  String? otherFolder;

  /// Receive from paired devices without asking. Off: each device's first
  /// transfer waits for "Accept" on this PC (then 30 minutes free).
  bool autoAccept = true;

  /// Read the text in photos and files (on this PC only) so it can be searched.
  bool textSearch = true;

  /// Search by what pictures show (needs the downloaded model; off until
  /// the person turns it on).
  bool pictureSearch = false;

  /// The person was asked once about picture search (yes or "later").
  bool pictureAsked = false;

  /// Library: arrivals up to this time were already looked at ("Just
  /// received" banner hidden for them).
  int recentSeenMs = 0;

  /// PCs the user chose to "Forget": not offered under "Nearby" any more.
  final Set<String> hiddenPeers = {};

  /// Family group: store originals as <member>/<year>/<month> instead of
  /// <year>/<month>.
  bool folderPerMember = false;

  /// Library thumbnail size: 0 small, 1 medium, 2 large.
  int thumbSize = 1;

  /// Paired phones in the family group, grouped into family members.
  /// (PCs and guests are listed separately.)
  FamilyDirectory get family => FamilyDirectory(
      trusted.values.where((t) => !isDesktopPlatform(t.platform) && t.familyMember).map((t) => t.family));

  static Future<AppSettings> load() async => loadFrom(await getApplicationSupportDirectory());

  /// Settings kept in [dir] (tests use a temporary folder).
  static Future<AppSettings> loadFrom(Directory dir) async {
    await dir.create(recursive: true);
    final s = AppSettings._(File('${dir.path}${Platform.pathSeparator}settings.json'));
    Map<String, dynamic> j = {};
    if (await s._file.exists()) {
      try {
        j = jsonDecode(await s._file.readAsString()) as Map<String, dynamic>;
      } catch (_) {
        // Corrupt settings: start fresh rather than refusing to launch.
      }
    }
    s.deviceId = j['deviceId'] as String? ?? randomId(16);
    s.deviceName = j['deviceName'] as String? ?? _defaultDeviceName();
    s.libraryPath = j['libraryPath'] as String? ?? _defaultLibraryPath();
    s.docsFolder = j['docsFolder'] as String?;
    s.otherFolder = j['otherFolder'] as String?;
    s.recentSeenMs = (j['recentSeenMs'] as num?)?.toInt() ?? 0;
    s.autoAccept = j['autoAccept'] != false;
    s.textSearch = j['textSearch'] != false;
    s.pictureSearch = j['pictureSearch'] == true;
    s.pictureAsked = j['pictureAsked'] == true;
    s.hiddenPeers.addAll((j['hiddenPeers'] as List? ?? const []).cast<String>());
    s.port = (j['port'] as num?)?.toInt() ?? LrProtocol.defaultPort;
    s.ffmpegPath = j['ffmpegPath'] as String?;
    s.language = j['language'] as String?;
    // First run: pick a look at random (changeable in Settings).
    s.iconKey = j['iconKey'] as String? ?? DeviceLook.randomIcon();
    s.colorValue = (j['colorValue'] as num?)?.toInt() ?? DeviceLook.randomColor();
    s.avatarVersion = (j['avatarVersion'] as num?)?.toInt() ?? 0;
    s.folderPerMember = j['folderPerMember'] == true;
    s.thumbSize = ((j['thumbSize'] as num?)?.toInt() ?? 1).clamp(0, 2);
    if (s.avatarVersion != 0 && !await s.avatarFile.exists()) s.avatarVersion = 0;
    for (final t in (j['trusted'] as List? ?? const [])) {
      final d = TrustedDevice.fromJson(t as Map<String, dynamic>);
      s.trusted[d.id] = d;
    }
    for (final p in (j['peers'] as List? ?? const [])) {
      try {
        final d = PeerPc.fromJson(p as Map<String, dynamic>);
        s.peers[d.id] = d;
      } catch (_) {}
    }
    await s.save();
    return s;
  }

  DeviceInfo get deviceInfo => DeviceInfo(
        id: deviceId,
        name: deviceName,
        platform: Platform.operatingSystem,
        icon: iconKey,
        color: colorValue,
        avatar: avatarVersion,
        protocolVersion: LrProtocol.version,
        tlsPort: tlsFingerprint == null ? null : port,
        fingerprint: tlsFingerprint,
      );

  Future<void> save() async {
    final tmp = File('${_file.path}.tmp');
    await tmp.writeAsString(const JsonEncoder.withIndent('  ').convert({
      'deviceId': deviceId,
      'deviceName': deviceName,
      'libraryPath': libraryPath,
      if (docsFolder != null) 'docsFolder': docsFolder,
      if (otherFolder != null) 'otherFolder': otherFolder,
      'hiddenPeers': hiddenPeers.toList(),
      'recentSeenMs': recentSeenMs,
      'autoAccept': autoAccept,
      'textSearch': textSearch,
      'pictureSearch': pictureSearch,
      'pictureAsked': pictureAsked,
      'port': port,
      'ffmpegPath': ffmpegPath,
      'language': language,
      'iconKey': iconKey,
      'colorValue': colorValue,
      'avatarVersion': avatarVersion,
      'folderPerMember': folderPerMember,
      'thumbSize': thumbSize,
      'trusted': trusted.values.map((t) => t.toJson()).toList(),
      'peers': peers.values.map((p) => p.toJson()).toList(),
    }));
    await tmp.rename(_file.path);
  }

  /// Re-reads paired phones from settings.json (merging, never dropping).
  Future<void> reloadTrusted() async {
    try {
      final j = jsonDecode(await _file.readAsString()) as Map<String, dynamic>;
      for (final t in (j['trusted'] as List? ?? const [])) {
        final d = TrustedDevice.fromJson(t as Map<String, dynamic>);
        trusted[d.id] = d;
      }
    } catch (_) {}
  }

  /// The port the running copy listens on (read-only peek; never writes).
  static Future<int?> savedPort() async {
    try {
      final dir = await getApplicationSupportDirectory();
      final f = File('${dir.path}${Platform.pathSeparator}settings.json');
      final j = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      return (j['port'] as num?)?.toInt();
    } catch (_) {
      return null;
    }
  }

  /// Holds an exclusive lock for the life of the process so only one
  /// LocalRoll runs at a time (two copies would split paired phones and
  /// ports between them). Returns false if another copy holds it.
  static Future<bool> acquireInstanceLock() async {
    try {
      final dir = await getApplicationSupportDirectory();
      await dir.create(recursive: true);
      final raf = await File('${dir.path}${Platform.pathSeparator}instance.lock').open(mode: FileMode.write);
      await raf.lock(FileLock.exclusive);
      _instanceLock = raf; // keep open: the OS releases it when we exit
      return true;
    } on FileSystemException {
      return false;
    } catch (_) {
      return true; // can't tell; don't block startup
    }
  }

  // Held only to keep the lock open; never read.
  // ignore: unused_field
  static RandomAccessFile? _instanceLock;

  Future<void> update(void Function(AppSettings s) change) async {
    change(this);
    await save();
    notifyListeners();
  }

  static String _defaultDeviceName() {
    try {
      return Platform.localHostname;
    } catch (_) {
      return 'My PC';
    }
  }

  static String _defaultLibraryPath() {
    final home = Platform.environment['USERPROFILE'] ?? Platform.environment['HOME'] ?? '.';
    final sep = Platform.pathSeparator;
    return '$home${sep}Pictures${sep}LocalRoll';
  }
}

final Random _rng = Random.secure();

/// Random URL-safe id of [length] characters.
String randomId(int length) {
  const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
  return List.generate(length, (_) => chars[_rng.nextInt(chars.length)]).join();
}

/// Random 6-digit PIN.
String randomPin() => (_rng.nextInt(900000) + 100000).toString();
