// apps/desktop/lib/ui/viewer_page.dart
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:localroll_core/localroll_core.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../app_services.dart';
import '../l10n/l10n.dart';
import '../services/converter.dart';
import '../services/file_actions.dart';
import '../services/library_index.dart';
import '../services/network.dart';
import 'format.dart';

/// Full-screen viewer: originals are shown directly (no conversion needed).
/// Videos — including HEVC, HDR and Dolby Vision — play through libmpv.
class ViewerPage extends StatefulWidget {
  const ViewerPage({
    super.key,
    required this.services,
    required this.items,
    required this.initialIndex,
  });

  final AppServices services;
  final List<MediaItem> items;
  final int initialIndex;

  @override
  State<ViewerPage> createState() => _ViewerPageState();
}

class _ViewerPageState extends State<ViewerPage> {
  late final PageController _pages = PageController(initialPage: widget.initialIndex);
  late int _index = widget.initialIndex;
  final FocusNode _focus = FocusNode();

  MediaItem get _item => widget.items[_index];

  @override
  void dispose() {
    _pages.dispose();
    _focus.dispose();
    super.dispose();
  }

  /// Delete (to the Recycle Bin) and close the viewer.
  Future<void> _deleteCurrent(MediaItem item) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('lib.delete_title', {'count': 1})),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Text(tr('lib.delete_body')),
        ),
        actions: [
          OutlinedButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('exit.stay'))),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(tr('lib.delete'))),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final n = await deleteItems(widget.services.library, [item]);
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    Navigator.of(context).pop();
    messenger.showSnackBar(SnackBar(content: Text(tr('lib.deleted', {'count': n}))));
  }

  /// "Anna 2" (family member + device number), else the phone's name.
  String? _from(MediaItem item) =>
      (item.deviceId == null ? null : widget.services.settings.family.labelOf(item.deviceId!)) ?? item.deviceName;

  void _go(int delta) {
    final next = _index + delta;
    if (next < 0 || next >= widget.items.length) return;
    _pages.animateToPage(next, duration: const Duration(milliseconds: 200), curve: Curves.easeOut);
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.services;
    final item = _item;
    return KeyboardListener(
      focusNode: _focus,
      autofocus: true,
      onKeyEvent: (e) {
        if (e is! KeyDownEvent) return;
        if (e.logicalKey == LogicalKeyboardKey.arrowRight) _go(1);
        if (e.logicalKey == LogicalKeyboardKey.arrowLeft) _go(-1);
        if (e.logicalKey == LogicalKeyboardKey.escape) Navigator.of(context).maybePop();
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(
          backgroundColor: Colors.black,
          foregroundColor: Colors.white,
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(item.name, style: const TextStyle(fontSize: 16)),
              Text(
                '${formatDate(item.captureTime)} · ${formatBytes(item.size)}'
                '${_from(item) != null ? ' · ${tr('viewer.from', {'name': _from(item)})}' : ''}'
                '${item.private ? ' · 🔒' : ''}',
                style: const TextStyle(fontSize: 12, color: Colors.white70),
              ),
            ],
          ),
          actions: [
            PopupMenuButton<ConvertPreset>(
              tooltip: tr('convert.keep_original_tooltip'),
              icon: const Icon(Icons.auto_fix_high),
              onSelected: (p) {
                s.converter.enqueue([item], p);
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text(tr('convert.queued_hint', {'preset': p.label}))),
                );
              },
              itemBuilder: (_) => [
                for (final p in ConvertPreset.values) PopupMenuItem(value: p, child: Text(tr('convert.to', {'preset': p.label}))),
              ],
            ),
            IconButton(
              tooltip: tr('common.show_in_folder'),
              onPressed: () => revealInExplorer(s.library.absPath(item)),
              icon: const Icon(Icons.folder_open),
            ),
            IconButton(
              tooltip: tr('lib.delete'),
              onPressed: () => _deleteCurrent(item),
              icon: const Icon(Icons.delete_outline_rounded),
            ),
            const SizedBox(width: 8),
          ],
        ),
        body: Stack(
          children: [
            PageView.builder(
              controller: _pages,
              itemCount: widget.items.length,
              onPageChanged: (i) => setState(() => _index = i),
              itemBuilder: (context, i) {
                final it = widget.items[i];
                return it.kind == MediaKind.video
                    ? _VideoView(key: ValueKey(it.relPath), path: s.library.absPath(it), active: i == _index)
                    : _ImageView(key: ValueKey(it.relPath), item: it, services: s);
              },
            ),
            if (_index > 0)
              Align(
                alignment: Alignment.centerLeft,
                child: IconButton(
                  color: Colors.white70,
                  iconSize: 40,
                  onPressed: () => _go(-1),
                  icon: const Icon(Icons.chevron_left),
                ),
              ),
            if (_index < widget.items.length - 1)
              Align(
                alignment: Alignment.centerRight,
                child: IconButton(
                  color: Colors.white70,
                  iconSize: 40,
                  onPressed: () => _go(1),
                  icon: const Icon(Icons.chevron_right),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _ImageView extends StatefulWidget {
  const _ImageView({super.key, required this.item, required this.services});

  final MediaItem item;
  final AppServices services;

  @override
  State<_ImageView> createState() => _ImageViewState();
}

class _ImageViewState extends State<_ImageView> {
  Future<File?>? _preview;

  bool get _direct => nativelyDecodableImages.contains(widget.item.extension);

  @override
  void initState() {
    super.initState();
    if (!_direct) _preview = widget.services.ffmpeg.preview(widget.item);
  }

  /// Playing the Live Photo's video over the still.
  bool _playingLive = false;

  @override
  Widget build(BuildContext context) {
    final live = widget.services.library.liveFor(widget.item);
    final still = _still(context);
    if (live == null) return still;
    return Stack(
      children: [
        Positioned.fill(child: still),
        if (_playingLive)
          Positioned.fill(
            child: _LivePlayback(
              path: widget.services.library.absPath(live),
              onDone: () {
                if (mounted) setState(() => _playingLive = false);
              },
            ),
          ),
        Positioned(
          left: 16,
          top: 12,
          child: MouseRegion(
            // Like pressing on a Live Photo on iPhone: hover (or click) plays it.
            onEnter: (_) => setState(() => _playingLive = true),
            child: ActionChip(
              avatar: const Icon(Icons.motion_photos_on_rounded, size: 18),
              label: Text(tr('viewer.live')),
              onPressed: () => setState(() => _playingLive = !_playingLive),
            ),
          ),
        ),
      ],
    );
  }

  Widget _still(BuildContext context) {
    final lib = widget.services.library;
    if (_direct) return _zoomable(Image.file(File(lib.absPath(widget.item))));
    return FutureBuilder<File?>(
      future: _preview,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        final f = snap.data;
        if (f == null) {
          return Center(
            child: Text(
              widget.services.ffmpeg.available
                  ? tr('viewer.cannot_decode')
                  : tr('viewer.needs_ffmpeg', {'ext': widget.item.extension.toUpperCase()}),
              style: const TextStyle(color: Colors.white70),
            ),
          );
        }
        return _zoomable(Image.file(f));
      },
    );
  }

  Widget _zoomable(Widget child) => InteractiveViewer(
        maxScale: 8,
        child: Center(child: child),
      );
}

/// Plays a Live Photo's video once (with sound), then hands back to the still.
class _LivePlayback extends StatefulWidget {
  const _LivePlayback({required this.path, required this.onDone});

  final String path;
  final VoidCallback onDone;

  @override
  State<_LivePlayback> createState() => _LivePlaybackState();
}

class _LivePlaybackState extends State<_LivePlayback> {
  late final Player _player = Player();
  late final VideoController _controller = VideoController(_player);
  StreamSubscription<bool>? _sub;

  @override
  void initState() {
    super.initState();
    _sub = _player.stream.completed.listen((done) {
      if (done) widget.onDone();
    });
    _player.open(Media(widget.path));
  }

  @override
  void dispose() {
    _sub?.cancel();
    _player.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: widget.onDone,
        child: Video(controller: _controller, controls: NoVideoControls, fill: Colors.black),
      );
}

class _VideoView extends StatefulWidget {
  const _VideoView({super.key, required this.path, required this.active});

  final String path;
  final bool active;

  @override
  State<_VideoView> createState() => _VideoViewState();
}

class _VideoViewState extends State<_VideoView> {
  late final Player _player = Player();
  late final VideoController _controller = VideoController(_player);

  @override
  void initState() {
    super.initState();
    _player.open(Media(widget.path), play: widget.active);
  }

  @override
  void didUpdateWidget(_VideoView old) {
    super.didUpdateWidget(old);
    // Pause when swiped away so audio does not keep playing.
    if (old.active && !widget.active) _player.pause();
  }

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Video on top, controls in their own bar below — the picture is never
    // covered and stays centred between the title bar and the controls.
    return Column(
      children: [
        Expanded(
          child: GestureDetector(
            onTap: _player.playOrPause,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Video(controller: _controller, controls: NoVideoControls, fill: Colors.black),
            ),
          ),
        ),
        _VideoBar(player: _player),
      ],
    );
  }
}

/// Play/pause, seek bar, time and mute, below the video.
class _VideoBar extends StatefulWidget {
  const _VideoBar({required this.player});

  final Player player;

  @override
  State<_VideoBar> createState() => _VideoBarState();
}

class _VideoBarState extends State<_VideoBar> {
  /// Slider position while the user drags (null = follow playback).
  double? _dragMs;

  static String _t(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes % 60;
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    return h > 0 ? '$h:${m.toString().padLeft(2, '0')}:$s' : '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.player;
    return Container(
      color: Colors.black,
      padding: const EdgeInsets.fromLTRB(8, 0, 16, 12),
      child: StreamBuilder<Duration>(
        stream: p.stream.position,
        initialData: p.state.position,
        builder: (context, posSnap) {
          final dur = p.state.duration;
          final pos = posSnap.data ?? Duration.zero;
          final maxMs = dur.inMilliseconds.toDouble();
          final valueMs = (_dragMs ?? pos.inMilliseconds.toDouble()).clamp(0.0, maxMs > 0 ? maxMs : 0.0);
          return Row(
            children: [
              StreamBuilder<bool>(
                stream: p.stream.playing,
                initialData: p.state.playing,
                builder: (context, snap) => IconButton(
                  color: Colors.white,
                  onPressed: p.playOrPause,
                  icon: Icon(snap.data == true ? Icons.pause : Icons.play_arrow),
                ),
              ),
              Text(_t(Duration(milliseconds: valueMs.round())), style: const TextStyle(color: Colors.white70, fontSize: 12)),
              Expanded(
                child: Slider(
                  value: valueMs,
                  max: maxMs > 0 ? maxMs : 1,
                  onChanged: maxMs > 0 ? (v) => setState(() => _dragMs = v) : null,
                  onChangeEnd: (v) async {
                    await p.seek(Duration(milliseconds: v.round()));
                    if (mounted) setState(() => _dragMs = null);
                  },
                ),
              ),
              Text(_t(dur), style: const TextStyle(color: Colors.white70, fontSize: 12)),
              StreamBuilder<double>(
                stream: p.stream.volume,
                initialData: p.state.volume,
                builder: (context, snap) {
                  final muted = (snap.data ?? 100) == 0;
                  return IconButton(
                    color: Colors.white,
                    onPressed: () => p.setVolume(muted ? 100 : 0),
                    icon: Icon(muted ? Icons.volume_off : Icons.volume_up),
                  );
                },
              ),
            ],
          );
        },
      ),
    );
  }
}
