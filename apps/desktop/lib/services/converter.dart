// apps/desktop/lib/services/converter.dart
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:localroll_core/localroll_core.dart';

import 'ffmpeg.dart';
import 'library_index.dart';
import 'video_encoders.dart';
import '../l10n/l10n.dart';

/// What the converted copy is for. Originals are never modified.
enum ConvertPreset {
  /// Plays/opens anywhere on Windows without extensions, near-lossless.
  compatible('compatible'),

  /// Small files for WeChat / email: ≤1080p video, ≤2048px photos.
  share('share');

  const ConvertPreset(this.folder);

  /// Output subfolder name (also the translation key suffix).
  final String folder;

  String get label => tr('preset.$folder');
}

/// What a format makes from: video, sound or a picture.
enum FormatKind { video, audio, image }

/// A file type to convert to (only what the LGPL ffmpeg can write: no
/// HEIC, it needs a GPL encoder). [encoder] must be in this ffmpeg.
enum ConvertFormat {
  mp4('mp4', 'MP4 (H.264)', FormatKind.video),
  mp4hevc('mp4', 'MP4 (H.265 / HEVC)', FormatKind.video),
  mov('mov', 'MOV', FormatKind.video),
  mkv('mkv', 'MKV', FormatKind.video),
  webm('webm', 'WebM', FormatKind.video, 'libvpx-vp9'),
  avi('avi', 'AVI', FormatKind.video, 'mpeg4'),
  wmv('wmv', 'WMV', FormatKind.video, 'wmv2'),
  gif('gif', 'GIF', FormatKind.video, 'gif'),
  mp3('mp3', 'MP3', FormatKind.audio, 'libmp3lame'),
  m4a('m4a', 'M4A (AAC)', FormatKind.audio, 'aac'),
  wav('wav', 'WAV', FormatKind.audio, 'pcm_s16le'),
  jpg('jpg', 'JPEG', FormatKind.image, 'mjpeg'),
  png('png', 'PNG', FormatKind.image, 'png'),
  webp('webp', 'WebP', FormatKind.image, 'libwebp'),
  avif('avif', 'AVIF', FormatKind.image),
  tiff('tif', 'TIFF', FormatKind.image, 'tiff'),
  bmp('bmp', 'BMP', FormatKind.image, 'bmp'),
  gifImage('gif', 'GIF', FormatKind.image, 'gif');

  const ConvertFormat(this.ext, this.label, this.kind, [this.encoder]);

  final String ext;
  final String label;
  final FormatKind kind;

  /// ffmpeg encoder it needs (null: checked another way).
  final String? encoder;

  /// Formats for a [video] (else a photo).
  static List<ConvertFormat> forSource({required bool video}) =>
      [for (final f in values) if (video ? f.kind != FormatKind.image : f.kind == FormatKind.image) f];
}

enum JobState { queued, running, done, failed }

class ConvertJob {
  ConvertJob(this.item, this.preset, {this.format, String? path, this.root})
      : path = path ?? '';

  /// A library item; or (outside the library) [path] with [item] made up.
  final MediaItem item;
  final ConvertPreset preset;

  /// A file type chosen (null: [preset]).
  final ConvertFormat? format;
  final String path;

  /// The library's folder (where `_converted` is), null: next to the file.
  final String? root;

  String get label => format?.label ?? preset.label;
  JobState state = JobState.queued;
  double progress = 0;
  String? outputPath;
  String? error;
  bool hdrTonemapped = false;
}

/// Sequential conversion queue (one ffmpeg encode at a time keeps the PC usable).
class ConverterService extends ChangeNotifier {
  ConverterService(this.ffmpeg, this.library) : encoders = H264Encoders(() => ffmpeg.ffmpeg);

  final FfmpegService ffmpeg;

  /// H.264 without GPL parts (graphics chip, or Windows' own).
  final H264Encoders encoders;
  final LibraryIndex library;
  final List<ConvertJob> jobs = [];
  bool _pumping = false;

  int get pending => jobs.where((j) => j.state == JobState.queued || j.state == JobState.running).length;

  void enqueue(Iterable<MediaItem> items, ConvertPreset preset, {ConvertFormat? format}) {
    for (final i in items) {
      if (i.kind == MediaKind.other) continue;
      if (format != null && (format.kind == FormatKind.image) != (i.kind == MediaKind.image)) continue;
      jobs.insert(0, ConvertJob(i, preset, format: format, path: library.absPath(i), root: library.rootPath));
    }
    notifyListeners();
    _pump();
  }

