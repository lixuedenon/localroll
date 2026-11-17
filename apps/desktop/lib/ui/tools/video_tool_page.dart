// apps/desktop/lib/ui/tools/video_tool_page.dart
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:localroll_core/localroll_core.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../app_services.dart';
import '../../l10n/l10n.dart';
import '../../services/file_tools.dart';
import '../../services/win_dialogs.dart';
import '../send_page.dart' show baseNameOf;
import 'tools.dart';

/// Cut a video (keep a part), make it smaller, only its sound, a GIF; or
/// join several into one.
class VideoToolPage extends StatefulWidget {
  const VideoToolPage({super.key, required this.services, required this.files});

  final AppServices services;
  final List<String> files;

  @override
  State<VideoToolPage> createState() => _VideoToolPageState();
}

class _VideoToolPageState extends State<VideoToolPage> {
  late final Player _player = Player();
  late final VideoController _video = VideoController(_player);
  late final List<String> _files = List.of(widget.files);
  int _at = 0;
  Duration _length = Duration.zero;
  Duration _now = Duration.zero;
  RangeValues _keep = const RangeValues(0, 1);
  VideoOut _how = VideoOut.original;
  final List<StreamSubscription<Object?>> _subs = [];

  /// The picture strip (frames along the whole video) and the frames at
  /// the start and end points; for the file now open.
  List<File?> _strip = const [];
  File? _startPic, _endPic, _dragPic;
  Timer? _picSoon;

  /// Being dragged: 0 the start point, 1 the end point, 2 the play line.
  int? _drag;
  static const _stripN = 12;

  AppServices get s => widget.services;

  @override
  void initState() {
    super.initState();
    _subs
      ..add(_player.stream.duration.listen((d) {
        if (!mounted) return;
        setState(() {
          _length = d;
          _keep = RangeValues(0, d.inMilliseconds.toDouble().clamp(1.0, double.infinity));
        });
        if (d > Duration.zero) unawaited(_loadStrip());
      }))
      ..add(_player.stream.position.listen((p) {
        if (!mounted) return;
        setState(() => _now = p);
        // Playing the part kept: stop at its end.
        if (_player.state.playing && p.inMilliseconds >= _keep.end) unawaited(_player.pause());
      }));
    unawaited(_open(0));
  }

  Future<void> _open(int i) async {
    _at = i;
    _strip = const [];
    _startPic = _endPic = _dragPic = null;
    await _player.open(Media(_files[i]), play: false);
    if (mounted) setState(() {});
  }

  /// A still of the open video at [ms] (to a tenth of a second).
  Future<File?> _frame(int ms) async {
    final path = _files[_at];
    try {
      final st = File(path).statSync();
      return await s.ffmpeg.frameAt(path, (ms ~/ 100) * 100, size: st.size, modifiedMs: st.modified.millisecondsSinceEpoch);
    } catch (_) {
      return null;
    }
  }

  Future<void> _loadStrip() async {
    final path = _files[_at];
    final len = _length.inMilliseconds;
    _strip = List<File?>.filled(_stripN, null);
    for (var i = 0; i < _stripN; i++) {
      final f = await _frame((len * (i + 0.5) / _stripN).round());
      if (!mounted || _files[_at] != path) return;
      setState(() => _strip[i] = f);
    }
    _endsSoon();
  }

  /// The start / end pictures, a moment after the points stop moving.
  void _endsSoon() {
    _picSoon?.cancel();
    _picSoon = Timer(const Duration(milliseconds: 150), () async {
      final a = await _frame(_keep.start.round());
      final b = await _frame(_keep.end.round());
      if (!mounted) return;
      setState(() {
        _startPic = a;
        _endPic = b;
      });
    });
  }

  /// Moves a point to [ms]; the big picture shows that frame.
  void _setPoint(int which, double ms) {
    final len = _length.inMilliseconds.toDouble();
    setState(() {
      _keep = which == 0
          ? RangeValues(ms.clamp(0.0, _keep.end - 100), _keep.end)
          : RangeValues(_keep.start, ms.clamp(_keep.start + 100, len));
    });
    unawaited(_player.seek(Duration(milliseconds: (which == 0 ? _keep.start : _keep.end).round())));
    _endsSoon();
  }

