// apps/desktop/lib/ui/screen/screen_editor.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:localroll_core/localroll_core.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../app_services.dart';
import '../../l10n/l10n.dart';
import '../../services/annotations.dart';
import '../../services/mic.dart';
import '../player/narration.dart' show NarrationInk, betweens;
import '../player/narration_dialogs.dart' show pickMicrophone;
import '../player/player_page.dart' show playerTime;
import '../theme.dart';
import 'screen_record.dart' show ScreenSession;

/// Edits a screen recording from its kept material, the way an explanation
/// is edited: plays it back, marks deleted, stretches made silent, cut out
/// or spoken again. True when something was changed and kept (then the
/// video is made again by the caller).
Future<bool> editScreenRecording(BuildContext context, AppServices s, ScreenSession session) async {
  final r = await Navigator.of(context).push<bool>(MaterialPageRoute(builder: (_) => _Editor(services: s, session: session)));
  return r == true;
}

/// One change (undone in reverse). Times: the recording as it was.
sealed class _Edit {}

class _DeleteInk extends _Edit {
  _DeleteInk(this.ids);
  final Set<String> ids;
}

class _Mute extends _Edit {
  _Mute(this.a, this.b);
  final int a, b;
}

class _Cut extends _Edit {
  _Cut(this.a, this.b);
  final int a, b;
}

/// [a]..[b] spoken again: [file] from [head] ms, [len] ms long (longer
/// than b − a: the picture holds at [b] meanwhile).
class _Redub extends _Edit {
  _Redub(this.a, this.b, this.file, this.head, this.len);
  final int a, b, head, len;
  final File file;
  int get extra => math.max(0, len - (b - a));
}

/// A stretch played back: the picture [from]..[to], [length] long (longer:
/// held at [to]); the voice as recorded, or a new one, or one being
/// recorded now.
class _Span {
  const _Span(this.from, this.to, this.length, {this.redub, this.taking = false});
  final int from, to, length;
  final _Redub? redub;
  final bool taking;
}

/// One filmed part: [file] from [head] ms shows at [start]..[start]+[len]
/// of the recording ([still]: its first picture held).
class _Part {
  _Part(this.file, this.start, this.head, this.len, {this.still = false});
  final String file;
  final int start, head, len;
  final bool still;
  int get end => start + len;

  static _Part of(Map<String, dynamic> p) =>
      _Part(p['f'] as String, (p['s'] as num).toInt(), (p['h'] as num).toInt(), (p['l'] as num).toInt(), still: p['still'] == 1);
  Map<String, dynamic> toJson() => {'f': file, 's': start, 'h': head, 'l': len, if (still) 'still': 1};
}

class _Editor extends StatefulWidget {
  const _Editor({required this.services, required this.session});

  final AppServices services;
  final ScreenSession session;

  @override
  State<_Editor> createState() => _EditorState();
}

class _EditorState extends State<_Editor> {
  late final Map<String, dynamic> j = jsonDecode(jsonEncode(widget.session.json)) as Map<String, dynamic>;
  Directory get dir => widget.session.dir;
  late final List<NarrationInk> inks = widget.session.inks;
  late final List<_Part> parts = [for (final p in (j['parts'] as List? ?? const [])) _Part.of(p as Map<String, dynamic>)];
  late final int length = (j['length'] as num?)?.toInt() ?? 0;
  late final Rect area = _rect(j['area']);
  late final Rect screen = _rect((j['screen'] as Map?)?['rect']);
  late final List<(int, int, Rect)> boards = [
    for (final b in (j['boards'] as List? ?? const [])) ((b[0] as num).toInt(), (b[1] as num).toInt(), _rect((b as List).sublist(2))),
  ];
  late final Map<String, bool> fades = {for (final e in (j['fades'] as Map? ?? const {}).entries) e.key as String: e.value == true};

  final List<_Edit> _edits = [];
  List<double> _peaks = const [];
  int _t = 0;
  (int, int)? _sel;
  bool _saving = false;
  final FocusNode _focus = FocusNode();

  // Playing back.
  final Player _voice = Player();
  final Player _pc = Player();
  final Player _take = Player();
  bool _voiceOpen = false, _pcOpen = false;
  List<_Span>? _spans;
  int _si = 0;
  final Stopwatch _clock = Stopwatch();
  int _spanAt = 0;
  Timer? _tick;
  bool get _playing => _spans != null;

  // Speaking again.
  MicRecorder? _mic;
  File? _takeFile;
  int _takeA = 0, _takeB = 0, _takeHead = 0;
  int? _takeStart;
  bool get _taking => _mic != null;

  static Rect _rect(Object? v) {
    final l = [for (final x in (v as List? ?? const [0, 0, 1, 1])) (x as num).toDouble()];
    return Rect.fromLTRB(l[0], l[1], l[2], l[3]);
  }

