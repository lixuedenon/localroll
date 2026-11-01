// apps/desktop/lib/ui/player/narration_editor.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:localroll_core/localroll_core.dart';

import '../../app_services.dart';
import '../../l10n/l10n.dart';
import '../../services/video_encoders.dart';
import '../theme.dart';
import 'ink_paint.dart';
import 'narration.dart';
import 'player_page.dart' show playerTime;

/// Edits a recorded explanation: where each mark was drawn, the voice;
/// marks deleted (their annotation too), stretches made silent or cut
/// out. True when something was changed and kept.
Future<bool> editNarration(BuildContext context, AppServices s, NarrationSession n) async {
  final r = await Navigator.of(context).push<bool>(MaterialPageRoute(builder: (_) => _Editor(services: s, original: n)));
  return r == true;
}

/// One change (undone in reverse).
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

  /// The picture at [_t] (and which file / place it is of).
  ui.Image? _frame;
  String _frameKey = '';
  Timer? _frameSoon;

  @override
  void initState() {
    super.initState();
    unawaited(_loadVoice());
    _showAt(0);
  }

  @override
  void dispose() {
    _frameSoon?.cancel();
    _frame?.dispose();
    super.dispose();
  }

  Set<String> get _deleted => {for (final e in _edits) if (e is _DeleteInk) ...e.ids};
  List<(int, int)> get _mutes => [for (final e in _edits) if (e is _Mute) (e.a, e.b)];
  List<(int, int)> get _cuts => [for (final e in _edits) if (e is _Cut) (e.a, e.b)];

  /// The voice's loudness, one value per 20 ms (0–1).
  Future<void> _loadVoice() async {
    final f = File('${dir.path}${Platform.pathSeparator}voice.wav');
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

  /// The picture shown at [t]: the file and place of that moment.
  void _showAt(int t) {
    _frameSoon?.cancel();
    _frameSoon = Timer(const Duration(milliseconds: 180), () async {
      final x = sampleAt(n.samples, t);
      if (x == null || x.file >= n.files.length) return;
      final f = n.files[x.file];
      final key = '${x.file}:${f.video ? x.pos ~/ 80 : 0}';
      if (key == _frameKey) return;
      final img = await _picture(f, x.pos);
      if (!mounted) {
        img?.dispose();
        return;
      }
      setState(() {
        _frame?.dispose();
        _frame = img;
        _frameKey = key;
      });
    });
  }

  Future<ui.Image?> _picture(NarrationFile f, int pos) async {
    final s = widget.services;
    try {
      Uint8List? bytes;
      if (!f.video && nativelyDecodableImages.contains(extensionOf(f.name))) {
        bytes = await File(f.path).readAsBytes();
      } else if (!f.video) {
        final st = File(f.path).statSync();
        final pv = await s.ffmpeg.previewFile(f.path, size: st.size, modifiedMs: st.modified.millisecondsSinceEpoch);
        if (pv != null) bytes = await pv.readAsBytes();
      } else {
        final exe = s.ffmpeg.ffmpeg;
        if (exe == null) return null;
        final r = await Process.run(
            exe,
            ['-hide_banner', '-loglevel', 'error', '-ss', (pos / 1000).toStringAsFixed(3), '-i', f.path, '-frames:v', '1', '-vf', 'scale=1280:-2', '-f', 'image2pipe', '-c:v', 'mjpeg', '-'],
            stdoutEncoding: null);
        if (r.exitCode == 0) bytes = Uint8List.fromList(r.stdout as List<int>);
      }
      if (bytes == null || bytes.isEmpty) return null;
      final codec = await ui.instantiateImageCodec(bytes, targetWidth: 1280);
      return (await codec.getNextFrame()).image;
    } catch (_) {
      return null;
    }
  }

  Future<void> _deleteInk(NarrationInk i) async {
    final inNotes = n.noteIds.isNotEmpty;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('nedit.delete_mark')),
        content: SizedBox(width: 420, child: Text(tr(inNotes ? 'nedit.delete_mark_tip' : 'nedit.delete_mark_tip_plain'))),
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
    if (_edits.isEmpty) {
      Navigator.pop(context, false);
      return;
    }
    setState(() => _saving = true);
    final s = widget.services;
    final exe = s.ffmpeg.ffmpeg;
    final sep = Platform.pathSeparator;
    try {
      final gone = {..._deleted};
      n.inks.removeWhere((i) => gone.contains(i.ink.id));
      final voice = File('${dir.path}${sep}voice.wav');
      final cam = File('${dir.path}${sep}camera.mp4');
      final mutes = _mutes;
      // Last first, so the earlier ones' times stay right.
      final cuts = _cuts..sort((x, y) => y.$1.compareTo(x.$1));
      if (exe != null && voice.existsSync() && (mutes.isNotEmpty || cuts.isNotEmpty)) {
        final out = File('${dir.path}${sep}voice_edit.wav');
        final af = [
          if (mutes.isNotEmpty) "volume=enable='${betweens(mutes)}':volume=0",
          if (cuts.isNotEmpty) "aselect='not(${betweens(cuts)})',asetpts=N/SR/TB",
        ].join(',');
        final r = await Process.run(exe, ['-hide_banner', '-loglevel', 'error', '-y', '-i', voice.path, '-af', af, '-c:a', 'pcm_s16le', out.path]);
        if (r.exitCode != 0 || !out.existsSync()) throw Exception('voice: ${'${r.stderr}'.trim()}');
        await out.rename(voice.path);
      }
      if (exe != null && cuts.isNotEmpty && cam.existsSync()) {
        final enc = await s.converter.encoders.best();
        if (enc != null) {
          final out = File('${dir.path}${sep}camera_edit.mp4');
          final r = await Process.run(exe, [
            '-hide_banner', '-loglevel', 'error', '-y', '-i', cam.path,
            '-vf', "select='not(${betweens(cuts)})',setpts=N/30/TB,format=nv12",
            ...H264Encoders.args(enc, high: true, width: 480, height: 480, fps: 30), out.path,
          ]);
          if (r.exitCode == 0 && out.existsSync()) await out.rename(cam.path);
        }
      }
      for (final c in cuts) {
        gone.addAll(cutNarration(n, c.$1, c.$2));
      }
      await _forgetInNotes(gone);
      await File('${dir.path}${sep}session.json').writeAsString(jsonEncode(n.toJson()));
      DiagLog.log('player', 'explanation edited: ${gone.length} marks out, ${mutes.length} silent, ${cuts.length} cut');
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      DiagLog.log('player', 'explanation not edited: $e');
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('nedit.failed'))));
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

  @override
  Widget build(BuildContext context) {
    final len = math.max(1, n.lengthMs);
    final sel = _sel;
    return Scaffold(
      backgroundColor: LrColors.ink,
      appBar: AppBar(
        title: Text(tr('nedit.title')),
        actions: [
          IconButton(tooltip: tr('ink.undo'), onPressed: _edits.isEmpty || _saving ? null : () => setState(_edits.removeLast), icon: const Icon(Icons.undo_rounded)),
          TextButton(onPressed: _saving ? null : () => Navigator.pop(context, false), child: Text(tr('common.cancel'))),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: FilledButton.icon(
              onPressed: _saving ? null : _save,
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
            child: Container(
              decoration: BoxDecoration(color: Colors.black, borderRadius: BorderRadius.circular(8)),
              clipBehavior: Clip.antiAlias,
              child: CustomPaint(painter: _Preview(n, _frame, _t, _deleted), size: Size.infinite),
            ),
          ),
          const SizedBox(height: 10),
          Row(children: [
            Text('${playerTime(Duration(milliseconds: _t))} / ${playerTime(Duration(milliseconds: n.lengthMs))}',
                style: const TextStyle(fontFeatures: [ui.FontFeature.tabularFigures()])),
            const SizedBox(width: 16),
            Expanded(child: Text(tr(sel == null ? 'nedit.tip' : 'nedit.sel_tip'), style: const TextStyle(color: LrColors.muted, fontSize: 12.5))),
            if (sel != null) ...[
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
              TextButton(onPressed: () => setState(() => _sel = null), child: Text(tr('common.cancel'))),
            ],
          ]),
          const SizedBox(height: 8),
          LayoutBuilder(builder: (context, c) {
            final w = c.maxWidth;
            int at(double x) => (x / w * len).round().clamp(0, len);
            int? dragFrom;
            return StatefulBuilder(builder: (context, set) {
              return GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTapDown: (d) {
                  final y = d.localPosition.dy;
                  if (y >= _Timeline.inkTop - 4 && y <= _Timeline.inkTop + 16) {
                    // The mark nearest the click (within a few pixels).
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
                      _showAt(_t);
                      unawaited(_deleteInk(best));
                      return;
                    }
                  }
                  setState(() {
                    _t = at(d.localPosition.dx);
                    _sel = null;
                  });
                  _showAt(_t);
                },
                onHorizontalDragStart: (d) {
                  final x = at(d.localPosition.dx);
                  if (d.localPosition.dy >= _Timeline.waveTop) {
                    dragFrom = x;
                  } else {
                    dragFrom = null;
                    setState(() => _t = x);
                  }
                },
                onHorizontalDragUpdate: (d) {
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
                  _showAt(_t);
                },
                child: CustomPaint(
                  size: Size(w, _Timeline.height),
                  painter: _Timeline(n: n, peaks: _peaks, t: _t, sel: _sel, mutes: _mutes, cuts: _cuts, deleted: _deleted),
                ),
              );
            });
          }),
        ]),
      ),
    );
  }
}

