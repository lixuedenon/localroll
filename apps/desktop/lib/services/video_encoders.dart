// apps/desktop/lib/services/video_encoders.dart
import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:localroll_core/localroll_core.dart';

/// H.264 encoding without GPL parts (the bundled ffmpeg is the LGPL build:
/// no libx264): the graphics chip's encoder (NVIDIA, Intel, AMD) when there
/// is one, else Windows' own (Media Foundation), which every Windows 10 / 11
/// has. Tried once each, with a tiny test, the first that works is kept.
class H264Encoders {
  H264Encoders(this.ffmpeg);

  /// ffmpeg.exe (null: none).
  final String? Function() ffmpeg;

  static const List<String> order = ['h264_nvenc', 'h264_qsv', 'h264_amf', 'h264_mf'];

  Future<String?>? _found;

  /// The encoder to use, or null (none works: conversion can't be done).
  Future<String?> best() => _found ??= _find();

  Future<String?> _find() async {
    final exe = ffmpeg();
    if (exe == null) return null;
    for (final enc in order) {
      try {
        final r = await Process.run(exe, [
          '-hide_banner', '-loglevel', 'error', '-nostdin',
          '-f', 'lavfi', '-i', 'color=c=black:s=640x360:d=0.2',
          '-vf', 'format=nv12', '-c:v', enc, '-f', 'null', '-',
        ]).timeout(const Duration(seconds: 20));
        if (r.exitCode == 0) {
          DiagLog.log('convert', 'H.264 encoder: $enc');
          return enc;
        }
      } catch (_) {}
    }
    DiagLog.log('convert', 'no H.264 encoder works on this PC');
    return null;
  }

  /// Whether it runs on the graphics chip (fast) rather than Windows'
  /// own encoder.
  static bool isGraphicsChip(String? enc) => enc != null && enc != 'h264_mf';

  /// Encoder settings for [enc]: [high] = near-original quality (else a
  /// smaller file for sharing). [width] × [height] (0: unknown) sets the
  /// bit rate where the encoder needs one.
  static List<String> args(String enc, {required bool high, int width = 0, int height = 0, double fps = 30}) {
    switch (enc) {
      case 'h264_nvenc':
        return ['-c:v', 'h264_nvenc', '-preset', 'p5', '-tune', 'hq', '-rc', 'vbr', '-cq', high ? '19' : '24', '-b:v', '0', '-profile:v', 'high'];
      case 'h264_qsv':
        return ['-c:v', 'h264_qsv', '-preset', 'slow', '-global_quality', high ? '20' : '25', '-profile:v', 'high'];
      case 'h264_amf':
        return ['-c:v', 'h264_amf', '-quality', 'quality', '-rc', 'cqp', '-qp_i', high ? '18' : '23', '-qp_p', high ? '20' : '25', '-profile:v', 'high'];
      default:
        // Windows' own encoder takes a bit rate: about what phones record at.
        final px = (width > 0 && height > 0 ? width * height : 1920 * 1080).toDouble();
        final perPixel = high ? 0.16 : 0.08;
        final bps = (px * math.max(24, math.min(fps, 60)) * perPixel).clamp(2e6, 60e6).round();
        return ['-c:v', 'h264_mf', '-rate_control', 'pc_vbr', '-b:v', '$bps', '-maxrate', '${(bps * 1.5).round()}', '-profile:v', 'high'];
    }
  }
}
