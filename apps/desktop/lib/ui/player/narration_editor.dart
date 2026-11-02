// apps/desktop/lib/ui/player/narration_editor.dart
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
import '../../services/mic.dart';
import '../../services/video_encoders.dart';
import '../theme.dart';
import 'ink_paint.dart';
import 'narration.dart';
import 'narration_dialogs.dart';
import 'player_page.dart' show playerTime;

/// Edits a recorded explanation: plays it back, marks deleted (their
/// annotation too), stretches made silent, cut out or spoken again.
/// True when something was changed and kept.
Future<bool> editNarration(BuildContext context, AppServices s, NarrationSession n) async {
  final r = await Navigator.of(context).push<bool>(MaterialPageRoute(builder: (_) => _Editor(services: s, original: n)));
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
/// held at [to]); the voice as recorded, or a new one, or a new one being
/// recorded now.
class _Span {
  const _Span(this.from, this.to, this.length, {this.redub, this.taking = false});
  final int from, to, length;
  final _Redub? redub;
  final bool taking;
}

class _Editor extends StatefulWidget {
  const _Editor({required this.services, required this.original});

  final AppServices services;
  final NarrationSession original;

  @override
  State<_Editor> createState() => _EditorState();
}

class _EditorState extends State<_Editor> {
  late final NarrationSession n = NarrationSession.fromJson(jsonDecode(jsonEncode(widget.original.toJson())) as Map<String, dynamic>);
  late final Directory dir = NarrationSession.folderOf(widget.services.settings.dataDir, n.id);
  final List<_Edit> _edits = [];
  List<double> _peaks = const [];
  int _t = 0;
  (int, int)? _sel;
  bool _saving = false;
  final FocusNode _focus = FocusNode();

  // Playing back.
  final Player _voice = Player();
  final Player _take = Player();
  bool _voiceOpen = false;
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

  @override
  void initState() {
    super.initState();
    unawaited(_loadVoice());
  }

  @override
  void dispose() {
    _tick?.cancel();
    unawaited(_mic?.stop());
    _voice.dispose();
    _take.dispose();
    _focus.dispose();
    super.dispose();
  }

  Set<String> get _deleted => {for (final e in _edits) if (e is _DeleteInk) ...e.ids};
  List<(int, int)> get _mutes => [for (final e in _edits) if (e is _Mute) (e.a, e.b)];
  List<(int, int)> get _cuts => [for (final e in _edits) if (e is _Cut) (e.a, e.b)];
  List<_Redub> get _redubs => [for (final e in _edits) if (e is _Redub) e];

  File get _voiceFile => File('${dir.path}${Platform.pathSeparator}voice.wav');

  /// The voice's loudness, one value per 20 ms (0–1).
  Future<void> _loadVoice() async {
    final f = _voiceFile;
    try {
      if (!await f.exists()) return;
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
        for (var j = i; j + 1 < end; j += 2 * ch) {
          final v = d.getInt16(j, Endian.little).abs();
          if (v > m) m = v;
        }
        peaks.add(math.min(1.0, m / 20000));
      }
      if (mounted) setState(() => _peaks = peaks);
    } catch (e) {
      DiagLog.log('player', 'explanation voice not read: $e');
    }
  }

  /// Overlaps a stretch already cut out or spoken again.
  bool _clashes(int a, int b) => [
        for (final e in _edits)
          if (e is _Cut) (e.a, e.b) else if (e is _Redub) (e.a, e.b),
      ].any((r) => a < r.$2 && b > r.$1);

  // ------------------------------------------------------------ playback

  /// The recording as it will be, from [from] (its own times) to the end.
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
    if (cursor < n.lengthMs) out.add(_Span(cursor, n.lengthMs, n.lengthMs - cursor));
    // From [from]: the span it is in, started part way.
    final res = <_Span>[];
    for (final s in out) {
      if (s.to <= from) continue;
      res.add(s.from < from && s.redub == null ? _Span(from, s.to, s.to - from) : s);
    }
    return res;
  }

  Future<void> _play(List<_Span> spans) async {
    if (spans.isEmpty) return;
    if (!_voiceOpen && _voiceFile.existsSync()) {
      await _voice.open(Media(_voiceFile.path), play: false);
      _voiceOpen = true;
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
    if (sp.taking) {
      await _voice.pause();
      await _take.pause();
    } else if (r != null) {
      await _voice.pause();
      await _take.open(Media(r.file.path, start: Duration(milliseconds: r.head)), play: true);
    } else {
      await _take.pause();
      if (_voiceOpen) {
        await _voice.seek(Duration(milliseconds: sp.from));
        await _voice.play();
      }
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
    final t = sp.from + math.min(e, sp.to - sp.from);
    // Speaking again: from the start of the stretch.
    if (sp.taking && _takeStart == null) {
      _takeStart = _clock.elapsedMilliseconds;
      final first = _mic?.firstSound ?? DateTime.now();
      _takeHead = math.max(0, DateTime.now().difference(first).inMilliseconds);
    }
    if (!sp.taking && sp.redub == null && _voiceOpen) {
      final silent = _mutes.any((m) => t >= m.$1 && t < m.$2);
      unawaited(_voice.setVolume(silent ? 0 : 100));
    }
    setState(() => _t = t);
  }

  Future<void> _stop() async {
    _tick?.cancel();
    _clock.stop();
    await _voice.pause();
    await _take.pause();
    final mic = _mic;
    if (mic != null) {
      final start = _takeStart;
      final len = start == null ? 0 : _clock.elapsedMilliseconds - start;
      _mic = null;
      await mic.stop();
      final f = _takeFile;
      if (f != null && len > 300) {
        _edits.add(_Redub(_takeA, _takeB, f, _takeHead, len));
        DiagLog.log('player', 'explanation: spoken again ${_takeB - _takeA} ms → $len ms');
      }
    }
    if (mounted) setState(() => _spans = null);
  }

  /// Speaks the selected stretch again: 2 s before it with the voice as
  /// it was, then the picture as it was without it (held at its end until
  /// "Stop").
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
        content: SizedBox(width: 420, child: Text(tr(n.noteIds.isNotEmpty ? 'nedit.delete_mark_tip' : 'nedit.delete_mark_tip_plain'))),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('common.cancel'))),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), style: FilledButton.styleFrom(backgroundColor: LrColors.danger), child: Text(tr('ink.delete'))),
        ],
      ),
    );
    if (ok == true) setState(() => _edits.add(_DeleteInk({i.ink.id})));
  }

  Future<void> _cutSelection() async {
    final sel = _sel;
    if (sel == null) return;
    if (_clashes(sel.$1, sel.$2)) return _snack(tr('nedit.overlap'));
    final drawn = [for (final i in n.inks) if (i.startT >= sel.$1 && i.startT < sel.$2 && !_deleted.contains(i.ink.id)) i].length;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('nedit.cut_title', {'len': playerTime(Duration(milliseconds: sel.$2 - sel.$1))})),
        content: SizedBox(width: 440, child: Text(drawn == 0 ? tr('nedit.cut_tip') : tr('nedit.cut_tip_marks', {'n': drawn}))),
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

  /// Applies every change: the marks (and their annotations), the voice,
  /// the camera, the recording itself.
  Future<void> _save() async {
    if (_playing) await _stop();
    if (_edits.isEmpty) {
      if (mounted) Navigator.pop(context, false);
      return;
    }
    setState(() => _saving = true);
    final s = widget.services;
    final exe = s.ffmpeg.ffmpeg;
    final sep = Platform.pathSeparator;
    try {
      final gone = {..._deleted};
      n.inks.removeWhere((i) => gone.contains(i.ink.id));
      final voice = _voiceFile;
      final cam = File('${dir.path}${sep}camera.mp4');
      final mutes = _mutes, redubs = _redubs;
      // Cut out / spoken again, in order.
      final structural = [
        for (final e in _edits)
          if (e is _Cut) (e.a, e.b, null as _Redub?) else if (e is _Redub) (e.a, e.b, e),
      ]..sort((x, y) => x.$1.compareTo(y.$1));
      String sec(int ms) => (ms / 1000).toStringAsFixed(3);
      if (exe != null && voice.existsSync() && (mutes.isNotEmpty || structural.isNotEmpty)) {
        // The voice: the old one (silent where asked) in pieces, the new
        // ones in between.
        final takes = [for (final r in redubs) r.file];
        final pieces = <String>[];
        var cursor = 0;
        void old(int a, int b) {
          if (b > a) pieces.add('o:$a:$b');
        }

        for (final (a, b, r) in structural) {
          old(cursor, a);
          if (r != null) pieces.add('t:${takes.indexOf(r.file)}:${r.head}:${math.max(b - a, r.len)}');
          cursor = b;
        }
        old(cursor, n.lengthMs + 1000);
        final olds = pieces.where((p) => p.startsWith('o')).length;
        final g = StringBuffer('[0:a]aresample=48000,aformat=channel_layouts=mono');
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
            g.write('[o${ok++}]atrim=start=${sec(int.parse(p[1]))}:end=${sec(int.parse(p[2]))},asetpts=PTS-STARTPTS[s$i];');
          } else {
            g.write('[${int.parse(p[1]) + 1}:a]aresample=48000,aformat=channel_layouts=mono,atrim=start=${sec(int.parse(p[2]))},'
                'asetpts=PTS-STARTPTS,apad,atrim=duration=${sec(int.parse(p[3]))}[s$i];');
          }
        }
        for (var i = 0; i < pieces.length; i++) {
          g.write('[s$i]');
        }
        g.write('concat=n=${pieces.length}:v=0:a=1[out]');
        final out = File('${dir.path}${sep}voice_edit.wav');
        final r = await Process.run(exe, [
          '-hide_banner', '-loglevel', 'error', '-y', '-i', voice.path,
          for (final t in takes) ...['-i', t.path],
          '-filter_complex', g.toString(), '-map', '[out]', '-c:a', 'pcm_s16le', out.path,
        ]);
        if (r.exitCode != 0 || !out.existsSync()) throw Exception('voice: ${'${r.stderr}'.trim()}');
        await out.rename(voice.path);
      }
      if (exe != null && structural.any((x) => x.$3 == null || x.$3!.extra > 0) && cam.existsSync() && n.camera.isNotEmpty) {
        // The camera: the same pieces; held still where the voice is longer.
        final enc = await s.converter.encoders.best();
        if (enc != null) {
          final g = StringBuffer();
          final parts = <String>[];
          var cursor = 0;
          var k = 0;
          void piece(int a, int b, int hold) {
            if (b <= a) return;
            g.write('[0:v]trim=start=${sec(a)}:end=${sec(b)},setpts=PTS-STARTPTS${hold > 0 ? ',tpad=stop_mode=clone:stop_duration=${sec(hold)}' : ''}[c$k];');
            parts.add('[c$k]');
            k++;
          }

          for (final (a, b, r) in structural) {
            piece(cursor, a, 0);
            if (r != null) piece(a, b, r.extra);
            cursor = b;
          }
          piece(cursor, n.lengthMs + 1000, 0);
          g.write('${parts.join()}concat=n=${parts.length}:v=1:a=0,fps=30,format=nv12[v]');
          final out = File('${dir.path}${sep}camera_edit.mp4');
          final r = await Process.run(exe, [
            '-hide_banner', '-loglevel', 'error', '-y', '-i', cam.path, '-filter_complex', g.toString(), '-map', '[v]',
            ...H264Encoders.args(enc, high: true, width: 480, height: 480, fps: 30), out.path,
          ]);
          if (r.exitCode == 0 && out.existsSync()) await out.rename(cam.path);
        }
      }
      // The recording itself: last first, so earlier times stay right.
      for (final (a, b, r) in structural.reversed) {
        if (r == null) {
          gone.addAll(cutNarration(n, a, b));
        } else {
          freezeNarration(n, b, r.extra);
        }
      }
      await _forgetInNotes(gone);
      await File('${dir.path}${sep}session.json').writeAsString(jsonEncode(n.toJson()));
      for (final r in redubs) {
        try {
          await r.file.delete();
        } catch (_) {}
      }
      DiagLog.log('player', 'explanation edited: ${gone.length} marks out, ${mutes.length} silent, ${structural.length} cut / spoken again');
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      DiagLog.log('player', 'explanation not edited: $e');
      if (!mounted) return;
      setState(() => _saving = false);
      _snack(tr('nedit.failed'));
    }
  }

  /// The annotations made from this recording lose the same marks (kept
  /// in step; empty ones go).
  Future<void> _forgetInNotes(Set<String> ids) async {
    if (ids.isEmpty || n.noteIds.isEmpty) return;
    final s = widget.services;
    for (final f in n.files) {
      if (!File(f.path).existsSync()) continue;
      try {
        final item = f.rel == null ? null : s.library.findByRel(f.rel!);
        final set = await s.notes.open(item: item, path: f.path, name: f.name, size: File(f.path).lengthSync(), video: f.video);
        var changed = false;
        for (final note in [...set.notes]) {
          if (!n.noteIds.contains(note.id)) continue;
          final before = note.inks.length;
          note.inks.removeWhere((m) => ids.contains(m.id));
          if (note.inks.length != before) changed = true;
          if (note.inks.isEmpty) set.notes.remove(note);
        }
        if (changed) await s.notes.save(set);
      } catch (e) {
        DiagLog.log('player', 'annotation not updated: $e');
      }
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
    final len = math.max(1, n.lengthMs);
    final sel = _sel;
    final sp = _spans == null ? null : _spans![_si];
    final taking = sp?.taking ?? false;
    return Focus(
      focusNode: _focus,
      autofocus: true,
      onKeyEvent: _key,
      child: Scaffold(
        backgroundColor: LrColors.ink,
        appBar: AppBar(
          automaticallyImplyLeading: false,
          title: Text(tr('nedit.title')),
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
                    child: _Stage(services: widget.services, n: n, t: _t, playing: _playing, deleted: _deleted),
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
              Text('${playerTime(Duration(milliseconds: _t))} / ${playerTime(Duration(milliseconds: n.lengthMs))}',
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
                    for (final i in n.inks) {
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
                  painter: _Timeline(n: n, peaks: _peaks, t: _t, sel: _sel, mutes: _mutes, cuts: _cuts, redubs: [for (final r in _redubs) (r.a, r.b)], deleted: _deleted),
                ),
              );
            }),
          ]),
        ),
      ),
    );
  }
}

