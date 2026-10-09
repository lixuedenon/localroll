// apps/mobile/lib/ui/home_page.dart
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:photo_manager/photo_manager.dart';

import '../l10n/l10n.dart';
import '../services/auto_sender.dart';
import '../services/discovery.dart';
import '../services/mobile_settings.dart';
import '../services/uploader.dart';
import 'cleanup_page.dart';
import 'connect_page.dart';
import 'device_badge.dart';
import 'settings_page.dart';
import 'theme.dart';
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

  /// Diagnostic line under the permission message (state + how we got it).
  String _diag = '';
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
    widget.discovery.addListener(_onDiscovery);
    _init();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.discovery.removeListener(_onDiscovery);
    _auto.dispose();
    super.dispose();
  }

  late final AutoSender _auto = AutoSender(widget.settings, widget.discovery);

  /// A paired PC showed up on the Wi-Fi: refresh its name / icon / picture,
  /// and send waiting photos if auto-send is on.
  void _onDiscovery() {
    refreshPairedLooks(widget.settings, widget.discovery.found);
    final d = widget.settings.current;
    if (_auto.state == AutoState.waiting && d != null && widget.discovery.found.any((f) => f.id == d.id)) {
      _auto.check();
    }
  }

  /// Back in the app: re-check photo access, and look for new photos to send.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    if (!(_permission?.hasAccess ?? false)) {
      _reload();
    } else {
      _auto.check();
    }
  }

  /// Switched in Settings.
  Future<void> _onAutoSendChanged() => _auto.check();

  /// Reverse signal: the PC deleted items that are still on this phone.
  Widget _lostBanner(BuildContext context) {
    final d = widget.settings.current;
    if (d == null) return const SizedBox.shrink();
    final lost = widget.settings.lostOn(d.id);
    if (lost.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      padding: const EdgeInsets.fromLTRB(14, 12, 8, 8),
      decoration: BoxDecoration(
        color: LrColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: LrColors.safelight),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            const Icon(Icons.warning_amber_rounded, color: LrColors.safelight, size: 20),
            const SizedBox(width: 10),
            Expanded(
              child: Text(tr('lost.title', {'count': lost.length, 'pc': d.name}), style: theme.textTheme.titleSmall),
            ),
          ]),
          const SizedBox(height: 4),
          Text(tr('lost.body'), style: theme.textTheme.bodySmall),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(onPressed: () => widget.settings.clearLost(d.id), child: Text(tr('lost.ignore'))),
              FilledButton.tonal(onPressed: () => _rebackupLost(d), child: Text(tr('lost.rebackup'))),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _rebackupLost(PairedDesktop d) async {
    final ids = widget.settings.lostOn(d.id).toList();
    final assets = <AssetEntity>[];
    for (final id in ids) {
      final a = await AssetEntity.fromId(id);
      if (a != null) assets.add(a);
    }
    // Deleted on the phone too: nothing to back up for those.
    await widget.settings.clearLost(d.id, ids.where((id) => !assets.any((a) => a.id == id)));
    if (!mounted || assets.isEmpty) return;
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => TransferPage(
        settings: widget.settings,
        discovery: widget.discovery,
        desktop: d,
        assets: assets,
      ),
    ));
  }

  /// Status line for auto-send (waiting / sending / sent).
  Widget _autoBanner(BuildContext context) {
    return ListenableBuilder(
      listenable: _auto,
      builder: (context, _) {
        final d = widget.settings.current;
        if (d == null || _auto.state == AutoState.idle) return const SizedBox.shrink();
        final theme = Theme.of(context);
        final up = _auto.uploader;
        final (IconData icon, Color color, String title, String? body) = switch (_auto.state) {
          AutoState.waiting => (
              Icons.cloud_off_rounded,
              LrColors.safelight,
              tr('auto.waiting', {'count': _auto.pending, 'pc': d.name}),
              tr('auto.waiting_hint'),
            ),
          AutoState.sending => (
              Icons.bolt_rounded,
              LrColors.safelight,
              tr('auto.sending', {'done': up?.doneCount ?? 0, 'total': _auto.pending, 'pc': d.name}),
              null,
            ),
          _ => (Icons.verified_rounded, LrColors.verified, tr('auto.done', {'count': _auto.lastSent, 'pc': d.name}), null),
        };
        return Container(
          margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
          padding: const EdgeInsets.fromLTRB(14, 12, 6, 12),
          decoration: BoxDecoration(
            color: LrColors.surface,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: color.withValues(alpha: 0.6)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                Icon(icon, color: color, size: 20),
                const SizedBox(width: 10),
                Expanded(child: Text(title, style: theme.textTheme.titleSmall)),
                if (_auto.state == AutoState.done)
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    onPressed: _auto.dismiss,
                    icon: const Icon(Icons.close_rounded, size: 18),
                  ),
              ]),
              if (body != null) ...[
                const SizedBox(height: 4),
                Text(body, style: theme.textTheme.bodySmall),
              ],
              if (_auto.state == AutoState.sending && up != null) ...[
                const SizedBox(height: 8),
                ListenableBuilder(
                  listenable: up,
                  builder: (context, _) {
                    final n = up.items.length;
                    final cur = up.items.where((i) => i.state == UploadState.uploading).firstOrNull;
                    final frac = n == 0 ? 0.0 : (up.doneCount + up.skippedCount + (cur?.fraction ?? 0)) / n;
                    return LinearProgressIndicator(value: frac.clamp(0.0, 1.0), minHeight: 4);
                  },
                ),
              ],
            ],
          ),
        );
      },
    );
  }

  Future<void> _init() async {
    if (mounted) setState(() => _error = null);
    PermissionState ps;
    try {
      // Ask for photos first and only then start LAN discovery: two system
      // permission prompts at once can leave one callback never firing on iOS.
      await _waitUntilForeground();
      final before = await PhotoManager.getPermissionState(requestOption: const PermissionRequestOption())
          .timeout(const Duration(seconds: 5));
      final sw = Stopwatch()..start();
      ps = await PhotoManager.requestPermissionExtend().timeout(const Duration(seconds: 20));
      _diag = 'before=${before.name} after=${ps.name} ${sw.elapsedMilliseconds}ms';
    } on TimeoutException {
      // The prompt never answered; read the current state instead of hanging.
      try {
        ps = await PhotoManager.getPermissionState(requestOption: const PermissionRequestOption());
        _diag = 'request timed out, state=${ps.name}';
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
      // Photos taken while the PC was off go out now.
      _auto.check();
    } catch (e) {
      _fail(e);
    }
  }

  /// iOS drops permission prompts requested before the scene is active, so
  /// wait (up to 5 s) until the app is really in the foreground.
  Future<void> _waitUntilForeground() async {
    final sw = Stopwatch()..start();
    while (WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed &&
        sw.elapsed < const Duration(seconds: 5)) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    // One more frame so the first screen is on display before the alert.
    await WidgetsBinding.instance.endOfFrame;
  }

  static const _diagChannel = MethodChannel('localroll/diag');

  /// iOS only: asks Apple's APIs directly, bypassing the plugins.
  Future<void> _nativeDiag() async {
    final out = StringBuffer();
    Future<void> step(String method) async {
      try {
        final r = await _diagChannel.invokeMethod<String>(method).timeout(const Duration(seconds: 15));
        out.writeln(r);
      } on TimeoutException {
        out.writeln('$method: no answer after 15 s');
      } catch (e) {
        out.writeln('$method: $e');
      }
      if (mounted) setState(() => _diag = out.toString().trim());
    }

    await step('info');
    await step('photos');
    await step('camera');
    await step('info');
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

  Future<void> _openCleanup(PairedDesktop desktop) async {
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => CleanupPage(settings: widget.settings, discovery: widget.discovery, desktop: desktop),
    ));
    // Deleted items disappear from the grid.
    if (mounted) await _reload();
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
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (desktop != null) ...[
                      DeviceBadge(
                        icon: desktop.icon,
                        color: desktop.color,
                        image: desktop.avatarUrl == null ? null : NetworkImage(desktop.avatarUrl!),
                        size: 18,
                      ),
                      const SizedBox(width: 6),
                    ],
                    Flexible(
                      child: Text(
                        desktop == null ? tr('home.not_connected') : tr('home.send_to', {'name': desktop.name}),
                        style: Theme.of(context).textTheme.bodySmall,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ],
            ),
            actions: [
              IconButton(
                tooltip: tr('settings.title'),
                onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => SettingsPage(
                    settings: widget.settings,
                    discovery: widget.discovery,
                    onAutoSendChanged: _onAutoSendChanged,
                  ),
                )),
                icon: const Icon(Icons.settings_rounded),
              ),
              if (desktop != null)
                IconButton(
                  tooltip: tr('home.cleanup'),
                  onPressed: () => _openCleanup(desktop),
                  icon: const Icon(Icons.cleaning_services_rounded),
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
              if (_diag.isNotEmpty) ...[
                const SizedBox(height: 8),
                SelectableText(_diag, textAlign: TextAlign.center, style: Theme.of(context).textTheme.bodySmall),
              ],
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
              // Debug aid while the iOS permission prompt issue is open.
              if (Platform.isIOS) TextButton(onPressed: _nativeDiag, child: const Text('Diagnostics')),
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
        _lostBanner(context),
        _autoBanner(context),
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
