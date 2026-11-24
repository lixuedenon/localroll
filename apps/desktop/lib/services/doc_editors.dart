// apps/desktop/lib/services/doc_editors.dart
import 'dart:async';
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

  /// Word found without a licence (it opens read-only, with a sign-in
  /// window): not used for editing on this PC. Kept for the session.
  static bool wordUnlicensed = false;

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

  /// Word has a licence, as far as can be told without opening it: Office's
  /// own licence check (OSPP.VBS) says LICENSED, or a Microsoft 365 sign-in
  /// licence is there.
  static Future<bool> _wordLicensed(String exe) async {
    try {
      final dir = File(exe).parent.path;
      final ospp = _firstFile(['$dir\\OSPP.VBS', '${File(dir).parent.path}\\Office16\\OSPP.VBS']);
      if (ospp != null) {
        final r = await Process.run('cscript', ['//nologo', ospp, '/dstatus']).timeout(const Duration(seconds: 20));
        if ('${r.stdout}'.contains('---LICENSED---')) return true;
      }
      final local = Platform.environment['LOCALAPPDATA'];
      if (local != null) {
        final lic = Directory('$local\\Microsoft\\Office\\Licenses');
        if (lic.existsSync() && lic.listSync(recursive: true).whereType<File>().isNotEmpty) return true;
      }
    } catch (e) {
      DiagLog.log('tools', 'word licence check: $e');
    }
    return false;
  }

  static const _noLicence = [
    'unlicensed',
    'product activation failed',
    '未经授权',
    '未授权',
    '產品啟用失敗',
    '未經授權',
    '产品激活失败',
    'nicht lizenziert',
    'sans licence',
    'sin licencia',
  ];

  /// [process]'s window titles, lower case, one per line.
  static Future<String> _titles(String process) async {
    try {
      final r = await Process.run('powershell', [
        '-NoProfile',
        '-NonInteractive',
        '-Command',
        "[Console]::OutputEncoding=[Text.Encoding]::UTF8; Get-Process $process -ErrorAction SilentlyContinue | ForEach-Object { \$_.MainWindowTitle }",
      ]);
      return '${r.stdout}'.toLowerCase();
    } catch (_) {
      return '';
    }
  }

  /// Closes [process]'s window showing [name] (it was opened just now,
  /// nothing changed in it).
  static Future<void> _closeWindow(String process, String name) async {
    try {
      await Process.run('powershell', [
        '-NoProfile',
        '-NonInteractive',
        '-Command',
        "Get-Process $process -ErrorAction SilentlyContinue | Where-Object { \$_.MainWindowTitle -like '*${name.replaceAll("'", "''")}*' } | ForEach-Object { [void]\$_.CloseMainWindow() }",
      ]);
    } catch (_) {}
  }

  static Future<void> _start(DocEditor e, String path) async {
    await Process.start(e.exe, [path], mode: ProcessStartMode.detached);
  }

  /// Opens [path] for editing in the first program that can; Word without a
  /// licence is skipped (checked first; if its window still says so, it is
  /// closed and the next one used). Null: none; else the program's name.
  static Future<String?> open(String path) async {
    final list = await found();
    for (var i = 0; i < list.length; i++) {
      final e = list[i];
      final rest = list.length - i - 1;
      if (e.word) {
        if (wordUnlicensed && rest > 0) continue;
        if (rest > 0 && !await _wordLicensed(e.exe)) {
          wordUnlicensed = true;
          DiagLog.log('tools', 'Word has no licence here: the next program edits');
          continue;
        }
      }
      try {
        await _start(e, path);
      } catch (x) {
        DiagLog.log('tools', '${e.name} did not start: $x');
        continue;
      }
      if (e.word && rest > 0) {
        // Its window says "Unlicensed": closed, the next one.
        final name = path.split('\\').last;
        final stem = name.contains('.') ? name.substring(0, name.lastIndexOf('.')) : name;
        for (var k = 0; k < 15; k++) {
          await Future<void>.delayed(const Duration(seconds: 2));
          final lines = (await _titles(e.process!)).split('\n').where((t) => t.contains(stem.toLowerCase()));
          if (lines.isEmpty) continue;
          if (lines.any((t) => _noLicence.any(t.contains))) {
            wordUnlicensed = true;
            DiagLog.log('tools', 'Word opened without a licence: closed, the next program edits');
            await _closeWindow(e.process!, stem);
          }
          break;
        }
        if (wordUnlicensed) continue;
      }
      DiagLog.log('tools', 'edit in ${e.name}');
      return e.name;
    }
    return null;
  }
}
