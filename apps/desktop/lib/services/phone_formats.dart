// apps/desktop/lib/services/phone_formats.dart
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:localroll_core/localroll_core.dart';

import 'converter.dart';
import 'ffmpeg.dart';
import 'peers.dart';
import 'video_encoders.dart';

/// What to do with one file before it goes to a phone.
enum PhoneAction {
  /// The phone shows / plays it as it is.
  asIs,

  /// Photo the phone can't show (BMP, TIFF on Android, camera RAW): a
  /// high-quality JPEG with the original's EXIF (date, place, camera).
  toJpeg,

  /// Video whose picture the phone can play but whose container it can't
  /// (MKV with H.264…): new MP4 box, picture untouched — seconds, lossless.
  remux,

  /// Video the phone can't play (AVI, WMV, MPEG-2, Xvid…): re-encoded to an
  /// MP4 every phone plays — H.265 on the graphics chip when this PC has
  /// one that can (fast, small files), else H.264 on the processor (x265
  /// on the processor would be several times slower). Near-original
  /// quality; capture date, place and rotation are kept.
  toH264,
}

/// Camera RAW files (not shown by phone photo apps).
const Set<String> rawExtensions = {
  'cr2', 'cr3', 'crw', 'nef', 'nrw', 'arw', 'srf', 'sr2', 'orf', 'rw2', 'raf', 'srw', 'pef', 'rwl', '3fr', 'erf', 'kdc', 'mrw',
};

/// Video files phones may not take as they are.
const Set<String> _otherVideo = {'wmv', 'asf', 'flv', 'f4v', 'mpg', 'mpeg', 'vob', 'ts', 'divx', 'xvid', 'ogv', 'rm', 'rmvb'};

/// Decides per file (by type, and for videos by what is inside) and
/// converts on this PC, so the phone gets something its photo app takes.
/// Originals are never touched: converted copies are temporary.
class PhoneFormatter {
  PhoneFormatter(this.ffmpeg);

  final FfmpegService ffmpeg;

  bool get available => ffmpeg.available;

  /// Hardware H.265 encoder that works on this PC (NVIDIA, Intel, AMD), or
  /// null: then H.264 on the processor. Tried once, with a tiny test.
  Future<String?> hardwareEncoder() => _hw ??= _findHardware();
  Future<String?>? _hw;

  static const _hwEncoders = ['hevc_nvenc', 'hevc_qsv', 'hevc_amf'];

  Future<String?> _findHardware() async {
    final exe = ffmpeg.ffmpeg;
    if (exe == null) return null;
    for (final enc in _hwEncoders) {
      try {
        final r = await Process.run(exe, [
          '-hide_banner', '-loglevel', 'error', '-nostdin',
          '-f', 'lavfi', '-i', 'color=c=black:s=640x360:d=0.2',
          '-vf', 'format=nv12', '-c:v', enc, '-f', 'null', '-',
        ]).timeout(const Duration(seconds: 15));
        if (r.exitCode == 0) return enc;
      } catch (_) {}
    }
    return null;
  }

  /// Encoder settings: near-original quality, 8-bit, what phones play.
  static List<String> _encodeArgs(String? hw) => switch (hw) {
        'hevc_nvenc' => ['-c:v', 'hevc_nvenc', '-preset', 'p5', '-tune', 'hq', '-rc', 'vbr', '-cq', '21', '-b:v', '0', '-profile:v', 'main', '-tag:v', 'hvc1'],
        'hevc_qsv' => ['-c:v', 'hevc_qsv', '-preset', 'medium', '-global_quality', '21', '-profile:v', 'main', '-tag:v', 'hvc1'],
        'hevc_amf' => ['-c:v', 'hevc_amf', '-quality', 'quality', '-rc', 'cqp', '-qp_i', '20', '-qp_p', '22', '-profile:v', 'main', '-tag:v', 'hvc1'],
        _ => const [],
      };

  late final H264Encoders _h264 = H264Encoders(() => ffmpeg.ffmpeg);

