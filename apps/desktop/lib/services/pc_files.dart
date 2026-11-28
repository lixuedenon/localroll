// apps/desktop/lib/services/pc_files.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ffi';
import 'dart:isolate';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:localroll_core/localroll_core.dart';

import '../ui/player/player_entry.dart';

/// The kinds of file listed.
enum PcKind { photo, video, pdf, word, excel, ppt, text }

/// A file somewhere on this PC (outside the library).
class PcFile {
  PcFile(this.path, this.size, this.modified, this.taken, {DateTime? created}) : created = created ?? modified;

  final String path;
  final int size;
  final DateTime modified;

  /// When it came onto this PC (Windows' creation time: a copy's is when it
  /// was copied, while its last change stays the original's).
  final DateTime created;

  /// When the photo was taken / the video made (when known).
  final DateTime? taken;

  String get name => path.split(Platform.pathSeparator).last;
  String get folder => File(path).parent.path;

  /// Taken (photos, videos), else when it came onto this PC (the later of
  /// created and last changed).
  DateTime get when => taken ?? (created.isAfter(modified) ? created : modified);

  /// Last changed (the "by last change" choice).
  DateTime get changed => modified;
  PcKind? get kind => PcFiles.kindOf(name);

  Map<String, Object?> toJson() => {
        'path': path,
        'name': name,
        'size': size,
        'modified': when.millisecondsSinceEpoch,
        if (taken != null) 'taken': taken!.millisecondsSinceEpoch,
        'kind': kind?.name,
      };
}

/// Where the list came from (always Keepnear's own look through the
/// drives now; Windows Search only for the words inside files).
enum PcSource { windowsSearch, scan }

/// The photos, videos, PDF, Office and text files elsewhere on this PC:
/// Keepnear looks through every drive of this PC (and the folders added),
/// skipping system and program folders, the library and the folders left
/// out; the list is kept on disk, shown at once next time and looked
/// through again in the background. Windows Search is used only for the
/// words inside files. Nothing is copied or changed.
class PcFiles extends ChangeNotifier {
  PcFiles({required this.libraryRoot, required this.extra, required this.skip, required this.cacheFile});

  /// The library (its files are listed there, not here).
  final String Function() libraryRoot;

  /// Folders added (other drives: USB, network), and folders left out.
  final List<String> Function() extra;
  final List<String> Function() skip;

  /// Where the list is kept between runs.
  final File Function() cacheFile;

  List<PcFile> _files = [];
  DateTime? _at;
  PcSource source = PcSource.scan;
  Future<List<PcFile>>? _running;

  /// Looking through the drives now: the drive, and how many found.
  String? scanning;
  int found = 0;

  /// The words-inside search can't be used on this PC (Windows Search
  /// didn't answer).
  bool insideBroken = false;

  static const Map<PcKind, Set<String>> _ext = {
    PcKind.pdf: {'pdf'},
    PcKind.word: {'doc', 'docx', 'odt', 'rtf', 'wps'},
    PcKind.excel: {'xls', 'xlsx', 'ods', 'csv', 'et'},
    PcKind.ppt: {'ppt', 'pptx', 'odp', 'dps'},
    PcKind.text: {'txt', 'md', 'log'},
  };

  static PcKind? kindOf(String name) {
    final e = extensionOf(name);
    if (playerImageExtensions.contains(e)) return PcKind.photo;
    if (playerVideoExtensions.contains(e)) return PcKind.video;
    for (final k in _ext.entries) {
      if (k.value.contains(e)) return k.key;
    }
    return null;
  }

  static Set<String> get allExtensions => {...playerImageExtensions, ...playerVideoExtensions, for (final v in _ext.values) ...v};

  /// The usual folders: Desktop, Documents, Downloads, Pictures, Videos,
  /// Music, OneDrive.
  static List<String> usualFolders() {
    final home = Platform.environment['USERPROFILE'];
    if (home == null) return const [];
    final sep = Platform.pathSeparator;
    return [
      for (final n in ['Desktop', 'Documents', 'Downloads', 'Pictures', 'Videos', 'Music', 'OneDrive']) '$home$sep$n',
    ].where((p) => Directory(p).existsSync()).toList();
  }

  List<PcFile> get files => _files;
  DateTime? get listedAt => _at;

  /// The list: the one kept on disk at once (looked through again in the
  /// background when older than [maxAge]), or a fresh look ([fresh]).
  Future<List<PcFile>> list({bool fresh = false, Duration maxAge = const Duration(hours: 6)}) async {
    if (_at == null && !fresh) await _loadCache();
    final at = _at;
    if (!fresh && at != null) {
      if (DateTime.now().difference(at) > maxAge) unawaited(_scanOnce());
      return _files;
    }
    return _scanOnce();
  }

  Future<List<PcFile>> _scanOnce() => _running ??= _read().whenComplete(() => _running = null);