/// The picture at that moment, with the marks drawn by then.
class _Preview extends CustomPainter {
  _Preview(this.n, this.frame, this.t, this.deleted);

  final NarrationSession n;
  final ui.Image? frame;
  final int t;
  final Set<String> deleted;

  @override
  void paint(Canvas c, Size out) {
    final x = sampleAt(n.samples, t);
    final img = frame;
    if (x == null || img == null || x.file >= n.files.length) return;
    final z = x.zoom;
    final iw = img.width.toDouble(), ih = img.height.toDouble();
    final src = Rect.fromLTWH(z.left * iw, z.top * ih, z.width * iw, z.height * ih);
    final fit = math.min(out.width / src.width, out.height / src.height);
    final dst = Rect.fromCenter(center: out.center(Offset.zero), width: src.width * fit, height: src.height * fit);
    c.drawImageRect(img, src, dst, Paint()..filterQuality = FilterQuality.medium);
    // The marks: on the whole picture's size, moved like the picture.
    final pic = Size(iw * fit, ih * fit);
    c.save();
    c.clipRect(dst);
    c.translate(dst.left - z.left * pic.width, dst.top - z.top * pic.height);
    for (final i in n.inks) {
      if (i.file != x.file || t < i.startT || (i.removedT != null && t >= i.removedT!) || deleted.contains(i.ink.id)) continue;
      final m = i.ink.copy()
        ..times = i.times
        ..live = true;
      InkGeometry.paint(c, pic, m, upto: t - i.startT);
    }
    c.restore();
  }

