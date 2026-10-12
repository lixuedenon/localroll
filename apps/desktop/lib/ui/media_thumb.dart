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

  // Live Photo: play the motion while the mouse rests on it (one at a time,
  // muted, like iPhone's Photos when you press on a Live Photo).
  static _MediaThumbState? _playingNow;
  Timer? _hover;
  Player? _player;
  VideoController? _video;
  bool _showVideo = false;

  void _enter() {
    final live = widget.library.liveFor(widget.item);
    if (live == null) return;
    _hover?.cancel();
    _hover = Timer(const Duration(milliseconds: 250), () => _play(live));
  }

  Future<void> _play(MediaItem live) async {
    if (!mounted) return;
    if (_playingNow != this) _playingNow?._stop();
    _playingNow = this;
    final p = Player();
    _player = p;
    _video = VideoController(p);
    try {
      await p.setVolume(0);
      p.stream.completed.listen((done) {
        if (done) _stop();
      });
      p.stream.playing.listen((on) {
        if (on && mounted && _player == p && !_showVideo) setState(() => _showVideo = true);
      });
      await p.open(Media(widget.library.absPath(live)));
    } catch (_) {
      _stop();
    }
  }

  void _stop() {
    _hover?.cancel();
    _hover = null;
    final p = _player;
    _player = null;
    _video = null;
    if (_playingNow == this) _playingNow = null;
    if (p != null) unawaited(p.dispose());
    if (mounted && _showVideo) setState(() => _showVideo = false);
  }

  @override
  void dispose() {
    _stop();
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

    final video = _video;
    final stack = Stack(
      fit: StackFit.expand,
      children: [
        image,
        if (_showVideo && video != null)
          IgnorePointer(child: Video(controller: video, controls: NoVideoControls, fit: BoxFit.cover)),
        if (widget.item.kind == MediaKind.video)
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