  File? _named(String key) {
    final n = j[key];
    if (n is! String) return null;
    final f = File('${dir.path}${Platform.pathSeparator}$n');
    return f.existsSync() ? f : null;
  }

  File? get _voiceFile => _named('voice');
  File? get _pcFile => _named('system');

  @override
  void initState() {
    super.initState();
    unawaited(_loadPeaks());
  }

  @override
  void dispose() {
    _tick?.cancel();
    unawaited(_mic?.stop());
    _voice.dispose();
    _pc.dispose();
    _take.dispose();
    _focus.dispose();
    super.dispose();
  }

  Set<String> get _deleted => {for (final e in _edits) if (e is _DeleteInk) ...e.ids};
  List<(int, int)> get _mutes => [for (final e in _edits) if (e is _Mute) (e.a, e.b)];
  List<(int, int)> get _cuts => [for (final e in _edits) if (e is _Cut) (e.a, e.b)];
  List<_Redub> get _redubs => [for (final e in _edits) if (e is _Redub) e];

  /// The voice's (else the PC sound's) loudness, one value per 20 ms (0–1).
  Future<void> _loadPeaks() async {
    final f = _voiceFile ?? _pcFile;
    if (f == null) return;
    try {
      final b = await f.readAsBytes();
      final d = ByteData.sublistView(b);
      var p = 12, ch = 1, rate = 48000, bits = 16, start = -1, size = 0;
      while (p + 8 <= b.length) {
        final id = String.fromCharCodes(b.sublist(p, p + 4));
        final len = d.getUint32(p + 4, Endian.little);
        if (id == 'fmt ') {
          ch = d.getUint16(p + 10, Endian.little);
          rate = d.getUint32(p + 12, Endian.little);
          bits = d.getUint16(p + 22, Endian.little);
        } else if (id == 'data') {
          start = p + 8;
          size = math.min(len, b.length - start);
          break;
        }
        p += 8 + len + (len & 1);
      }
      if (start < 0 || bits != 16) return;
      final frame = 2 * ch, per = rate ~/ 50;
      final peaks = <double>[];
      for (var i = start; i + frame <= start + size; i += per * frame) {
        var m = 0;
        final end = math.min(start + size, i + per * frame);
        for (var k = i; k + 1 < end; k += 2 * ch) {
          final v = d.getInt16(k, Endian.little).abs();
          if (v > m) m = v;
        }
        peaks.add(math.min(1.0, m / 20000));
      }
      if (mounted) setState(() => _peaks = peaks);
    } catch (e) {
      DiagLog.log('screen', 'recording sound not read: $e');
    }
  }

  bool _clashes(int a, int b) => [
        for (final e in _edits)
          if (e is _Cut) (e.a, e.b) else if (e is _Redub) (e.a, e.b),
      ].any((r) => a < r.$2 && b > r.$1);

  // ------------------------------------------------------------ playback

  List<_Span> _plan(int from) {
    final structural = [
      for (final e in _edits)
        if (e is _Cut) (e.a, e.b, null as _Redub?) else if (e is _Redub) (e.a, e.b, e),
    ]..sort((x, y) => x.$1.compareTo(y.$1));
    final out = <_Span>[];
    var cursor = 0;
    for (final (a, b, r) in structural) {
      if (cursor < a) out.add(_Span(cursor, a, a - cursor));
      if (r != null) out.add(_Span(a, b, math.max(b - a, r.len), redub: r));
      cursor = b;
    }
    if (cursor < length) out.add(_Span(cursor, length, length - cursor));
    final res = <_Span>[];
    for (final s in out) {
      if (s.to <= from) continue;
      res.add(s.from < from && s.redub == null ? _Span(from, s.to, s.to - from) : s);
    }
    return res;
  }

  Future<void> _play(List<_Span> spans) async {
    if (spans.isEmpty) return;
    final v = _voiceFile, p = _pcFile;
    if (!_voiceOpen && v != null) {
      await _voice.open(Media(v.path), play: false);
      _voiceOpen = true;
    }
    if (!_pcOpen && p != null) {
      await _pc.open(Media(p.path), play: false);
      _pcOpen = true;
    }
    setState(() {
      _spans = spans;
      _si = 0;
      _sel = null;
    });
    _clock
      ..reset()
      ..start();
    _spanAt = 0;
    await _startSpan();
    _tick?.cancel();
    _tick = Timer.periodic(const Duration(milliseconds: 33), (_) => _onTick());
  }

  Future<void> _startSpan() async {
    final sp = _spans![_si];
    final r = sp.redub;
    Future<void> sounds(bool on) async {
      for (final (pl, open) in [(_voice, _voiceOpen), (_pc, _pcOpen)]) {
        if (!open) continue;
        if (on) {
          await pl.seek(Duration(milliseconds: sp.from));
          await pl.play();
        } else {
          await pl.pause();
        }
      }
    }

    if (sp.taking) {
      await sounds(false);
      await _take.pause();
    } else if (r != null) {
      await sounds(false);
      await _take.open(Media(r.file.path, start: Duration(milliseconds: r.head)), play: true);
    } else {
      await _take.pause();
      await sounds(true);
    }
  }

