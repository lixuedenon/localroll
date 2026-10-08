// apps/desktop/lib/services/ffmpeg.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:localroll_core/localroll_core.dart';

import 'library_index.dart';
import 'settings.dart';

/// Basic stream facts from ffprobe.
class ProbeInfo {
  const ProbeInfo({
    this.codec,
    this.width,
    this.height,
    this.durationSec,
    this.colorTransfer,
  });

  final String? codec;
  final int? width;
  final int? height;
  final double? durationSec;

  /// 'arib-std-b67' (HLG, iPhone default HDR) or 'smpte2084' (PQ/HDR10) means HDR.
  final String? colorTransfer;

  bool get isHdr => colorTransfer == 'arib-std-b67' || colorTransfer == 'smpte2084';
}

/// Locates and drives ffmpeg.exe / ffprobe.exe: thumbnails, HEIC previews,
/// probing. Runs at most [_maxParallel] processes at once.
class FfmpegService extends ChangeNotifier {
  FfmpegService(this.settings, this.library);

  final AppSettings settings;
  final LibraryIndex library;

  String? ffmpeg;
  String? ffprobe;
  String? version;

  static const int _maxParallel = 2;
  int _running = 0;
  final List<Completer<void>> _waiting = [];
  final Map<String, Future<File?>> _inflight = {};

  bool get available => ffmpeg != null;

  /// Search order: path from settings, `ffmpeg\` next to the app exe, PATH.
  Future<void> locate() async {
    ffmpeg = null;
    ffprobe = null;
    version = null;
    final sep = Platform.pathSeparator;
    final exe = Platform.isWindows ? 'ffmpeg.exe' : 'ffmpeg';
    final probeExe = Platform.isWindows ? 'ffprobe.exe' : 'ffprobe';
    final candidates = <String>[
      if (settings.ffmpegPath != null && settings.ffmpegPath!.isNotEmpty) settings.ffmpegPath!,
      '${File(Platform.resolvedExecutable).parent.path}${sep}ffmpeg$sep$exe',
    ];
    for (final c in candidates) {
      if (await File(c).exists()) {
        ffmpeg = c;
        break;
      }
    }
    if (ffmpeg == null) {
      try {
        final r = await Process.run(Platform.isWindows ? 'where' : 'which', ['ffmpeg']);
        if (r.exitCode == 0) {
          ffmpeg = (r.stdout as String).split(RegExp(r'\r?\n')).firstWhere((l) => l.trim().isNotEmpty).trim();
        }
      } catch (_) {}
    }
    if (ffmpeg != null) {
      final probe = '${File(ffmpeg!).parent.path}$sep$probeExe';
      ffprobe = await File(probe).exists() ? probe : null;
      try {
        final r = await Process.run(ffmpeg!, ['-hide_banner', '-version']);
        version = (r.stdout as String).split('\n').first.trim();
      } catch (_) {
        ffmpeg = null;
      }
    }
    notifyListeners();
  }

  Future<T> _limited<T>(Future<T> Function() task) async {
    while (_running >= _maxParallel) {
      final c = Completer<void>();
      _waiting.add(c);
      await c.future;
    }
    _running++;
    try {
      return await task();
    } finally {
      _running--;
      if (_waiting.isNotEmpty) _waiting.removeAt(0).complete();
    }
  }

  String _cachePath(MediaItem item, String suffix) =>
      '${library.cacheDir}${Platform.pathSeparator}${shortKey('${item.relPath}|${item.size}')}$suffix.jpg';

  /// Small JPEG for the grid (videos: frame at 1s; HEIC: decoded image).
  Future<File?> thumbnail(MediaItem item) =>
      _cached(_cachePath(item, '_t'), item, (src, out) => [
            if (item.kind == MediaKind.video) ...['-ss', '1'],
            '-i', src,
            '-frames:v', '1',
            '-vf', 'scale=360:-2',
            '-q:v', '4',
            out,
          ]);

  /// Full-resolution JPEG used to display formats Flutter cannot decode (HEIC, DNG…).
  Future<File?> preview(MediaItem item) =>
      _cached(_cachePath(item, '_p'), item, (src, out) => [
            '-i', src,
            '-frames:v', '1',
            '-q:v', '2',
            out,
          ]);

  Future<File?> _cached(
    String outPath,
    MediaItem item,
    List<String> Function(String src, String out) args,
  ) {
    return _inflight.putIfAbsent(outPath, () async {
      try {
        final out = File(outPath);
        if (await out.exists() && await out.length() > 0) return out;
        if (!available) return null;
        final src = library.absPath(item);
        var ok = await _limited(() => _run(args(src, outPath)));
        if (!ok && item.kind == MediaKind.video) {
          // Clips shorter than 1s: grab the first frame instead.
          ok = await _limited(() => _run(['-i', src, '-frames:v', '1', '-vf', 'scale=360:-2', outPath]));
        }
        return ok && await out.exists() ? out : null;
      } finally {
        // Keep successful results cached on disk; allow retry of failures.
        _inflight.remove(outPath);
      }
    });
  }

  Future<bool> _run(List<String> args) async {
    try {
      final r = await Process.run(ffmpeg!, ['-hide_banner', '-loglevel', 'error', '-y', ...args]);
      if (r.exitCode != 0) debugPrint('ffmpeg failed: ${r.stderr}');
      return r.exitCode == 0;
    } catch (e) {
      debugPrint('ffmpeg not runnable: $e');
      return false;
    }
  }

  Future<ProbeInfo> probe(String path) async {
    if (ffprobe == null) return const ProbeInfo();
    try {
      final r = await Process.run(ffprobe!, [
        '-v', 'error',
        '-select_streams', 'v:0',
        '-show_entries', 'stream=codec_name,width,height,color_transfer:format=duration',
        '-of', 'json',
        path,
      ]);
      if (r.exitCode != 0) return const ProbeInfo();
      final j = jsonDecode(r.stdout as String) as Map<String, dynamic>;
      final streams = (j['streams'] as List?) ?? const [];
      final s = streams.isEmpty ? const <String, dynamic>{} : streams.first as Map<String, dynamic>;
      final f = (j['format'] as Map<String, dynamic>?) ?? const {};
      return ProbeInfo(
        codec: s['codec_name'] as String?,
        width: (s['width'] as num?)?.toInt(),
        height: (s['height'] as num?)?.toInt(),
        colorTransfer: s['color_transfer'] as String?,
        durationSec: double.tryParse('${f['duration'] ?? ''}'),
      );
    } catch (_) {
      return const ProbeInfo();
    }
  }
}
