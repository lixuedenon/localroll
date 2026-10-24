// apps/desktop/lib/ui/player/player_entry.dart
import 'dart:io';

import 'package:localroll_core/localroll_core.dart';

import '../../services/library_index.dart';
import '../../services/phone_formats.dart';

/// Photos the player shows (camera RAW too: the JPEG the camera put inside).
const Set<String> playerImageExtensions = {...imageExtensions, 'jxr', 'jfif', ...rawExtensions};

/// Videos the player plays (libmpv plays nearly everything).
const Set<String> playerVideoExtensions = {
  ...videoExtensions,
  'wmv', 'asf', 'flv', 'f4v', 'mpg', 'mpeg', 'vob', 'ts', 'ogv', 'rm', 'rmvb', 'divx',
};

/// One thing the player shows: a library item, or a file anywhere on this PC.
class PlayerEntry {
  PlayerEntry._({
    required this.path,
    required this.name,
    required this.video,
    required this.size,
    required this.modifiedMs,
    this.item,
  });

  /// Full path on this PC.
  final String path;
  final String name;
  final bool video;
  final int size;
  final int modifiedMs;

  /// Set when it is in the library (Live Photo, convert, delete…).
  final MediaItem? item;

  String get extension => extensionOf(name);

  /// Remembered under this (where it was in a video…).
  String get key => item != null ? 'lib:${item!.relPath}' : 'file:${path.toLowerCase()}|$size';

  /// Taken (library) or last changed (other files).
  DateTime get time => item?.captureTime ?? DateTime.fromMillisecondsSinceEpoch(modifiedMs);

  static PlayerEntry fromItem(LibraryIndex lib, MediaItem i) => PlayerEntry._(
        path: lib.absPath(i),
        name: i.name,
        video: i.kind == MediaKind.video,
        size: i.size,
        modifiedMs: i.captureMs,
        item: i,
      );

  /// A file on this PC (null: gone, or not a photo / video). One inside
  /// the library is opened as that library item.
  static PlayerEntry? fromPath(String path, {LibraryIndex? library}) {
    final name = path.split(RegExp(r'[\\/]')).last;
    if (!playable(name)) return null;
    final lib = library;
    if (lib != null && lib.rootPath.isNotEmpty) {
      final root = '${lib.rootPath}${Platform.pathSeparator}';
      if (path.toLowerCase().startsWith(root.toLowerCase())) {
        final hit = lib.findByRel(path.substring(root.length).replaceAll(Platform.pathSeparator, '/'));
        if (hit != null) return fromItem(lib, hit);
      }
    }
    try {
      final st = File(path).statSync();
      if (st.type != FileSystemEntityType.file) return null;
      return PlayerEntry._(
        path: path,
        name: name,
        video: isVideoName(name),
        size: st.size,
        modifiedMs: st.modified.millisecondsSinceEpoch,
      );
    } catch (_) {
      return null;
    }
  }

  static bool isVideoName(String name) => playerVideoExtensions.contains(extensionOf(name));

  /// A photo or video the player can show.
  static bool playable(String name) {
    final e = extensionOf(name);
    return playerImageExtensions.contains(e) || playerVideoExtensions.contains(e);
  }

  /// The photos and videos in [folder], by name (at most [max]).
  static List<String> inFolder(String folder, {int max = 5000}) {
    final out = <String>[];
    try {
      for (final e in Directory(folder).listSync(followLinks: false)) {
        if (e is File && playable(e.path)) out.add(e.path);
        if (out.length >= max) break;
      }
    } catch (_) {}
    out.sort((a, b) => _natural(a.toLowerCase(), b.toLowerCase()));
    return out;
  }

  /// "IMG_2.jpg" before "IMG_10.jpg", like Explorer.
  static int _natural(String a, String b) {
    final re = RegExp(r'(\d+)|(\D+)');
    final x = re.allMatches(a).toList(), y = re.allMatches(b).toList();
    for (var i = 0; i < x.length && i < y.length; i++) {
      final p = x[i].group(0)!, q = y[i].group(0)!;
      final np = int.tryParse(p), nq = int.tryParse(q);
      final c = np != null && nq != null ? np.compareTo(nq) : p.compareTo(q);
      if (c != 0) return c;
    }
    return x.length.compareTo(y.length);
  }

  /// For tests.
  static int naturalCompare(String a, String b) => _natural(a, b);
}
