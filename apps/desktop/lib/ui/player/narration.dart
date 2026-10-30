// apps/desktop/lib/ui/player/narration.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:localroll_core/localroll_core.dart';

import '../../app_services.dart';
import '../../services/annotations.dart';
import '../../services/library_index.dart';
import '../../services/video_encoders.dart';
import 'ink_paint.dart';
import 'snapshot.dart';

/// How the original's own sound goes into an explanation.
enum OriginalSound {
  /// Turned down to 30 %, under the voice.
  quiet,

  /// Only the voice.
  none,

  /// As it is, under the voice.
  full,
}

/// What the player looked like at one moment of a recording (20 times a
/// second): which file, where in it, playing or not, how fast, the part
/// of the picture shown (zoom), a replay of marks drawn while paused.
class NarrationSample {
  NarrationSample({
    required this.t,
    required this.file,
    required this.pos,
    required this.playing,
    required this.rate,
    required this.zoom,
    this.freezeNote,
    this.freezeAt,
    this.freezeMs,
  });

  /// ms into the recording.
  final int t;

  /// Which file (index in [NarrationSession.files]).
  final int file;

  /// Where in the video (ms; photos 0).
  final int pos;
  final bool playing;
  final double rate;

  /// The part of the picture shown (0–1).
  final Rect zoom;
  final String? freezeNote;
  final int? freezeAt;
  final int? freezeMs;

  Map<String, dynamic> toJson() => {
        't': t,
        'f': file,
        'p': pos,
        if (playing) 'pl': true,
        if (rate != 1) 'r': rate,
        if (zoom != const Rect.fromLTWH(0, 0, 1, 1)) 'z': [zoom.left, zoom.top, zoom.width, zoom.height],
        'fn': ?freezeNote,
        'fa': ?freezeAt,
        'fm': ?freezeMs,
      };

  static NarrationSample fromJson(Map<String, dynamic> j) {
    final z = j['z'] as List?;
    return NarrationSample(
      t: (j['t'] as num).toInt(),
      file: (j['f'] as num).toInt(),
      pos: (j['p'] as num).toInt(),
      playing: j['pl'] == true,
      rate: (j['r'] as num?)?.toDouble() ?? 1,
      zoom: z == null
          ? const Rect.fromLTWH(0, 0, 1, 1)
          : Rect.fromLTWH((z[0] as num).toDouble(), (z[1] as num).toDouble(), (z[2] as num).toDouble(), (z[3] as num).toDouble()),
      freezeNote: j['fn'] as String?,
      freezeAt: (j['fa'] as num?)?.toInt(),
      freezeMs: (j['fm'] as num?)?.toInt(),
    );
  }
}

/// A mark drawn while recording: what it looked like last, when it was
/// started on the recording's clock, each point's time, when it was rubbed
/// out (if it was).
class NarrationInk {
  NarrationInk({required this.file, required this.ink, required this.startT, required this.times, this.removedT});

  final int file;
  InkMark ink;
  final int startT;
  List<int> times;
  int? removedT;

  Map<String, dynamic> toJson() => {'f': file, 'ink': ink.toJson(), 's': startT, 'pt': times, 'x': ?removedT};

  static NarrationInk fromJson(Map<String, dynamic> j) => NarrationInk(
        file: (j['f'] as num).toInt(),
        ink: InkMark.fromJson(j['ink'] as Map<String, dynamic>),
        startT: (j['s'] as num).toInt(),
        times: [for (final t in (j['pt'] as List?) ?? const []) (t as num).toInt()],
        removedT: (j['x'] as num?)?.toInt(),
      );
}

/// One file of a recording.
class NarrationFile {
  const NarrationFile({required this.path, required this.name, required this.video, required this.width, required this.height, this.rel});

  final String path;
  final String name;
  final bool video;

  /// The picture's size as shown (rotation applied).
  final int width, height;
  final String? rel;

  Map<String, dynamic> toJson() => {'path': path, 'name': name, 'video': video, 'w': width, 'h': height, 'rel': ?rel};

  static NarrationFile fromJson(Map<String, dynamic> j) => NarrationFile(
        path: j['path'] as String,
        name: j['name'] as String? ?? '',
        video: j['video'] == true,
        width: (j['w'] as num?)?.toInt() ?? 1920,
        height: (j['h'] as num?)?.toInt() ?? 1080,
        rel: j['rel'] as String?,
      );
}