  @override
  void dispose() {
    _picSoon?.cancel();
    for (final x in _subs) {
      unawaited(x.cancel());
    }
    unawaited(_player.dispose());
    super.dispose();
  }

  static String _clock(num ms) {
    final d = Duration(milliseconds: ms.round());
    final m = d.inMinutes, sec = d.inSeconds % 60, cs = (d.inMilliseconds % 1000) ~/ 100;
    return '${m.toString().padLeft(2, '0')}:${sec.toString().padLeft(2, '0')}.$cs';
  }

  Future<void> _export({bool ask = false}) async {
    final src = _files[_at];
    final ext = switch (_how) {
      VideoOut.mp3 => 'mp3',
      VideoOut.gif => 'gif',
      VideoOut.original => extensionOf(src).isEmpty ? 'mp4' : extensionOf(src),
      _ => 'mp4',
    };
    var out = toolOutPath(s, src, tr('video.suffix_${_how.name}'), ext);
    if (ask) {
      final p = await WinDialogs.saveFile(suggestedName: baseNameOf(out), extensions: [ext]);
      if (p == null) return;
      out = p.toLowerCase().endsWith('.$ext') ? p : '$p.$ext';
    }
    if (!mounted) return;
    await _player.pause();
    final whole = _keep.start <= 0 && _keep.end >= _length.inMilliseconds - 50;
    final ok = await runBusy(
      context,
      tr('video.working'),
      () => VideoTools.cut(s, src, out, _how, fromMs: _keep.start.round(), toMs: whole ? null : _keep.end.round()),
      heavy: true,
    );
    if (!mounted) {
      // Left meanwhile: the results still go into the library / records.
      if (ok == true) await s.tools.saved([out]);
      return;
    }
    if (ok != true) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(tr('tool.failed', {'why': 'ffmpeg'}))));
      return;
    }
    await showToolResult(context, s, [out]);
  }

  Future<void> _join() async {
    final out = toolOutPath(s, _files.first, tr('video.suffix_joined'), 'mp4');
    await _player.pause();
    if (!mounted) return;
    final ok = await runBusy(context, tr('video.joining', {'count': _files.length}), () => VideoTools.join(s, _files, out), heavy: true);
    if (!mounted) {
      // Left meanwhile: the results still go into the library / records.
      if (ok == true) await s.tools.saved([out]);
      return;
    }
    if (ok != true) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(tr('video.join_failed'))));
      return;
    }
    await showToolResult(context, s, [out]);
  }

  static const _gold = Color(0xFFFFB547);

  /// The picture strip: what is cut off dimmed, what is kept framed; drag
  /// either end (its frame shows above it), or elsewhere to move the play line.
  Widget _timeline(double len) => LayoutBuilder(builder: (context, box) {
        final w = box.maxWidth;
        double xOf(double ms) => ms / len * w;
        double msOf(double x) => (x / w * len).clamp(0.0, len);
        final xs = xOf(_keep.start), xe = xOf(_keep.end), xn = xOf(_now.inMilliseconds.toDouble());
        const top = 78.0, h = 46.0;
        final pop = _drag == 0 || _drag == 1;
        final popX = _drag == 0 ? xs : xe;
        return SizedBox(
          height: top + h + 8,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onPanStart: (d) {
              final x = d.localPosition.dx;
              // The nearer end, if close; else the play line.
              final ds = (x - xs).abs(), de = (x - xe).abs();
              _drag = ds <= 24 && ds <= de ? 0 : (de <= 24 ? 1 : 2);
              _dragPic = null;
              if (_drag == 2) unawaited(_player.seek(Duration(milliseconds: msOf(x).round())));
              setState(() {});
            },
            onPanUpdate: (d) {
              final ms = msOf(d.localPosition.dx);
              final which = _drag;
              if (which == null) return;
              if (which == 2) {
                unawaited(_player.seek(Duration(milliseconds: ms.round())));
                return;
              }
              _setPoint(which, ms);
              final at = which == 0 ? _keep.start : _keep.end;
              unawaited(_frame(at.round()).then((f) {
                if (mounted && _drag == which) setState(() => _dragPic = f);
              }));
            },
            onPanEnd: (_) => setState(() => _drag = null),
            onTapUp: (d) => unawaited(_player.seek(Duration(milliseconds: msOf(d.localPosition.dx).round()))),
            child: Stack(clipBehavior: Clip.none, children: [
              // The frames.
              Positioned(
                left: 0,
                right: 0,
                top: top,
                height: h,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: Row(children: [
                    for (var i = 0; i < _stripN; i++)
                      Expanded(
                        child: Container(
                          decoration: const BoxDecoration(
                            color: Color(0xFF26324A),
                            border: Border(right: BorderSide(color: Color(0xFF141B26))),
                          ),
                          child: i < _strip.length && _strip[i] != null
                              ? Image.file(_strip[i]!, fit: BoxFit.cover, gaplessPlayback: true)
                              : null,
                        ),
                      ),
                  ]),
                ),
              ),
              // Cut off: dimmed.
              Positioned(left: 0, width: xs, top: top, height: h, child: const ColoredBox(color: Color(0xB30A0E14))),
              Positioned(left: xe, right: 0, top: top, height: h, child: const ColoredBox(color: Color(0xB30A0E14))),
              // Kept: framed.
              Positioned(
                left: xs,
                width: (xe - xs).clamp(2.0, w),
                top: top - 4,
                height: h + 8,
                child: IgnorePointer(
                  child: Container(decoration: BoxDecoration(border: Border.all(color: _gold, width: 3), borderRadius: BorderRadius.circular(6))),
                ),
              ),
              for (final x in [xs, xe])
                Positioned(
                  left: x - 7,
                  top: top - 8,
                  width: 14,
                  height: h + 16,
                  child: MouseRegion(
                    cursor: SystemMouseCursors.resizeLeftRight,
                    child: Container(decoration: BoxDecoration(color: _gold, borderRadius: BorderRadius.circular(4))),
                  ),
                ),
              // Where it is playing.
              Positioned(left: xn - 1, top: top - 6, width: 2, height: h + 12, child: const IgnorePointer(child: ColoredBox(color: Colors.white))),
              // The frame at the point being dragged.
              if (pop)
                Positioned(
                  left: (popX - 66).clamp(0.0, w - 132),
                  top: 0,
                  width: 132,
                  child: IgnorePointer(
                    child: Column(children: [
                      Container(
                        height: 60,
                        decoration: BoxDecoration(
                          color: const Color(0xFF26324A),
                          border: Border.all(color: _gold, width: 2),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        clipBehavior: Clip.antiAlias,
                        child: _dragPic == null ? null : Image.file(_dragPic!, fit: BoxFit.cover, gaplessPlayback: true),
                      ),
                      const SizedBox(height: 2),
                      Text(_clock(_drag == 0 ? _keep.start : _keep.end), style: const TextStyle(color: _gold, fontSize: 12)),
                    ]),
                  ),
                ),
            ]),
          ),
        );
      });

  /// The start or end point: its frame, its time, nudges, "set to now".
  Widget _pointCard(int which, double ms, File? pic) {
    Widget small(String label, VoidCallback onTap, {bool gold = false}) => OutlinedButton(
          style: OutlinedButton.styleFrom(
            foregroundColor: gold ? _gold : Colors.white,
            side: BorderSide(color: gold ? _gold : const Color(0xFF3A475A)),
            visualDensity: VisualDensity.compact,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            minimumSize: const Size(0, 30),
          ),
          onPressed: onTap,
          child: Text(label, style: const TextStyle(fontSize: 12)),
        );
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(color: const Color(0xFF1D2633), borderRadius: BorderRadius.circular(10)),
      child: Row(children: [
        Container(
          width: 96,
          height: 54,
          decoration: BoxDecoration(color: const Color(0xFF26324A), border: Border.all(color: _gold, width: 2), borderRadius: BorderRadius.circular(5)),
          clipBehavior: Clip.antiAlias,
          child: pic == null ? null : Image.file(pic, fit: BoxFit.cover, gaplessPlayback: true),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(tr(which == 0 ? 'video.start_point' : 'video.end_point', {'t': _clock(ms)}),
                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
            const SizedBox(height: 4),
            Wrap(spacing: 6, runSpacing: 4, children: [
              small(tr('video.nudge_back'), () => _setPoint(which, ms - 100)),
              small(tr('video.nudge_fwd'), () => _setPoint(which, ms + 100)),
              small(tr('video.set_here'), () => _setPoint(which, _now.inMilliseconds.toDouble()), gold: true),
            ]),
          ]),
        ),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final len = _length.inMilliseconds.toDouble();
    final keepMs = (_keep.end - _keep.start).round();
    return Scaffold(
      backgroundColor: const Color(0xFF141B26),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1D2633),
        title: Text(baseNameOf(_files[_at]), overflow: TextOverflow.ellipsis),
        actions: [
          ToolSaveChip(services: s, dark: true),
          if (_files.length > 1)
            TextButton.icon(onPressed: _join, icon: const Icon(Icons.merge_rounded), label: Text(tr('video.join', {'count': _files.length}))),
          TextButton.icon(
            onPressed: () async {
              final more = await WinDialogs.pickFiles(title: tr('video.add'), extensions: Tool.cutVideo.extensions);
              if (more.isNotEmpty) setState(() => _files.addAll(more));
            },
            icon: const Icon(Icons.add_rounded),
            label: Text(tr('video.add')),
          ),
          const SizedBox(width: 12),
        ],
      ),
      body: Row(children: [
        if (_files.length > 1)
          Container(
            width: 220,
            color: const Color(0xFF1D2633),
            child: ReorderableListView(
              buildDefaultDragHandles: true,
              onReorder: (a, b) => setState(() {
                final cur = _files[_at];
                final f = _files.removeAt(a);
                _files.insert(b > a ? b - 1 : b, f);
                _at = _files.indexOf(cur);
              }),
              children: [
                for (var i = 0; i < _files.length; i++)
                  ListTile(
                    key: ValueKey('${_files[i]}#$i'),
                    selected: i == _at,
                    title: Text('${i + 1}. ${baseNameOf(_files[i])}', maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13)),
                    onTap: () => unawaited(_open(i)),
                  ),
              ],
            ),
          ),
        Expanded(
          child: Column(children: [
            Expanded(child: Padding(padding: const EdgeInsets.all(16), child: Video(controller: _video, controls: NoVideoControls))),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Column(children: [
                if (len > 0) _timeline(len),
                const SizedBox(height: 6),
                Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
                  Expanded(child: _pointCard(0, _keep.start, _startPic)),
                  SizedBox(
                    width: 170,
                    child: Column(children: [
                      IconButton(
                        color: Colors.white,
                        iconSize: 30,
                        onPressed: () async {
                          if (_player.state.playing) {
                            await _player.pause();
                          } else {
                            if (_now.inMilliseconds < _keep.start || _now.inMilliseconds >= _keep.end - 100) {
                              await _player.seek(Duration(milliseconds: _keep.start.round()));
                            }
                            await _player.play();
                          }
                        },
                        icon: Icon(_player.state.playing ? Icons.pause_rounded : Icons.play_arrow_rounded),
                      ),
                      Text('${_clock(_now.inMilliseconds)} / ${_clock(len)}', style: const TextStyle(color: Colors.white54, fontSize: 12)),
                      const SizedBox(height: 2),
                      Text(tr('video.keep_secs', {'secs': (keepMs / 1000).toStringAsFixed(1)}),
                          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
                    ]),
                  ),
                  Expanded(child: _pointCard(1, _keep.end, _endPic)),
                ]),
                const SizedBox(height: 10),
              ]),
            ),
            Container(
              color: const Color(0xFF1D2633),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Row(children: [
                Text(tr('video.save_as'), style: const TextStyle(color: Colors.white70)),
                const SizedBox(width: 10),
                Expanded(
                  child: Wrap(spacing: 6, runSpacing: 6, children: [
                    for (final h in VideoOut.values)
                      ChoiceChip(selected: _how == h, onSelected: (_) => setState(() => _how = h), label: Text(tr('video.out_${h.name}'))),
                  ]),
                ),
                Text(_how == VideoOut.original ? tr('video.fast') : '', style: const TextStyle(color: Colors.white54, fontSize: 12)),
                const SizedBox(width: 10),
                OutlinedButton(onPressed: len > 0 ? () => _export(ask: true) : null, child: Text(tr('tool.save_as'))),
                const SizedBox(width: 8),
                FilledButton.icon(
                  onPressed: len > 0 ? _export : null,
                  icon: const Icon(Icons.save_rounded, size: 18),
                  label: Text(tr('video.export')),
                ),
              ]),
            ),
          ]),
        ),
      ]),
    );
  }
}