  void _onTick() {
    final spans = _spans;
    if (spans == null || !mounted) return;
    var sp = spans[_si];
    var e = _clock.elapsedMilliseconds - _spanAt;
    if (e >= sp.length) {
      if (_si + 1 >= spans.length) {
        unawaited(_stop());
        return;
      }
      _si++;
      _spanAt = _clock.elapsedMilliseconds;
      e = 0;
      sp = spans[_si];
      unawaited(_startSpan());
    }
    final int t = sp.from + math.min<int>(e, sp.to - sp.from);
    if (sp.taking && _takeStart == null) {
      _takeStart = _clock.elapsedMilliseconds;
      final first = _mic?.firstSound ?? DateTime.now();
      _takeHead = math.max(0, DateTime.now().difference(first).inMilliseconds);
    }
    if (!sp.taking && sp.redub == null) {
      final silent = _mutes.any((m) => t >= m.$1 && t < m.$2);
      if (_voiceOpen) unawaited(_voice.setVolume(silent ? 0 : 100));
      if (_pcOpen) unawaited(_pc.setVolume(silent ? 0 : 100));
    }
    setState(() => _t = t);
  }

  Future<void> _stop() async {
    _tick?.cancel();
    _clock.stop();
    await _voice.pause();
    await _pc.pause();
    await _take.pause();
    final mic = _mic;
    if (mic != null) {
      final start = _takeStart;
      final len = start == null ? 0 : _clock.elapsedMilliseconds - start;
      _mic = null;
      await mic.stop();
      final f = _takeFile;
      if (f != null && len > 300) _edits.add(_Redub(_takeA, _takeB, f, _takeHead, len));
    }
    if (mounted) setState(() => _spans = null);
  }

  Future<void> _redub() async {
    final sel = _sel;
    final s = widget.services;
    if (sel == null || _playing) return;
    if (_clashes(sel.$1, sel.$2)) return _snack(tr('nedit.overlap'));
    final mic = MicRecorder(s.ffmpeg.ffmpeg);
    var device = s.player.mic;
    final devices = await mic.devices();
    if (!mounted) return;
    if (device == null || !devices.contains(device)) {
      device = await pickMicrophone(context, mic, current: device);
      if (device == null || !mounted) return;
      s.player.setMic(device);
    }
    final f = File('${dir.path}${Platform.pathSeparator}take_${DateTime.now().millisecondsSinceEpoch}.wav');
    if (!await mic.start(device, f)) return _snack(tr('rec.mic_failed'));
    _mic = mic;
    _takeFile = f;
    _takeA = sel.$1;
    _takeB = sel.$2;
    _takeStart = null;
    final pre = math.max(0, sel.$1 - 2000);
    await _play([
      if (pre < sel.$1) _Span(pre, sel.$1, sel.$1 - pre),
      _Span(sel.$1, sel.$2, 1 << 30, taking: true),
    ]);
  }