  /// A file outside the library (a recording, a file opened in the player).
  void enqueueFile(String path, ConvertFormat format) {
    final name = path.split(Platform.pathSeparator).last;
    final video = format.kind != FormatKind.image;
    final f = File(path);
    final ms = f.existsSync() ? f.lastModifiedSync().millisecondsSinceEpoch : DateTime.now().millisecondsSinceEpoch;
    final item = MediaItem(relPath: '', name: name, size: f.existsSync() ? f.lengthSync() : 0, kind: video ? MediaKind.video : MediaKind.image, captureMs: ms, receivedMs: ms);
    final lib = library.rootPath;
    final inLib = lib.isNotEmpty && path.toLowerCase().startsWith('${lib.toLowerCase()}${Platform.pathSeparator}');
    jobs.insert(0, ConvertJob(item, ConvertPreset.compatible, format: format, path: path, root: inLib ? lib : null));
    notifyListeners();
    _pump();
  }

  /// The formats this PC's ffmpeg can write (checked once).
  Future<Set<ConvertFormat>> available() => _available ??= _findAvailable();
  Future<Set<ConvertFormat>>? _available;

  Set<String>? _encoderNames;

  Future<Set<ConvertFormat>> _findAvailable() async {
    final exe = ffmpeg.ffmpeg;
    if (exe == null) return {};
    final names = <String>{};
    try {
      final r = await Process.run(exe, ['-hide_banner', '-encoders']);
      for (final line in '${r.stdout}'.split('\n')) {
        final m = RegExp(r'^\s*[VAS][\.FSXBD]{5}\s+(\S+)').firstMatch(line);
        if (m != null) names.add(m.group(1)!);
      }
    } catch (_) {}
    _encoderNames = names;
    final h264 = await encoders.best() != null;
    final hevc = await _hevc() != null;
    final out = <ConvertFormat>{};
    for (final f in ConvertFormat.values) {
      final ok = switch (f) {
        ConvertFormat.mp4 || ConvertFormat.mov || ConvertFormat.mkv => h264,
        ConvertFormat.mp4hevc => hevc,
        ConvertFormat.avif => names.contains('libaom-av1') || names.contains('libsvtav1'),
        _ => f.encoder != null && names.contains(f.encoder),
      };
      if (ok) out.add(f);
    }
    DiagLog.log('convert', 'formats: ${[for (final f in out) f.name].join(' ')}');
    return out;
  }

  Future<String?>? _hevcFound;

  /// H.265 on the graphics chip, or Windows' own (none in LGPL software).
  Future<String?> _hevc() => _hevcFound ??= () async {
        final exe = ffmpeg.ffmpeg;
        if (exe == null) return null;
        for (final enc in const ['hevc_nvenc', 'hevc_qsv', 'hevc_amf', 'hevc_mf']) {
          try {
            final r = await Process.run(exe, [
              '-hide_banner', '-loglevel', 'error', '-nostdin',
              '-f', 'lavfi', '-i', 'color=c=black:s=640x360:d=0.2',
              '-vf', 'format=nv12', '-c:v', enc, '-f', 'null', '-',
            ]).timeout(const Duration(seconds: 20));
            if (r.exitCode == 0) return enc;
          } catch (_) {}
        }
        return null;
      }();

  void clearFinished() {
    jobs.removeWhere((j) => j.state == JobState.done || j.state == JobState.failed);
    notifyListeners();
  }

  Future<void> _pump() async {
    if (_pumping) return;
    _pumping = true;
    try {
      while (true) {
        final next = jobs.lastWhere((j) => j.state == JobState.queued, orElse: () => _none);
        if (identical(next, _none)) break;
        await _run(next);
      }
    } finally {
      _pumping = false;
    }
  }

  static final ConvertJob _none = ConvertJob(
    MediaItem(relPath: '', name: '', size: 0, kind: MediaKind.other, captureMs: 0, receivedMs: 0),
    ConvertPreset.compatible,
  );