  /// This PC's own drives (not USB sticks, network or CD).
  static List<String> fixedDrives() {
    if (!Platform.isWindows) return const [];
    try {
      final k = DynamicLibrary.open('kernel32.dll');
      final type = k.lookupFunction<Uint32 Function(Pointer<Utf16>), int Function(Pointer<Utf16>)>('GetDriveTypeW');
      final out = <String>[];
      for (var c = 'C'.codeUnitAt(0); c <= 'Z'.codeUnitAt(0); c++) {
        final root = '${String.fromCharCode(c)}:\\';
        final p = root.toNativeUtf16();
        try {
          if (type(p) == 3) out.add(root); // DRIVE_FIXED
        } finally {
          calloc.free(p);
        }
      }
      return out;
    } catch (_) {
      return const ['C:\\'];
    }
  }

  Future<List<PcFile>> _read() async {
    final t0 = DateTime.now();
    final roots = [...fixedDrives(), ...extra().where((d) => Directory(d).existsSync())];
    final skips = <String>{
      libraryRoot().toLowerCase(),
      for (final x in skip()) x.toLowerCase().replaceAll(RegExp(r'[\\/]+$'), ''),
    }.where((e) => e.isNotEmpty).toList();
    final got = <String, PcFile>{};
    found = 0;
    for (final r in roots) {
      scanning = r;
      notifyListeners();
      for (final f in await _scan([r], skips)) {
        got.putIfAbsent(f.path.toLowerCase(), () => f);
      }
      found = got.length;
    }
    scanning = null;
    final out = got.values.where(_keep).toList()..sort((a, b) => b.when.compareTo(a.when));
    _files = out;
    _at = DateTime.now();
    source = PcSource.scan;
    DiagLog.log('library', 'pc files: ${out.length} on ${roots.length} places in ${DateTime.now().difference(t0).inSeconds} s');
    unawaited(_saveCache());
    notifyListeners();
    return out;
  }

  Future<void> _loadCache() async {
    try {
      final f = cacheFile();
      if (!f.existsSync()) return;
      final lines = await f.readAsLines();
      if (lines.isEmpty) return;
      final at = DateTime.fromMillisecondsSinceEpoch(int.tryParse(lines.first) ?? 0);
      final out = <PcFile>[];
      for (final l in lines.skip(1)) {
        final p = l.split('\t');
        if (p.length < 4) continue;
        out.add(PcFile(p[0], int.tryParse(p[1]) ?? 0, DateTime.fromMillisecondsSinceEpoch(int.tryParse(p[2]) ?? 0), null,
            created: DateTime.fromMillisecondsSinceEpoch(int.tryParse(p[3]) ?? 0)));
      }
      _files = out.where(_keep).toList()..sort((a, b) => b.when.compareTo(a.when));
      _at = at;
    } catch (e) {
      DiagLog.log('library', 'pc files: kept list unreadable: $e');
    }
  }

  Future<void> _saveCache() async {
    try {
      final b = StringBuffer('${_at?.millisecondsSinceEpoch ?? 0}\n');
      for (final f in _files) {
        b.write('${f.path}\t${f.size}\t${f.modified.millisecondsSinceEpoch}\t${f.created.millisecondsSinceEpoch}\n');
      }
      final f = cacheFile();
      await f.parent.create(recursive: true);
      await f.writeAsString(b.toString(), flush: true);
    } catch (_) {}
  }

  /// May a phone see / take [path]: an existing file of a kind listed,
  /// outside the library and the folders never listed.
  bool allowed(String path) {
    if (path.isEmpty || path.contains('..')) return false;
    final f = File(path);
    if (!f.existsSync()) return false;
    final st = f.statSync();
    return _keep(PcFile(f.absolute.path, st.size, st.modified, null));
  }

  /// Not in the library, not in system / program / app-data folders, not
  /// in a folder left out, not a temporary Office file.
  bool _keep(PcFile f) {
    final p = f.path.toLowerCase();
    final lib = libraryRoot().toLowerCase();
    if (lib.isNotEmpty && (p.startsWith('$lib\\') || p == lib)) return false;
    final win = (Platform.environment['SystemRoot'] ?? r'C:\Windows').toLowerCase();
    for (final s in [
      '$win\\',
      ...[Platform.environment['ProgramFiles'], Platform.environment['ProgramFiles(x86)'], Platform.environment['ProgramData']]
          .whereType<String>()
          .map((e) => '${e.toLowerCase()}\\'),
      ...skip().map((e) => '${e.toLowerCase().replaceAll(RegExp(r'[\\/]+$'), '')}\\'),
    ]) {
      if (p.startsWith(s)) return false;
    }
    if (p.contains('\\appdata\\') || p.contains('\\\$recycle.bin\\') || p.contains('\\node_modules\\') || p.contains('\\.git\\')) return false;
    final n = f.name;
    if (n.startsWith('~\$') || n.startsWith('.')) return false;
    return f.kind != null;
  }