  void _snack(String text) => ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(text)));

  // ------------------------------------------------------------- editing

  Future<void> _deleteInk(NarrationInk i) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('nedit.delete_mark')),
        content: SizedBox(width: 420, child: Text(tr('sedit.delete_mark_tip'))),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('common.cancel'))),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), style: FilledButton.styleFrom(backgroundColor: LrColors.danger), child: Text(tr('ink.delete'))),
        ],
      ),
    );
    // A mark moved later is the same mark: all its versions go.
    if (ok == true) {
      final base = i.ink.id.contains('_') ? i.ink.id.substring(0, i.ink.id.lastIndexOf('_')) : i.ink.id;
      setState(() => _edits.add(_DeleteInk({for (final x in inks) if (x.ink.id == i.ink.id || x.ink.id.startsWith('${base}_')) x.ink.id})));
    }
  }

  Future<void> _cutSelection() async {
    final sel = _sel;
    if (sel == null) return;
    if (_clashes(sel.$1, sel.$2)) return _snack(tr('nedit.overlap'));
    final drawn = [for (final i in inks) if (i.startT >= sel.$1 && i.startT < sel.$2 && !_deleted.contains(i.ink.id)) i].length;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('nedit.cut_title', {'len': playerTime(Duration(milliseconds: sel.$2 - sel.$1))})),
        content: SizedBox(width: 440, child: Text(drawn == 0 ? tr('nedit.cut_tip') : tr('sedit.cut_tip_marks', {'n': drawn}))),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('common.cancel'))),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(tr('nedit.cut'))),
        ],
      ),
    );
    if (ok == true) {
      setState(() {
        _edits.add(_Cut(sel.$1, sel.$2));
        _sel = null;
      });
    }
  }

  /// Rebuilds a sound file: its old pieces (silent where asked), new ones
  /// in between ([takes], for the voice).
  Future<void> _sound(String exe, File src, List<(int, int, _Redub?)> structural, List<(int, int)> mutes,
      {required bool voice, required List<File> takes}) async {
    String sec(int ms) => (ms / 1000).toStringAsFixed(3);
    final layout = voice ? 'mono' : 'stereo';
    final pieces = <String>[];
    var cursor = 0;
    void old(int a, int b, [int pad = 0]) {
      if (b > a) pieces.add('o:$a:$b:$pad');
    }

    for (final (a, b, r) in structural) {
      old(cursor, a);
      if (r != null) {
        if (voice) {
          pieces.add('t:${takes.indexOf(r.file)}:${r.head}:${math.max(b - a, r.len)}');
        } else {
          // The PC's sound goes on under the new voice; quiet while the
          // picture holds.
          old(a, b, r.extra);
        }
      }
      cursor = b;
    }
    old(cursor, length + 1000);
    final olds = pieces.where((p) => p.startsWith('o')).length;
    final g = StringBuffer('[0:a]aresample=48000,aformat=channel_layouts=$layout');
    if (mutes.isNotEmpty) g.write(",volume=enable='${betweens(mutes)}':volume=0");
    g.write(olds > 1 ? ',asplit=$olds' : '');
    for (var k = 0; k < olds; k++) {
      g.write('[o$k]');
    }
    g.write(';');
    var ok = 0;
    for (var i = 0; i < pieces.length; i++) {
      final p = pieces[i].split(':');
      if (p[0] == 'o') {
        final a = int.parse(p[1]), b = int.parse(p[2]), pad = int.parse(p[3]);
        g.write('[o${ok++}]atrim=start=${sec(a)}:end=${sec(b)},asetpts=PTS-STARTPTS'
            '${pad > 0 ? ',apad,atrim=duration=${sec(b - a + pad)}' : ''}[s$i];');
      } else {
        g.write('[${int.parse(p[1]) + 1}:a]aresample=48000,aformat=channel_layouts=$layout,atrim=start=${sec(int.parse(p[2]))},'
            'asetpts=PTS-STARTPTS,apad,atrim=duration=${sec(int.parse(p[3]))}[s$i];');
      }
    }
    for (var i = 0; i < pieces.length; i++) {
      g.write('[s$i]');
    }
    g.write('concat=n=${pieces.length}:v=0:a=1[out]');
    final out = File('${src.path}.edit.wav');
    final r = await Process.run(exe, [
      '-hide_banner', '-loglevel', 'error', '-y', '-i', src.path,
      for (final t in takes) ...['-i', t.path],
      '-filter_complex', g.toString(), '-map', '[out]', '-c:a', 'pcm_s16le', out.path,
    ]);
    if (r.exitCode != 0 || !out.existsSync()) throw Exception('sound: ${'${r.stderr}'.trim()}');
    await out.rename(src.path);
  }

  /// Applies every change: the marks, the sounds, the filmed parts and
  /// everything timed (clicks, window, boards), then keeps it.
  Future<void> _save() async {
    if (_playing) await _stop();
    if (_edits.isEmpty) {
      if (mounted) Navigator.pop(context, false);
      return;
    }
    setState(() => _saving = true);
    final exe = widget.services.ffmpeg.ffmpeg;
    try {
      final gone = {..._deleted};
      var marks = [for (final i in inks) if (!gone.contains(i.ink.id)) i];
      final mutes = _mutes, redubs = _redubs;
      final structural = [
        for (final e in _edits)
          if (e is _Cut) (e.a, e.b, null as _Redub?) else if (e is _Redub) (e.a, e.b, e),
      ]..sort((x, y) => x.$1.compareTo(y.$1));
      if (exe != null && (mutes.isNotEmpty || structural.isNotEmpty)) {
        final v = _voiceFile, p = _pcFile;
        if (v != null) await _sound(exe, v, structural, mutes, voice: true, takes: [for (final r in redubs) r.file]);
        if (p != null) await _sound(exe, p, structural, mutes, voice: false, takes: const []);
      }
      // Everything timed, last change first so earlier times stay right.
      var ps = List.of(parts);
      var clicks = [for (final c in (j['clicks'] as List? ?? const [])) List<Object?>.of(c as List)];
      var windowAt = [for (final w in (j['windowAt'] as List? ?? const [])) List<Object?>.of(w as List)];
      var front = [for (final f in (j['front'] as List? ?? const [])) List<Object?>.of(f as List)];
      var bds = [for (final b in (j['boards'] as List? ?? const [])) List<Object?>.of(b as List)];
      var len = length;
      int tOf(List<Object?> x) => (x[0] as num).toInt();
      List<Object?> at(List<Object?> x, int t) => [t, ...x.sublist(1)];
      // A "where it is from then on" list cut at [a]..[b]: what was in
      // force at b starts at a.
      List<List<Object?>> cutSteps(List<List<Object?>> l, int a, int b) {
        final d = b - a;
        List<Object?>? inForce;
        for (final x in l) {
          if (tOf(x) <= b) inForce = x;
        }
        return [
          for (final x in l)
            if (tOf(x) < a) x,
          if (inForce != null && tOf(inForce) >= a) at(inForce, a),
          for (final x in l)
            if (tOf(x) > b) at(x, tOf(x) - d),
        ];
      }

      for (final (a, b, r) in structural.reversed) {
        if (r == null) {
          final d = b - a;
          int map(int t) => t < a ? t : (t >= b ? t - d : a);
          marks = [
            for (final i in marks)
              if (i.startT < a || i.startT >= b)
                NarrationInk(file: 0, ink: i.ink, startT: map(i.startT), times: i.times, removedT: i.removedT == null ? null : map(i.removedT!)),
          ];
          ps = [
            for (final p in ps)
              if (p.end <= a)
                p
              else if (p.start >= b)
                _Part(p.file, p.start - d, p.head, p.len, still: p.still)
              else ...[
                if (p.start < a) _Part(p.file, p.start, p.head, a - p.start, still: p.still),
                if (p.end > b) _Part(p.file, a, p.still ? p.head : p.head + (b - p.start), p.end - b, still: p.still),
              ],
          ];
          clicks = [
            for (final c in clicks)
              if (tOf(c) < a || tOf(c) >= b) at(c, map(tOf(c))),
          ];
          windowAt = cutSteps(windowAt, a, b);
          front = cutSteps(front, a, b);
          bds = cutSteps(bds, a, b);
          len -= d;
        } else if (r.extra > 0) {
          // The picture holds at b while the new voice goes on.
          final e = r.extra;
          int later(int t) => t >= b ? t + e : t;
          marks = [
            for (final i in marks)
              NarrationInk(file: 0, ink: i.ink, startT: later(i.startT), times: i.times, removedT: i.removedT == null ? null : later(i.removedT!)),
          ];
          final out = <_Part>[];
          if (ps.isNotEmpty) {
            // The part playing at b (or the last one, b being the end).
            final hit = ps.lastWhere((p) => p.start <= b && b < p.end, orElse: () => ps.last);
            for (final p in ps) {
              if (identical(p, hit)) {
                final local = p.still ? p.head : p.head + (math.min(b, p.end) - p.start);
                if (b > p.start) out.add(_Part(p.file, p.start, p.head, math.min(b, p.end) - p.start, still: p.still));
                out.add(_Part(p.file, b, math.max(0, local - 40), e, still: true));
                if (p.end > b) out.add(_Part(p.file, b + e, local, p.end - b, still: p.still));
              } else if (p.start >= b) {
                out.add(_Part(p.file, p.start + e, p.head, p.len, still: p.still));
              } else {
                out.add(p);
              }
            }
          }
          ps = out;
          clicks = [for (final c in clicks) at(c, later(tOf(c)))];
          windowAt = [for (final w in windowAt) at(w, later(tOf(w)))];
          front = [for (final f in front) at(f, later(tOf(f)))];
          bds = [for (final x in bds) at(x, later(tOf(x)))];
          len += e;
        }
      }
      j['parts'] = [for (final p in ps) p.toJson()];
      j['inks'] = [for (final i in marks) i.toJson()];
      j['clicks'] = clicks;
      j['windowAt'] = windowAt;
      j['front'] = front;
      j['boards'] = bds;
      j['length'] = len;
      await File('${dir.path}${Platform.pathSeparator}session.json').writeAsString(jsonEncode(j));
      for (final r in redubs) {
        try {
          await r.file.delete();
        } catch (_) {}
      }
      DiagLog.log('screen', 'recording edited: ${gone.length} marks out, ${mutes.length} silent, ${structural.length} cut / spoken again');
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      DiagLog.log('screen', 'recording not edited: $e');
      if (!mounted) return;
      setState(() => _saving = false);
      _snack(tr('nedit.failed'));
    }
  }

  Future<void> _close() async {
    if (_playing) await _stop();
    for (final r in _redubs) {
      try {
        await r.file.delete();
      } catch (_) {}
    }
    if (mounted) Navigator.pop(context, false);
  }

  KeyEventResult _key(FocusNode _, KeyEvent e) {
    if (e is! KeyDownEvent || e.logicalKey != LogicalKeyboardKey.space) return KeyEventResult.ignored;
    _playing ? unawaited(_stop()) : unawaited(_play(_plan(_t)));
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final len = math.max(1, length);
    final sel = _sel;
    final sp = _spans == null ? null : _spans![_si];
    final taking = sp?.taking ?? false;
    // Holding the picture (spoken longer than the stretch): the video waits.
    final holding = sp != null && (_clock.elapsedMilliseconds - _spanAt) > (sp.to - sp.from);
    return Focus(
      focusNode: _focus,
      autofocus: true,
      onKeyEvent: _key,
      child: Scaffold(
        backgroundColor: LrColors.ink,
        appBar: AppBar(
          automaticallyImplyLeading: false,
          title: Text(tr('sedit.title')),
          actions: [
            IconButton(
              tooltip: tr('ink.undo'),
              onPressed: _edits.isEmpty || _saving || _playing
                  ? null
                  : () => setState(() {
                        final e = _edits.removeLast();
                        if (e is _Redub) unawaited(e.file.delete().catchError((_) => e.file));
                      }),
              icon: const Icon(Icons.undo_rounded),
            ),
            TextButton(onPressed: _saving ? null : () => unawaited(_close()), child: Text(tr('common.cancel'))),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: FilledButton.icon(
                onPressed: _saving || _taking ? null : _save,
                icon: _saving ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.check_rounded, size: 18),
                label: Text(tr('nedit.save')),
              ),
            ),
          ],
        ),
        body: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Expanded(
              child: Stack(children: [
                Positioned.fill(
                  child: Container(
                    decoration: BoxDecoration(color: Colors.black, borderRadius: BorderRadius.circular(8)),
                    clipBehavior: Clip.antiAlias,
                    child: _Stage(
                      dir: dir,
                      parts: parts,
                      area: area,
                      screen: screen,
                      inks: inks,
                      fades: fades,
                      boards: boards,
                      deleted: _deleted,
                      t: _t,
                      playing: _playing && !holding,
                    ),
                  ),
                ),
                if (_taking)
                  Positioned(
                    top: 12,
                    left: 0,
                    right: 0,
                    child: Center(
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                        decoration: BoxDecoration(color: const Color(0xE6202020), borderRadius: BorderRadius.circular(20), border: Border.all(color: LrColors.danger)),
                        child: Text(
                          taking
                              ? tr('nedit.taking', {
                                  'was': playerTime(Duration(milliseconds: _takeB - _takeA)),
                                  'now': playerTime(Duration(milliseconds: _takeStart == null ? 0 : _clock.elapsedMilliseconds - _takeStart!)),
                                })
                              : tr('nedit.take_soon'),
                          style: const TextStyle(color: Colors.white, fontFeatures: [ui.FontFeature.tabularFigures()]),
                        ),
                      ),
                    ),
                  ),
              ]),
            ),
            const SizedBox(height: 10),
            Row(children: [
              IconButton.filledTonal(
                tooltip: tr(_playing ? 'nedit.stop' : 'nedit.play'),
                onPressed: _saving ? null : () => _playing ? unawaited(_stop()) : unawaited(_play(_plan(_t))),
                icon: Icon(_playing ? Icons.stop_rounded : Icons.play_arrow_rounded),
              ),
              const SizedBox(width: 10),
              Text('${playerTime(Duration(milliseconds: _t))} / ${playerTime(Duration(milliseconds: length))}',
                  style: const TextStyle(fontFeatures: [ui.FontFeature.tabularFigures()])),
              const SizedBox(width: 16),
              Expanded(
                child: Text(tr(_taking ? 'nedit.take_tip' : (sel == null ? 'nedit.tip' : 'nedit.sel_tip')),
                    style: const TextStyle(color: LrColors.muted, fontSize: 12.5)),
              ),
              if (sel != null && !_playing) ...[
                OutlinedButton.icon(
                  onPressed: () => setState(() {
                    _edits.add(_Mute(sel.$1, sel.$2));
                    _sel = null;
                  }),
                  icon: const Icon(Icons.volume_off_rounded, size: 18),
                  label: Text(tr('nedit.mute')),
                ),
                const SizedBox(width: 8),
                OutlinedButton.icon(onPressed: _cutSelection, icon: const Icon(Icons.content_cut_rounded, size: 18), label: Text(tr('nedit.cut'))),
                const SizedBox(width: 8),
                FilledButton.icon(onPressed: _redub, icon: const Icon(Icons.mic_rounded, size: 18), label: Text(tr('nedit.redub'))),
                const SizedBox(width: 8),
                TextButton(onPressed: () => setState(() => _sel = null), child: Text(tr('common.cancel'))),
              ],
            ]),
            const SizedBox(height: 8),
            LayoutBuilder(builder: (context, c) {
              final w = c.maxWidth;
              int at(double x) => (x / w * len).round().clamp(0, len);
              int? dragFrom;
              return GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTapDown: (d) {
                  if (_playing) return;
                  final y = d.localPosition.dy;
                  if (y >= _Timeline.inkTop - 4 && y <= _Timeline.inkTop + 16) {
                    NarrationInk? best;
                    var bd = 8.0;
                    for (final i in inks) {
                      if (_deleted.contains(i.ink.id)) continue;
                      final dx = (i.startT / len * w - d.localPosition.dx).abs();
                      if (dx < bd) {
                        bd = dx;
                        best = i;
                      }
                    }
                    if (best != null) {
                      setState(() => _t = best!.startT + 400);
                      unawaited(_deleteInk(best));
                      return;
                    }
                  }
                  setState(() {
                    _t = at(d.localPosition.dx);
                    _sel = null;
                  });
                },
                onHorizontalDragStart: (d) {
                  if (_playing) return;
                  final x = at(d.localPosition.dx);
                  if (d.localPosition.dy >= _Timeline.waveTop) {
                    dragFrom = x;
                  } else {
                    dragFrom = null;
                    setState(() => _t = x);
                  }
                },
                onHorizontalDragUpdate: (d) {
                  if (_playing) return;
                  final x = at(d.localPosition.dx);
                  final from = dragFrom;
                  setState(() {
                    if (from != null) {
                      _sel = (math.min(from, x), math.max(from, x));
                    } else {
                      _t = x;
                    }
                  });
                },
                onHorizontalDragEnd: (_) {
                  if (_sel != null && _sel!.$2 - _sel!.$1 < 100) setState(() => _sel = null);
                },
                child: CustomPaint(
                  size: Size(w, _Timeline.height),
                  painter: _Timeline(
                    length: length,
                    parts: parts,
                    inks: inks,
                    peaks: _peaks,
                    t: _t,
                    sel: _sel,
                    mutes: _mutes,
                    cuts: _cuts,
                    redubs: [for (final r in _redubs) (r.a, r.b)],
                    deleted: _deleted,
                  ),
                ),
              );
            }),
          ]),
        ),
      ),
    );
  }
}