/// A whole recording: kept (with its voice) so it can be made again later,
/// e.g. with the original sound another way.
class NarrationSession {
  NarrationSession(
      {required this.id,
      required this.createdMs,
      List<NarrationFile>? files,
      List<NarrationSample>? samples,
      List<NarrationInk>? inks,
      this.lengthMs = 0,
      Set<String>? noteIds,
      Map<String, int>? edited})
      : files = files ?? [],
        samples = samples ?? [],
        inks = inks ?? [],
        noteIds = noteIds ?? {},
        edited = edited ?? {};

  final String id;
  final int createdMs;
  final List<NarrationFile> files;
  final List<NarrationSample> samples;
  final List<NarrationInk> inks;
  int lengthMs;

  /// Annotations made from what was drawn (left out when drawing those as
  /// they were before, so nothing shows twice).
  final Set<String> noteIds;

  /// Annotations from before that were changed while recording: from this
  /// moment on (ms), their marks are drawn from what was recorded (so a
  /// mark rubbed out goes at that moment, not from the start).
  final Map<String, int> edited;

  /// Where it is kept (with voice.wav).
  static Directory folderOf(Directory dataDir, String id) =>
      Directory('${dataDir.path}${Platform.pathSeparator}narrations${Platform.pathSeparator}$id');

  Map<String, dynamic> toJson() => {
        'version': 1,
        'id': id,
        'created': createdMs,
        'length': lengthMs,
        'files': [for (final f in files) f.toJson()],
        'samples': [for (final s in samples) s.toJson()],
        'inks': [for (final i in inks) i.toJson()],
        'notes': [...noteIds],
        'edited': edited,
      };

  static NarrationSession fromJson(Map<String, dynamic> j) => NarrationSession(
        id: j['id'] as String,
        createdMs: (j['created'] as num?)?.toInt() ?? 0,
        lengthMs: (j['length'] as num?)?.toInt() ?? 0,
        files: [for (final f in (j['files'] as List?) ?? const []) NarrationFile.fromJson(f as Map<String, dynamic>)],
        samples: [for (final s in (j['samples'] as List?) ?? const []) NarrationSample.fromJson(s as Map<String, dynamic>)],
        inks: [for (final i in (j['inks'] as List?) ?? const []) NarrationInk.fromJson(i as Map<String, dynamic>)],
        noteIds: {for (final x in (j['notes'] as List?) ?? const []) '$x'},
        edited: {
          for (final e in ((j['edited'] as Map?) ?? const {}).entries)
            if (e.value is num) '${e.key}': (e.value as num).toInt(),
        },
      );

  /// Every recording kept on this PC, newest first.
  static Future<List<NarrationSession>> all(Directory dataDir) async {
    final dir = Directory('${dataDir.path}${Platform.pathSeparator}narrations');
    final out = <NarrationSession>[];
    try {
      if (!await dir.exists()) return out;
      await for (final d in dir.list()) {
        if (d is! Directory) continue;
        final f = File('${d.path}${Platform.pathSeparator}session.json');
        try {
          if (await f.exists()) out.add(fromJson(jsonDecode(await f.readAsString()) as Map<String, dynamic>));
        } catch (_) {}
      }
    } catch (_) {}
    out.sort((a, b) => b.createdMs.compareTo(a.createdMs));
    return out;
  }
}

/// One stretch of the explanation video: a file playing from [fromMs] to
/// [toMs] (any speed), or standing still at [fromMs]; always [lengthMs]
/// long in the recording, and one framing ([zoom]).
class NarrationPiece {
  NarrationPiece({
    required this.file,
    required this.startT,
    required this.endT,
    required this.fromMs,
    required this.toMs,
    required this.still,
    required this.zoom,
    this.extra = false,
  });

  /// Before / after the explanation: the original as it is (its own sound,
  /// no voice, nothing drawn from the recording).
  final bool extra;

  final int file;
  final int startT;
  int endT;
  final int fromMs;
  int toMs;
  final bool still;
  final Rect zoom;

  int get lengthMs => endT - startT;

  /// Played at its own speed (its sound can go in).
  bool get normalSpeed => !still && ((toMs - fromMs) / math.max(1, lengthMs) - 1).abs() < 0.04;
}

