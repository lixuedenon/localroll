// apps/desktop/lib/services/doc_editors.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:localroll_core/localroll_core.dart' show DiagLog;

/// A program that can edit Word files on this PC.
class DocEditor {
  const DocEditor(this.name, this.exe, {this.process, this.word = false});

  final String name;
  final String exe;

  /// Its process name (to look at its window title), if known.
  final String? process;

  /// Microsoft Word (it may be there without a licence).
  final bool word;
}

/// The programs that edit a Word file, in the order Keepnear uses them:
/// Microsoft Word (when activated) → WPS → ONLYOFFICE → LibreOffice →
/// SoftMaker / FreeOffice → Apache OpenOffice. One that can't edit (Word
/// not activated) is skipped on its own, nothing asked.
class DocEditors {
  DocEditors._();

  static List<DocEditor>? _found;

  static Future<String?> _reg(String key, {String? value}) async {
    try {
      final r = await Process.run('reg', ['query', key, if (value == null) '/ve' else '/v', ?value]);
      if (r.exitCode != 0) return null;
      final m = RegExp(r'REG_(?:EXPAND_)?SZ\s+(.+)').firstMatch('${r.stdout}');
      return m?.group(1)?.trim();
    } catch (_) {
      return null;
    }
  }

  /// "C:\...\x.exe" /n "%1" → C:\...\x.exe
  static String? _exeOf(String? command) {
    if (command == null) return null;
    final c = command.trim();
    final m = c.startsWith('"') ? RegExp(r'^"([^"]+)"').firstMatch(c) : RegExp(r'^(\S+\.exe)', caseSensitive: false).firstMatch(c);
    final p = m?.group(1);
    return p != null && File(p).existsSync() ? p : null;
  }

  static String? _firstFile(List<String> paths) {
    for (final p in paths) {
      if (File(p).existsSync()) return p;
    }
    return null;
  }

  /// Program Files folders whose name starts with [prefix] (newest name
  /// last), with [rel] inside.
  static List<String> _under(String prefix, String rel) {
    final out = <String>[];
    for (final env in ['ProgramFiles', 'ProgramFiles(x86)', 'ProgramW6432', 'LOCALAPPDATA']) {
      final root = Platform.environment[env];
      if (root == null) continue;
      try {
        final dirs = Directory(root).listSync().whereType<Directory>().where((d) => d.path.split('\\').last.toLowerCase().startsWith(prefix.toLowerCase())).toList()
          ..sort((a, b) => b.path.compareTo(a.path));
        for (final d in dirs) {
          out.add('${d.path}\\$rel');
        }
      } catch (_) {}
    }
    return out;
  }

  /// The editing programs on this PC, in Keepnear's order (looked up once).
  static Future<List<DocEditor>> found() async {
    final f = _found;
    if (f != null) return f;
    final list = <DocEditor>[];
    if (Platform.isWindows) {
      final word = _exeOf(await _reg(r'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\Winword.exe')) ??
          _exeOf(await _reg(r'HKCR\Word.Document.12\shell\open\command'));
      if (word != null) list.add(DocEditor('Word', word, process: 'WINWORD', word: true));
      final wps = _exeOf(await _reg(r'HKCR\KWPS.Document.12\shell\open\command')) ?? _exeOf(await _reg(r'HKCR\KWPS.Docx.12\shell\open\command'));
      if (wps != null) list.add(DocEditor('WPS', wps, process: 'wps'));
      final only = _firstFile([..._under('ONLYOFFICE', r'DesktopEditors\DesktopEditors.exe')]);
      if (only != null) list.add(DocEditor('ONLYOFFICE', only, process: 'DesktopEditors'));
      final libre = _exeOf(await _reg(r'HKCR\LibreOffice.WriterDocument.1\shell\open\command')) ??
          _firstFile(_under('LibreOffice', r'program\swriter.exe'));
      if (libre != null) list.add(DocEditor('LibreOffice', libre, process: 'soffice'));
      final soft = _firstFile([..._under('SoftMaker', 'TextMaker.exe'), ..._under('SoftMaker', 'textmaker.exe')]);
      if (soft != null) list.add(DocEditor('SoftMaker', soft, process: 'TextMaker'));
      final oo = _firstFile(_under('OpenOffice', r'program\swriter.exe'));
      if (oo != null) list.add(DocEditor('OpenOffice', oo, process: 'soffice'));
    }
    DiagLog.log('tools', 'word editors: ${list.map((e) => e.name).join(' → ')}${list.isEmpty ? 'none' : ''}');
    return _found = list;
  }

