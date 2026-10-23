// apps/mobile/lib/ui/phone_photo_viewer.dart
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:video_player/video_player.dart';

import '../l10n/l10n.dart';
import 'theme.dart';

/// What the person chose in the viewer.
enum PhotoAction { send, delete }

/// This phone's own photos and videos, full screen: swipe left / right,
/// pinch to zoom; send one on, or delete it (the system asks first).
/// Returns the action and the photo's id, or null.
class PhonePhotoViewer extends StatefulWidget {
  const PhonePhotoViewer({super.key, required this.assets, required this.start, required this.sent});

  final List<AssetEntity> assets;
  final int start;

  /// Already backed up to the PC (ids).
  final Set<String> sent;

  @override
  State<PhonePhotoViewer> createState() => _PhonePhotoViewerState();
}

class _PhonePhotoViewerState extends State<PhonePhotoViewer> {
  late final PageController _pages = PageController(initialPage: widget.start);
  late int _at = widget.start;

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  String _when(AssetEntity a) {
    final d = a.createDateTime;
    String two(int n) => n.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}';
  }

  @override
  Widget build(BuildContext context) {
    final a = widget.assets[_at];
    final backedUp = widget.sent.contains(a.id);
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(_when(a), style: const TextStyle(fontSize: 15)),
          Row(children: [
            Icon(backedUp ? Icons.cloud_done_rounded : Icons.cloud_off_rounded, size: 14, color: backedUp ? LrColors.verified : LrColors.muted),
            const SizedBox(width: 4),
            Text(tr(backedUp ? 'photos.backed_up' : 'photos.not_backed_up'),
                style: TextStyle(fontSize: 12, color: backedUp ? LrColors.verified : LrColors.muted)),
          ]),
        ]),
      ),
      body: PageView.builder(
        controller: _pages,
        itemCount: widget.assets.length,
        onPageChanged: (n) => setState(() => _at = n),
        itemBuilder: (context, k) {
          final it = widget.assets[k];
          return it.type == AssetType.video ? _Video(key: ValueKey(it.id), asset: it, active: k == _at) : _Photo(key: ValueKey(it.id), asset: it);
        },
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: Row(children: [
            Expanded(
              child: FilledButton.icon(
                onPressed: () => Navigator.of(context).pop((PhotoAction.send, a.id)),
                icon: const Icon(Icons.send_rounded),
                label: Text(tr('photos.send')),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () => Navigator.of(context).pop((PhotoAction.delete, a.id)),
                icon: const Icon(Icons.delete_outline_rounded),
                label: Text(tr('photos.delete')),
              ),
            ),
          ]),
        ),
      ),
    );
  }
}

class _Photo extends StatefulWidget {
  const _Photo({super.key, required this.asset});

  final AssetEntity asset;

  @override
  State<_Photo> createState() => _PhotoState();
}

class _PhotoState extends State<_Photo> {
  late final Future<Uint8List?> _big = widget.asset.thumbnailDataWithSize(const ThumbnailSize(2560, 2560), quality: 90);

  @override
  Widget build(BuildContext context) => FutureBuilder<Uint8List?>(
        future: _big,
        builder: (context, s) {
          final b = s.data;
          if (b == null) {
            return s.connectionState == ConnectionState.done
                ? Center(child: Text(tr('mylib.cannot_open'), style: const TextStyle(color: LrColors.muted)))
                : const Center(child: CircularProgressIndicator());
          }
          return InteractiveViewer(maxScale: 6, child: Center(child: Image.memory(b, fit: BoxFit.contain, gaplessPlayback: true)));
        },
      );
}

class _Video extends StatefulWidget {
  const _Video({super.key, required this.asset, required this.active});

  final AssetEntity asset;
  final bool active;

  @override
  State<_Video> createState() => _VideoState();
}

class _VideoState extends State<_Video> {
  VideoPlayerController? _c;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    unawaited(_open());
  }

  Future<void> _open() async {
    try {
      final f = await widget.asset.file;
      if (f == null) throw StateError('no file');
      final c = VideoPlayerController.file(f);
      await c.initialize();
      if (!mounted) {
        await c.dispose();
        return;
      }
      setState(() => _c = c);
      if (widget.active) await c.play();
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  @override
  void didUpdateWidget(_Video old) {
    super.didUpdateWidget(old);
    if (old.active && !widget.active) unawaited(_c?.pause());
  }

  @override
  void dispose() {
    unawaited(_c?.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_failed) return Center(child: Text(tr('mylib.cannot_open'), style: const TextStyle(color: LrColors.muted)));
    final c = _c;
    if (c == null) return const Center(child: CircularProgressIndicator());
    return GestureDetector(
      onTap: () => unawaited(c.value.isPlaying ? c.pause() : c.play()),
      child: Stack(alignment: Alignment.bottomCenter, children: [
        Center(child: AspectRatio(aspectRatio: c.value.aspectRatio, child: VideoPlayer(c))),
        VideoProgressIndicator(c, allowScrubbing: true, padding: const EdgeInsets.fromLTRB(12, 12, 12, 24)),
        ValueListenableBuilder(
          valueListenable: c,
          builder: (_, v, _) => v.isPlaying
              ? const SizedBox.shrink()
              : const Center(child: Icon(Icons.play_circle_outline_rounded, color: Colors.white70, size: 72)),
        ),
      ]),
    );
  }
}