/// The recording cut into pieces: a new piece when the file, the framing
/// or playing / pausing changes, or the video jumped.
List<NarrationPiece> narrationPieces(NarrationSession s) {
  final out = <NarrationPiece>[];
  final samples = s.samples;
  if (samples.isEmpty) return out;
  bool sameZoom(Rect a, Rect b) =>
      (a.left - b.left).abs() < 0.01 && (a.top - b.top).abs() < 0.01 && (a.width - b.width).abs() < 0.01 && (a.height - b.height).abs() < 0.01;
  NarrationPiece? cur;
  for (var k = 0; k < samples.length; k++) {
    final x = samples[k];
    final video = s.files[x.file].video;
    final still = !video || !x.playing;
    var joins = false;
    if (cur != null && cur.file == x.file && cur.still == still && sameZoom(cur.zoom, x.zoom)) {
      if (still) {
        joins = (x.pos - cur.fromMs).abs() < 40;
      } else {
        // Playing on: where it should be by now, give or take.
        final prev = samples[k - 1];
        final expected = prev.pos + (x.t - prev.t) * prev.rate;
        joins = (x.rate - prev.rate).abs() < 0.01 && (x.pos - expected).abs() < 250 && x.pos >= cur.toMs;
      }
    }
    if (joins) {
      cur!.endT = x.t;
      if (!still) cur.toMs = x.pos;
    } else {
      if (cur != null) {
        cur.endT = x.t;
        if (!cur.still) {
          // Up to where it got just before this moment.
          final prev = samples[k - 1];
          cur.toMs = math.max(cur.toMs, (prev.pos + (x.t - prev.t) * prev.rate).round());
        }
      }
      cur = NarrationPiece(file: x.file, startT: x.t, endT: x.t, fromMs: x.pos, toMs: x.pos, still: still, zoom: x.zoom);
      out.add(cur);
    }
  }
  final last = out.last;
  last.endT = math.max(last.endT, s.lengthMs);
  // Tiny pieces (a few frames) join the one before.
  final merged = <NarrationPiece>[];
  for (final p in out) {
    if (merged.isNotEmpty && p.lengthMs < 120) {
      merged.last.endT = p.endT;
      if (!merged.last.still && merged.last.file == p.file) merged.last.toMs = math.max(merged.last.toMs, p.toMs);
      continue;
    }
    merged.add(p);
  }
  return [for (final p in merged) if (p.lengthMs > 0) p];
}

/// The sample in effect at [t] (the last one at or before it).
NarrationSample? sampleAt(List<NarrationSample> samples, int t) {
  var lo = 0, hi = samples.length - 1;
  NarrationSample? best;
  while (lo <= hi) {
    final mid = (lo + hi) >> 1;
    if (samples[mid].t <= t) {
      best = samples[mid];
      lo = mid + 1;
    } else {
      hi = mid - 1;
    }
  }
  return best ?? (samples.isEmpty ? null : samples.first);
}

/// Makes the explanation video from a recording: each piece cut from the
/// original (standing still where it was paused, at its speed where it
/// played), the marks drawn on as they were drawn, joined, with the voice.
class NarrationComposer {
  NarrationComposer(this.s);

  final AppServices s;
  Process? _proc;
  bool _cancelled = false;

  void cancel() {
    _cancelled = true;
    _proc?.kill();
  }

  static String _secs(int ms) => (ms / 1000).toStringAsFixed(3);
  static int _even(double v) => math.max(2, (v / 2).round() * 2);

  static const String _toneMap = 'zscale=t=linear:npl=100,format=gbrpf32le,zscale=p=bt709,'
      'tonemap=tonemap=hable:desat=0,zscale=t=bt709:m=bt709:r=tv';

  static const int fps = 30;

  Future<bool> _run(String exe, List<String> args, {Future<void> Function(IOSink stdin)? feed}) async {
    if (_cancelled) return false;
    final p = _proc = await Process.start(exe, args);
    final err = StringBuffer();
    p.stderr.transform(const Utf8Decoder(allowMalformed: true)).listen(err.write);
    unawaited(p.stdout.drain<void>());
    if (feed != null) {
      try {
        await feed(p.stdin);
      } catch (e) {
        DiagLog.log('player', 'explanation: marks not handed over: $e');
      }
      try {
        await p.stdin.close();
      } catch (_) {}
    }
    final code = await p.exitCode;
    _proc = null;
    if (code != 0 && !_cancelled) DiagLog.log('player', 'explanation: ffmpeg failed: ${err.toString().trim().split('\n').last}');
    return code == 0;
  }