  /// Windows Search (the index behind the taskbar's search box). Throws
  /// when it can't be used (switched off).
  Future<List<PcFile>> _fromWindowsSearch({String? words}) async {
    final exts = allExtensions.map((e) => "'.$e'").join(',');
    final w = words?.replaceAll("'", "''").replaceAll('"', '');
    final where = [
      "SCOPE='file:'",
      'System.FileExtension IN ($exts)',
      if (w != null && w.isNotEmpty) "CONTAINS(*,'\"$w*\"')",
    ].join(' AND ');
    final sql = 'SELECT TOP 100000 System.ItemPathDisplay, System.Size, System.DateModified, System.Photo.DateTaken, System.Media.DateEncoded '
        'FROM SystemIndex WHERE $where';
    final ps = r'''
[Console]::OutputEncoding=[Text.Encoding]::UTF8
$c=New-Object -ComObject ADODB.Connection
$r=New-Object -ComObject ADODB.Recordset
$c.Open("Provider=Search.CollatorDSO;Extended Properties='Application=Windows';")
$r.Open($env:LR_SQL,$c)
function d($v){ if($v -eq $null -or $v -is [DBNull]){ '' } else { ([datetime]$v).ToUniversalTime().ToString('o') } }
while(-not $r.EOF){
  $p=$r.Fields.Item('System.ItemPathDisplay').Value
  if($p){
    $s=$r.Fields.Item('System.Size').Value; if($s -eq $null -or $s -is [DBNull]){$s=0}
    [Console]::Out.WriteLine($p+"`t"+$s+"`t"+(d $r.Fields.Item('System.DateModified').Value)+"`t"+(d $r.Fields.Item('System.Photo.DateTaken').Value)+"`t"+(d $r.Fields.Item('System.Media.DateEncoded').Value))
  }
  $r.MoveNext()
}
$r.Close(); $c.Close()
''';
    final r = await Process.run('powershell', ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-Command', ps],
            environment: {'LR_SQL': sql}, stdoutEncoding: utf8, stderrEncoding: utf8)
        .timeout(const Duration(seconds: 15));
    if (r.exitCode != 0) throw StateError('${r.stderr}'.trim().split('\n').first);
    final out = <PcFile>[];
    for (final line in const LineSplitter().convert('${r.stdout}')) {
      final p = line.split('\t');
      if (p.length < 3) continue;
      final m = DateTime.tryParse(p[2])?.toLocal();
      final taken = p.length > 3 ? (DateTime.tryParse(p[3]) ?? (p.length > 4 ? DateTime.tryParse(p[4]) : null))?.toLocal() : null;
      out.add(PcFile(p[0], int.tryParse(p[1].split('.').first) ?? 0, m ?? DateTime.fromMillisecondsSinceEpoch(0), taken));
    }
    return out;
  }

  /// Files whose words contain [words] (Windows Search reads inside PDF and
  /// Office files where it indexes). Null: Windows Search can't be used.
  Future<List<PcFile>?> searchInside(String words) async {
    if (words.trim().isEmpty) return null;
    try {
      final got = await _fromWindowsSearch(words: words.trim());
      insideBroken = false;
      return got.where((f) => File(f.path).existsSync() && _keep(f)).toList()..sort((a, b) => b.when.compareTo(a.when));
    } catch (e) {
      insideBroken = true;
      DiagLog.log('library', 'pc files: search inside failed: $e');
      return null;
    }
  }

  /// Looks through [dirs] (in another isolate: Keepnear stays free).
  static Future<List<PcFile>> _scan(List<String> dirs, List<String> skips) async {
    final exts = allExtensions;
    final rows = await Isolate.run(() => _walk(dirs, exts, skips));
    return [
      for (final r in rows)
        PcFile(r.$1, r.$2, DateTime.fromMillisecondsSinceEpoch(r.$3), null, created: DateTime.fromMillisecondsSinceEpoch(r.$4)),
    ];
  }

  /// Folders never looked into (system, programs, app data, bins).
  static const Set<String> _skipNames = {
    'windows', 'windows.old', 'program files', 'program files (x86)', 'programdata', 'appdata', 'system volume information',
    'recovery', 'perflogs', 'msocache', 'config.msi', 'onedrivetemp', 'node_modules', 'intel', 'amd', 'nvidia', 'drivers',
  };

  static List<(String, int, int, int)> _walk(List<String> dirs, Set<String> exts, List<String> skips) {
    final out = <(String, int, int, int)>[];
    final seen = <String>{};
    final stack = [...dirs];
    while (stack.isNotEmpty && out.length < 500000) {
      final d = stack.removeLast();
      final low = d.toLowerCase();
      if (!seen.add(low) || skips.any((x) => low == x || low.startsWith('$x\\'))) continue;
      List<FileSystemEntity> list;
      try {
        list = Directory(d).listSync(followLinks: false);
      } catch (_) {
        continue;
      }
      for (final e in list) {
        final n = e.path.split(Platform.pathSeparator).last;
        if (n.startsWith('.') || n.startsWith(r'$')) continue;
        if (e is Directory) {
          if (!_skipNames.contains(n.toLowerCase())) stack.add(e.path);
        } else if (e is File) {
          final dot = n.lastIndexOf('.');
          if (dot < 0 || !exts.contains(n.substring(dot + 1).toLowerCase())) continue;
          try {
            final st = e.statSync();
            // On Windows "changed" is the creation time.
            out.add((e.path, st.size, st.modified.millisecondsSinceEpoch, st.changed.millisecondsSinceEpoch));
          } catch (_) {}
        }
      }
    }
    return out;
  }
}
