// apps/desktop/lib/services/file_actions.dart
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'library_index.dart';

/// Recycle Bin via the Windows shell (SHFileOperation): one call per 500
/// files, so deleting thousands takes seconds, not minutes.
/// FOF_WANTNUKEWARNING: if the Recycle Bin is too small for a file, Windows
/// asks before deleting it for good — it is never destroyed silently.
const String _recycleScript = r"""
param([string]$ListFile)
$ErrorActionPreference = 'Stop'
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class LrRecycle {
  [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
  public struct SHFILEOPSTRUCT {
    public IntPtr hwnd;
    public uint wFunc;
    [MarshalAs(UnmanagedType.LPWStr)] public string pFrom;
    [MarshalAs(UnmanagedType.LPWStr)] public string pTo;
    public ushort fFlags;
    public bool fAnyOperationsAborted;
    public IntPtr hNameMappings;
    [MarshalAs(UnmanagedType.LPWStr)] public string lpszProgressTitle;
  }
  [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
  public static extern int SHFileOperation(ref SHFILEOPSTRUCT op);
  public static int Recycle(string[] paths) {
    var op = new SHFILEOPSTRUCT();
    op.wFunc = 3; // FO_DELETE
    op.pFrom = string.Join("\0", paths) + "\0\0";
    // ALLOWUNDO | NOCONFIRMATION | SILENT | NOERRORUI | WANTNUKEWARNING
    op.fFlags = (ushort)(0x0040 | 0x0010 | 0x0004 | 0x0400 | 0x4000);
    return SHFileOperation(ref op);
  }
}
'@
$paths = @(Get-Content -LiteralPath $ListFile -Encoding UTF8 | Where-Object { $_ -ne '' })
if ($paths.Count -gt 0) { exit [LrRecycle]::Recycle($paths) }
""";

/// Moves files to the Windows Recycle Bin (recoverable), never deletes
/// outright. Returns the paths that are really gone. [onProgress] gets the
/// number of files handled so far.
Future<List<String>> moveToRecycleBin(List<String> paths, {void Function(int done)? onProgress}) async {
  if (!Platform.isWindows || paths.isEmpty) return const [];
  final tmp = Directory.systemTemp.path;
  final script = File('$tmp${Platform.pathSeparator}localroll-recycle.ps1');
  final list = File('$tmp${Platform.pathSeparator}localroll-recycle-$pid.txt');
  try {
    await script.writeAsString(_recycleScript);
    for (var i = 0; i < paths.length; i += 500) {
      final batch = paths.sublist(i, min(i + 500, paths.length));
      // UTF-8 with BOM so Windows PowerShell 5 reads Chinese etc. correctly.
      await list.writeAsBytes([0xEF, 0xBB, 0xBF, ...utf8.encode(batch.join('\r\n'))]);
      try {
        await Process.run('powershell', [
          '-NoProfile',
          '-NonInteractive',
          '-ExecutionPolicy',
          'Bypass',
          '-File',
          script.path,
          list.path,
        ]);
      } catch (_) {}
      onProgress?.call(min(i + 500, paths.length));
    }
  } finally {
    try {
      await list.delete();
    } catch (_) {}
  }
  return [for (final p in paths) if (FileSystemEntity.typeSync(p) == FileSystemEntityType.notFound) p];
}

/// Deletes library items (to the Recycle Bin) and updates the index, which
/// remembers them so phones are told on their next connection.
/// A Live Photo's video goes with its photo. Returns how many of [items]
/// (not counting those videos) are gone.
Future<int> deleteItems(
  LibraryIndex library,
  List<MediaItem> items, {
  void Function(int done, int total)? onProgress,
}) async {
  final byPath = {for (final i in library.withLive(items)) library.absPath(i): i};
  final gone = await moveToRecycleBin(
    byPath.keys.toList(),
    onProgress: onProgress == null ? null : (done) => onProgress(done, byPath.length),
  );
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

/// Free and total bytes of the drive holding [path] (Windows), or null.
Future<({int free, int total})?> diskSpace(String path) async {
  if (!Platform.isWindows || path.length < 2 || path[1] != ':') return null;
  final letter = path[0].toUpperCase();
  try {
    final r = await Process.run('powershell', [
      '-NoProfile',
      '-NonInteractive',
      '-Command',
      r'$d = Get-PSDrive -Name ' + letter + r'; "$($d.Free) $($d.Used)"',
    ]);
    final parts = (r.stdout as String).trim().split(RegExp(r'\s+'));
    if (parts.length < 2) return null;
    final free = int.parse(parts[0]);
    final used = int.parse(parts[1]);
    return (free: free, total: free + used);
  } catch (_) {
    return null;
  }
}

final Map<String, bool> _programFor = {};

/// Does Windows have a program for files ending in .[ext] (Office, WPS…)?
Future<bool> hasProgramFor(String ext) async {
  if (!Platform.isWindows || ext.isEmpty) return false;
  final known = _programFor[ext];
  if (known != null) return known;
  var yes = false;
  try {
    final r = await Process.run('reg', ['query', 'HKCR\\.$ext', '/ve']).timeout(const Duration(seconds: 3));
    if (r.exitCode == 0) {
      final m = RegExp(r'REG_SZ\s+(\S.*)').firstMatch('${r.stdout}');
      final progId = m?.group(1)?.trim();
      if (progId != null && progId.isNotEmpty) {
        final c = await Process.run('reg', ['query', 'HKCR\\$progId\\shell']).timeout(const Duration(seconds: 3));
        yes = c.exitCode == 0;
      }
    }
  } catch (_) {}
  return _programFor[ext] = yes;
}
