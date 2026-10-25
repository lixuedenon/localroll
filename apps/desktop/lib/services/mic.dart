// apps/desktop/lib/services/mic.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:localroll_core/localroll_core.dart';

/// Recording from a microphone with the bundled ffmpeg (Windows' own
/// DirectShow input): a 48 kHz mono WAV file. Nothing leaves this PC.
class MicRecorder {
  MicRecorder(this.ffmpeg);

  /// Path of ffmpeg.exe (null: none).
  final String? ffmpeg;

  /// The microphones Windows offers (their names).
  Future<List<String>> devices() async {
    final exe = ffmpeg;
    if (exe == null) return const [];
    try {
      final r = await Process.run(exe, ['-hide_banner', '-list_devices', 'true', '-f', 'dshow', '-i', 'dummy'],
          stderrEncoding: const Utf8Codec(allowMalformed: true));
      return parseDevices('${r.stderr}');
    } catch (_) {
      return const [];
    }
  }

  /// Audio devices from ffmpeg's DirectShow list.
  static List<String> parseDevices(String text) {
    final out = <String>[];
    var audioSection = false;
    for (final line in const LineSplitter().convert(text)) {
      if (line.contains('DirectShow audio devices')) audioSection = true;
      if (line.contains('DirectShow video devices')) audioSection = false;
      if (line.contains('Alternative name')) continue;
      final m = RegExp(r'"([^"]+)"(\s*\((audio|video|audio, video)\))?').firstMatch(line);
      if (m == null) continue;
      final kind = m.group(3);
      if (kind == 'audio' || (kind == null && audioSection)) out.add(m.group(1)!);
    }
    return {...out}.toList();
  }

  Process? _proc;
  File? _file;
  final StringBuffer _err = StringBuffer();

  /// When the first sound arrived (to line it up with the recording).
  DateTime? firstSound;

  bool get running => _proc != null;

  /// Starts recording [device] into [out]. False when it could not start.
  Future<bool> start(String device, File out) async {
    final exe = ffmpeg;
    if (exe == null) return false;
    _err.clear();
    firstSound = null;
    try {
      final p = _proc = await Process.start(exe, [
        '-hide_banner', '-loglevel', 'error', '-y',
        '-f', 'dshow', '-audio_buffer_size', '50', '-i', 'audio=$device',
        '-ac', '1', '-ar', '48000', '-c:a', 'pcm_s16le', out.path,
      ]);
      _file = out;
      p.stderr.transform(const Utf8Decoder(allowMalformed: true)).listen(_err.write);
      unawaited(p.stdout.drain<void>());
      var ended = false;
      unawaited(p.exitCode.then((_) => ended = true));
      // Wait for the first sound (or a failure).
      for (var i = 0; i < 150 && !ended; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        if (out.existsSync() && out.lengthSync() > 44 + 960) {
          firstSound = DateTime.now();
          return true;
        }
      }
      if (!ended) {
        firstSound = DateTime.now();
        return true;
      }
      DiagLog.log('player', 'microphone did not start: ${_err.toString().trim().split('\n').last}');
      _proc = null;
      return false;
    } catch (e) {
      DiagLog.log('player', 'microphone did not start: $e');
      _proc = null;
      return false;
    }
  }

  /// Why it stopped (for the message), if it said.
  String get lastError => _err.toString().trim();

  /// Stops and finishes the file.
  Future<void> stop() async {
    final p = _proc;
    _proc = null;
    if (p == null) return;
    try {
      p.stdin.write('q');
      await p.stdin.flush();
      await p.stdin.close();
    } catch (_) {}
    try {
      await p.exitCode.timeout(const Duration(seconds: 3));
    } catch (_) {
      p.kill();
    }
  }

  /// How loud it is now (0–1), from the last tenth of a second written.
  double level() {
    final f = _file;
    if (f == null || _proc == null) return 0;
    RandomAccessFile? raf;
    try {
      raf = f.openSync();
      final len = raf.lengthSync();
      const n = 4800 * 2;
      if (len < 44 + n) return 0;
      raf.setPositionSync(len - n - (len - 44) % 2);
      final b = raf.readSync(n);
      final s = Int16List.view(Uint8List.fromList(b).buffer, 0, b.length ~/ 2);
      var sum = 0.0;
      for (final v in s) {
        sum += v * v;
      }
      final rms = math.sqrt(sum / s.length) / 32768;
      // Roughly like a meter: -50 dB empty, 0 dB full.
      final db = rms <= 0 ? -100 : 20 * math.log(rms) / math.ln10;
      return ((db + 50) / 50).clamp(0.0, 1.0);
    } catch (_) {
      return 0;
    } finally {
      try {
        raf?.closeSync();
      } catch (_) {}
    }
  }
}
