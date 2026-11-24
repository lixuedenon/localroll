// apps/desktop/lib/services/office_engines.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:localroll_core/localroll_core.dart' show DiagLog;

/// The office programs that can do our Office conversions on this PC.
enum OfficeApp { office, wps, libre }

extension OfficeAppName on OfficeApp {
  String get label => switch (this) {
        OfficeApp.office => 'Office',
        OfficeApp.wps => 'WPS',
        OfficeApp.libre => 'LibreOffice',
      };
}

/// Conversions that need an office program (Word / Excel / PowerPoint →
/// PDF, PDF → Word, Word ↔ TXT, Excel ↔ CSV): done by Microsoft Office if
/// it is there, else WPS, else LibreOffice (free) — or the one chosen.
/// One at a time (two copies of these programs at once often fail).
class OfficeEngines {
  OfficeEngines._();

  static Set<OfficeApp>? _have;
  static String? _soffice;

  /// "auto", or an [OfficeApp] name: the one to try first.
  static String preferred = 'auto';

  /// Where LibreOffice's command-line program is (null: not installed).
  static String? get soffice => _soffice;

  /// Which are installed (looked up once).
  static Future<Set<OfficeApp>> installed() async {
    final h = _have;
    if (h != null) return h;
    final found = <OfficeApp>{};
    if (Platform.isWindows) {
      Future<bool> reg(String key) async {
        try {
          return (await Process.run('reg', ['query', key])).exitCode == 0;
        } catch (_) {
          return false;
        }
      }

      if (await reg(r'HKCR\Word.Application\CLSID') || await reg(r'HKCR\Excel.Application\CLSID') || await reg(r'HKCR\PowerPoint.Application\CLSID')) {
        found.add(OfficeApp.office);
      }
      if (await reg(r'HKCR\KWPS.Application\CLSID') || await reg(r'HKCR\KET.Application\CLSID') || await reg(r'HKCR\KWPP.Application\CLSID')) {
        found.add(OfficeApp.wps);
      }
      _soffice = await _findSoffice();
      if (_soffice != null) found.add(OfficeApp.libre);
    }
    DiagLog.log('tools', 'office programs: ${found.map((a) => a.label).join(', ')}${found.isEmpty ? 'none' : ''}');
    return _have = found;
  }

  /// Looked up again (after the user installed one).
  static void forget() => _have = null;

  static Future<String?> _findSoffice() async {
    final dirs = <String>[];
    try {
      final r = await Process.run('reg', ['query', r'HKLM\SOFTWARE\LibreOffice\UNO\InstallPath', '/ve']);
      final m = RegExp(r'REG_SZ\s+(.+)').firstMatch('${r.stdout}');
      if (m != null) dirs.add(m.group(1)!.trim());
    } catch (_) {}
    for (final env in ['ProgramFiles', 'ProgramFiles(x86)', 'ProgramW6432']) {
      final p = Platform.environment[env];
      if (p != null) dirs.add('$p\\LibreOffice\\program');
    }
    for (final d in dirs) {
      // soffice.com waits until done; soffice.exe may return at once.
      for (final n in ['soffice.com', 'soffice.exe']) {
        final f = File('$d\\$n');
        if (f.existsSync()) return f.path;
      }
    }
    return null;
  }

  /// Which program would do [kind] on [src] (null: none can). WPS can't
  /// turn a PDF into Word for another program (only inside WPS itself).
  static OfficeApp? pickFrom(Set<OfficeApp> have, String kind, String src) {
    final pdfIn = src.toLowerCase().endsWith('.pdf');
    final order = [OfficeApp.office, OfficeApp.wps, OfficeApp.libre];
    final first = OfficeApp.values.where((a) => a.name == preferred).firstOrNull;
    if (first != null) {
      order
        ..remove(first)
        ..insert(0, first);
    }
    for (final a in order) {
      if (!have.contains(a)) continue;
      if (a == OfficeApp.wps && pdfIn && kind == 'wordDocx') continue;
      return a;
    }
    return null;
  }

  static Future<void> _line = Future.value();

  /// The program working now (PowerShell driving Office / WPS, or
  /// LibreOffice): stopped by [cancel].
  static Process? _running;
  static bool _stopped = false;

  /// Stops the conversion running now: its process, and the Word / Excel /
  /// PowerPoint / WPS it started in the background (only those: they have
  /// "-Embedding" / "/Automation" in their command line).
  static Future<void> cancel() async {
    _stopped = true;
    final p = _running;
    if (p != null) {
      try {
        await Process.run('taskkill', ['/T', '/F', '/PID', '${p.pid}']);
      } catch (_) {}
    }
    try {
      await Process.run('powershell', [
        '-NoProfile',
        '-NonInteractive',
        '-Command',
        "Get-CimInstance Win32_Process | Where-Object { @('WINWORD.EXE','EXCEL.EXE','POWERPNT.EXE','wps.exe','et.exe','wpp.exe') -contains \$_.Name -and \$_.CommandLine -match 'Embedding|Automation' } | ForEach-Object { Stop-Process -Id \$_.ProcessId -Force }",
      ]);
    } catch (_) {}
    DiagLog.log('tools', 'office conversion stopped');
  }

