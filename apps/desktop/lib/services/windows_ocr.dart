// apps/desktop/lib/services/windows_ocr.dart
import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:localroll_core/localroll_core.dart';

/// Windows' own text recognition (Windows.Media.Ocr), run in one PowerShell
/// process that stays open: a picture in, its lines of text out. Nothing
/// leaves this PC; nothing to install (the languages are Windows' own).
const String _ocrScript = r"""
$ErrorActionPreference = 'Stop'
[Console]::InputEncoding = New-Object System.Text.UTF8Encoding $false
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false
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
while ($true) {
  $line = [Console]::In.ReadLine()
  if ($null -eq $line) { break }
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
    $out.error = "$($_.Exception.Message)"
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

/// Text recognition with Windows' own engine (Windows only).
class WindowsOcr {
  Process? _p;
  final Queue<Completer<Map<String, dynamic>>> _waiting = Queue();
  StreamSubscription<String>? _out;
  Future<void> _chain = Future.value();

  static bool get supported => Platform.isWindows;

  Future<Process> _start() async {
    final known = _p;
    if (known != null) return known;
    final script = File('${Directory.systemTemp.path}${Platform.pathSeparator}localroll-ocr.ps1');
    await script.writeAsString(_ocrScript);
    final p = await Process.start('powershell', [
      '-NoProfile',
      '-NonInteractive',
      '-ExecutionPolicy',
      'Bypass',
      '-File',
      script.path,
    ]);
    _out = p.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen((line) {
      if (_waiting.isEmpty) return;
      Map<String, dynamic> j;
      try {
        final v = jsonDecode(line.trim());
        j = v is Map<String, dynamic> ? v : {'error': 'bad answer'};
      } catch (_) {
        j = {'error': 'bad answer: ${line.length > 80 ? line.substring(0, 80) : line}'};
      }
      _waiting.removeFirst().complete(j);
    });
    p.stderr.transform(utf8.decoder).listen((e) {
      if (e.trim().isNotEmpty) DiagLog.log('ocr', 'stderr: ${e.trim()}');
    });
    unawaited(p.exitCode.then((code) {
      DiagLog.log('ocr', 'recognizer stopped ($code)');
      if (identical(_p, p)) _p = null;
      while (_waiting.isNotEmpty) {
        _waiting.removeFirst().complete({'error': 'stopped'});
      }
    }));
    return _p = p;
  }

  /// One request at a time, with a time limit (a stuck picture can't hold
  /// the rest up: the process is started again).
  Future<Map<String, dynamic>> _ask(Map<String, dynamic> req, {Duration limit = const Duration(seconds: 60)}) {
    final next = _chain.then((_) async {
      final p = await _start();
      final c = Completer<Map<String, dynamic>>();
      _waiting.add(c);
      p.stdin.add(utf8.encode('${jsonEncode(req)}\n'));
      await p.stdin.flush();
      return c.future.timeout(limit, onTimeout: () {
        DiagLog.log('ocr', 'no answer in ${limit.inSeconds}s: restarting');
        _waiting.remove(c);
        close();
        return {'error': 'timeout'};
      });
    });
    _chain = next.then((_) {}, onError: (_) {});
    return next;
  }

  OcrLanguages? _langs;

  /// The languages Windows can read (asked once; [refresh] asks again,
  /// e.g. after a language was installed).
  Future<OcrLanguages> languages({bool refresh = false}) async {
    if (!supported) return const OcrLanguages([]);
    if (refresh) close();
    final known = _langs;
    if (known != null && !refresh) return known;
    try {
      final r = await _ask({'cmd': 'langs'}, limit: const Duration(seconds: 30));
      if (r['error'] != null) {
        DiagLog.log('ocr', 'languages: ${r['error']}');
        return const OcrLanguages([]);
      }
      final list = r['available'];
      return _langs = OcrLanguages(
        <String>[if (list is List) ...list.whereType<String>() else if (list is String) list],
        maxDimension: (r['max'] as num?)?.toInt() ?? 0,
      );
    } catch (e) {
      DiagLog.log('ocr', 'languages: $e');
      return const OcrLanguages([]);
    }
  }

  /// The text in the picture at [imagePath] (lines joined), '' if none; null
  /// if it could not be read.
  Future<String?> read(String imagePath) async {
    final langs = await languages();
    if (!langs.any) return null;
    final r = await _ask({'cmd': 'ocr', 'path': imagePath, 'lang': langs.preferred ?? ''});
    final err = r['error'];
    if (err != null) {
      DiagLog.log('ocr', 'not read: $err');
      return null;
    }
    final lines = r['lines'];
    final text = lines is List ? lines.whereType<String>().join('\n') : (lines is String ? lines : '');
    return tidyOcrText(text);
  }

  void close() {
    final p = _p;
    _p = null;
    _langs = null;
    unawaited(_out?.cancel());
    _out = null;
    p?.kill();
  }
}

/// Windows reads Chinese / Japanese / Korean one character at a time with
/// spaces between: those spaces go.
String tidyOcrText(String text) {
  const cjk = r'぀-ヿ㐀-䶿一-鿿豈-﫿가-힯＀-￯　-〿';
  return text.replaceAll(RegExp('(?<=[$cjk]) +(?=[$cjk])'), '').trim();
}
