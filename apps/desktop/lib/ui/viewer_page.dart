// apps/desktop/lib/ui/viewer_page.dart
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:localroll_core/localroll_core.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../app_services.dart';
import '../services/converter.dart';
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
                '${item.deviceName != null ? ' · 来自 ${item.deviceName}' : ''}',
                style: const TextStyle(fontSize: 12, color: Colors.white70),
              ),
            ],
          ),
          actions: [
            PopupMenuButton<ConvertPreset>(
              tooltip: '转换（原片保留）',
              icon: const Icon(Icons.auto_fix_high),
              onSelected: (p) {
                s.converter.enqueue([item], p);
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('已加入转换队列（${p.label}），可在「转换」页查看')),
                );
              },
              itemBuilder: (_) => [
                for (final p in ConvertPreset.values) PopupMenuItem(value: p, child: Text('转换为：${p.label}')),
              ],
            ),
            IconButton(
              tooltip: '在文件夹中显示',
              onPressed: () => revealInExplorer(s.library.absPath(item)),
              icon: const Icon(Icons.folder_open),
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

  @override
  Widget build(BuildContext context) {
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
                  ? '无法解码这张图片'
                  : '显示 ${widget.item.extension.toUpperCase()} 需要 ffmpeg，请到「设置」配置',
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
  Widget build(BuildContext context) => Video(controller: _controller);
}