  /// Makes it; [voice] is the voice recording (WAV). Null when it failed
  /// or was cancelled.
  Future<File?> make(
    NarrationSession n, {
    required File voice,
    required OriginalSound sound,
    required List<NoteSet?> notes,
    required void Function(double) onProgress,
    int beforeMs = 0,
    int afterMs = 0,
    String? name,
  }) async {
    final ff = s.ffmpeg;
    final exe = ff.ffmpeg;
    if (exe == null || n.files.isEmpty) return null;
    final enc = await s.converter.encoders.best();
    if (enc == null) return null;
    final pieces = narrationPieces(n);
    if (pieces.isEmpty) return null;
    // A little of the original before and after: what led up to it, what
    // followed (videos only).
    var preMs = 0;
    final first = pieces.first, last = pieces.last;
    const whole = Rect.fromLTWH(0, 0, 1, 1);
    if (beforeMs > 0 && n.files[first.file].video) {
      preMs = math.min(beforeMs, first.fromMs);
      if (preMs >= 200) {
        pieces.insert(0, NarrationPiece(file: first.file, startT: 0, endT: preMs, fromMs: first.fromMs - preMs, toMs: first.fromMs, still: false, zoom: whole, extra: true));
      } else {
        preMs = 0;
      }
    }
    if (afterMs > 0 && n.files[last.file].video) {
      final from = last.still ? last.fromMs : last.toMs;
      final dur = (((await ff.probe(n.files[last.file].path)).durationSec ?? 0) * 1000).round();
      final len = dur > 0 ? math.min(afterMs, dur - from) : afterMs;
      if (len >= 200) {
        pieces.add(NarrationPiece(file: last.file, startT: 0, endT: len, fromMs: from, toMs: from + len, still: false, zoom: whole, extra: true));
      }
    }
    for (final p in pieces) {
      DiagLog.log('player', 'explanation piece: file ${p.file} (${n.files[p.file].video ? 'video' : 'photo'}) '
          '${p.extra ? 'around ' : ''}${p.still ? 'still at' : 'from'} ${p.fromMs} ms${p.still ? '' : ' to ${p.toMs} ms'}, ${p.lengthMs} ms');
    }
    final f0 = n.files[pieces.first.file];
    final k = math.min(1.0, 3840 / math.max(f0.width, f0.height));
    final w = _even(f0.width * k), h = _even(f0.height * k);
    // The marks are drawn at most 1920 on the long side, then scaled.
    final ok2 = math.min(1.0, 1920 / math.max(w, h));
    final ow = _even(w * ok2), oh = _even(h * ok2);

    final dir = await Directory.systemTemp.createTemp('lr_narration');
    final sep = Platform.pathSeparator;
    try {
      final total = pieces.fold<int>(0, (t, p) => t + p.lengthMs);
      var done = 0;
      final parts = <String>[];
      final info = <int, ({double fps, bool audio, bool hdr})>{};
      for (var i = 0; i < pieces.length && !_cancelled; i++) {
        final p = pieces[i];
        final file = n.files[p.file];
        final si = info[p.file] ??= await () async {
          if (!file.video) return (fps: 30.0, audio: false, hdr: false);
          final x = await ff.streamInfo(file.path);
          return (fps: x.fps, audio: x.audio, hdr: (await ff.probe(file.path)).isHdr);
        }();
        var src = file.path;
        if (!file.video && !nativelyDecodableImages.contains(extensionOf(file.name))) {
          final st = File(file.path).statSync();
          final pv = await ff.previewFile(file.path, size: st.size, modifiedMs: st.modified.millisecondsSinceEpoch);
          if (pv == null) return null;
          src = pv.path;
        }
        final out = '${dir.path}${sep}p$i.mp4';
        final len = _secs(p.lengthMs);
        final z = p.zoom;
        final frame = [
          if (si.hdr) _toneMap,
          if (z != const Rect.fromLTWH(0, 0, 1, 1))
            'crop=iw*${z.width.toStringAsFixed(5)}:ih*${z.height.toStringAsFixed(5)}:iw*${z.left.toStringAsFixed(5)}:ih*${z.top.toStringAsFixed(5)}',
          'scale=$w:$h:force_original_aspect_ratio=decrease',
          'pad=$w:$h:(ow-iw)/2:(oh-ih)/2',
          'setsar=1',
        ].join(',');
        final String vf;
        final List<String> input;
        if (!file.video) {
          input = ['-loop', '1', '-framerate', '$fps', '-t', len, '-i', src];
          vf = '[0:v]$frame,fps=$fps[base]';
        } else if (p.still) {
          input = ['-ss', _secs(p.fromMs), '-i', src];
          vf = '[0:v]trim=end_frame=1,$frame,setpts=PTS-STARTPTS,tpad=stop_mode=clone:stop_duration=$len,fps=$fps[base]';
        } else {
          final srcLen = math.max(40, p.toMs - p.fromMs);
          final stretch = (p.lengthMs / srcLen).toStringAsFixed(5);
          input = ['-ss', _secs(p.fromMs), '-t', _secs(srcLen + 100), '-i', src];
          vf = '[0:v]$frame,setpts=(PTS-STARTPTS)*$stretch,fps=$fps[base]';
        }
        // Around the explanation: the original's own sound, as it is.
        final keepSound = file.video && si.audio && (p.extra || (p.normalSpeed && sound != OriginalSound.none));
        final af = keepSound
            ? '[0:a]atrim=duration=$len,asetpts=PTS-STARTPTS,aresample=48000,aformat=sample_fmts=fltp:channel_layouts=stereo,'
                'volume=${sound == OriginalSound.quiet && !p.extra ? '0.3' : '1.0'},apad=whole_dur=$len[aout]'
            : 'anullsrc=channel_layout=stereo:sample_rate=48000,atrim=duration=$len[aout]';
        final frames = (p.lengthMs / 1000 * fps).ceil() + 1;
        final args = [
          '-hide_banner', '-loglevel', 'error', '-y',
          ...input,
          '-f', 'rawvideo', '-pix_fmt', 'rgba', '-s', '${ow}x$oh', '-framerate', '$fps', '-i', 'pipe:0',
          '-filter_complex', '$vf;[1:v]scale=$w:$h,format=rgba[ov];[base][ov]overlay=0:0:eof_action=repeat,format=nv12[vout];$af',
          '-map', '[vout]', '-map', '[aout]',
          ...H264Encoders.args(enc, high: true, width: w, height: h, fps: fps.toDouble()),
          '-g', '$fps', '-c:a', 'aac', '-b:a', '192k', '-ar', '48000', '-ac', '2',
          '-t', len,
          out,
        ];
        final pieceStart = done;
        final ok = await _run(exe, args, feed: (stdin) async {
          final size = Size(ow.toDouble(), oh.toDouble());
          for (var f = 0; f < frames && !_cancelled; f++) {
            final t = p.startT + (f * 1000 / fps).round();
            final rec = ui.PictureRecorder();
            _paintAt(Canvas(rec), size, n, notes, p, t, file);
            final img = await rec.endRecording().toImage(ow, oh);
            final bytes = await img.toByteData(format: ui.ImageByteFormat.rawStraightRgba);
            img.dispose();
            if (bytes == null) break;
            stdin.add(bytes.buffer.asUint8List());
            await stdin.flush();
            if (f % 15 == 0) onProgress(((pieceStart + f * 1000 / fps) / total * 0.9).clamp(0.0, 0.9));
          }
        });
        if (!ok) return null;
        parts.add(out);
        done += p.lengthMs;
      }
      if (_cancelled) return null;

      // Joined (as they are), then the voice laid over.
      final list = File('${dir.path}${sep}list.txt');
      await list.writeAsString([for (final p in parts) "file '${p.replaceAll("'", "'\\''")}'"].join('\n'));
      final joined = '${dir.path}${sep}joined.mp4';
      if (!await _run(exe, ['-hide_banner', '-loglevel', 'error', '-y', '-f', 'concat', '-safe', '0', '-i', list.path, '-c', 'copy', joined])) {
        return null;
      }
      onProgress(0.95);
      final folder = Snapshots.folder(s, narration: true);
      await Directory(folder).create(recursive: true);
      final base = f0.name.contains('.') ? f0.name.substring(0, f0.name.lastIndexOf('.')) : f0.name;
      final stamp = DateTime.fromMillisecondsSinceEpoch(n.createdMs);
      String two(int v) => v.toString().padLeft(2, '0');
      final fallback = '${base}_${stamp.year}${two(stamp.month)}${two(stamp.day)}-${two(stamp.hour)}${two(stamp.minute)}';
      final out = LibraryIndex.uniquePath(folder, sanitizeFileName('${(name ?? '').trim().isEmpty ? fallback : name!.trim()}.mp4'));
      final hasVoice = voice.existsSync() && voice.lengthSync() > 44;
      final ok = await _run(exe, [
        '-hide_banner', '-loglevel', 'error', '-y',
        '-i', joined,
        if (hasVoice) ...['-i', voice.path],
        if (hasVoice) ...[
          '-filter_complex',
          // The voice starts where the explanation starts (after the lead-in).
          '[1:a]aresample=48000,aformat=sample_fmts=fltp:channel_layouts=stereo,${preMs > 0 ? 'adelay=$preMs|$preMs,' : ''}apad[v];'
              '[0:a][v]amix=inputs=2:duration=first:normalize=0[a]',
          '-map', '0:v', '-map', '[a]',
        ] else ...['-map', '0:v', '-map', '0:a'],
        '-c:v', 'copy', '-c:a', 'aac', '-b:a', '192k',
        '-movflags', '+faststart',
        out,
      ]);
      if (!ok || !File(out).existsSync()) return null;
      onProgress(1);
      return Snapshots.done(s, File(out), video: true);
    } catch (e) {
      DiagLog.log('player', 'explanation not made: $e');
      return null;
    } finally {
      try {
        await dir.delete(recursive: true);
      } catch (_) {}
    }
  }