  /// Word has a licence, by Office's own licence tools (no Word window
  /// opens): OSPP.VBS (bought once: "---LICENSED---") or vnextdiag.ps1
  /// (Microsoft 365: "LicenseState: Licensed"). Neither says so, or neither
  /// can be run: not licensed. Kept in a small file for 30 days (and until
  /// Word itself changes).
  static Future<bool> wordLicensed() async {
    final list = await found();
    final w = list.where((e) => e.word).firstOrNull;
    if (w == null) return false;
    final cached = _licenceCache;
    final stamp = '${File(w.exe).lastModifiedSync().millisecondsSinceEpoch}';
    try {
      if (cached != null && cached.existsSync()) {
        final p = cached.readAsStringSync().trim().split('|');
        final at = DateTime.fromMillisecondsSinceEpoch(int.tryParse(p.first) ?? 0);
        if (p.length == 3 && p[1] == stamp && DateTime.now().difference(at).inDays < 30) return p[2] == '1';
      }
    } catch (_) {}
    var ok = false;
    final why = <String>[];
    final dir = File(w.exe).parent.path; // …\Microsoft Office\root\Office16
    final pf = [Platform.environment['ProgramFiles'], Platform.environment['ProgramFiles(x86)']].whereType<String>();
    final ospp = _firstFile([
      '$dir\\OSPP.VBS',
      '${File(File(dir).parent.path).parent.path}\\Office16\\OSPP.VBS',
      for (final p in pf) '$p\\Microsoft Office\\Office16\\OSPP.VBS',
    ]);
    if (ospp != null) {
      try {
        final r = await Process.run('cscript', ['//nologo', ospp, '/dstatus'], stdoutEncoding: const SystemEncoding()).timeout(const Duration(seconds: 30));
        final out = '${r.stdout}';
        if (out.contains('---LICENSED---')) ok = true;
        why.add('ospp: ${out.contains('---LICENSED---') ? 'licensed' : 'not licensed'}');
      } catch (e) {
        why.add('ospp: $e');
      }
    } else {
      why.add('ospp: none');
    }
    if (!ok) {
      final vnext = _firstFile(['$dir\\vnextdiag.ps1', for (final p in pf) '$p\\Microsoft Office\\root\\Office16\\vnextdiag.ps1']);
      if (vnext != null) {
        try {
          final r = await Process.run('powershell', ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', vnext, '-action', 'list'],
                  stdoutEncoding: const SystemEncoding())
              .timeout(const Duration(seconds: 30));
          final out = '${r.stdout}';
          if (RegExp(r'LicenseState"?\s*:\s*"?Licensed\b').hasMatch(out)) ok = true;
          why.add('vnext: ${ok ? 'licensed' : 'not licensed'}');
        } catch (e) {
          why.add('vnext: $e');
        }
      } else {
        why.add('vnext: none');
      }
    }
    DiagLog.log('tools', 'Word licence: ${ok ? 'yes' : 'no'} (${why.join(', ')})');
    try {
      cached?.parent.createSync(recursive: true);
      cached?.writeAsStringSync('${DateTime.now().millisecondsSinceEpoch}|$stamp|${ok ? 1 : 0}');
    } catch (_) {}
    return ok;
  }

  static File? get _licenceCache {
    final local = Platform.environment['LOCALAPPDATA'];
    return local == null ? null : File('$local\\Keepnear\\word-licence.txt');
  }

  static Future<void> _start(DocEditor e, String path) async {
    await Process.start(e.exe, [path], mode: ProcessStartMode.detached);
  }

  /// Opens [path] for editing in the first program that can: Word only
  /// when it has a licence (else it opens read-only, with a sign-in
  /// window). Null: none; else the program.
  static Future<DocEditor?> open(String path) async {
    final list = await found();
    for (final e in list) {
      if (e.word && !await wordLicensed()) continue;
      try {
        await _start(e, path);
      } catch (x) {
        DiagLog.log('tools', '${e.name} did not start: $x');
        continue;
      }
      DiagLog.log('tools', 'edit in ${e.name}');
      return e;
    }
    return null;
  }

  /// Every window title of the programs running (lower case, one per
  /// line), read as UTF-8.
  static Future<String> titles() async {
    try {
      final r = await Process.run(
        'powershell',
        [
          '-NoProfile',
          '-NonInteractive',
          '-Command',
          "[Console]::OutputEncoding=[Text.Encoding]::UTF8; Get-Process | Where-Object { \$_.MainWindowTitle } | ForEach-Object { \$_.MainWindowTitle }",
        ],
        stdoutEncoding: utf8,
      );
      return '${r.stdout}'.toLowerCase();
    } catch (_) {
      return '';
    }
  }
}