/// The picture at [t] into the recording: the file shown then, where it
/// was, its framing, the marks drawn by then. While [playing], videos play
/// along (kept in step).
class _Stage extends StatefulWidget {
  const _Stage({required this.services, required this.n, required this.t, required this.playing, required this.deleted});

  final AppServices services;
  final NarrationSession n;
  final int t;
  final bool playing;
  final Set<String> deleted;

  @override
  State<_Stage> createState() => _StageState();
}

class _StageState extends State<_Stage> {
  late final Player _player = Player();
  late final VideoController _video = VideoController(_player);
  int _file = -1;
  bool _ready = false;
  String? _photo;
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

  void _sync() {
    final n = widget.n;
    final x = sampleAt(n.samples, widget.t);
    if (x == null || x.file >= n.files.length) return;
    final f = n.files[x.file];
    if (x.file != _file) {
      _file = x.file;
      _ready = false;
      _photo = null;
      if (f.video) {
        unawaited(_player.open(Media(f.path), play: false).then((_) {
          if (mounted) setState(() => _ready = true);
        }));
      } else {
        unawaited(_player.stop());
        unawaited(_photoOf(f));
      }
    }
    if (!f.video || !_ready) return;
    final want = x.playing ? x.pos + ((widget.t - x.t) * x.rate).round() : x.pos;
    final now = _player.state.position.inMilliseconds;
    if (widget.playing && x.playing) {
      if (!_player.state.playing) {
        unawaited(_player.setRate(x.rate));
        unawaited(_player.play());
      }
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

  Future<void> _photoOf(NarrationFile f) async {
    var path = f.path;
    if (!nativelyDecodableImages.contains(extensionOf(f.name))) {
      try {
        final st = File(f.path).statSync();
        final pv = await widget.services.ffmpeg.previewFile(f.path, size: st.size, modifiedMs: st.modified.millisecondsSinceEpoch);
        if (pv != null) path = pv.path;
      } catch (_) {}
    }
    if (mounted) setState(() => _photo = path);
  }

  @override
  Widget build(BuildContext context) {
    final n = widget.n;
    final x = sampleAt(n.samples, widget.t);
    if (x == null || x.file >= n.files.length) return const SizedBox.shrink();
    final f = n.files[x.file];
    return LayoutBuilder(builder: (context, c) {
      // The picture fitted, then its framing (the part zoomed into) filling it.
      final z = x.zoom;
      final pw = f.width * z.width, ph = f.height * z.height;
      final fit = math.min(c.maxWidth / pw, c.maxHeight / ph);
      final pic = Size(f.width * fit, f.height * fit);
      final view = Size(pw * fit, ph * fit);
      final picture = f.video
          ? Video(controller: _video, controls: NoVideoControls, fill: Colors.black)
          : (_photo == null ? const SizedBox.shrink() : Image.file(File(_photo!), fit: BoxFit.fill, gaplessPlayback: true));
      return Center(
        child: SizedBox.fromSize(
          size: view,
          child: ClipRect(
            child: OverflowBox(
              alignment: Alignment.topLeft,
              minWidth: pic.width,
              maxWidth: pic.width,
              minHeight: pic.height,
              maxHeight: pic.height,
              child: Transform.translate(
                offset: Offset(-z.left * pic.width, -z.top * pic.height),
                child: SizedBox.fromSize(
                  size: pic,
                  child: Stack(fit: StackFit.expand, children: [
                    picture,
                    CustomPaint(painter: _Marks(n, x.file, widget.t, widget.deleted)),
                  ]),
                ),
              ),
            ),
          ),
        ),
      );
    });
  }
}

/// The marks of [file] drawn by [t].
class _Marks extends CustomPainter {
  _Marks(this.n, this.file, this.t, this.deleted);

  final NarrationSession n;
  final int file, t;
  final Set<String> deleted;

  @override
  void paint(Canvas c, Size pic) {
    for (final i in n.inks) {
      if (i.file != file || t < i.startT || (i.removedT != null && t >= i.removedT!) || deleted.contains(i.ink.id)) continue;
      final m = i.ink.copy()
        ..times = i.times
        ..live = true;
      InkGeometry.paint(c, pic, m, upto: t - i.startT);
    }
  }

  @override
  bool shouldRepaint(_Marks old) => true;
}

/// The recording's time line: what was shown (each file its colour,
/// paused stretches lighter, zoomed ones marked), where marks were drawn,
/// the voice; silent / cut / spoken-again stretches and the selection.
class _Timeline extends CustomPainter {
  _Timeline({
    required this.n,
    required this.peaks,
    required this.t,
    required this.sel,
    required this.mutes,
    required this.cuts,
    required this.redubs,
    required this.deleted,
  });

  static const double height = 150, inkTop = 34, waveTop = 58;

  final NarrationSession n;
  final List<double> peaks;
  final int t;
  final (int, int)? sel;
  final List<(int, int)> mutes, cuts, redubs;
  final Set<String> deleted;

  static const List<Color> _files = [Color(0xFF3B82F6), Color(0xFF10B981), Color(0xFFF59E0B), Color(0xFFA855F7), Color(0xFFEF4444), Color(0xFF14B8A6)];

  @override
  void paint(Canvas c, Size s) {
    final len = math.max(1, n.lengthMs).toDouble();
    double x(int ms) => ms / len * s.width;
    for (final p in narrationPieces(n)) {
      final r = Rect.fromLTRB(x(p.startT), 4, math.max(x(p.startT) + 1, x(p.endT)), 26);
      final col = _files[p.file % _files.length];
      c.drawRect(r, Paint()..color = p.still ? col.withValues(alpha: 0.45) : col);
      if (p.zoom != const Rect.fromLTWH(0, 0, 1, 1) && r.width > 10) {
        c.drawCircle(Offset(r.left + 6, r.center.dy), 3.5, Paint()..color = Colors.white);
      }
    }
    for (final i in n.inks) {
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
        for (var j = k; j < math.min(peaks.length, k + step); j++) {
          m = math.max(m, peaks[j]);
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
