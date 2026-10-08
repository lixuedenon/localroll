// apps/desktop/lib/ui/media_thumb.dart
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:localroll_core/localroll_core.dart';

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

    return Stack(
      fit: StackFit.expand,
      children: [
        image,
        if (widget.item.kind == MediaKind.video)
          const Positioned(
            right: 6,
            bottom: 6,
            child: Icon(Icons.play_circle_fill, color: Colors.white, size: 22,
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
  }
}
