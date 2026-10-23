// apps/desktop/lib/services/ffmpeg.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:localroll_core/localroll_core.dart';

import 'face_math.dart';
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

  /// Small JPEG for the grid. Videos: frame at 1s. Still images (HEIC…):
  /// scaled down from the full preview — ffmpeg decodes iPhone HEIC as a tile
  /// grid that it stitches itself, and adding our own -vf to that fails.
  Future<File?> thumbnail(MediaItem item) async {
    if (item.kind == MediaKind.video) {
      return _cached(_cachePath(item, '_t'), item, (src, out) => [
            '-ss', '1',
            '-i', src,
            '-frames:v', '1',
            '-vf', 'scale=360:-2',
            '-q:v', '4',
            out,
          ]);
    }
    final full = await preview(item);
    if (full == null) return null;
    return _cached(
      _cachePath(item, '_t'),
      item,
      (src, out) => ['-i', src, '-frames:v', '1', '-vf', 'scale=360:-2', '-q:v', '4', out],
      source: full.path,
    );
  }

  /// A JPEG for a phone's screen (at most 2560 px on the long side), from
  /// any photo format; videos: a still from 1 s.
  Future<File?> display(MediaItem item) async {
    if (item.kind == MediaKind.video) return thumbnail(item);
    final full = await preview(item);
    if (full == null) return null;
    return _cached(
      _cachePath(item, '_d'),
      item,
      (src, out) => [
        '-i', src,
        '-frames:v', '1',
        '-vf', "scale='min(2560,iw)':'min(2560,ih)':force_original_aspect_ratio=decrease",
        '-q:v', '3',
        out,
      ],
      source: full.path,
    );
  }

  /// A JPEG of [src] for text recognition (HEIC, RAW, WebP…), at most
  /// 2560 pixels a side, written to [out]. Not kept in the picture cache.
  Future<bool> ocrPicture(String src, String out) async {
    if (!available) return false;
    return _limited(() => _run([
          '-i', src,
          '-frames:v', '1',
          '-vf', "scale='min(2560,iw)':'min(2560,ih)':force_original_aspect_ratio=decrease",
          '-q:v', '3',
          out,
        ]));
  }

  /// The picture (a video: its middle frame) as 224×224 RGB bytes for
  /// picture search: shortest side to 224, centre cut, like the model was
  /// trained. Null if it can't be read.
  Future<Uint8List?> rgb224(String src, {bool video = false}) async {
    if (!available) return null;
    var seek = <String>[];
    if (video) {
      final d = (await probe(src)).durationSec;
      seek = ['-ss', (d == null || d <= 0 ? 1.0 : d / 2).toStringAsFixed(2)];
    }
    return _viaJpeg(src, video, (from) async {
      final out = await _raw([
        ...seek, '-i', from, '-frames:v', '1',
        '-vf', 'scale=224:224:force_original_aspect_ratio=increase:flags=bicubic,crop=224:224',
        '-f', 'rawvideo', '-pix_fmt', 'rgb24', 'pipe:1',
      ]);
      return out != null && out.length == 224 * 224 * 3 ? out : null;
    });
  }

  /// A photo for finding faces: at most 1280 on its long side, RGB bytes
  /// with its size. Null if it can't be read.
  Future<(int, int, Uint8List)?> facePicture(String src) async {
    if (!available) return null;
    return _viaJpeg(src, false, (from) async {
      final out = await _raw([
        '-i', from, '-frames:v', '1',
        '-vf', "scale='min(1280,iw)':'min(1280,ih)':force_original_aspect_ratio=decrease:flags=bicubic",
        '-f', 'image2pipe', '-vcodec', 'ppm', '-pix_fmt', 'rgb24', 'pipe:1',
      ]);
      return out == null ? null : FaceMath.readPpm(out);
    });
  }

  /// A face cut out of [src] (x, y, w, h: 0–1 of the picture), with some
  /// room around it, 160×160, kept in the thumbnail cache.
  Future<File?> faceCrop(String src, String key, double x, double y, double w, double h) {
    final outPath = '${library.cacheDir}${Platform.pathSeparator}'
        '${shortKey('face|$key|${x.toStringAsFixed(4)}|${y.toStringAsFixed(4)}')}_f.jpg';
    return _inflight.putIfAbsent(outPath, () async {
      try {
        final out = File(outPath);
        if (await out.exists() && await out.length() > 0) return out;
        if (!available) return null;
        // A square around the face, a quarter bigger, kept inside the picture.
        const side = 1.25;
        final cx = x + w / 2, cy = y + h / 2;
        String f(double v) => v.toStringAsFixed(5);
        final sq = 'min(min(iw,ih),max(iw*${f(w * side)},ih*${f(h * side)}))';
        final crop = "crop='$sq':'$sq'"
            ":'max(0,min(iw-ow,iw*${f(cx)}-ow/2))':'max(0,min(ih-oh,ih*${f(cy)}-oh/2))',scale=160:160";
        final ok = await _viaJpeg(src, false, (from) async {
          final r = await _limited(() => _run(['-i', from, '-frames:v', '1', '-vf', crop, '-q:v', '3', outPath]));
          return r ? true : null;
        });
        return ok == true && await out.exists() ? out : null;
      } finally {
        _inflight.remove(outPath);
      }
    });
  }

  /// Runs [read] on [src]; if that fails for a still picture (HEIC is a
  /// tile grid ffmpeg stitches itself, and a filter on top of it fails),
  /// once more on a plain JPEG made from it first.
  Future<T?> _viaJpeg<T>(String src, bool video, Future<T?> Function(String from) read) async {
    final direct = await read(src);
    if (direct != null || video) return direct;
    final tmp = File('${Directory.systemTemp.path}${Platform.pathSeparator}lr_${shortKey(src)}_${DateTime.now().microsecondsSinceEpoch}.jpg');
    try {
      final ok = await _limited(() => _run(['-i', src, '-frames:v', '1', '-q:v', '2', tmp.path]));
      if (!ok || !await tmp.exists()) return null;
      return await read(tmp.path);
    } finally {
      try {
        if (await tmp.exists()) await tmp.delete();
      } catch (_) {}
    }
  }

  /// ffmpeg's output bytes (null on failure), at most [_maxParallel] at once.
  Future<Uint8List?> _raw(List<String> args) => _limited(() async {
        try {
          final r = await Process.run(ffmpeg!, ['-hide_banner', '-loglevel', 'error', ...args], stdoutEncoding: null);
          final out = r.stdout;
          if (r.exitCode != 0 || out is! List<int> || out.isEmpty) return null;
          return Uint8List.fromList(out);
        } catch (_) {
          return null;
        }
      });

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
    List<String> Function(String src, String out) args, {
    String? source,
  }) {
    return _inflight.putIfAbsent(outPath, () async {
      try {
        final out = File(outPath);
        if (await out.exists() && await out.length() > 0) return out;
        if (!available) return null;
        final src = source ?? library.absPath(item);
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
