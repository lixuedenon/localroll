// apps/desktop/lib/ui/player/clip_export.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:localroll_core/localroll_core.dart';

import '../../app_services.dart';
import '../../l10n/l10n.dart';
import '../../services/annotations.dart';
import '../../services/library_index.dart';
import '../../services/recordings.dart';
import '../../services/video_encoders.dart';
import 'ink_paint.dart';
import 'player_entry.dart';
import 'snapshot.dart';

/// HDR frames brought to ordinary colours (as the converter does).
const String _toneMap = 'zscale=t=linear:npl=100,format=gbrpf32le,zscale=p=bt709,'
    'tonemap=tonemap=hable:desat=0,zscale=t=bt709:m=bt709:r=tv';

/// One part of a clip: the video playing from [fromMs] to [toMs], or
/// standing still at [fromMs] while [freeze] is drawn again.
class ClipPiece {
  const ClipPiece.play(this.fromMs, this.toMs) : freeze = null;
  ClipPiece.still(FreezePlan f)
      : freeze = f,
        fromMs = f.atMs,
        toMs = f.atMs;

  final int fromMs, toMs;
  final FreezePlan? freeze;

  int get lengthMs => freeze?.totalMs ?? (toMs - fromMs);
}

/// The parts of a clip from [startMs] to [endMs]: where something was
/// drawn while paused, the clip stands still and draws it (as in the
/// player).
List<ClipPiece> clipPieces(List<Note> notes, int startMs, int endMs) {
  final stills = [
    for (final n in notes)
      for (final f in n.freezes)
        if (f.atMs > startMs && f.atMs < endMs) f,
  ]..sort((a, b) => a.atMs.compareTo(b.atMs));
  final out = <ClipPiece>[];
  var at = startMs;
  for (final f in stills) {
    if (f.atMs - at >= 40) out.add(ClipPiece.play(at, f.atMs));
    out.add(ClipPiece.still(f));
    at = f.atMs;
  }
  if (endMs - at >= 40 || out.isEmpty) out.add(ClipPiece.play(at, endMs));
  return out;
}

/// What the marks look like [ms] into the clip.
({int now, FreezeNow? freeze}) clipMoment(List<ClipPiece> pieces, int ms) {
  var t = 0;
  for (final p in pieces) {
    if (ms < t + p.lengthMs || identical(p, pieces.last)) {
      final into = math.max(0, ms - t);
      final f = p.freeze;
      if (f != null) return (now: f.atMs, freeze: (plan: f, elapsedMs: math.min(into, f.totalMs)));
      return (now: math.min(p.toMs, p.fromMs + into), freeze: null);
    }
    t += p.lengthMs;
  }
  return (now: pieces.isEmpty ? 0 : pieces.last.toMs, freeze: null);
}

/// Cuts a piece of a video into its own file, in the library's clip
/// folder: as it is (no re-encoding, seconds), or with the drawings —
/// drawn as they were drawn — at the original's size.
class ClipExporter {
  ClipExporter(this.s);

  final AppServices s;
  Process? _proc;
  bool _cancelled = false;

  void cancel() {
    _cancelled = true;
    _proc?.kill();
  }

  static String _secs(int ms) => (ms / 1000).toStringAsFixed(3);
  static int _even(double v) => math.max(2, (v / 2).round() * 2);

  Future<File?> run(
    PlayerEntry e, {
    required int startMs,
    required int endMs,
    required bool withInk,
    required List<Note> notes,
    required Size picture,
    required void Function(double done) onProgress,
  }) async {
    final ff = s.ffmpeg;
    final exe = ff.ffmpeg;
    if (exe == null || endMs <= startMs) return null;
    final dir = Snapshots.folder(s, clips: true);
    await Directory(dir).create(recursive: true);
    final base = stemOf(e.name);
    final ext = withInk ? 'mp4' : (e.extension.isEmpty ? 'mp4' : e.extension);
    final out = LibraryIndex.uniquePath(dir, sanitizeFileName('${recName(base, tr('recs.name_clip'), DateTime.now())}.$ext'));
    final ok = withInk
        ? await _drawn(exe, e, out, startMs, endMs, notes, picture, onProgress)
        : await _copy(exe, e, out, startMs, endMs, onProgress);
    if (!ok || _cancelled || !File(out).existsSync()) {
      try {
        if (File(out).existsSync()) File(out).deleteSync();
      } catch (_) {}
      return null;
    }
    return Snapshots.done(s, File(out), video: true, kind: RecKind.clip, source: base, sourcePath: e.path, lengthMs: endMs - startMs);
  }

  /// As it is: no re-encoding (it starts at the key frame just before).
  Future<bool> _copy(String exe, PlayerEntry e, String out, int startMs, int endMs, void Function(double) onProgress) async {
    final args = [
      '-hide_banner', '-loglevel', 'error', '-y',
      '-ss', _secs(startMs), '-i', e.path, '-t', _secs(endMs - startMs),
      '-map', '0:v:0', '-map', '0:a:0?', '-c', 'copy',
      '-avoid_negative_ts', 'make_zero',
      if (out.toLowerCase().endsWith('.mp4') || out.toLowerCase().endsWith('.mov') || out.toLowerCase().endsWith('.m4v')) ...['-movflags', '+faststart'],
      out,
    ];
    onProgress(0.3);
    final p = _proc = await Process.start(exe, args);
    final err = StringBuffer();
    p.stderr.transform(utf8.decoder).listen(err.write);
    unawaited(p.stdout.drain<void>());
    final code = await p.exitCode;
    if (code != 0 && !_cancelled) DiagLog.log('player', 'clip copy failed: ${err.toString().trim().split('\n').last}');
    onProgress(1);
    return code == 0;
  }