  /// [platform]: 'ios' or 'android'.
  Future<PhoneAction> decide(SendFile f, String platform) async {
    final ext = extensionOf(f.name);
    final ios = platform == 'ios';
    if (rawExtensions.contains(ext)) return PhoneAction.toJpeg;
    switch (ext) {
      case 'jpg' || 'jpeg' || 'png' || 'gif' || 'webp' || 'heic' || 'heif' || 'avif':
        return PhoneAction.asIs;
      case 'bmp':
        return PhoneAction.toJpeg;
      case 'tif' || 'tiff' || 'dng':
        // The iPhone photo library takes these; Android galleries mostly don't.
        return ios ? PhoneAction.asIs : PhoneAction.toJpeg;
    }
    final video = videoExtensions.contains(ext) || _otherVideo.contains(ext);
    if (!video) return PhoneAction.asIs; // documents, music…: as files
    final codec = (await ffmpeg.probe(f.path)).codec;
    final playable = codec == 'h264' || codec == 'hevc' || (!ios && (codec == 'vp9' || codec == 'av1' || codec == 'vp8'));
    final goodBox = ext == 'mp4' || ext == 'mov' || ext == 'm4v' || (!ios && (ext == 'mkv' || ext == 'webm' || ext == '3gp'));
    if (playable && goodBox) return PhoneAction.asIs;
    if (codec == 'h264' || codec == 'hevc') return PhoneAction.remux;
    if (codec == null) return PhoneAction.asIs; // can't read it: send as it is
    return PhoneAction.toH264;
  }

  /// Converted copy of [f] in [dir] (null when it could not be done — the
  /// original is then sent as it is). [onProgress] 0…1 for videos.
  Future<SendFile?> convert(SendFile f, PhoneAction a, Directory dir, {void Function(double)? onProgress}) async {
    if (a == PhoneAction.asIs) return f;
    await dir.create(recursive: true);
    final dot = f.name.lastIndexOf('.');
    final stem = dot > 0 ? f.name.substring(0, dot) : f.name;
    final ext = a == PhoneAction.toJpeg ? 'jpg' : 'mp4';
    final out = File('${dir.path}${Platform.pathSeparator}${shortKey(f.path)}_${sanitizeFileName(stem)}.$ext');
    final ok = switch (a) {
      PhoneAction.toJpeg => await _toJpeg(f.path, out),
      PhoneAction.remux => await _video(f.path, out, reencode: false, onProgress: onProgress),
      PhoneAction.toH264 => await _video(f.path, out, reencode: true, onProgress: onProgress),
      PhoneAction.asIs => true,
    };
    if (!ok || !await out.exists()) return null;
    final rel = f.relPath;
    return SendFile(
      path: out.path,
      name: '$stem.$ext',
      // Same id as the original (Live Photo pairing, "already have it").
      assetId: f.assetId,
      kind: a == PhoneAction.toJpeg ? MediaKind.image : MediaKind.video,
      createdMs: f.createdMs,
      modifiedMs: f.modifiedMs,
      size: await out.length(),
      target: f.target,
      relPath: rel == null ? null : '${rel.contains('.') ? rel.substring(0, rel.lastIndexOf('.')) : rel}.$ext',
      private: f.private,
    );
  }

  // ----------------------------------------------------------------- photos

  Future<bool> _toJpeg(String src, File out) async {
    final ext = extensionOf(src);
    final exif = await ConverterService.readExif(src);
    if (rawExtensions.contains(ext)) {
      // Camera RAW: the camera already put a full-size JPEG inside (that is
      // what its own screen shows). Use it, with the RAW file's EXIF.
      final jpeg = await embeddedJpeg(src);
      if (jpeg == null) return false;
      await out.writeAsBytes(jpeg, flush: true);
      if (exif != null && Exif.extractTiff(jpeg) == null) await ConverterService.writeExif(out.path, exif);
      return true;
    }
    if (!ffmpeg.available) return false;
    final upright = exif == null ? null : Exif.uprightFilter(Exif.orientation(exif));
    final ok = await _ffmpeg([
      if (exif != null && Exif.orientation(exif) != null) '-noautorotate',
      '-i', src,
      '-frames:v', '1',
      if (upright != null) ...['-vf', upright],
      '-q:v', '2',
      out.path,
    ]);
    if (ok && exif != null) await ConverterService.writeExif(out.path, exif);
    return ok;
  }

  /// The largest JPEG stored inside a RAW file (its full-size preview).
  static Future<Uint8List?> embeddedJpeg(String path) async {
    final b = await File(path).readAsBytes();
    var bestStart = -1, bestLen = 0;
    for (var i = 0; i + 3 < b.length; i++) {
      // Start of a JPEG: FF D8 FF.
      if (b[i] != 0xFF || b[i + 1] != 0xD8 || b[i + 2] != 0xFF) continue;
      final end = _jpegEnd(b, i);
      if (end > i && end - i > bestLen) {
        bestStart = i;
        bestLen = end - i;
      }
      if (end > i) i = end - 1;
    }
    // Small ones are thumbnails, not worth sending.
    if (bestStart < 0 || bestLen < 200 * 1024) return null;
    return Uint8List.sublistView(b, bestStart, bestStart + bestLen);
  }