  /// [exe] [args] to the end (or [limit]); its error output, or why it
  /// didn't run. The process can be stopped by [cancel].
  static Future<String?> _exec(String exe, List<String> args, Duration limit) async {
    try {
      final p = await Process.start(exe, args);
      _running = p;
      final err = StringBuffer();
      final a = p.stdout.drain<void>();
      final b = p.stderr.transform(const SystemEncoding().decoder).forEach(err.write);
      await p.exitCode.timeout(limit, onTimeout: () {
        p.kill();
        throw TimeoutException('timeout');
      });
      await Future.wait([a, b]);
      final t = '$err'.trim();
      return t.isEmpty ? null : (t.length > 300 ? t.substring(0, 300) : t);
    } on TimeoutException {
      return 'timeout';
    } catch (e) {
      return '$e';
    } finally {
      _running = null;
    }
  }

  /// [kind] ('pdf', 'wordDocx', 'wordTxt', 'excelCsv', 'excelXlsx') from
  /// [src] into [out]. Null when done, else why not.
  static Future<String?> run(String kind, String src, String out) {
    final done = Completer<String?>();
    _line = _line.then((_) async {
      try {
        done.complete(await _run(kind, src, out));
      } catch (e) {
        done.complete('$e');
      }
    });
    return done.future;
  }

  static Future<String?> _run(String kind, String src, String out) async {
    _stopped = false;
    final app = pickFrom(await installed(), kind, src);
    if (app == null) return 'no_office';
    final err = switch (app) {
      OfficeApp.libre => await _libre(kind, src, out),
      _ => await _com(app, kind, src, out),
    };
    if (_stopped) return 'cancelled';
    if (err == null && kind == 'wordTxt') await _toUtf8(out);
    if (err != null) DiagLog.log('tools', '${app.label} $kind failed: $err');
    return err;
  }

  static String _ext(String p) {
    final n = p.split(RegExp(r'[\\/]')).last;
    final dot = n.lastIndexOf('.');
    return dot < 0 ? '' : n.substring(dot + 1).toLowerCase();
  }

  static const _word = {'doc', 'docx', 'rtf', 'odt', 'wps', 'txt', 'md', 'log', 'pdf'};
  static const _excel = {'xls', 'xlsx', 'xlsm', 'csv', 'ods', 'et'};

  /// Microsoft Office or WPS through their programming interface (WPS's
  /// copies of Word / Excel / PowerPoint answer the same calls).
  static Future<String?> _com(OfficeApp app, String kind, String src, String out) async {
    final wps = app == OfficeApp.wps;
    final e = _ext(src);
    final s = src.replaceAll("'", "''"), o = out.replaceAll("'", "''");
    final text = e == 'txt' || e == 'md' || e == 'log';
    final String script;
    if (kind == 'excelCsv' || kind == 'excelXlsx' || (kind == 'pdf' && _excel.contains(e))) {
      final prog = wps ? 'KET.Application' : 'Excel.Application';
      final save = switch (kind) {
        'excelCsv' => "try{\$d.SaveAs('$o',62)}catch{\$d.SaveAs('$o',6)}",
        'excelXlsx' => "\$d.SaveAs('$o',51)",
        _ => "\$d.ExportAsFixedFormat(0,'$o')",
      };
      final open = kind == 'excelXlsx' && !wps
          ? "\$a.Workbooks.OpenText('$s',65001,1,1,1,\$false,\$false,\$false,\$true);\$d=\$a.ActiveWorkbook;"
          : "\$d=\$a.Workbooks.Open('$s',0,\$true);";
      script = "\$a=New-Object -ComObject $prog;\$a.Visible=\$false;\$a.DisplayAlerts=\$false;"
          "try{$open$save;\$d.Close(\$false)}finally{\$a.Quit()}";
    } else if (kind == 'pdf' && !_word.contains(e)) {
      // PowerPoint.
      final prog = wps ? 'KWPP.Application' : 'PowerPoint.Application';
      script = "\$a=New-Object -ComObject $prog;"
          "try{\$d=\$a.Presentations.Open('$s',\$true,\$false,\$false);\$d.SaveAs('$o',32);\$d.Close()}finally{\$a.Quit()}";
    } else {
      final prog = wps ? 'KWPS.Application' : 'Word.Application';
      // Word: a PDF opened in Word becomes an editable document (Word's
      // own "PDF Reflow"; its question switched off first).
      final quiet = !wps && e == 'pdf'
          ? "try{\$k='HKCU:\\Software\\Microsoft\\Office\\'+\$a.Version+'\\Word\\Options';if(!(Test-Path \$k)){New-Item \$k|Out-Null};"
              "Set-ItemProperty \$k DisableConvertPdfWarning 1 -Type DWord}catch{};"
          : '';
      final open = text ? "\$d=\$a.Documents.Open('$s',\$false,\$true,\$false,'','',\$false,'','',5,65001);" : "\$d=\$a.Documents.Open('$s',\$false,\$true);";
      final save = switch (kind) {
        'wordDocx' => "\$d.SaveAs('$o',12)",
        'wordTxt' => "\$d.SaveAs('$o',7)",
        _ => "try{\$d.ExportAsFixedFormat('$o',17)}catch{\$d.SaveAs('$o',17)}",
      };
      script = "\$a=New-Object -ComObject $prog;\$a.Visible=\$false;try{\$a.DisplayAlerts=0}catch{};$quiet"
          "try{$open$save;\$d.Close(\$false)}finally{\$a.Quit()}";
    }
    final err = await _ps(script);
    if (await _made(out)) return null;
    return err ?? 'no file';
  }

