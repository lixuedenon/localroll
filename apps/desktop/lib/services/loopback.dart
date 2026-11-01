// apps/desktop/lib/services/loopback.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:localroll_core/localroll_core.dart';

/// Records the sound the PC plays (lr_loopback.exe next to LocalRoll's
/// exe: Windows' own loopback of the speakers) into a WAV.
class LoopbackRecorder {
  static String get exe =>
      '${File(Platform.resolvedExecutable).parent.path}${Platform.pathSeparator}lr_loopback.exe';

  static bool get available => Platform.isWindows && File(exe).existsSync();

  Process? _p;
  int _level = 0;

  /// When its first sound was written (the WAV starts there).
  DateTime? firstSound;

  bool get running => _p != null;

  /// How loud it is now (0–1).
  double level() => _level / 100;

  /// Starts into [out]; false when it can't (no speakers, no helper).
  Future<bool> start(File out) async {
    if (_p != null || !available) return false;
    firstSound = null;
    _level = 0;
    try {
      final p = _p = await Process.start(exe, [out.path]);
      final ready = Completer<bool>();
      p.stdout.transform(const Utf8Decoder(allowMalformed: true)).transform(const LineSplitter()).listen((line) {
        if (line.startsWith('ready')) {
          firstSound = DateTime.now();
          if (!ready.isCompleted) ready.complete(true);
        } else if (line.startsWith('level ')) {
          _level = int.tryParse(line.substring(6)) ?? 0;
        } else if (line.startsWith('error')) {
          DiagLog.log('screen', 'pc sound: $line');
          if (!ready.isCompleted) ready.complete(false);
        }
      });
      p.stderr.drain<void>().ignore();
      unawaited(p.exitCode.then((_) {
        if (!ready.isCompleted) ready.complete(false);
        if (identical(_p, p)) _p = null;
      }));
      final ok = await ready.future.timeout(const Duration(seconds: 5), onTimeout: () => false);
      if (!ok) await stop();
      return ok;
    } catch (e) {
      DiagLog.log('screen', 'pc sound not started: $e');
      _p = null;
      return false;
    }
  }

  /// Stops and finishes the WAV.
  Future<void> stop() async {
    final p = _p;
    _p = null;
    _level = 0;
    if (p == null) return;
    try {
      p.stdin.writeln('stop');
      await p.stdin.flush();
      await p.stdin.close();
    } catch (_) {}
    await p.exitCode.timeout(const Duration(seconds: 5), onTimeout: () {
      p.kill();
      return -1;
    });
  }
}

/// ffmpeg filter: [main] lowered while [side] (the voice) is heard — to
/// about a third while speaking, back within half a second after.
String duckFilter(String main, String side, String out) =>
    '[$main][$side]sidechaincompress=threshold=0.03:ratio=20:attack=15:release=450:makeup=1[$out]';

/// The same sound format for mixing.
const String mixFormat = 'aformat=sample_fmts=fltp:sample_rates=48000:channel_layouts=stereo';