  /// End (exclusive) of the JPEG starting at [s], walking its segments.
  static int _jpegEnd(Uint8List b, int s) {
    var i = s + 2;
    while (i + 4 <= b.length) {
      if (b[i] != 0xFF) return -1;
      final m = b[i + 1];
      if (m == 0xD9) return i + 2;
      if (m == 0xFF) {
        i++;
        continue;
      }
      if ((m >= 0xD0 && m <= 0xD7) || m == 0x01) {
        i += 2;
        continue;
      }
      final len = (b[i + 2] << 8) | b[i + 3];
      i += 2 + len;
      if (m == 0xDA) {
        // Entropy-coded data: run to the next marker that is not a stuffed
        // byte or a restart marker.
        while (i + 1 < b.length) {
          if (b[i] == 0xFF && b[i + 1] != 0x00 && !(b[i + 1] >= 0xD0 && b[i + 1] <= 0xD7)) break;
          i++;
        }
      }
    }
    return -1;
  }

  // ----------------------------------------------------------------- videos

  Future<bool> _video(String src, File out, {required bool reencode, void Function(double)? onProgress}) async {
    if (!ffmpeg.available) return false;
    final info = await ffmpeg.probe(src);
    if (!reencode) return _videoWith(src, out, info, reencode: false, onProgress: onProgress);
    final hw = await hardwareEncoder();
    if (hw != null) {
      if (await _videoWith(src, out, info, reencode: true, hw: hw, onProgress: onProgress)) return true;
      // The graphics chip refused this one (size, format…): processor.
      try {
        if (await out.exists()) await out.delete();
      } catch (_) {}
      onProgress?.call(0);
    }
    // No HEVC on the graphics chip: H.264 (graphics chip or Windows' own;
    // no GPL encoder in this ffmpeg).
    final h264 = await _h264.best();
    if (h264 == null) return false;
    return _videoWith(src, out, info, reencode: true, h264: h264, onProgress: onProgress);
  }

  Future<bool> _videoWith(String src, File out, ProbeInfo info,
      {required bool reencode, String? hw, String? h264, void Function(double)? onProgress}) {
    final filters = <String>[
      // HDR (iPhone HLG, HDR10) to normal colours, else it looks washed out.
      if (reencode && info.isHdr)
        'zscale=t=linear:npl=100,format=gbrpf32le,zscale=p=bt709,tonemap=tonemap=hable:desat=0,zscale=t=bt709:m=bt709:r=tv',
      if (reencode) 'format=nv12',
    ];
    final args = [
      '-i', src,
      '-map', '0:v:0', '-map', '0:a:0?',
      if (reencode) ...[
        '-vf', filters.join(','),
        ...(hw != null ? _encodeArgs(hw) : H264Encoders.args(h264!, high: true, width: info.width ?? 0, height: info.height ?? 0)),
      ] else
        ...['-c:v', 'copy', if (info.codec == 'hevc') ...['-tag:v', 'hvc1']],
      // Phones want AAC sound (AC-3, DTS, Vorbis, WMA… are re-encoded).
      '-c:a', 'aac', '-b:a', '192k',
      // Capture date, place and rotation stay.
      '-map_metadata', '0',
      '-movflags', '+faststart+use_metadata_tags',
      out.path,
    ];
    return _ffmpeg(args, durationSec: info.durationSec, onProgress: onProgress);
  }

  Future<bool> _ffmpeg(List<String> args, {double? durationSec, void Function(double)? onProgress}) async {
    try {
      final proc = await Process.start(ffmpeg.ffmpeg!, ['-hide_banner', '-loglevel', 'error', '-nostdin', '-y', '-nostats', '-progress', 'pipe:1', ...args]);
      final err = proc.stderr.drain<void>();
      final total = (durationSec ?? 0) * 1e6;
      await for (final line in proc.stdout.transform(utf8.decoder).transform(const LineSplitter())) {
        if (total > 0 && onProgress != null && line.startsWith('out_time_us=')) {
          final us = double.tryParse(line.substring(12)) ?? 0;
          onProgress((us / total).clamp(0.0, 1.0));
        }
      }
      await err;
      return await proc.exitCode == 0;
    } catch (_) {
      return false;
    }
  }
}

/// What will happen to a batch for a phone (shown before sending).
class PhonePlan {
  PhonePlan(this.actions);

  final List<PhoneAction> actions;

  int count(PhoneAction a) => actions.where((x) => x == a).length;
  bool get anyConversion => actions.any((a) => a != PhoneAction.asIs);
}