/// The filmed picture at [t] (the part playing then) with the marks drawn
/// on as they were; while [playing], the video plays along.
class _Stage extends StatefulWidget {
  const _Stage({
    required this.dir,
    required this.parts,
    required this.area,
    required this.screen,
    required this.inks,
    required this.fades,
    required this.boards,
    required this.deleted,
    required this.t,
    required this.playing,
  });

  final Directory dir;
  final List<_Part> parts;
  final Rect area, screen;
  final List<NarrationInk> inks;
  final Map<String, bool> fades;
  final List<(int, int, Rect)> boards;
  final Set<String> deleted;
  final int t;
  final bool playing;

  @override
  State<_Stage> createState() => _StageState();
}

class _StageState extends State<_Stage> {
  late final Player _player = Player();
  late final VideoController _video = VideoController(_player);
  String? _file;
  bool _ready = false;
  int _lastSeek = -100000;
  DateTime _seekedAt = DateTime(0);

  @override
  void initState() {
    super.initState();
    unawaited(_player.setVolume(0));
    _sync();
  }

  @override
  void didUpdateWidget(_Stage old) {
    super.didUpdateWidget(old);
    _sync();
  }

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  _Part? get _part {
    _Part? best;
    for (final p in widget.parts) {
      if (p.start <= widget.t) best = p;
    }
    return best ?? (widget.parts.isEmpty ? null : widget.parts.first);
  }

