// apps/desktop/lib/services/settings.dart
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:localroll_core/localroll_core.dart';
import 'package:path_provider/path_provider.dart';

/// A phone that has paired with this PC.
class TrustedDevice {
  TrustedDevice({
    required this.id,
    required this.name,
    required this.platform,
    required this.token,
    required this.pairedMs,
  });

  final String id;
  String name;
  final String platform;
  final String token;
  final int pairedMs;

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'platform': platform,
        'token': token,
        'pairedMs': pairedMs,
      };

  factory TrustedDevice.fromJson(Map<String, dynamic> j) => TrustedDevice(
        id: j['id'] as String,
        name: j['name'] as String? ?? 'Phone',
        platform: j['platform'] as String? ?? 'unknown',
        token: j['token'] as String,
        pairedMs: (j['pairedMs'] as num?)?.toInt() ?? 0,
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

  File get avatarFile => File('${_file.parent.path}${Platform.pathSeparator}avatar.png');

  /// Windows computer name — the "keep the original name" choice.
  static String get originalName => _defaultDeviceName();
  final Map<String, TrustedDevice> trusted = {};

  static Future<AppSettings> load() async {
    final dir = await getApplicationSupportDirectory();
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
    s.port = (j['port'] as num?)?.toInt() ?? LrProtocol.defaultPort;
    s.ffmpegPath = j['ffmpegPath'] as String?;
    s.language = j['language'] as String?;
    // First run: pick a look at random (changeable in Settings).
    s.iconKey = j['iconKey'] as String? ?? DeviceLook.randomIcon();
    s.colorValue = (j['colorValue'] as num?)?.toInt() ?? DeviceLook.randomColor();
    s.avatarVersion = (j['avatarVersion'] as num?)?.toInt() ?? 0;
    if (s.avatarVersion != 0 && !await s.avatarFile.exists()) s.avatarVersion = 0;
    for (final t in (j['trusted'] as List? ?? const [])) {
      final d = TrustedDevice.fromJson(t as Map<String, dynamic>);
      s.trusted[d.id] = d;
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
      );

  Future<void> save() async {
    final tmp = File('${_file.path}.tmp');
    await tmp.writeAsString(const JsonEncoder.withIndent('  ').convert({
      'deviceId': deviceId,
      'deviceName': deviceName,
      'libraryPath': libraryPath,
      'port': port,
      'ffmpegPath': ffmpegPath,
      'language': language,
      'iconKey': iconKey,
      'colorValue': colorValue,
      'avatarVersion': avatarVersion,
      'trusted': trusted.values.map((t) => t.toJson()).toList(),
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
