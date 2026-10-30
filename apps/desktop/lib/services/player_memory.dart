// apps/desktop/lib/services/player_memory.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

/// What happens when a video ends.
enum EndMode { stop, next, repeat }

/// Something opened in the player, for "Recent" and "Continue".
class RecentEntry {
  const RecentEntry({required this.path, this.relPath, required this.name, required this.video, required this.openedMs});

  /// Full path on this PC (library items: where it was when opened).
  final String path;

  /// Library item: its place in the library (it may have moved since).
  final String? relPath;
  final String name;
  final bool video;
  final int openedMs;

  Map<String, dynamic> toJson() => {'path': path, 'rel': ?relPath, 'name': name, 'video': video, 'at': openedMs};

  static RecentEntry? fromJson(Object? j) {
    if (j is! Map) return null;
    final path = j['path'], name = j['name'];
    if (path is! String || name is! String) return null;
    return RecentEntry(
      path: path,
      relPath: j['rel'] as String?,
      name: name,
      video: j['video'] == true,
      openedMs: (j['at'] as num?)?.toInt() ?? 0,
    );
  }
}

/// The player's memory on this PC (player.json next to settings.json):
/// where each video was left, recently opened files, what to do at the end,
/// the volume. Nothing leaves this PC.
class PlayerMemory extends ChangeNotifier {
  PlayerMemory(this.file);

  final File file;

  static const int maxPositions = 800;
  static const int maxRecent = 40;

  /// key → milliseconds; oldest first (insertion order).
  final Map<String, int> _positions = {};
  final List<RecentEntry> _recent = [];
  EndMode endMode = EndMode.stop;
  double volume = 100;

  /// Jumping to an annotation starts this many seconds before it.
  int leadSec = 2;

  /// Playing stops at each annotation (for explaining / teaching).
  bool pauseAtNotes = false;

  /// Screenshots' folder in the library (named once, in the language then).
  String? shotsFolder;

  /// Clips' folder in the library (named the same way).
  String? clipsFolder;

  /// Recorded explanations' folder in the library.
  String? narrationsFolder;

  /// Screen recording: its folder, what was recorded last time (screen /
  /// window / area, which screen), frames a second, with the microphone.
  String? screensFolder;
  String screenMode = 'screen';
  int screenIndex = 0;
  int screenFps = 30;
  bool screenMic = true;

  /// The microphone chosen for explanations, and how the original's sound
  /// goes in ('quiet', 'none', 'full').
  String? mic;
  String sound = 'quiet';

  /// A clip of an annotation starts / ends this many seconds around it.
  int clipBefore = 10;
  int clipAfter = 10;

  /// An explanation also takes this many seconds of the original before /
  /// after it (0–30).
  int narrationBefore = 5;
  int narrationAfter = 5;

  /// The list on the right of the player is open, and which tab.
  bool sideOpen = true;
  String sideTab = 'list';

  /// The last video playing (for "Continue"), with its key.
  RecentEntry? last;
  String? lastKey;

  /// The open player saves where its video is (the app is closing).
  void Function()? saveOpen;

  List<RecentEntry> get recent => List.unmodifiable(_recent);

  Future<void> load() async {
    try {
      if (!await file.exists()) return;
      final j = jsonDecode(await file.readAsString());
      if (j is! Map) return;
      final pos = j['positions'];
      if (pos is Map) {
        for (final e in pos.entries) {
          if (e.value is num) _positions['${e.key}'] = (e.value as num).toInt();
        }
      }
      final rec = j['recent'];
      if (rec is List) {
        for (final r in rec) {
          final e = RecentEntry.fromJson(r);
          if (e != null) _recent.add(e);
        }
      }
      endMode = EndMode.values.firstWhere((m) => m.name == j['end'], orElse: () => EndMode.stop);
      volume = ((j['volume'] as num?)?.toDouble() ?? 100).clamp(0, 100).toDouble();
      leadSec = ((j['lead'] as num?)?.toInt() ?? 2).clamp(0, 30);
      pauseAtNotes = j['pauseAtNotes'] == true;
      shotsFolder = j['shots'] as String?;
      clipsFolder = j['clips'] as String?;
      narrationsFolder = j['narrations'] as String?;
      screensFolder = j['screens'] as String?;
      screenMode = j['screenMode'] as String? ?? 'screen';
      screenIndex = (j['screenIndex'] as num?)?.toInt() ?? 0;
      screenFps = (j['screenFps'] as num?)?.toInt() == 60 ? 60 : 30;
      screenMic = j['screenMic'] != false;
      mic = j['mic'] as String?;
      sound = j['sound'] as String? ?? 'quiet';
      sideOpen = j['side'] != false;
      sideTab = j['sideTab'] as String? ?? 'list';
      clipBefore = ((j['clipBefore'] as num?)?.toInt() ?? 10).clamp(0, 60);
      clipAfter = ((j['clipAfter'] as num?)?.toInt() ?? 10).clamp(0, 60);
      narrationBefore = ((j['narrBefore'] as num?)?.toInt() ?? 5).clamp(0, 30);
      narrationAfter = ((j['narrAfter'] as num?)?.toInt() ?? 5).clamp(0, 30);
      last = RecentEntry.fromJson(j['last']);
      lastKey = j['lastKey'] as String?;
    } catch (e) {
      debugPrint('player memory not read: $e');
    }
  }