  void _sync() {
    final p = _part;
    if (p == null) return;
    if (p.file != _file) {
      _file = p.file;
      _ready = false;
      unawaited(_player.open(Media('${widget.dir.path}${Platform.pathSeparator}${p.file}'), play: false).then((_) {
        if (mounted) setState(() => _ready = true);
      }));
    }
    if (!_ready) return;
    final int want = p.still ? p.head : p.head + math.min<int>(widget.t - p.start, p.len);
    final now = _player.state.position.inMilliseconds;
    if (widget.playing && !p.still) {
      if (!_player.state.playing) unawaited(_player.play());
      if ((now - want).abs() > 400 && DateTime.now().difference(_seekedAt).inMilliseconds > 600) _seek(want);
    } else {
      if (_player.state.playing) unawaited(_player.pause());
      if ((want - _lastSeek).abs() > 40) _seek(want);
    }
  }

  void _seek(int ms) {
    _lastSeek = ms;
    _seekedAt = DateTime.now();
    unawaited(_player.seek(Duration(milliseconds: math.max(0, ms))));
  }

  @override
  Widget build(BuildContext context) {
    final a = widget.area;
    return Center(
      child: AspectRatio(
        aspectRatio: a.width <= 0 || a.height <= 0 ? 16 / 9 : a.width / a.height,
        child: Stack(fit: StackFit.expand, children: [
          Video(controller: _video, controls: NoVideoControls, fit: BoxFit.fill),
          IgnorePointer(
            child: CustomPaint(
              painter: _Marks(
                area: a,
                screen: widget.screen,
                inks: widget.inks,
                fades: widget.fades,
                boards: widget.boards,
                deleted: widget.deleted,
                t: widget.t,
              ),
            ),
          ),
        ]),
      ),
    );
  }
}