  Future<void> _run(ConvertJob job) async {
    job.state = JobState.running;
    notifyListeners();
    try {
      if (!ffmpeg.available) throw Exception(tr('convert.no_ffmpeg'));
      final src = job.path.isNotEmpty ? job.path : library.absPath(job.item);
      final out = await _outputPath(job);
      job.outputPath = out;
      // Photos: ffmpeg drops EXIF, so lift it from the original now and put
      // it back into the JPEG afterwards (capture time, GPS, camera, lens).
      final exif = job.item.kind == MediaKind.image ? await readExif(src) : null;
      final fmt = job.format;
      final args = fmt != null
          ? await _formatArgs(job, fmt, src, out, exif)
          : job.item.kind == MediaKind.video
              ? await _videoArgs(job, src, out)
              : _imageArgs(job, src, out, exif);
      final durationUs = job.item.kind == MediaKind.video
          ? ((await ffmpeg.probe(src)).durationSec ?? 0) * 1e6
          : 0.0;

      final proc = await Process.start(ffmpeg.ffmpeg!, [
        '-hide_banner', '-y', '-nostats', '-progress', 'pipe:1', ...args,
      ]);
      final errTail = <String>[];
      final errSub = proc.stderr
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((l) {
        errTail.add(l);
        if (errTail.length > 20) errTail.removeAt(0);
      });
      await for (final line in proc.stdout.transform(utf8.decoder).transform(const LineSplitter())) {
        if (line.startsWith('out_time_us=') && durationUs > 0) {
          final us = double.tryParse(line.substring(12)) ?? 0;
          job.progress = (us / durationUs).clamp(0.0, 1.0);
          notifyListeners();
        }
      }
      final code = await proc.exitCode;
      await errSub.cancel();
      if (code != 0) {
        try {
          await File(out).delete();
        } catch (_) {}
        throw Exception(errTail.isEmpty ? 'ffmpeg exit $code' : errTail.join('\n'));
      }
      if (exif != null && out.toLowerCase().endsWith('.jpg')) await writeExif(out, exif);
      try {
        // Explorer / Photos sort by this: the capture time, like the original.
        await File(out).setLastModified(job.item.captureTime);
      } catch (_) {}
      job.progress = 1;
      job.state = JobState.done;
    } catch (e) {
      job.state = JobState.failed;
      job.error = e.toString();
    }
    notifyListeners();
  }

  Future<String> _outputPath(ConvertJob job) async {
    final sep = Platform.pathSeparator;
    final t = job.item.captureTime;
    final fmt = job.format;
    final root = job.root;
    final String folder;
    if (root == null || root.isEmpty) {
      // Outside the library: next to the file, in "converted".
      final i = job.path.lastIndexOf(sep);
      folder = '${i > 0 ? job.path.substring(0, i) : Directory.systemTemp.path}${sep}converted';
    } else {
      folder = '$root${sep}_converted$sep${fmt == null ? job.preset.folder : fmt.name}$sep'
          '${t.year}$sep${t.month.toString().padLeft(2, '0')}';
    }
    await Directory(folder).create(recursive: true);
    final name = job.item.name;
    final dot = name.lastIndexOf('.');
    final stem = dot > 0 ? name.substring(0, dot) : name;
    final ext = fmt?.ext ?? (job.item.kind == MediaKind.video ? 'mp4' : 'jpg');
    return LibraryIndex.uniquePath(folder, sanitizeFileName('$stem.$ext'));
  }

  static const String _toneMap = 'zscale=t=linear:npl=100,format=gbrpf32le,zscale=p=bt709,'
      'tonemap=tonemap=hable:desat=0,zscale=t=bt709:m=bt709:r=tv';

