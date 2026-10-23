// apps/desktop/lib/services/windows_ocr.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:localroll_core/localroll_core.dart';

/// Windows' own text recognition (Windows.Media.Ocr), run in one PowerShell
/// process that stays open: a picture in, its lines of text out. Nothing
/// leaves this PC; nothing to install (the languages are Windows' own).
const String _ocrScript = r"""
param([string]$In)
$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false } catch {}
Add-Type -AssemblyName System.Runtime.WindowsRuntime
$asTask = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
  $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1'
})[0]
function Await($op, [Type]$t) {
  $task = $asTask.MakeGenericMethod($t).Invoke($null, @($op))
  $task.Wait(-1) | Out-Null
  $task.Result
}
$null = [Windows.Storage.StorageFile, Windows.Storage, ContentType = WindowsRuntime]
$null = [Windows.Storage.Streams.IRandomAccessStream, Windows.Storage.Streams, ContentType = WindowsRuntime]
$null = [Windows.Media.Ocr.OcrEngine, Windows.Foundation, ContentType = WindowsRuntime]
$null = [Windows.Graphics.Imaging.BitmapDecoder, Windows.Graphics, ContentType = WindowsRuntime]
$null = [Windows.Globalization.Language, Windows.Globalization, ContentType = WindowsRuntime]
$engines = @{}
function Engine([string]$tag) {
  if (-not $engines.ContainsKey($tag)) {
    $e = $null
    if ($tag) { $e = [Windows.Media.Ocr.OcrEngine]::TryCreateFromLanguage([Windows.Globalization.Language]::new($tag)) }
    if (-not $e) { $e = [Windows.Media.Ocr.OcrEngine]::TryCreateFromUserProfileLanguages() }
    $engines[$tag] = $e
  }
  $engines[$tag]
}
# One request per line in the file given; one answer per line, in order.
foreach ($line in [System.IO.File]::ReadAllLines($In, [System.Text.Encoding]::UTF8)) {
  if (-not $line.Trim()) { continue }
  $out = @{}
  try {
    $req = $line | ConvertFrom-Json
    if ($req.cmd -eq 'langs') {
      $out.available = @([Windows.Media.Ocr.OcrEngine]::AvailableRecognizerLanguages | ForEach-Object { $_.LanguageTag })
      $out.max = [Windows.Media.Ocr.OcrEngine]::MaxImageDimension
    } else {
      $e = Engine $req.lang
      if (-not $e) { throw 'no_engine' }
      $file = Await ([Windows.Storage.StorageFile]::GetFileFromPathAsync($req.path)) ([Windows.Storage.StorageFile])
      $stream = Await ($file.OpenAsync([Windows.Storage.FileAccessMode]::Read)) ([Windows.Storage.Streams.IRandomAccessStream])
      try {
        $dec = Await ([Windows.Graphics.Imaging.BitmapDecoder]::CreateAsync($stream)) ([Windows.Graphics.Imaging.BitmapDecoder])
        $bmp = Await ($dec.GetSoftwareBitmapAsync()) ([Windows.Graphics.Imaging.SoftwareBitmap])
        $res = Await ($e.RecognizeAsync($bmp)) ([Windows.Media.Ocr.OcrResult])
        $out.lines = @($res.Lines | ForEach-Object { $_.Text })
        $out.lang = $e.RecognizerLanguage.LanguageTag
      } finally {
        $stream.Dispose()
      }
    }
  } catch {
    $out.error = "$($_.Exception.GetBaseException().Message)"
  }
  [Console]::Out.WriteLine(($out | ConvertTo-Json -Compress -Depth 3))
  [Console]::Out.Flush()
}
""";

/// What this PC's Windows can read.
class OcrLanguages {
  const OcrLanguages(this.available, {this.maxDimension = 0});

  /// Language tags with a recognizer installed ("zh-Hans-CN", "en-US"…).
  final List<String> available;

  /// Largest picture side the recognizer takes (pixels).
  final int maxDimension;

  bool get any => available.isNotEmpty;

  /// Chinese (simplified or traditional) can be read.
  bool get chinese => available.any((t) => t.toLowerCase().startsWith('zh'));

  /// The language to read with: Chinese first (it reads Latin letters too),
  /// then Japanese / Korean, else Windows' own choice.
  String? get preferred {
    String? find(bool Function(String t) ok) {
      for (final t in available) {
        if (ok(t.toLowerCase())) return t;
      }
      return null;
    }

    return find((t) => t.startsWith('zh-hans') || t == 'zh-cn' || t.startsWith('zh-cn')) ??
        find((t) => t.startsWith('zh')) ??
        find((t) => t.startsWith('ja')) ??
        find((t) => t.startsWith('ko')) ??
        (available.isEmpty ? null : available.first);
  }
}

/// Text recognition with Windows' own engine (Windows only). Each batch is
/// one short PowerShell run: the requests go in a file, the answers come
/// back one per line and PowerShell ends. (A PowerShell kept open and
/// talked to through its input never answered when started from LocalRoll
/// on some PCs, while the very same script answered at once when run like
/// this.)
class WindowsOcr {
  static bool get supported => Platform.isWindows;

  /// Why reading doesn't work on this PC (null: it does, or not known yet).
  String? problem;

  Future<void> _chain = Future.value();
  final Set<Process> _running = {};
  int _n = 0;

  /// Runs [reqs] (one at a time per PC); null if PowerShell gave no usable
  /// answer in time.
  Future<List<Map<String, dynamic>>?> _run(List<Map<String, dynamic>> reqs, {Duration? limit}) {
    final next = _chain.then((_) => _runNow(reqs, limit ?? Duration(seconds: 40 + 20 * reqs.length)));
    _chain = next.then((_) {}, onError: (_) {});
    return next;
  }