  /// The marks at [t] into the recording, on the output frame: the
  /// file's own annotations as the player showed them, plus what was drawn
  /// while recording, stroke by stroke.
  void _paintAt(Canvas c, Size out, NarrationSession n, List<NoteSet?> notes, NarrationPiece p, int t, NarrationFile file) {
    final x = sampleAt(n.samples, t);
    // Where the picture sits on the frame (the framing [p.zoom], fitted).
    final z = p.zoom;
    final pw = file.width * z.width, ph = file.height * z.height;
    final fit = math.min(out.width / pw, out.height / ph);
    final pic = Size(file.width * fit, file.height * fit);
    final dx = (out.width - pw * fit) / 2 - z.left * pic.width;
    final dy = (out.height - ph * fit) / 2 - z.top * pic.height;
    c.save();
    c.clipRect(Offset.zero & out);
    c.translate(dx, dy);
    // The file's own annotations (not those made from this recording).
    final set = p.file < notes.length ? notes[p.file] : null;
    if (set != null) {
      final own = [
        for (final m in set.notes)
          if (!n.noteIds.contains(m.id) && (p.extra || n.edited[m.id] == null || t < n.edited[m.id]!)) m,
      ];
      final FreezeNow? fz = x?.freezeNote == null
          ? null
          : () {
              for (final m in own) {
                for (final f in m.freezes) {
                  if (f.noteId == x!.freezeNote && f.atMs == x.freezeAt) return (plan: f, elapsedMs: x.freezeMs ?? 0);
                }
              }
              return null;
            }();
      final pos = p.extra ? p.fromMs + (t - p.startT) : (x?.pos ?? p.fromMs);
      paintNotes(c, pic, own, video: file.video, now: pos, freeze: p.extra ? null : fz);
    }
    for (final i in n.inks) {
      if (p.extra) break;
      if (i.file != p.file || t < i.startT || (i.removedT != null && t >= i.removedT!)) continue;
      final m = i.ink.copy()
        ..times = i.times
        ..live = true;
      InkGeometry.paint(c, pic, m, upto: t - i.startT);
    }
    c.restore();
  }
}

