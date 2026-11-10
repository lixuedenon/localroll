// apps/desktop/lib/ui/tools/video_tool_page.dart
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:localroll_core/localroll_core.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../app_services.dart';
import '../../l10n/l10n.dart';
import '../../services/file_tools.dart';
import '../../services/win_dialogs.dart';
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

  AppServices get s => widget.services;

  @override
  void initState() {
    super.initState();
    _subs
      ..add(_player.stream.duration.listen((d) {
        if (!mounted) return;
        setState(() {
          _length = d;
          _keep = RangeValues(0, d.inMilliseconds.toDouble().clamp(1, double.infinity));
        });
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
    await _player.open(Media(_files[i]), play: false);
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
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
    );
    if (!mounted) return;
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
    final ok = await runBusy(context, tr('video.joining', {'count': _files.length}), () => VideoTools.join(s, _files, out));
    if (!mounted) return;
    if (ok != true) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(tr('video.join_failed'))));
      return;
    }
    await showToolResult(context, s, [out]);
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
                if (len > 0)
                  RangeSlider(
                    values: _keep,
                    min: 0,
                    max: len,
                    onChanged: (v) {
                      setState(() => _keep = v);
                      unawaited(_player.seek(Duration(milliseconds: (v.start != _keep.start ? v.start : v.end).round())));
                    },
                  ),
                Row(children: [
                  IconButton(
                    color: Colors.white,
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
                  Text('${_clock(_now.inMilliseconds)} / ${_clock(len)}', style: const TextStyle(color: Colors.white70)),
                  const SizedBox(width: 16),
                  TextButton(
                    onPressed: () => setState(() => _keep = RangeValues(_now.inMilliseconds.toDouble().clamp(0, _keep.end - 100), _keep.end)),
                    child: Text(tr('video.start_here')),
                  ),
                  TextButton(
                    onPressed: () => setState(() => _keep = RangeValues(_keep.start, _now.inMilliseconds.toDouble().clamp(_keep.start + 100, len))),
                    child: Text(tr('video.end_here')),
                  ),
                  const Spacer(),
                  Text(tr('video.keep', {'from': _clock(_keep.start), 'to': _clock(_keep.end), 'secs': (keepMs / 1000).toStringAsFixed(1)}),
                      style: const TextStyle(color: Colors.white70)),
                ]),
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