  /// To a chosen file type, at good quality.
  Future<List<String>> _formatArgs(ConvertJob job, ConvertFormat f, String src, String out, Uint8List? exif) async {
    if (f.kind == FormatKind.image) {
      final filters = <String>[];
      final upright = exif == null ? null : Exif.uprightFilter(Exif.orientation(exif));
      if (upright != null) filters.add(upright);
      final codec = switch (f) {
        ConvertFormat.jpg => ['-q:v', '2'],
        ConvertFormat.png => ['-c:v', 'png'],
        ConvertFormat.webp => ['-c:v', 'libwebp', '-quality', '90'],
        ConvertFormat.avif => [
            '-c:v', (_encoderNames?.contains('libaom-av1') ?? false) ? 'libaom-av1' : 'libsvtav1',
            '-still-picture', '1', '-crf', '28', '-pix_fmt', 'yuv420p',
          ],
        ConvertFormat.tiff => ['-c:v', 'tiff', '-compression_algo', 'lzw'],
        ConvertFormat.bmp => ['-c:v', 'bmp', '-pix_fmt', 'bgr24'],
        _ => ['-c:v', 'gif'],
      };
      if (f == ConvertFormat.gifImage) {
        filters.add('split[a][b];[a]palettegen[p];[b][p]paletteuse');
      }
      return [
        if (exif != null && Exif.orientation(exif) != null) '-noautorotate',
        '-i', src,
        '-frames:v', '1',
        if (filters.isNotEmpty) ...['-vf', filters.join(',')],
        ...codec,
        if (f == ConvertFormat.jpg) ...['-pix_fmt', 'yuvj444p'],
        out,
      ];
    }
    final info = await ffmpeg.probe(src);
    final hdr = info.isHdr;
    if (hdr) job.hdrTonemapped = true;
    if (f.kind == FormatKind.audio) {
      final a = switch (f) {
        ConvertFormat.mp3 => ['-c:a', 'libmp3lame', '-q:a', '2'],
        ConvertFormat.m4a => ['-c:a', 'aac', '-b:a', '192k'],
        _ => ['-c:a', 'pcm_s16le'],
      };
      return ['-i', src, '-vn', '-map', '0:a:0', ...a, '-map_metadata', '0', out];
    }
    final filters = <String>[if (hdr) _toneMap];
    final w = info.width ?? 0, h = info.height ?? 0;
    switch (f) {
      case ConvertFormat.gif:
        // Small and smooth enough: 12 frames a second, long edge ≤ 640.
        filters.add("fps=12,scale='if(gt(iw,ih),min(640,iw),-2)':'if(gt(iw,ih),-2,min(640,ih))':flags=lanczos,split[a][b];[a]palettegen[p];[b][p]paletteuse");
        return ['-i', src, '-vf', filters.join(','), '-loop', '0', out];
      case ConvertFormat.webm:
        filters.add('format=yuv420p');
        final opus = _encoderNames?.contains('libopus') ?? false;
        return [
          '-i', src, '-map', '0:v:0', '-map', '0:a:0?', '-vf', filters.join(','),
          '-c:v', 'libvpx-vp9', '-crf', '31', '-b:v', '0', '-row-mt', '1', '-deadline', 'good', '-cpu-used', '4',
          '-c:a', opus ? 'libopus' : 'libvorbis', '-b:a', '160k', '-map_metadata', '0', out,
        ];
      case ConvertFormat.avi:
        filters.add('format=yuv420p');
        final mp3 = _encoderNames?.contains('libmp3lame') ?? false;
        return [
          '-i', src, '-map', '0:v:0', '-map', '0:a:0?', '-vf', filters.join(','),
          '-c:v', 'mpeg4', '-q:v', '3', '-tag:v', 'XVID',
          '-c:a', mp3 ? 'libmp3lame' : 'ac3', '-b:a', '192k', out,
        ];
      case ConvertFormat.wmv:
        filters.add('format=yuv420p');
        final bps = ((w > 0 && h > 0 ? w * h : 1920 * 1080) * 30 * 0.2).clamp(2e6, 40e6).round();
        return [
          '-i', src, '-map', '0:v:0', '-map', '0:a:0?', '-vf', filters.join(','),
          '-c:v', 'wmv2', '-b:v', '$bps', '-c:a', 'wmav2', '-b:a', '192k', out,
        ];
      case ConvertFormat.mp4hevc:
        final enc = await _hevc();
        if (enc == null) throw StateError('no H.265 encoder on this PC');
        filters.add('format=nv12');
        final bps = ((w > 0 && h > 0 ? w * h : 1920 * 1080) * 30 * 0.09).clamp(1.5e6, 40e6).round();
        final v = switch (enc) {
          'hevc_nvenc' => ['-c:v', enc, '-preset', 'p5', '-rc', 'vbr', '-cq', '22', '-b:v', '0'],
          'hevc_qsv' => ['-c:v', enc, '-global_quality', '22'],
          'hevc_amf' => ['-c:v', enc, '-rc', 'cqp', '-qp_i', '20', '-qp_p', '22'],
          _ => ['-c:v', enc, '-b:v', '$bps'],
        };
        return [
          '-i', src, '-map', '0:v:0', '-map', '0:a:0?', '-vf', filters.join(','), ...v, '-tag:v', 'hvc1',
          '-c:a', 'aac', '-b:a', '192k', '-map_metadata', '0', '-movflags', '+faststart+use_metadata_tags', out,
        ];
      default:
        // MP4 / MOV / MKV: H.264 (graphics chip or Windows' own) + AAC.
        final enc = await encoders.best();
        if (enc == null) throw StateError('no H.264 encoder on this PC');
        filters.add('format=nv12');
        return [
          '-i', src, '-map', '0:v:0', '-map', '0:a:0?', '-vf', filters.join(','),
          ...H264Encoders.args(enc, high: true, width: w, height: h),
          '-c:a', 'aac', '-b:a', '192k', '-map_metadata', '0',
          if (f != ConvertFormat.mkv) ...['-movflags', '+faststart+use_metadata_tags'],
          out,
        ];
    }
  }