  @override
  bool shouldRepaint(_Preview old) => true;
}

/// The recording's time line: what was shown (each file its colour,
/// paused stretches lighter, zoomed ones marked), where marks were drawn,
/// the voice; silent / cut stretches and the selection.
class _Timeline extends CustomPainter {
  _Timeline({required this.n, required this.peaks, required this.t, required this.sel, required this.mutes, required this.cuts, required this.deleted});

  static const double height = 150, inkTop = 34, waveTop = 58;

  final NarrationSession n;
  final List<double> peaks;
  final int t;
  final (int, int)? sel;
  final List<(int, int)> mutes, cuts;
  final Set<String> deleted;

  static const List<Color> _files = [Color(0xFF3B82F6), Color(0xFF10B981), Color(0xFFF59E0B), Color(0xFFA855F7), Color(0xFFEF4444), Color(0xFF14B8A6)];

  @override
  void paint(Canvas c, Size s) {
    final len = math.max(1, n.lengthMs).toDouble();
    double x(int ms) => ms / len * s.width;
    // What was shown.
    for (final p in narrationPieces(n)) {
      final r = Rect.fromLTRB(x(p.startT), 4, math.max(x(p.startT) + 1, x(p.endT)), 26);
      final col = _files[p.file % _files.length];
      c.drawRect(r, Paint()..color = p.still ? col.withValues(alpha: 0.45) : col);
      if (p.zoom != const Rect.fromLTWH(0, 0, 1, 1) && r.width > 10) {
        c.drawCircle(Offset(r.left + 6, r.center.dy), 3.5, Paint()..color = Colors.white);
      }
    }
    // Where marks were drawn.
    for (final i in n.inks) {
      if (deleted.contains(i.ink.id)) continue;
      c.drawCircle(Offset(x(i.startT), inkTop + 6), 4.5, Paint()..color = Color(i.ink.color | 0xFF000000));
    }
    // The voice.
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
    for (final (a, b) in cuts) {
      c.drawRect(Rect.fromLTRB(x(a), 0, x(b), height), Paint()..color = const Color(0x88E53935));
    }
    final se = sel;
    if (se != null) c.drawRect(Rect.fromLTRB(x(se.$1), waveTop, x(se.$2), height - 4), Paint()..color = const Color(0x553B82F6));
    c.drawLine(Offset(x(t), 0), Offset(x(t), height), Paint()
      ..color = Colors.white
      ..strokeWidth = 2);
  }

  @override
  bool shouldRepaint(_Timeline old) => true;
}
