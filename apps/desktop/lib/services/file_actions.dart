// apps/desktop/lib/services/file_actions.dart
import 'dart:io';

import 'library_index.dart';

/// Moves files to the Windows Recycle Bin (recoverable), never deletes
/// outright. Returns the paths that are really gone.
Future<List<String>> moveToRecycleBin(List<String> paths) async {
  if (!Platform.isWindows) return const [];
  for (var i = 0; i < paths.length; i += 40) {
    final batch = paths.sublist(i, (i + 40).clamp(0, paths.length));
    final calls = batch
        .map((p) => "[Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile('${p.replaceAll("'", "''")}', "
            "'OnlyErrorDialogs', 'SendToRecycleBin')")
        .join('; ');
    try {
      await Process.run('powershell', [
        '-NoProfile',
        '-NonInteractive',
        '-Command',
        'Add-Type -AssemblyName Microsoft.VisualBasic; $calls',
      ]);
    } catch (_) {}
  }
  return [for (final p in paths) if (!File(p).existsSync()) p];
}

/// Deletes library items (to the Recycle Bin) and updates the index, which
/// remembers them so phones are told on their next connection.
/// A Live Photo's video goes with its photo. Returns how many of [items]
/// (not counting those videos) are gone.
Future<int> deleteItems(LibraryIndex library, List<MediaItem> items) async {
  final byPath = {for (final i in library.withLive(items)) library.absPath(i): i};
  final gone = await moveToRecycleBin(byPath.keys.toList());
  final removed = [for (final p in gone) byPath[p]!];
  library.removeItems(removed);
  return removed.where(items.contains).length;
}

/// Copies originals into [folder]; returns how many were copied.
Future<int> exportItems(LibraryIndex library, List<MediaItem> items, String folder) async {
  var n = 0;
  for (final i in library.withLive(items)) {
    try {
      await File(library.absPath(i)).copy(LibraryIndex.uniquePath(folder, i.name));
      if (items.contains(i)) n++;
    } catch (_) {}
  }
  return n;
}