  /// With the drawings: ffmpeg cuts the video (standing still where
  /// marks were drawn while paused), LocalRoll draws the marks frame by
  /// frame and hands them over; they are laid on top and encoded with the
  /// graphics chip's encoder (or Windows' own).
  Future<bool> _drawn(String exe, PlayerEntry e, String out, int startMs, int endMs, List<Note> notes, Size picture,
      void Function(double) onProgress) async {
    final ff = s.ffmpeg;
    final enc = await s.converter.encoders.best();
    if (enc == null) return false;
    final info = await ff.streamInfo(e.path);
    final hdr = (await ff.probe(e.path)).isHdr;
    final fps = info.fps;
    final w = _even(picture.width), h = _even(picture.height);
    // The marks are drawn at most 1920 on the long side, then scaled.
    final k = math.min(1.0, 1920 / math.max(w, h));
    final ow = _even(w * k), oh = _even(h * k);
    const ofps = 30;
    final pieces = clipPieces(notes, startMs, endMs);
    final total = pieces.fold<int>(0, (t, p) => t + p.lengthMs);
    final frames = (total / 1000 * ofps).ceil() + 1;

    // The filter: cut into pieces, stills held, joined, marks on top.
    final n = pieces.length;
    final g = StringBuffer('[0:v]${hdr ? '$_toneMap,' : ''}fps=${fps.toStringAsFixed(3)},scale=$w:$h,setsar=1,split=$n');
    for (var i = 0; i < n; i++) {
      g.write('[v$i]');
    }
    g.write(';');
    if (info.audio) {
      g.write('[0:a]aresample=48000,aformat=sample_fmts=fltp:channel_layouts=stereo,asplit=$n');
      for (var i = 0; i < n; i++) {
        g.write('[a$i]');
      }
      g.write(';');
    }
    final frame = (1 / fps).toStringAsFixed(4);
    for (var i = 0; i < n; i++) {
      final p = pieces[i];
      final from = _secs(p.fromMs - startMs), to = _secs(p.toMs - startMs);
      final f = p.freeze;
      if (f != null) {
        final d = _secs(f.totalMs);
        g.write('[v$i]trim=start=$from:duration=$frame,setpts=PTS-STARTPTS,tpad=stop_mode=clone:stop_duration=$d[p$i];');
        if (info.audio) {
          g.write('aevalsrc=exprs=0|0:channel_layout=stereo:sample_rate=48000:duration=$d,aformat=sample_fmts=fltp:channel_layouts=stereo[q$i];');
          g.write('[a$i]anullsink;');
        }
      } else {
        g.write('[v$i]trim=start=$from:end=$to,setpts=PTS-STARTPTS[p$i];');
        if (info.audio) g.write('[a$i]atrim=start=$from:end=$to,asetpts=PTS-STARTPTS[q$i];');
      }
    }
    for (var i = 0; i < n; i++) {
      g.write('[p$i]');
      if (info.audio) g.write('[q$i]');
    }
    g.write('concat=n=$n:v=1:a=${info.audio ? 1 : 0}[base]${info.audio ? '[aout]' : ''};');
    g.write('[1:v]scale=$w:$h,format=rgba[ov];[base][ov]overlay=0:0:eof_action=repeat,format=nv12[vout]');

    final args = [
      '-hide_banner', '-loglevel', 'error', '-y',
      '-ss', _secs(startMs), '-t', _secs(endMs - startMs + 200), '-i', e.path,
      '-f', 'rawvideo', '-pix_fmt', 'rgba', '-s', '${ow}x$oh', '-framerate', '$ofps', '-i', 'pipe:0',
      '-filter_complex', g.toString(),
      '-map', '[vout]', if (info.audio) ...['-map', '[aout]'],
      ...H264Encoders.args(enc, high: true, width: w, height: h, fps: fps),
      if (info.audio) ...['-c:a', 'aac', '-b:a', '192k'],
      '-t', _secs(total),
      '-movflags', '+faststart',
      out,
    ];
    final p = _proc = await Process.start(exe, args);
    final err = StringBuffer();
    p.stderr.transform(utf8.decoder).listen(err.write);
    unawaited(p.stdout.drain<void>());
    var closed = false;
    unawaited(p.exitCode.then((_) => closed = true));
    final size = Size(ow.toDouble(), oh.toDouble());
    try {
      for (var f = 0; f < frames && !_cancelled && !closed; f++) {
        final m = clipMoment(pieces, (f * 1000 / ofps).round());
        final rec = ui.PictureRecorder();
        paintNotes(Canvas(rec), size, notes, video: true, now: m.now, freeze: m.freeze);
        final img = await rec.endRecording().toImage(ow, oh);
        final bytes = await img.toByteData(format: ui.ImageByteFormat.rawStraightRgba);
        img.dispose();
        if (bytes == null) break;
        p.stdin.add(bytes.buffer.asUint8List());
        await p.stdin.flush();
        if (f % 10 == 0) onProgress(f / frames * 0.97);
      }
    } catch (err) {
      DiagLog.log('player', 'clip marks not handed over: $err');
    }
    try {
      await p.stdin.close();
    } catch (_) {}
    final code = await p.exitCode;
    if (code != 0 && !_cancelled) DiagLog.log('player', 'clip encode failed: ${err.toString().trim().split('\n').last}');
    onProgress(1);
    return code == 0;
  }
}
