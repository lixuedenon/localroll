// apps/desktop/lib/ui/media_thumb.dart
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:localroll_core/localroll_core.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../services/ffmpeg.dart';
import '../services/library_index.dart';

/// Grid cell: JPEG/PNG decoded directly, HEIC/video via a cached ffmpeg thumbnail.
class MediaThumb extends StatefulWidget {
  const MediaThumb({
    super.key,
    required this.item,
    required this.library,
    required this.ffmpeg,
  });

  final MediaItem item;
  final LibraryIndex library;
  final FfmpegService ffmpeg;

  @override
  State<MediaThumb> createState() => _MediaThumbState();
}

class _MediaThumbState extends State<MediaThumb> {
  Future<File?>? _thumb;

  // Mouse resting on it: a Live Photo plays its motion once; a video plays
  // muted from the start and loops, like YouTube's preview. One at a time.
  static _MediaThumbState? _playingNow;
  Timer? _hover;
  bool _live = false;

  bool get _isVideo => widget.item.kind == MediaKind.video;

  /// What to play on hover, or null.
  String? get _previewPath {
    if (_isVideo) return widget.library.absPath(widget.item);
    final live = widget.library.liveFor(widget.item);
    return live == null ? null : widget.library.absPath(live);
  }

  void _enter() {
    if (_previewPath == null) return;
    _hover?.cancel();
    // A short pause, so sweeping the mouse across the grid starts nothing.
    _hover = Timer(Duration(milliseconds: _isVideo ? 450 : 250), () {
      if (!mounted) return;
      if (_playingNow != this) _playingNow?._stop();
      _playingNow = this;
      setState(() => _live = true);
    });
  }

  void _stop() {
    _hover?.cancel();
    _hover = null;
    if (_playingNow == this) _playingNow = null;
    if (mounted && _live) setState(() => _live = false);
  }

  @override
  void dispose() {
    _hover?.cancel();
    if (_playingNow == this) _playingNow = null;
    super.dispose();
  }

  bool get _direct =>
      widget.item.kind == MediaKind.image && nativelyDecodableImages.contains(widget.item.extension);

  @override
  void initState() {
    super.initState();
    if (!_direct) _thumb = widget.ffmpeg.thumbnail(widget.item);
  }

  @override
  void didUpdateWidget(MediaThumb old) {
    super.didUpdateWidget(old);
    if (old.item.relPath != widget.item.relPath && !_direct) {
      _thumb = widget.ffmpeg.thumbnail(widget.item);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final placeholder = Container(
      color: scheme.surfaceContainerHighest,
      alignment: Alignment.center,
      child: Icon(
        widget.item.kind == MediaKind.video ? Icons.movie_outlined : Icons.image_outlined,
        color: scheme.onSurfaceVariant,
      ),
    );

    Widget image;
    if (_direct) {
      image = Image.file(
        File(widget.library.absPath(widget.item)),
        fit: BoxFit.cover,
        cacheWidth: 360,
        errorBuilder: (_, _, _) => placeholder,
      );
    } else {
      image = FutureBuilder<File?>(
        future: _thumb,
        builder: (context, snap) {
          final f = snap.data;
          if (f == null) return placeholder;
          return Image.file(f, fit: BoxFit.cover, errorBuilder: (_, _, _) => placeholder);
        },
      );
    }

    final preview = _live ? _previewPath : null;
    final stack = Stack(
      fit: StackFit.expand,
      children: [
        image,
        if (preview != null)
          IgnorePointer(child: _ThumbLive(path: preview, loop: _isVideo, onDone: _stop)),
        if (widget.item.kind == MediaKind.video && preview == null)
          const Positioned(
            right: 6,
            bottom: 6,
            child: Icon(Icons.play_circle_fill, color: Colors.white, size: 22,
                shadows: [Shadow(blurRadius: 4, color: Colors.black54)]),
          ),
        if (widget.item.private)
          const Positioned(
            right: 6,
            top: 6,
            child: Icon(Icons.lock_rounded, color: Colors.white, size: 18,
                shadows: [Shadow(blurRadius: 4, color: Colors.black54)]),
          ),
        // Live Photo: the same concentric-rings mark iPhone uses.
        if (widget.library.liveFor(widget.item) != null)
          const Positioned(
            left: 6,
            top: 6,
            child: Icon(Icons.motion_photos_on_rounded, color: Colors.white, size: 20,
                shadows: [Shadow(blurRadius: 4, color: Colors.black54)]),
          ),
        if (widget.item.extension == 'heic' || widget.item.extension == 'heif')
          Positioned(
            left: 6,
            bottom: 6,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
              decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(4)),
              child: const Text('HEIC', style: TextStyle(color: Colors.white, fontSize: 10)),
            ),
          ),
      ],
    );
    return MouseRegion(onEnter: (_) => _enter(), onExit: (_) => _stop(), child: stack);
  }
}