/// The marks (and the board) at [t], over the filmed area.
class _Marks extends CustomPainter {
  _Marks({required this.area, required this.screen, required this.inks, required this.fades, required this.boards, required this.deleted, required this.t})
      : super(repaint: StampImages.loaded);

  final Rect area, screen;
  final List<NarrationInk> inks;
  final Map<String, bool> fades;
  final List<(int, int, Rect)> boards;
  final Set<String> deleted;
  final int t;

  @override
  void paint(Canvas c, Size out) {
    if (area.width <= 0) return;
    final k = out.width / area.width;
    c.save();
    c.clipRect(Offset.zero & out);
    c.scale(k);
    c.translate(-area.left, -area.top);
    (int, int, Rect)? board;
    for (final b in boards) {
      if (b.$1 > t) break;
      board = b;
    }
    if (board != null && board.$2 != 0) {
      c.drawRect(board.$3, Paint()..color = board.$2 == 1 ? const Color(0xFFFAFAF7) : const Color(0xFF1E2A24));
    }
    c.translate(screen.left, screen.top);
    for (final i in inks) {
      if (deleted.contains(i.ink.id) || t < i.startT) continue;
      var until = i.removedT;
      if (fades[i.ink.id] == true) {
        final end = i.startT + (i.times.isEmpty ? 0 : i.times.last) + 3000;
        until = until == null ? end : math.min(until, end);
      }
      if (until != null && t >= until) continue;
      final m = i.ink.copy()
        ..times = i.times
        ..live = true;
      InkGeometry.paint(c, screen.size, m, upto: t - i.startT);
    }
    c.restore();
  }

