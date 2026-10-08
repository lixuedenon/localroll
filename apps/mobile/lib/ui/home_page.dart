// apps/mobile/lib/ui/home_page.dart
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:photo_manager/photo_manager.dart';

import '../services/discovery.dart';
import '../services/mobile_settings.dart';
import 'connect_page.dart';
import 'transfer_page.dart';

/// Photo library grid: pick photos/videos and send them to the PC.
class HomePage extends StatefulWidget {
  const HomePage({super.key, required this.settings, required this.discovery});

  final MobileSettings settings;
  final DesktopDiscovery discovery;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  static const int _pageSize = 120;

  PermissionState? _permission;
  AssetPathEntity? _all;
  final List<AssetEntity> _assets = [];
  int _nextPage = 0;
  bool _loading = false;
  bool _hasMore = true;
  bool _onlyUnsent = false;
  final Set<String> _selected = {};
  final Map<String, Future<Uint8List?>> _thumbs = {};

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final ps = await PhotoManager.requestPermissionExtend();
    setState(() => _permission = ps);
    if (!ps.hasAccess) return;
    final paths = await PhotoManager.getAssetPathList(
      type: RequestType.common,
      onlyAll: true,
      filterOption: FilterOptionGroup(
        orders: [const OrderOption(type: OrderOptionType.createDate, asc: false)],
      ),
    );
    if (paths.isEmpty) {
      setState(() => _hasMore = false);
      return;
    }
    _all = paths.first;
    await _loadMore();
  }

  Future<void> _reload() async {
    _assets.clear();
    _thumbs.clear();
    _nextPage = 0;
    _hasMore = true;
    await _init();
  }

  Future<void> _loadMore() async {
    final all = _all;
    if (_loading || !_hasMore || all == null) return;
    _loading = true;
    final page = await all.getAssetListPaged(page: _nextPage, size: _pageSize);
    _nextPage++;
    if (!mounted) return;
    setState(() {
      _assets.addAll(page);
      _hasMore = page.length == _pageSize;
      _loading = false;
    });
  }

  Future<Uint8List?> _thumb(AssetEntity a) =>
      _thumbs.putIfAbsent(a.id, () => a.thumbnailDataWithSize(const ThumbnailSize.square(240), quality: 80));

  Future<void> _openConnect() async {
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => ConnectPage(settings: widget.settings, discovery: widget.discovery),
    ));
    if (mounted) setState(() {});
  }

  Future<void> _send() async {
    final desktop = widget.settings.current;
    if (desktop == null) {
      await _openConnect();
      return;
    }
    final chosen = _assets.where((a) => _selected.contains(a.id)).toList();
    if (chosen.isEmpty) return;
    final finished = await Navigator.of(context).push<bool>(MaterialPageRoute(
      builder: (_) => TransferPage(
        settings: widget.settings,
        discovery: widget.discovery,
        desktop: desktop,
        assets: chosen,
      ),
    ));
    if (finished == true && mounted) setState(_selected.clear);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.settings,
      builder: (context, _) {
        final desktop = widget.settings.current;
        final sent = desktop == null ? const <String>{} : widget.settings.sentTo(desktop.id);
        final visible = _onlyUnsent ? _assets.where((a) => !sent.contains(a.id)).toList() : _assets;
        return Scaffold(
          appBar: AppBar(
            title: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('LocalRoll'),
                Text(
                  desktop == null ? '未连接电脑' : '发送到：${desktop.name}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
            actions: [
              IconButton(
                tooltip: '连接电脑',
                onPressed: _openConnect,
                icon: Icon(desktop == null ? Icons.add_link : Icons.computer),
              ),
            ],
          ),
          body: _body(context, visible, sent),
          bottomNavigationBar: _assets.isEmpty ? null : _bottomBar(context, visible, sent),
        );
      },
    );
  }

  Widget _body(BuildContext context, List<AssetEntity> visible, Set<String> sent) {
    final ps = _permission;
    if (ps == null) return const Center(child: CircularProgressIndicator());
    if (!ps.hasAccess) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('需要访问照片才能发送原片到电脑', textAlign: TextAlign.center),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: () async {
                  await PhotoManager.openSetting();
                },
                child: const Text('去设置里允许'),
              ),
              TextButton(onPressed: _reload, child: const Text('我已允许，重新加载')),
            ],
          ),
        ),
      );
    }
    return Column(
      children: [
        if (ps == PermissionState.limited)
          MaterialBanner(
            content: const Text('只允许了部分照片，只能看到和发送这些照片。'),
            actions: [
              TextButton(
                onPressed: () async {
                  await PhotoManager.presentLimited();
                  await _reload();
                },
                child: const Text('选择更多'),
              ),
            ],
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
          child: Row(
            children: [
              FilterChip(
                label: const Text('只看没传过的'),
                selected: _onlyUnsent,
                onSelected: (v) => setState(() => _onlyUnsent = v),
              ),
              const Spacer(),
              TextButton(
                onPressed: () => setState(() {
                  _selected.addAll(_assets.where((a) => !sent.contains(a.id)).map((a) => a.id));
                }),
                child: const Text('选中所有没传过的'),
              ),
            ],
          ),
        ),
        Expanded(
          child: NotificationListener<ScrollNotification>(
            onNotification: (n) {
              if (n.metrics.pixels > n.metrics.maxScrollExtent - 800) _loadMore();
              return false;
            },
            child: RefreshIndicator(
              onRefresh: _reload,
              child: GridView.builder(
                padding: const EdgeInsets.all(2),
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 4,
                  mainAxisSpacing: 2,
                  crossAxisSpacing: 2,
                ),
                itemCount: visible.length,
                itemBuilder: (context, i) => _tile(visible[i], sent.contains(visible[i].id)),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _tile(AssetEntity a, bool alreadySent) {
    final selected = _selected.contains(a.id);
    final scheme = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: () => setState(() => selected ? _selected.remove(a.id) : _selected.add(a.id)),
      child: Stack(
        fit: StackFit.expand,
        children: [
          FutureBuilder<Uint8List?>(
            future: _thumb(a),
            builder: (context, snap) => snap.data == null
                ? Container(color: scheme.surfaceContainerHighest)
                : Image.memory(snap.data!, fit: BoxFit.cover, gaplessPlayback: true),
          ),
          if (a.type == AssetType.video)
            Positioned(
              right: 4,
              bottom: 4,
              child: Text(
                _duration(a.videoDuration),
                style: const TextStyle(color: Colors.white, fontSize: 11, shadows: [Shadow(blurRadius: 3)]),
              ),
            ),
          if (alreadySent)
            const Positioned(
              left: 4,
              bottom: 4,
              child: Icon(Icons.cloud_done, color: Colors.white, size: 16, shadows: [Shadow(blurRadius: 3)]),
            ),
          if (selected)
            Container(
              color: Colors.black38,
              alignment: Alignment.topRight,
              padding: const EdgeInsets.all(4),
              child: Icon(Icons.check_circle, color: scheme.primary),
            ),
        ],
      ),
    );
  }

  Widget _bottomBar(BuildContext context, List<AssetEntity> visible, Set<String> sent) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
        child: Row(
          children: [
            if (_selected.isNotEmpty)
              TextButton(onPressed: () => setState(_selected.clear), child: const Text('取消选择')),
            const Spacer(),
            FilledButton.icon(
              onPressed: _selected.isEmpty ? null : _send,
              icon: const Icon(Icons.send),
              label: Text(_selected.isEmpty ? '选择照片或视频' : '发送 ${_selected.length} 项'),
            ),
          ],
        ),
      ),
    );
  }

  static String _duration(Duration d) {
    final m = d.inMinutes;
    final s = d.inSeconds % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }
}
