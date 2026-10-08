// apps/desktop/lib/services/converter.dart
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:localroll_core/localroll_core.dart';

import 'ffmpeg.dart';
import 'library_index.dart';
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

enum JobState { queued, running, done, failed }

class ConvertJob {
  ConvertJob(this.item, this.preset);

  final MediaItem item;
  final ConvertPreset preset;
  JobState state = JobState.queued;
  double progress = 0;
  String? outputPath;
  String? error;
  bool hdrTonemapped = false;
}

/// Sequential conversion queue (one ffmpeg encode at a time keeps the PC usable).
class ConverterService extends ChangeNotifier {
  ConverterService(this.ffmpeg, this.library);

  final FfmpegService ffmpeg;
  final LibraryIndex library;
  final List<ConvertJob> jobs = [];
  bool _pumping = false;

  int get pending => jobs.where((j) => j.state == JobState.queued || j.state == JobState.running).length;

  void enqueue(Iterable<MediaItem> items, ConvertPreset preset) {
    for (final i in items) {
      if (i.kind == MediaKind.other) continue;
      jobs.insert(0, ConvertJob(i, preset));
    }
    notifyListeners();
    _pump();
  }

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
      final src = library.absPath(job.item);
      final out = await _outputPath(job);
      job.outputPath = out;
      final args = job.item.kind == MediaKind.video
          ? await _videoArgs(job, src, out)
          : _imageArgs(job, src, out);
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
      try {
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
    final folder = '${library.rootPath}${sep}_converted$sep${job.preset.folder}$sep'
        '${t.year}$sep${t.month.toString().padLeft(2, '0')}';
    await Directory(folder).create(recursive: true);
    final name = job.item.name;
    final dot = name.lastIndexOf('.');
    final stem = dot > 0 ? name.substring(0, dot) : name;
    final ext = job.item.kind == MediaKind.video ? 'mp4' : 'jpg';
    return LibraryIndex.uniquePath(folder, sanitizeFileName('$stem.$ext'));
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
    filters.add('format=yuv420p');

    final crf = job.preset == ConvertPreset.compatible ? '18' : '23';
    final preset = job.preset == ConvertPreset.compatible ? 'slow' : 'medium';
    final audio = job.preset == ConvertPreset.compatible ? '192k' : '128k';
    return [
      '-i', src,
      '-map', '0:v:0', '-map', '0:a:0?',
      '-vf', filters.join(','),
      '-c:v', 'libx264', '-crf', crf, '-preset', preset, '-profile:v', 'high',
      '-c:a', 'aac', '-b:a', audio,
      // Keep capture date, GPS (com.apple.quicktime.location) and rotation.
      '-map_metadata', '0',
      '-movflags', '+faststart+use_metadata_tags',
      out,
    ];
  }

  List<String> _imageArgs(ConvertJob job, String src, String out) {
    return [
      '-i', src,
      '-frames:v', '1',
      if (job.preset == ConvertPreset.share)
        ...['-vf', "scale='if(gt(iw,ih),min(2048,iw),-2)':'if(gt(iw,ih),-2,min(2048,ih))'"],
      '-q:v', job.preset == ConvertPreset.compatible ? '2' : '4',
      out,
    ];
  }
}
