// apps/mobile/lib/ui/home_page.dart
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:localroll_core/localroll_core.dart';
import 'package:photo_manager/photo_manager.dart';

import '../l10n/l10n.dart';
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

class _HomePageState extends State<HomePage> with WidgetsBindingObserver {
  static const int _pageSize = 120;

  PermissionState? _permission;

  /// Shown instead of an endless spinner when the photo library can't be read.
  String? _error;
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
    WidgetsBinding.instance.addObserver(this);
    _init();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// Coming back from the Settings app: re-check photo access.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && !(_permission?.hasAccess ?? false)) _reload();
  }

  Future<void> _init() async {
    if (mounted) setState(() => _error = null);
    PermissionState ps;
    try {
      // Ask for photos first and only then start LAN discovery: two system
      // permission prompts at once can leave one callback never firing on iOS.
      ps = await PhotoManager.requestPermissionExtend().timeout(const Duration(seconds: 20));
    } on TimeoutException {
      // The prompt never answered; read the current state instead of hanging.
      try {
        ps = await PhotoManager.getPermissionState(requestOption: const PermissionRequestOption());
      } catch (e) {
        _fail(e);
        return;
      }
    } catch (e) {
      _fail(e);
      return;
    } finally {
      widget.discovery.start();
    }
    if (!mounted) return;
    setState(() => _permission = ps);
    if (!ps.hasAccess) return;
    try {
      final paths = await PhotoManager.getAssetPathList(
        type: RequestType.common,
        onlyAll: true,
        filterOption: FilterOptionGroup(
          orders: [const OrderOption(type: OrderOptionType.createDate, asc: false)],
        ),
      );
      if (paths.isEmpty) {
        if (mounted) setState(() => _hasMore = false);
        return;
      }
      _all = paths.first;
      await _loadMore();
    } catch (e) {
      _fail(e);
    }
  }

  void _fail(Object e) {
    if (!mounted) return;
    setState(() {
      _error = e.toString();
      _loading = false;
      _permission ??= PermissionState.notDetermined;
    });
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
    final List<AssetEntity> page;
    try {
      page = await all.getAssetListPaged(page: _nextPage, size: _pageSize);
    } catch (e) {
      _fail(e);
      return;
    }
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
                  desktop == null ? tr('home.not_connected') : tr('home.send_to', {'name': desktop.name}),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
            actions: [
              PopupMenuButton<String>(
                tooltip: tr('home.language'),
                icon: const Icon(Icons.translate),
                onSelected: (code) => widget.settings.setLanguage(code.isEmpty ? null : code),
                itemBuilder: (_) => [
                  CheckedPopupMenuItem(
                    value: '',
                    checked: widget.settings.language == null,
                    child: Text(tr('home.language_system')),
                  ),
                  for (final l in supportedLanguages)
                    CheckedPopupMenuItem(
                      value: l.code,
                      checked: widget.settings.language == l.code,
                      child: Text(l.nativeName),
                    ),
                ],
              ),
              IconButton(
                tooltip: tr('home.connect_pc'),
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
    if (_error == null && ps == null) {
      return Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const CircularProgressIndicator(),
          const SizedBox(height: 16),
          Text(tr('home.waiting_permission')),
        ]),
      );
    }
    if (_error != null || !ps!.hasAccess) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(tr('home.need_photos'), textAlign: TextAlign.center),
              if (_error != null) ...[
                const SizedBox(height: 8),
                Text(tr('home.permission_error', {'error': _error}),
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Theme.of(context).colorScheme.error, fontSize: 12)),
              ],
              const SizedBox(height: 16),
              FilledButton(
                onPressed: () async {
                  await PhotoManager.openSetting();
                },
                child: Text(tr('home.open_settings')),
              ),
              TextButton(onPressed: _reload, child: Text(tr('home.reload'))),
            ],
          ),
        ),
      );
    }
    return Column(
      children: [
        if (ps == PermissionState.limited)
          MaterialBanner(
            content: Text(tr('home.limited')),
            actions: [
              TextButton(
                onPressed: () async {
                  await PhotoManager.presentLimited();
                  await _reload();
                },
                child: Text(tr('home.select_more')),
              ),
            ],
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
          child: Row(
            children: [
              FilterChip(
                label: Text(tr('home.only_unsent')),
                selected: _onlyUnsent,
                onSelected: (v) => setState(() => _onlyUnsent = v),
              ),
              const Spacer(),
              TextButton(
                onPressed: () => setState(() {
                  _selected.addAll(_assets.where((a) => !sent.contains(a.id)).map((a) => a.id));
                }),
                child: Text(tr('home.select_unsent')),
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
              TextButton(onPressed: () => setState(_selected.clear), child: Text(tr('home.clear_selection'))),
            const Spacer(),
            FilledButton.icon(
              onPressed: _selected.isEmpty ? null : _send,
              icon: const Icon(Icons.send),
              label: Text(_selected.isEmpty ? tr('home.pick') : tr('home.send_n', {'count': _selected.length})),
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