  Future<List<Map<String, dynamic>>?> _runNow(List<Map<String, dynamic>> reqs, Duration limit) async {
    final sep = Platform.pathSeparator;
    final tmp = Directory.systemTemp.path;
    final script = File('$tmp${sep}localroll-ocr.ps1');
    final input = File('$tmp${sep}localroll-ocr-${pid}_${_n++}.txt');
    final out = StringBuffer();
    final err = StringBuffer();
    Process? p;
    try {
      if (!await script.exists() || await script.readAsString() != _ocrScript) await script.writeAsString(_ocrScript);
      await input.writeAsString('${reqs.map(jsonEncode).join('\n')}\n', encoding: utf8);
      p = await Process.start('powershell', [
        '-NoProfile',
        '-NonInteractive',
        '-ExecutionPolicy',
        'Bypass',
        '-File',
        script.path,
        '-In',
        input.path,
      ]);
      _running.add(p);
      // Nothing comes on its input: closed right away.
      unawaited(p.stdin.close().catchError((_) {}));
      final o = p.stdout.transform(utf8.decoder).forEach(out.write);
      final e = p.stderr.transform(utf8.decoder).forEach(err.write);
      final code = await p.exitCode.timeout(limit, onTimeout: () {
        p?.kill();
        return -999;
      });
      await Future.wait([o, e]).timeout(const Duration(seconds: 5), onTimeout: () => const []);
      final lines = [for (final l in const LineSplitter().convert(out.toString())) if (l.trim().isNotEmpty) l.trim()];
      if (code == -999 || lines.length < reqs.length) {
        final why = code == -999 ? 'no answer in ${limit.inSeconds}s' : 'ended ($code)';
        DiagLog.log('ocr', '$why; answers ${lines.length}/${reqs.length}; '
            'output: ${_short(out.toString())}; errors: ${_short(err.toString())}');
        problem = err.toString().trim().isNotEmpty ? _short(err.toString()) : why;
        return null;
      }
      problem = null;
      return [
        for (final l in lines.take(reqs.length))
          () {
            try {
              final v = jsonDecode(l);
              return v is Map<String, dynamic> ? v : <String, dynamic>{'error': 'bad answer'};
            } catch (_) {
              return <String, dynamic>{'error': 'bad answer: ${_short(l)}'};
            }
          }(),
      ];
    } catch (e) {
      DiagLog.log('ocr', 'could not run PowerShell: $e');
      problem = '$e';
      return null;
    } finally {
      if (p != null) _running.remove(p);
      try {
        await input.delete();
      } catch (_) {}
    }
  }

  static String _short(String s) {
    final t = s.trim().replaceAll(RegExp(r'\s+'), ' ');
    return t.length > 300 ? '${t.substring(0, 300)}…' : t;
  }

  OcrLanguages? _langs;

  /// The languages Windows can read (asked once; [refresh] asks again,
  /// e.g. after a language was installed). Also the check that reading
  /// works on this PC at all ([problem] says why not).
  Future<OcrLanguages> languages({bool refresh = false}) async {
    if (!supported) return const OcrLanguages([]);
    final known = _langs;
    if (known != null && !refresh) return known;
    final r = await _run([
      {'cmd': 'langs'},
    ], limit: const Duration(seconds: 60));
    if (r == null) return const OcrLanguages([]);
    final a = r.first;
    if (a['error'] != null) {
      DiagLog.log('ocr', 'languages: ${a['error']}');
      problem = '${a['error']}';
      return const OcrLanguages([]);
    }
    final list = a['available'];
    final l = OcrLanguages(
      <String>[if (list is List) ...list.whereType<String>() else if (list is String) list],
      maxDimension: (a['max'] as num?)?.toInt() ?? 0,
    );
    DiagLog.log('ocr', 'ready: ${l.available.join(', ')}');
    return _langs = l;
  }

  /// The text in each picture (lines joined; '' if none; null for one that
  /// could not be read). Null: nothing could be read at all (PowerShell gave
  /// no answer; see [problem]).
  Future<List<String?>?> readMany(List<String> imagePaths) async {
    if (imagePaths.isEmpty) return const [];
    final langs = await languages();
    if (!langs.any) return null;
    final r = await _run([
      for (final p in imagePaths) {'cmd': 'ocr', 'path': p, 'lang': langs.preferred ?? ''},
    ]);
    if (r == null) return null;
    return [
      for (var i = 0; i < imagePaths.length; i++)
        () {
          final a = r[i];
          final err = a['error'];
          if (err != null) {
            DiagLog.log('ocr', 'not read: $err');
            return null;
          }
          final lines = a['lines'];
          return tidyOcrText(lines is List ? lines.whereType<String>().join('\n') : (lines is String ? lines : ''));
        }(),
    ];
  }

  /// One picture (see [readMany]).
  Future<String?> read(String imagePath) async => (await readMany([imagePath]))?.first;

  void close() {
    _langs = null;
    for (final p in _running.toList()) {
      p.kill();
    }
  }
}

/// Windows reads Chinese / Japanese / Korean one character at a time with
/// spaces between: those spaces go.
String tidyOcrText(String text) {
  const cjk = r'぀-ヿ㐀-䶿一-鿿豈-﫿가-힯＀-￯　-〿';
  return text.replaceAll(RegExp('(?<=[$cjk]) +(?=[$cjk])'), '').trim();
}
