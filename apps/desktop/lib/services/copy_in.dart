// apps/desktop/lib/services/copy_in.dart
import 'dart:io';

import 'package:localroll_core/localroll_core.dart';

import '../app_services.dart';
import '../l10n/l10n.dart';
import '../ui/player/player_entry.dart';
import 'library_index.dart';
import 'open_with.dart';
import 'received_files.dart';

/// What [CopyIn.copy] did.
class CopyInResult {
  final List<String> added = [];

  /// Already in the library (the same content): where.
  final List<String> had = [];
  final List<String> failed = [];
  int photos = 0, docs = 0, others = 0;
}

/// Files from elsewhere on this PC copied into the library, each where its
/// kind belongs: photos and videos by date (<year>\<month>, as phones send
/// them), PDF / Office / text in Documents, the rest in Other files. Only
/// copied: the originals stay as they are.
class CopyIn {
  /// Device id recorded for files copied in from this PC.
  static const String deviceId = 'this-pc';

  /// [path] is not in the library (nor its Documents / Other files).
  static bool outside(AppServices s, String path) => s.server.files.relOf(path) == null;

  static Future<CopyInResult> copy(AppServices s, List<String> paths, {void Function(int done, int all)? progress}) async {
    final r = CopyInResult();
    final sep = Platform.pathSeparator;
    final lib = s.server.library;
    final list = [
      for (final p in paths)
        if (FileSystemEntity.isFileSync(p) && outside(s, p)) p,
    ];
    for (var i = 0; i < list.length; i++) {
      progress?.call(i, list.length);
      final src = list[i];
      final name = src.split(sep).last;
      try {
        final f = File(src);
        final size = await f.length();
        final ext = extensionOf(name);
        final media = PlayerEntry.playable(name);
        if (media) {
          // The same photo / video is here already: kept once.
          final same = lib.findSame(size, await sha256OfFile(f));
          if (same != null) {
            r.had.add(lib.absPath(same));
            continue;
          }
        }
        final String folder;
        if (media) {
          final t = await f.lastModified();
          folder = '${lib.rootPath}$sep${t.year}$sep${t.month.toString().padLeft(2, '0')}';
          await Directory(folder).create(recursive: true);
        } else {
          folder = await s.server.folderPath(document: OpenWith.documentExtensions.contains(ext));
        }
        final dest = LibraryIndex.uniquePath(folder, sanitizeFileName(name));
        // Windows' copy keeps the file's date (the library sorts by it).
        await f.copy(dest);
        r.added.add(dest);
        if (media) {
          r.photos++;
        } else {
          OpenWith.documentExtensions.contains(ext) ? r.docs++ : r.others++;
          await s.server.files.received(dest, FileOwner(deviceId, tr('copyin.owner'), size: size));
        }
        DiagLog.log('library', 'copied in: $name → ${dest.substring(lib.rootPath.length + 1)}');
      } catch (e) {
        r.failed.add(name);
        DiagLog.log('library', 'copy in failed: $name: $e');
      }
    }
    progress?.call(list.length, list.length);
    return r;
  }
}
