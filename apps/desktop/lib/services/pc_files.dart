// apps/desktop/lib/services/pc_files.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:localroll_core/localroll_core.dart';

import '../ui/player/player_entry.dart';

/// The kinds of file listed.
enum PcKind { photo, video, pdf, word, excel, ppt, text }

/// A file somewhere on this PC (outside the library).
class PcFile {
  PcFile(this.path, this.size, this.modified, this.taken);

  final String path;
  final int size;
  final DateTime modified;

  /// When the photo was taken / the video made (Windows Search knows it);
  /// null: not known.
  final DateTime? taken;

  String get name => path.split(Platform.pathSeparator).last;
  String get folder => File(path).parent.path;

  /// Taken (photos, videos), else last changed.
  DateTime get when => taken ?? modified;
  PcKind? get kind => PcFiles.kindOf(name);

  Map<String, Object?> toJson() => {
        'path': path,
        'name': name,
        'size': size,
        'modified': modified.millisecondsSinceEpoch,
        if (taken != null) 'taken': taken!.millisecondsSinceEpoch,
        'kind': kind?.name,
      };
}

/// Where the list came from.
enum PcSource { windowsSearch, scan }

/// The photos, videos, PDF, Office and text files elsewhere on this PC:
/// from Windows' own search index (it is kept up to date by Windows, and
/// knows when photos were taken), else by looking through the usual folders
/// and the ones added. System and program folders, the library and the
/// folders left out are never listed. Nothing is copied or changed.
class PcFiles {
  PcFiles({required this.libraryRoot, required this.extra, required this.skip});

  /// The library (its files are listed there, not here).
  final String Function() libraryRoot;

  /// Folders added to the usual ones, and folders left out.
  final List<String> Function() extra;
  final List<String> Function() skip;

  List<PcFile> _files = const [];
  DateTime? _at;
  PcSource source = PcSource.windowsSearch;
  Future<List<PcFile>>? _running;

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

  /// The list (read again when older than [maxAge], or [fresh]).
  Future<List<PcFile>> list({bool fresh = false, Duration maxAge = const Duration(minutes: 10)}) {
    final at = _at;
    if (!fresh && at != null && DateTime.now().difference(at) < maxAge) return Future.value(_files);
    return _running ??= _read().whenComplete(() => _running = null);
  }

  Future<List<PcFile>> _read() async {
    final t0 = DateTime.now();
    List<PcFile>? got;
    try {
      got = await _fromWindowsSearch();
      source = PcSource.windowsSearch;
    } catch (e) {
      DiagLog.log('library', 'pc files: Windows Search not usable ($e): looking through the folders');
    }
    // Folders added that Windows doesn't index: looked through as well.
    final extraDirs = extra().where((d) => Directory(d).existsSync()).toList();
    if (got == null) {
      source = PcSource.scan;
      got = await _scan([...usualFolders(), ...extraDirs]);
    } else if (extraDirs.isNotEmpty) {
      final have = {for (final f in got) f.path.toLowerCase()};
      for (final f in await _scan(extraDirs)) {
        if (have.add(f.path.toLowerCase())) got.add(f);
      }
    }
    final out = got.where(_keep).toList()..sort((a, b) => b.when.compareTo(a.when));
    _files = out;
    _at = DateTime.now();
    DiagLog.log('library', 'pc files: ${out.length} from ${source.name} in ${DateTime.now().difference(t0).inMilliseconds} ms');
    return out;
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
        .timeout(const Duration(minutes: 2));
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
  /// Office files). Null: Windows Search can't be used.
  Future<List<PcFile>?> searchInside(String words) async {
    if (source != PcSource.windowsSearch || words.trim().isEmpty) return null;
    try {
      final got = await _fromWindowsSearch(words: words.trim());
      return got.where(_keep).toList()..sort((a, b) => b.when.compareTo(a.when));
    } catch (e) {
      DiagLog.log('library', 'pc files: search inside failed: $e');
      return null;
    }
  }

  /// Looks through [dirs] (in another isolate: Keepnear stays free).
  static Future<List<PcFile>> _scan(List<String> dirs) async {
    final exts = allExtensions;
    final rows = await Isolate.run(() => _walk(dirs, exts));
    return [
      for (final r in rows) PcFile(r.$1, r.$2, DateTime.fromMillisecondsSinceEpoch(r.$3), null),
    ];
  }

  static List<(String, int, int)> _walk(List<String> dirs, Set<String> exts) {
    final out = <(String, int, int)>[];
    final seen = <String>{};
    final stack = [...dirs];
    while (stack.isNotEmpty && out.length < 200000) {
      final d = stack.removeLast();
      if (!seen.add(d.toLowerCase())) continue;
      List<FileSystemEntity> list;
      try {
        list = Directory(d).listSync(followLinks: false);
      } catch (_) {
        continue;
      }
      for (final e in list) {
        final n = e.path.split(Platform.pathSeparator).last;
        if (n.startsWith('.') || n.startsWith(r'$') || n.toLowerCase() == 'appdata' || n == 'node_modules') continue;
        if (e is Directory) {
          stack.add(e.path);
        } else if (e is File) {
          final dot = n.lastIndexOf('.');
          if (dot < 0 || !exts.contains(n.substring(dot + 1).toLowerCase())) continue;
          try {
            final st = e.statSync();
            out.add((e.path, st.size, st.modified.millisecondsSinceEpoch));
          } catch (_) {}
        }
      }
    }
    return out;
  }
}
