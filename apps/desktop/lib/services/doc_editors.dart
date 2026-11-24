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

  /// Office products without Word (their licence says nothing about Word):
  /// a free OneNote is "licensed" on a PC whose Word is not.
  static final _noWord = RegExp(r'onenote|visio|project|access|publisher|excel|powerpoint|outlook|skype|lync|teams|groove|infopath', caseSensitive: false);

  /// Word has a licence, by Office's own licence tools (no Word window
  /// opens), for the product that has Word in it only:
  /// - Click-to-Run products (registry ProductReleaseIds) run by vNext
  ///   (Microsoft 365): vnextdiag.ps1 must list a licence ("LicenseState:
  ///   Licensed"); none listed = not activated (signed out, trial over).
  /// - The others (bought once, volume): OSPP.VBS, read one licence at a
  ///   time — a LICENSED one whose name is a product with Word.
  /// Neither can be run: not licensed. Kept in a small file for 30 days
  /// (and until Word itself changes).
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
    final why = <String>[];
    final dir = File(w.exe).parent.path; // …\Microsoft Office\root\Office16
    final pf = [Platform.environment['ProgramFiles'], Platform.environment['ProgramFiles(x86)']].whereType<String>();
    // The Click-to-Run products with Word in them.
    final ids = ((await _reg(r'HKLM\SOFTWARE\Microsoft\Office\ClickToRun\Configuration', value: 'ProductReleaseIds')) ?? '')
        .split(',')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
    final wordIds = ids.where((e) => !_noWord.hasMatch(e)).toList();
    why.add('products: ${ids.isEmpty ? 'none listed' : ids.join(' ')}');
    // vNext: which products it runs, and the licences it holds.
    var vnextIds = <String>{};
    var vnextOk = false;
    final vnext = _firstFile(['$dir\\vnextdiag.ps1', for (final p in pf) '$p\\Microsoft Office\\root\\Office16\\vnextdiag.ps1']);
    if (vnext != null) {
      try {
        final r = await Process.run('powershell', ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', vnext, '-action', 'list'],
                stdoutEncoding: const SystemEncoding())
            .timeout(const Duration(seconds: 30));
        final out = '${r.stdout}';
        vnextIds = {for (final m in RegExp(r'^\s*(\S+)\s*=\s*vNext\s*$', multiLine: true, caseSensitive: false).allMatches(out)) m.group(1)!.toLowerCase()};
        // A licence for a product with Word ("ProductReleases": ["O365…"]).
        for (final m in RegExp(r'LicenseState"?\s*:\s*"?Licensed\b', caseSensitive: false).allMatches(out)) {
          final near = out.substring((m.start - 1500).clamp(0, out.length), (m.end + 1500).clamp(0, out.length));
          final names = RegExp(r'[A-Za-z0-9]+Retail|[A-Za-z0-9]+Volume', caseSensitive: false).allMatches(near).map((x) => x.group(0)!).toList();
          if (names.isEmpty || names.any((n) => !_noWord.hasMatch(n))) vnextOk = true;
        }
        why.add('vnext: runs ${vnextIds.isEmpty ? 'none' : vnextIds.join(' ')}, ${vnextOk ? 'a Word licence' : 'no Word licence'}');
      } catch (e) {
        why.add('vnext: $e');
      }
    } else {
      why.add('vnext: none');
    }
    var ok = false;
    final byVnext = wordIds.where((e) => vnextIds.contains(e.toLowerCase())).toList();
    if (byVnext.isNotEmpty && vnextOk) ok = true;
    // Products not run by vNext (or no list at all): OSPP, licence by licence.
    final rest = wordIds.where((e) => !vnextIds.contains(e.toLowerCase())).toList();
    if (!ok && (rest.isNotEmpty || ids.isEmpty)) {
      final ospp = _firstFile([
        '$dir\\OSPP.VBS',
        '${File(File(dir).parent.path).parent.path}\\Office16\\OSPP.VBS',
        for (final p in pf) '$p\\Microsoft Office\\Office16\\OSPP.VBS',
      ]);
      if (ospp != null) {
        try {
          final r = await Process.run('cscript', ['//nologo', ospp, '/dstatus'], stdoutEncoding: const SystemEncoding()).timeout(const Duration(seconds: 30));
          final out = '${r.stdout}';
          final good = <String>[];
          for (final block in out.split(RegExp(r'-{20,}'))) {
            if (!block.contains('---LICENSED---')) continue;
            final name = RegExp(r'LICENSE NAME:\s*(.+)').firstMatch(block)?.group(1)?.trim() ?? '';
            if (name.isEmpty || _noWord.hasMatch(name)) continue;
            good.add(name);
          }
          if (good.isNotEmpty) ok = true;
          why.add('ospp: ${good.isEmpty ? 'no Word licence' : good.join('; ')}');
        } catch (e) {
          why.add('ospp: $e');
        }
      } else {
        why.add('ospp: none');
      }
    }
    DiagLog.log('tools', 'Word licence: ${ok ? 'yes' : 'no'} (${why.join(', ')})');
    _remember(ok, stamp);
    return ok;
  }

  static void _remember(bool ok, String? stamp) {
    final cached = _licenceCache;
    try {
      stamp ??= () {
        final w = _found?.where((e) => e.word).firstOrNull;
        return w == null ? '0' : '${File(w.exe).lastModifiedSync().millisecondsSinceEpoch}';
      }();
      cached?.parent.createSync(recursive: true);
      cached?.writeAsStringSync('${DateTime.now().millisecondsSinceEpoch}|$stamp|${ok ? 1 : 0}');
    } catch (_) {}
  }

  static File? get _licenceCache {
    final local = Platform.environment['LOCALAPPDATA'];
    return local == null ? null : File('$local\\Keepnear\\word-licence-2.txt');
  }

  static Future<void> _start(DocEditor e, String path) async {
    await Process.start(e.exe, [path], mode: ProcessStartMode.detached);
  }

  /// The programs that can edit now (Word only when activated), in order.
  static Future<List<DocEditor>> usable() async {
    final out = <DocEditor>[];
    for (final e in await found()) {
      if (e.word && !await wordLicensed()) continue;
      out.add(e);
    }
    return out;
  }

  /// Words in Word's title when it has no licence ("… - Word (Unlicensed
  /// Product)"), in the languages Keepnear speaks.
  static const _unlicensed = [
    'unlicensed', 'activation failed', '未经授权', '未授权', '未經授權', '未授權', 'ライセンスのない', 'ライセンスされていない', '라이선스가 없는', '정품 인증 실패',
    'nicht lizenziert', 'sans licence', 'sin licencia', 'sem licença', 'não licenciado', 'senza licenza', 'без лицензии', 'нелицензированн', 'غير مرخص',
    'बिना लाइसेंस', 'tidak berlisensi', 'ไม่มีสิทธิ์', 'lisanssız', 'không có giấy phép',
  ];

  /// Opens [path] for editing: [first] (when given), then the others that
  /// can, in order. Word is checked once more by its window: one that says
  /// "unlicensed" is closed again, remembered as not activated, and the
  /// next program is used. Null: none could.
  static Future<({DocEditor? by, bool wordRefused})> open(String path, {DocEditor? first}) async {
    final list = await usable();
    final order = [if (first != null && list.any((e) => e.exe == first.exe)) first, ...list.where((e) => e.exe != first?.exe)];
    var refused = false;
    for (final e in order) {
      try {
        await _start(e, path);
      } catch (x) {
        DiagLog.log('tools', '${e.name} did not start: $x');
        continue;
      }
      DiagLog.log('tools', 'edit in ${e.name}');
      if (e.word && !await _wordWindowOk(path)) {
        refused = true;
        _remember(false, null);
        continue;
      }
      return (by: e, wordRefused: refused);
    }
    return (by: null, wordRefused: refused);
  }

  /// Word's window for [path], up to 25 s: false when its title says it has
  /// no licence (that document is then closed: read-only, nothing to save).
  static Future<bool> _wordWindowOk(String path) async {
    final name = path.split('\\').last;
    final stem = (name.contains('.') ? name.substring(0, name.lastIndexOf('.')) : name).toLowerCase();
    final end = DateTime.now().add(const Duration(seconds: 25));
    while (DateTime.now().isBefore(end)) {
      await Future<void>.delayed(const Duration(seconds: 2));
      final mine = (await titles()).split('\n').where((t) => t.contains(stem)).toList();
      if (mine.isEmpty) continue;
      if (mine.any((t) => _unlicensed.any(t.contains))) {
        DiagLog.log('tools', 'Word says it has no licence ("${mine.first.trim()}"): closed, next program');
        await _closeInWord(path);
        return false;
      }
      return true;
    }
    return true;
  }

  static Future<void> _closeInWord(String path) async {
    final p = path.replaceAll("'", "''");
    try {
      await Process.run('powershell', [
        '-NoProfile',
        '-NonInteractive',
        '-Command',
        "try { \$w=[Runtime.InteropServices.Marshal]::GetActiveObject('Word.Application'); foreach (\$d in @(\$w.Documents)) { if (\$d.FullName -ieq '$p') { \$d.Close(0) } }; if (\$w.Documents.Count -eq 0) { \$w.Quit(0) } } catch {}",
      ]).timeout(const Duration(seconds: 20));
    } catch (_) {}
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