/// The voice of a recording in one file: each part (recording was paused
/// in between) from [headMs] in (the microphone started a little before),
/// cut or padded to exactly how long it lasted.
Future<bool> joinVoice(String exe, List<({File file, int headMs, int lengthMs})> parts, File out) async {
  final use = [for (final p in parts) if (p.file.existsSync() && p.file.lengthSync() > 44 && p.lengthMs > 0) p];
  if (use.isEmpty) return false;
  final g = StringBuffer();
  for (var i = 0; i < use.length; i++) {
    final h = (use[i].headMs / 1000).toStringAsFixed(3);
    final d = (use[i].lengthMs / 1000).toStringAsFixed(3);
    g.write('[$i:a]aresample=48000,atrim=start=$h,asetpts=PTS-STARTPTS,apad=whole_dur=$d,atrim=duration=$d,asetpts=PTS-STARTPTS[a$i];');
  }
  for (var i = 0; i < use.length; i++) {
    g.write('[a$i]');
  }
  g.write('concat=n=${use.length}:v=0:a=1[out]');
  try {
    final r = await Process.run(exe, [
      '-hide_banner', '-loglevel', 'error', '-y',
      for (final p in use) ...['-i', p.file.path],
      '-filter_complex', g.toString(),
      '-map', '[out]', '-c:a', 'pcm_s16le', out.path,
    ]);
    if (r.exitCode != 0) DiagLog.log('player', 'explanation voice not joined: ${'${r.stderr}'.trim().split('\n').last}');
    return r.exitCode == 0;
  } catch (e) {
    DiagLog.log('player', 'explanation voice not joined: $e');
    return false;
  }
}