  /// LibreOffice from the command line, in a profile of its own (so it
  /// works even while LibreOffice is open).
  static Future<String?> _libre(String kind, String src, String out) async {
    final exe = _soffice;
    if (exe == null) return 'no_office';
    final e = _ext(src);
    final tmp = await Directory.systemTemp.createTemp('lr_lo');
    final profile = Directory('${Directory.systemTemp.path}\\lr_lo_profile');
    final (String? infilter, String to) = switch (kind) {
      'wordDocx' => (e == 'pdf' ? 'writer_pdf_import' : (e == 'txt' || e == 'md' || e == 'log' ? 'Text (encoded):UTF8' : null), 'docx:MS Word 2007 XML'),
      'wordTxt' => (null, 'txt:Text (encoded):UTF8'),
      'excelCsv' => (null, 'csv:Text - txt - csv (StarCalc):44,34,76'),
      'excelXlsx' => ('CSV:44,34,76', 'xlsx:Calc MS Excel 2007 XML'),
      _ => (null, 'pdf'),
    };
    final args = [
      '-env:UserInstallation=${Uri.directory(profile.path, windows: true)}',
      '--headless',
      '--norestore',
      '--nologo',
      if (infilter != null) '--infilter=$infilter',
      '--convert-to',
      to,
      '--outdir',
      tmp.path,
      src,
    ];
    var err = await _exec(exe, args, const Duration(minutes: 3));
    // soffice.exe may come back before the file is written.
    File? made;
    for (var i = 0; i < 60 && made == null && !_stopped; i++) {
      final files = tmp.existsSync() ? tmp.listSync().whereType<File>().toList() : <File>[];
      if (files.isNotEmpty && files.first.lengthSync() > 0) {
        made = files.first;
      } else {
        await Future<void>.delayed(const Duration(seconds: 1));
      }
    }
    try {
      if (made != null) {
        await made.copy(out);
        await tmp.delete(recursive: true);
        return null;
      }
      await tmp.delete(recursive: true);
    } catch (x) {
      err ??= '$x';
    }
    return err ?? 'no file';
  }

  static Future<bool> _made(String out) async {
    final f = File(out);
    return await f.exists() && await f.length() > 0;
  }

  /// Text saved as UTF-16 (Word's "Unicode text") → UTF-8.
  static Future<void> _toUtf8(String path) async {
    try {
      final b = await File(path).readAsBytes();
      if (b.length >= 2 && b[0] == 0xFF && b[1] == 0xFE) {
        final units = <int>[for (var i = 2; i + 1 < b.length; i += 2) b[i] | (b[i + 1] << 8)];
        await File(path).writeAsString(String.fromCharCodes(units), encoding: utf8);
      }
    } catch (_) {}
  }

  /// PowerShell, encoded (paths with any characters survive).
  static Future<String?> _ps(String script) async {
    final units = <int>[];
    for (final u in script.codeUnits) {
      units
        ..add(u & 0xFF)
        ..add(u >> 8);
    }
    return _exec('powershell', ['-NoProfile', '-NonInteractive', '-EncodedCommand', base64.encode(units)], const Duration(minutes: 3));
  }

  /// Opens [path] in another program: Word or LibreOffice by name, or
  /// Windows' own "Open with" list (where WPS and others are).
  static Future<void> openWith(String path, OfficeApp? app) async {
    try {
      switch (app) {
        case OfficeApp.office:
          await Process.start('cmd', ['/c', 'start', '', 'winword', path], mode: ProcessStartMode.detached);
        case OfficeApp.libre:
          final exe = _soffice;
          if (exe != null) {
            await Process.start(exe.replaceAll('soffice.com', 'soffice.exe'), [path], mode: ProcessStartMode.detached);
          }
        default:
          await Process.start('rundll32', ['shell32.dll,OpenAs_RunDLL', path], mode: ProcessStartMode.detached);
      }
    } catch (e) {
      DiagLog.log('tools', 'open with: $e');
    }
  }
}