/// Hover preview inside a thumbnail, muted: a Live Photo's motion (once) or
/// a video (looping, with a thin progress line).
class _ThumbLive extends StatefulWidget {
  const _ThumbLive({required this.path, required this.onDone, this.loop = false});

  final String path;
  final VoidCallback onDone;
  final bool loop;

  @override
  State<_ThumbLive> createState() => _ThumbLiveState();
}

/// The one player behind every hover preview. Made once and kept: making a
/// player and its picture surface for each hover — and throwing them away a
/// moment later, sometimes before the surface was even ready — could take
/// the whole app down (seen on a PC: closed itself right after quick hovers
/// over videos). One preview plays at a time anyway.
class _HoverPlayer {
  _HoverPlayer._() {
    player.setVolume(0);
    player.stream.completed.listen((done) {
      if (done) _onDone?.call();
    });
  }

  static _HoverPlayer? _one;
  static _HoverPlayer get instance => _one ??= _HoverPlayer._();

  final Player player = Player();
  late final VideoController controller = VideoController(player);

  /// Who plays now (a newer preview takes over; the old one's stop does nothing).
  Object? _owner;
  VoidCallback? _onDone;

  void play(Object owner, String path, {required bool loop, VoidCallback? onDone}) {
    _owner = owner;
    _onDone = loop ? null : onDone;
    DiagLog.log('ui', 'video preview start');
    unawaited(player.setPlaylistMode(loop ? PlaylistMode.loop : PlaylistMode.none));
    unawaited(player.open(Media(path)));
  }

  void stop(Object owner) {
    if (!identical(_owner, owner)) return;
    _owner = null;
    _onDone = null;
    DiagLog.log('ui', 'video preview stop');
    unawaited(player.stop());
  }
}

class _ThumbLiveState extends State<_ThumbLive> {
  final _HoverPlayer _hp = _HoverPlayer.instance;
  Player get _player => _hp.player;
  VideoController get _controller => _hp.controller;

  @override
  void initState() {
    super.initState();
    _hp.play(this, widget.path, loop: widget.loop, onDone: () {
      if (mounted) widget.onDone();
    });
  }

  @override
  void dispose() {
    _hp.stop(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final video = Video(controller: _controller, controls: NoVideoControls, fit: BoxFit.cover, fill: Colors.transparent);
    if (!widget.loop) return video;
    return Stack(fit: StackFit.expand, children: [
      video,
      Positioned(
        left: 0,
        right: 0,
        bottom: 0,
        child: StreamBuilder<Duration>(
          stream: _player.stream.position,
          builder: (context, snap) {
            final total = _player.state.duration.inMilliseconds;
            final at = snap.data?.inMilliseconds ?? 0;
            return LinearProgressIndicator(
              value: total <= 0 ? 0 : (at / total).clamp(0.0, 1.0),
              minHeight: 3,
              color: const Color(0xFFFF3B30),
              backgroundColor: Colors.white24,
            );
          },
        ),
      ),
    ]);
  }
}