  /// Where [key] was left (null: from the start).
  Duration? positionOf(String key) {
    final ms = _positions[key];
    return ms == null ? null : Duration(milliseconds: ms);
  }

  /// Remember where a video is. Near the start or the end it starts over
  /// next time.
  void setPosition(String key, Duration at, Duration length, {required RecentEntry entry}) {
    final ms = at.inMilliseconds;
    final total = length.inMilliseconds;
    final keep = ms > 5000 && (total <= 0 || ms < total - 5000) && (total <= 0 || ms < total * 0.97);
    _positions.remove(key);
    if (keep) {
      _positions[key] = ms;
      while (_positions.length > maxPositions) {
        _positions.remove(_positions.keys.first);
      }
      last = entry;
      lastKey = key;
    } else if (lastKey == key) {
      last = null;
      lastKey = null;
    }
    _save();
  }

  /// Opened just now: first in "Recent".
  void opened(RecentEntry e) {
    _recent.removeWhere((r) => r.path.toLowerCase() == e.path.toLowerCase());
    _recent.insert(0, e);
    if (_recent.length > maxRecent) _recent.removeRange(maxRecent, _recent.length);
    _save();
    notifyListeners();
  }

  void forget(String path) {
    _recent.removeWhere((r) => r.path.toLowerCase() == path.toLowerCase());
    if (last?.path.toLowerCase() == path.toLowerCase()) {
      last = null;
      lastKey = null;
    }
    _save();
    notifyListeners();
  }

  void clearRecent() {
    _recent.clear();
    _save();
    notifyListeners();
  }

  void setEndMode(EndMode m) {
    endMode = m;
    _save();
    notifyListeners();
  }

  void setLead(int sec) {
    leadSec = sec.clamp(0, 30);
    _save();
    notifyListeners();
  }

  void setPauseAtNotes(bool on) {
    pauseAtNotes = on;
    _save();
    notifyListeners();
  }

  void setSide({bool? open, String? tab}) {
    if (open != null) sideOpen = open;
    if (tab != null) sideTab = tab;
    _save();
  }

  void setClipAround(int before, int after) {
    clipBefore = before.clamp(0, 60);
    clipAfter = after.clamp(0, 60);
    _save();
    notifyListeners();
  }

  void setScreen({String? mode, int? index, int? fps, bool? mic, String? folder}) {
    if (mode != null) screenMode = mode;
    if (index != null) screenIndex = index;
    if (fps != null) screenFps = fps;
    if (mic != null) screenMic = mic;
    if (folder != null) screensFolder = folder;
    _save();
  }

  void setNarrationAround(int before, int after) {
    narrationBefore = before.clamp(0, 30);
    narrationAfter = after.clamp(0, 30);
    _save();
  }

  void setNarrationsFolder(String name) {
    narrationsFolder = name;
    _save();
  }

  void setMic(String? name) {
    mic = name;
    _save();
  }

  void setSound(String v) {
    sound = v;
    _save();
  }

  void setClipsFolder(String name) {
    clipsFolder = name;
    _save();
  }

  void setShotsFolder(String name) {
    shotsFolder = name;
    _save();
  }

  void setVolume(double v) {
    volume = v.clamp(0, 100).toDouble();
    _save();
  }

  Timer? _saveTimer;

  void _save() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(seconds: 1), flush);
  }

  Map<String, dynamic> toJson() => {
        'positions': _positions,
        'recent': [for (final r in _recent) r.toJson()],
        'end': endMode.name,
        'volume': volume,
        'lead': leadSec,
        'pauseAtNotes': pauseAtNotes,
        'shots': ?shotsFolder,
        'clips': ?clipsFolder,
        'narrations': ?narrationsFolder,
        'screens': ?screensFolder,
        'screenMode': screenMode,
        'screenIndex': screenIndex,
        'screenFps': screenFps,
        'screenMic': screenMic,
        'mic': ?mic,
        'sound': sound,
        'clipBefore': clipBefore,
        'side': sideOpen,
        'sideTab': sideTab,
        'clipAfter': clipAfter,
        'narrBefore': narrationBefore,
        'narrAfter': narrationAfter,
        'last': ?last?.toJson(),
        'lastKey': ?lastKey,
      };

  Future<void> flush() async {
    _saveTimer?.cancel();
    _saveTimer = null;
    try {
      final tmp = File('${file.path}.tmp');
      await tmp.writeAsString(jsonEncode(toJson()), flush: true);
      await tmp.rename(file.path);
    } catch (e) {
      debugPrint('player memory not saved: $e');
    }
  }
}