  @override
  bool shouldRepaint(_Marks old) => true;
}

/// The time line: the filmed parts (held stretches lighter), where marks
/// were drawn, the sound; silent / cut / spoken-again stretches and the
/// selection.
class _Timeline extends CustomPainter {
  _Timeline({
    required this.length,
    required this.parts,
    required this.inks,
    required this.peaks,
    required this.t,
    required this.sel,
    required this.mutes,
    required this.cuts,
    required this.redubs,
    required this.deleted,
  });

  static const double height = 150, inkTop = 34, waveTop = 58;

  final int length;
  final List<_Part> parts;
  final List<NarrationInk> inks;
  final List<double> peaks;
  final int t;
  final (int, int)? sel;
  final List<(int, int)> mutes, cuts, redubs;
  final Set<String> deleted;

  @override
  void paint(Canvas c, Size s) {
    final len = math.max(1, length).toDouble();
    double x(int ms) => ms / len * s.width;
    const col = Color(0xFF3B82F6);
    for (final p in parts) {
      final r = Rect.fromLTRB(x(p.start), 4, math.max(x(p.start) + 1, x(p.end)), 26);
      c.drawRect(r, Paint()..color = p.still ? col.withValues(alpha: 0.45) : col);
    }
    for (final i in inks) {
      if (deleted.contains(i.ink.id)) continue;
      c.drawCircle(Offset(x(i.startT), inkTop + 6), 4.5, Paint()..color = Color(i.ink.color | 0xFF000000));
    }
    final mid = waveTop + (height - waveTop - 6) / 2, half = (height - waveTop - 10) / 2;
    c.drawRect(Rect.fromLTRB(0, waveTop, s.width, height - 4), Paint()..color = const Color(0x14FFFFFF));
    if (peaks.isNotEmpty) {
      final wave = Paint()
        ..color = LrColors.safelight
        ..strokeWidth = 1;
      final step = math.max(1, (peaks.length / s.width).ceil());
      for (var k = 0; k < peaks.length; k += step) {
        var m = 0.0;
        for (var q = k; q < math.min(peaks.length, k + step); q++) {
          m = math.max(m, peaks[q]);
        }
        final px = k * 20 / len * s.width;
        c.drawLine(Offset(px, mid - m * half - 0.5), Offset(px, mid + m * half + 0.5), wave);
      }
    }
    for (final (a, b) in mutes) {
      c.drawRect(Rect.fromLTRB(x(a), waveTop, x(b), height - 4), Paint()..color = const Color(0xAA000000));
    }
    for (final (a, b) in redubs) {
      c.drawRect(Rect.fromLTRB(x(a), waveTop, x(b), height - 4), Paint()..color = const Color(0x8810B981));
    }
    for (final (a, b) in cuts) {
      c.drawRect(Rect.fromLTRB(x(a), 0, x(b), height), Paint()..color = const Color(0x88E53935));
    }
    final se = sel;
    if (se != null) c.drawRect(Rect.fromLTRB(x(se.$1), waveTop, x(se.$2), height - 4), Paint()..color = const Color(0x553B82F6));
    c.drawLine(
        Offset(x(t), 0),
        Offset(x(t), height),
        Paint()
          ..color = Colors.white
          ..strokeWidth = 2);
  }

  @override
  bool shouldRepaint(_Timeline old) => true;
}