  /// HEVC/HDR → H.264 SDR. HDR (iPhone records HLG by default) must be
  /// tone-mapped, otherwise the result looks grey and washed out.
  Future<List<String>> _videoArgs(ConvertJob job, String src, String out) async {
    final info = await ffmpeg.probe(src);
    final filters = <String>[];
    if (info.isHdr) {
      job.hdrTonemapped = true;
      filters.add('zscale=t=linear:npl=100,format=gbrpf32le,zscale=p=bt709,'
          'tonemap=tonemap=hable:desat=0,zscale=t=bt709:m=bt709:r=tv');
    }
    if (job.preset == ConvertPreset.share) {
      // Long edge ≤ 1920 for both landscape and portrait.
      filters.add("scale='if(gt(iw,ih),min(1920,iw),-2)':'if(gt(iw,ih),-2,min(1920,ih))'");
    }
    filters.add('format=nv12');

    // No GPL encoder: the graphics chip's, or Windows' own.
    final enc = await encoders.best();
    if (enc == null) throw StateError('no H.264 encoder on this PC');
    final high = job.preset == ConvertPreset.compatible;
    final audio = high ? '192k' : '128k';
    var w = info.width ?? 0, h = info.height ?? 0;
    if (!high && math.max(w, h) > 1920) {
      final k = 1920 / math.max(w, h);
      w = (w * k).round();
      h = (h * k).round();
    }
    return [
      '-i', src,
      '-map', '0:v:0', '-map', '0:a:0?',
      '-vf', filters.join(','),
      ...H264Encoders.args(enc, high: high, width: w, height: h),
      '-c:a', 'aac', '-b:a', audio,
      // Keep capture date, GPS (com.apple.quicktime.location) and rotation.
      '-map_metadata', '0',
      '-movflags', '+faststart+use_metadata_tags',
      out,
    ];
  }

  /// The pixels are turned upright here (from the EXIF orientation) and the
  /// copied EXIF then says Orientation = 1, so every viewer — Windows Photos,
  /// WeChat, browsers — shows the same thing.
  List<String> _imageArgs(ConvertJob job, String src, String out, Uint8List? exif) {
    final filters = <String>[];
    final upright = exif == null ? null : Exif.uprightFilter(Exif.orientation(exif));
    if (upright != null) filters.add(upright);
    if (job.preset == ConvertPreset.share) {
      filters.add("scale='if(gt(iw,ih),min(2048,iw),-2)':'if(gt(iw,ih),-2,min(2048,ih))'");
    }
    return [
      // We rotate ourselves (above); without this ffmpeg might rotate as well.
      if (exif != null && Exif.orientation(exif) != null) '-noautorotate',
      '-i', src,
      '-frames:v', '1',
      if (filters.isNotEmpty) ...['-vf', filters.join(',')],
      '-q:v', job.preset == ConvertPreset.compatible ? '2' : '4',
      out,
    ];
  }

  static Future<Uint8List?> readExif(String path) async {
    try {
      final f = File(path);
      // EXIF sits near the start; HEIC metadata can point anywhere, so read
      // the whole file for HEIF (photos are a few MB).
      return Exif.extractTiff(await f.readAsBytes());
    } catch (_) {
      return null;
    }
  }

  static Future<void> writeExif(String jpegPath, Uint8List tiff) async {
    try {
      final f = File(jpegPath);
      final fixed = Exif.orientation(tiff) == null ? tiff : Exif.withOrientation(tiff, 1);
      final out = Exif.insertIntoJpeg(await f.readAsBytes(), fixed);
      await f.writeAsBytes(out, flush: true);
    } catch (_) {
      // The conversion itself succeeded; missing EXIF is not worth failing it.
    }
  }

}
