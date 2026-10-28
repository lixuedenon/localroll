// apps/mobile/lib/ui/home_page.dart
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart' show FilePicker, PlatformFile;
import 'package:flutter/material.dart';
import 'package:localroll_core/localroll_core.dart';
import 'package:photo_manager/photo_manager.dart';

import '../l10n/l10n.dart';
import '../services/auto_sender.dart';
import '../services/discovery.dart';
import '../services/file_sender.dart';
import '../services/live_service.dart';
import '../services/mobile_settings.dart';
import '../services/phone_names.dart';
import 'phone_name_dialog.dart';
import '../services/my_library.dart';
import '../services/phone_server.dart';
import '../services/uploader.dart';
import '../services/background_transfer.dart';
import '../services/backup_plan.dart';
import 'backup_page.dart';
import 'cleanup_page.dart';
import 'connect_page.dart';
import 'device_badge.dart';
import 'device_strip.dart';
import 'incoming.dart';
import 'lost_notice.dart';
import 'my_library_page.dart';
import 'phone_photo_viewer.dart';
import 'document_scan_page.dart';
import 'send_files_page.dart';
import 'pc_library_page.dart';
import 'presence_toasts.dart';
import 'send_target.dart';
import 'settings_page.dart';
import 'simple_home.dart';
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

  /// Simple mode: browsing the full grid for a moment ("Pick photos").
  bool _browse = false;

  /// Bottom navigation: 0 Home, 1 Photos, 2 Free up space, 3 PC.
  int _tab = 0;

  /// Home: what is not on the PC yet, and how much cleanup could free.
  BackupPlan? _pending;
  int _freeable = -1;
  bool _counting = false;
  final Map<String, Future<Uint8List?>> _thumbs = {};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // First start: the phone's own name, and a word that it can be renamed.
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_firstName()));
    widget.discovery.addListener(_onDiscovery);
    widget.settings.addListener(_onSettings);
    _liveEvents = _live.events.listen((e) {
      if (mounted) _note(e.id, e.name, pc: e.pc, online: e.online);
    });
    // The PC says photos were deleted there: ask it now ("not backed up any
    // more" shows without a pull-down).
    _lostSub = widget.settings.lostAdded.listen(_onLostNews);
    _live.onChanged = (pcId) {
      if (mounted) unawaited(refreshPairedLooks(widget.settings, widget.discovery, now: true, only: pcId));
    };
    // Every device is equal: this phone can receive while LocalRoll is open.
    // The receiver starts first, so the PCs learn where to send right away.
    widget.discovery.selfId = widget.settings.deviceId;
    _server.asks.addListener(_onAsks);
    _receivedSub = _server.finished.listen((r) {
      if (mounted) unawaited(showReceived(context, r, onOpen: _openMyLibrary));
    });
    _live.receiveInfo = (pcId) => {
          if (_server.running) 'rport': '${_server.port}',
          if (_server.fingerprint != null) 'rfp': _server.fingerprint!,
          // The secret this PC shows when it sends here — only over an
          // encrypted link.
          if (_server.running && widget.settings.byId(pcId)?.fingerprint != null) 'rtk': _server.receiveTokenFor(pcId),
        };
    _queue(_comeBack);
    _lastDesktop = widget.settings.current?.id;
    _lastLost = _lostCount();
    // Ask the PC now and then what was deleted there (not only when it
    // re-appears on the Wi-Fi), so the phone notices without a restart.
    _changesTimer = Timer.periodic(const Duration(seconds: 20), (_) {
      if (WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed) {
        refreshPairedLooks(widget.settings, widget.discovery);
        _checkPresence(); // "went offline" also when nothing else changes
        // On screen but not receiving / not linked (start failed earlier):
        // set it up again.
        if (!_saidBye && (!_server.running || !_live.running)) _queue(_comeBack);
      }
    });
    // "I'm here" every 10 s while on screen (one small request per PC).
    _beatTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      if (WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed) {
        unawaited(heartbeat(widget.settings, widget.discovery));
      }
    });
    _init();
    unawaited(MyLibrary.instance.load().then((_) {
      if (mounted) setState(() {});
    }));
  }

  String? _lastDesktop;
  int _lastLost = 0;
  Timer? _changesTimer;
  Timer? _beatTimer;

  int _lostCount() {
    final d = widget.settings.current;
    return d == null ? 0 : widget.settings.lostOn(d.id).length;
  }

  /// Another PC chosen, or the PC reported deletions: count again.
  void _onSettings() {
    _live.sync(); // a PC paired or forgotten
    final id = widget.settings.current?.id;
    final lost = _lostCount();
    if (id != _lastDesktop || lost != _lastLost) {
      _lastDesktop = id;
      _lastLost = lost;
      unawaited(_refreshHome());
    }
  }

  Future<void> _firstName() async {
    if (!await PhoneNames.firstStart(widget.settings, widget.discovery) || !mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      duration: const Duration(seconds: 10),
      content: Text(tr('phone.first_hint', {'name': widget.settings.deviceName})),
      action: SnackBarAction(
        label: tr('phone.rename'),
        onPressed: () => unawaited(editPhoneName(context, widget.settings, widget.discovery)),
      ),
    ));
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.discovery.removeListener(_onDiscovery);
    widget.settings.removeListener(_onSettings);
    _changesTimer?.cancel();
    _beatTimer?.cancel();
    _liveEvents?.cancel();
    _lostSub?.cancel();
    unawaited(_live.stop());
    _server.asks.removeListener(_onAsks);
    _receivedSub?.cancel();
    unawaited(_server.stop());
    _auto.dispose();
    super.dispose();
  }

  late final AutoSender _auto = AutoSender(widget.settings, widget.discovery);

  /// A paired PC showed up on the Wi-Fi: refresh its name / icon / picture,
  /// and send waiting photos if auto-send is on.
  /// Devices online last time we looked, id -> (name, is a PC); null = not
  /// looked yet (no notes for what was already there when the app opened).
  Map<String, (String, bool)>? _onlineNow;

  /// "X is online / went offline" — older PCs without live links only
  /// (compared now and then); everything else comes from [_live] events.
  void _checkPresence() {
    if (!mounted) return;
    final now = {
      for (final d in widget.settings.desktops)
        if (!widget.discovery.linked(d.id) && widget.discovery.isOnline(d.id)) d.id: (d.name, true),
    };
    final before = _onlineNow;
    _onlineNow = now;
    // Just came on: what we find now was already there.
    if (before == null || _live.quiet) {
      now.keys.forEach(_live.markSeen);
      return;
    }
    for (final id in now.keys) {
      if (!before.containsKey(id) && !widget.discovery.linked(id) && _live.announceOnline(id)) {
        _note(id, now[id]!.$1, pc: true, online: true);
      }
    }
    for (final id in before.keys) {
      if (!now.containsKey(id) && !widget.discovery.linked(id)) _note(id, before[id]!.$1, pc: true, online: false);
    }
  }

  /// One note per device; a newer one about the same device replaces it.
  void _note(String id, String name, {required bool pc, required bool online}) {
    final overlay = Navigator.maybeOf(context)?.overlay;
    if (overlay == null || name.isEmpty) return;
    PresenceToasts.show(
      overlay,
      key: id,
      text: tr(online ? 'presence.online' : 'presence.offline', {'name': name}),
      icon: pc ? Icons.computer_rounded : Icons.smartphone_rounded,
      online: online,
    );
  }

  /// Receiving (from phones and PCs nearby).
  late final PhoneServer _server = PhoneServer(widget.settings);
  StreamSubscription<Receiving>? _receivedSub;
  final Set<IncomingAsk> _shownAsks = {};
  IncomingAsk? _openAsk;

  /// Someone wants to send: ask (one dialog at a time, in order).
  Future<void> _onAsks() async {
    if (_openAsk != null || !mounted) return;
    final next = _server.asks.value.where((a) => !_shownAsks.contains(a)).firstOrNull;
    if (next == null) return;
    _shownAsks.add(next);
    _openAsk = next;
    // Answered elsewhere / timed out: close the dialog.
    unawaited(next.answer.future.then((_) {
      if (_openAsk == next && mounted) Navigator.of(context, rootNavigator: true).maybePop();
    }));
    final reply = await askIncoming(context, next);
    _openAsk = null;
    _server.answer(next, reply);
    if (mounted) unawaited(_onAsks());
  }

  /// Live links to the paired PCs (online state and notes).
  late final LiveService _live = LiveService(widget.settings, widget.discovery);
  StreamSubscription<PresenceEvent>? _liveEvents;

  void _onDiscovery() {
    _checkPresence();
    _live.kick();
    refreshPairedLooks(widget.settings, widget.discovery);
    final d = widget.settings.current;
    if (_auto.state == AutoState.waiting && d != null && widget.discovery.found.any((f) => f.id == d.id)) {
      _auto.check();
    }
  }

  /// Pull-down on Home: ask the PCs what changed there now (not only once a
  /// minute), then count again.
  Future<void> _pullDown() async {
    await refreshPairedLooks(widget.settings, widget.discovery, now: true);
    await _refreshHome();
  }

  /// Back in the app: re-check photo access, and look for new photos to send.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Leaving the app: "I'm leaving" (unless a transfer keeps going in the
    // background — then the phone is still talking to the PC).
    // "hidden" comes first (as soon as the app leaves the screen); "paused"
    // as a fallback. Once per leaving.
    if ((state == AppLifecycleState.hidden || state == AppLifecycleState.paused) && !BackgroundTransfer.active) {
      if (!_saidBye) {
        _saidBye = true;
        _queue(_goodbye);
      }
      return;
    }
    if (state != AppLifecycleState.resumed) return;
    // Back: "I'm here" at once.
    final back = _saidBye;
    _saidBye = false;
    if (back) _queue(_comeBack);
    if (!(_permission?.hasAccess ?? false)) {
      _reload();
      if (back) refreshPairedLooks(widget.settings, widget.discovery, now: true);
    } else {
      _auto.check();
      refreshPairedLooks(widget.settings, widget.discovery, now: back);
      unawaited(_refreshHome());
    }
  }

  bool _saidBye = false;

  /// Leaving and coming back run one after the other, never interleaved:
  /// coming back quickly must not end with the links closed and the
  /// receiver stopped while the app is on screen (the PC then sees the
  /// phone as "online" from its check-ins but can't send to it).
  Future<void> _lifecycle = Future.value();
  void _queue(Future<void> Function() step) {
    _lifecycle = _lifecycle.then((_) => step()).catchError((Object e) {
      debugPrint('lifecycle: $e');
    });
  }

  /// On screen: receiver up first (its port goes with the live links), then
  /// the live links. If the receiver came up only now, links opened
  /// without it are reopened so the PCs learn where to send.
  Future<void> _comeBack() async {
    if (_saidBye || !mounted) return; // left again meanwhile
    final had = _server.running;
    await _server.start();
    if (_saidBye || !mounted) return;
    if (!had && _server.running && _live.running) await _live.stop();
    if (!_live.running) _live.start();
  }

  Future<void> _goodbye() async {
    if (!_saidBye) return; // already back: nothing to say
    await BackgroundTransfer.grace(true); // iPhone: a few seconds to say it
    if (!_saidBye) {
      await BackgroundTransfer.grace(false);
      return;
    }
    try {
      // Closing the live links is the goodbye; older PCs get a message.
      await Future.wait([
        _live.stop(),
        sayBye(widget.settings, widget.discovery),
        // Not visible to nearby phones while away (unless something is arriving).
        if (!_server.busy) _server.stop(),
      ]);
    } finally {
      // Coming back later is a new visit (announced even if this goodbye
      // never arrived).
      widget.discovery.newSession();
      await BackgroundTransfer.grace(false);
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
        border: Border.all(color: LrColors.safelight, width: 1.5),
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
          const SizedBox(height: 8),
          LostThumbs(ids: lost.toList()),
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

  /// Just deleted on a PC: say so clearly, with the pictures (one notice at
  /// a time; news arriving meanwhile is added to the next one).
  StreamSubscription<LostNews>? _lostSub;
  final Map<String, List<String>> _lostWaiting = {};
  bool _lostShowing = false;

  void _onLostNews(LostNews n) {
    (_lostWaiting[n.desktopId] ??= []).addAll(n.ids);
    unawaited(_showLostNews());
  }

  Future<void> _showLostNews() async {
    if (_lostShowing || !mounted || _lostWaiting.isEmpty) return;
    final pcId = _lostWaiting.keys.first;
    final ids = _lostWaiting.remove(pcId)!.toSet().toList();
    final d = widget.settings.byId(pcId);
    // Still lost (not re-sent or dismissed meanwhile).
    final still = d == null ? const <String>[] : ids.where(widget.settings.lostOn(pcId).contains).toList();
    if (d == null || still.isEmpty) return _showLostNews();
    _lostShowing = true;
    try {
      final again = await showLostNotice(context, pc: d.name, ids: still);
      if (again && mounted) await _rebackupLost(d, only: still);
    } finally {
      _lostShowing = false;
    }
    if (mounted) unawaited(_showLostNews());
  }

  Future<void> _rebackupLost(PairedDesktop d, {List<String>? only}) async {
    final ids = only ?? widget.settings.lostOn(d.id).toList();
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
          AutoState.guest => (
              Icons.lock_clock_rounded,
              LrColors.safelight,
              tr('auto.guest', {'count': _auto.pending, 'pc': d.name}),
              tr('auto.guest_hint'),
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

  /// Android 10+ removes the GPS position from photos handed to apps unless
  /// "media location" access is asked for too — ask, so originals arrive on
  /// the PC with their location (iPhone always includes it).
  static const PermissionRequestOption _permissionOption = PermissionRequestOption(
    androidPermission: AndroidPermission(type: RequestType.common, mediaLocation: true),
  );

  Future<void> _init() async {
    if (mounted) setState(() => _error = null);
    PermissionState ps;
    try {
      // Ask for photos first and only then start LAN discovery: two system
      // permission prompts at once can leave one callback never firing on iOS.
      await _waitUntilForeground();
      final before = await PhotoManager.getPermissionState(requestOption: _permissionOption)
          .timeout(const Duration(seconds: 5));
      final sw = Stopwatch()..start();
      ps = await PhotoManager.requestPermissionExtend(requestOption: _permissionOption).timeout(const Duration(seconds: 20));
      _diag = 'before=${before.name} after=${ps.name} ${sw.elapsedMilliseconds}ms';
    } on TimeoutException {
      // The prompt never answered; read the current state instead of hanging.
      try {
        ps = await PhotoManager.getPermissionState(requestOption: _permissionOption);
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
      unawaited(_refreshHome());
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
    unawaited(_refreshHome());
  }

  /// Counts for the Home tab (whole library, in the background).
  /// Asked again while counting (e.g. the PC reported deletions): count
  /// once more when done, so nothing is missed.
  bool _countAgain = false;

  Future<void> _refreshHome() async {
    if (!(_permission?.hasAccess ?? false)) return;
    if (_counting) {
      _countAgain = true;
      if (mounted) setState(() {}); // the "not backed up any more" banner
      return;
    }
    final d = widget.settings.current;
    setState(() => _counting = true);
    try {
      // No PC yet: everything is "not backed up".
      final sent = d == null ? <String>{} : widget.settings.sentTo(d.id);
      final plan = await BackupPlanner.plan(BackupFilter(), sent);
      final sizes = sent.isEmpty ? const <String, int>{} : await BackgroundTransfer.originalSizes(sent.toList());
      if (!mounted) return;
      setState(() {
        _pending = plan;
        _freeable = sizes.values.fold<int>(0, (a, b) => a + b);
      });
    } catch (_) {
    } finally {
      if (mounted) setState(() => _counting = false);
    }
    if (_countAgain && mounted) {
      _countAgain = false;
      await _refreshHome();
    }
  }

  void _selectTab(int i) {
    setState(() {
      _tab = i;
      if (i != 1) _sendTarget = null; // a chosen target is for this one visit
    });
    if (i == 0) unawaited(_refreshHome());
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

  /// "My files": what arrived here, by sender.
  void _openMyLibrary() => _selectTab(2);

  /// Scan paper into a PDF, then send / share / keep it.
  Future<void> _openScan() => Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => DocumentScanPage(settings: widget.settings, discovery: widget.discovery),
      ));

  Future<void> _openCleanup(PairedDesktop desktop) async {
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => CleanupPage(settings: widget.settings, discovery: widget.discovery, desktop: desktop),
    ));
    // Deleted items disappear from the grid.
    if (mounted) await _reload();
  }

  Future<void> _openSettings() => Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => SettingsPage(
          settings: widget.settings,
          discovery: widget.discovery,
          onAutoSendChanged: _onAutoSendChanged,
        ),
      ));

  /// Family group: change who may see already-sent items.
  Future<void> _setVisibility(List<String> ids, {required bool private}) async {
    final desktop = widget.settings.current;
    if (desktop == null || ids.isEmpty) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      final client = await connectToDesktop(widget.settings, desktop, discovered: widget.discovery.found);
      try {
        await client.setVisibility(ids, private: private);
      } finally {
        client.close();
      }
      if (!mounted) return;
      setState(_selected.clear);
      messenger.showSnackBar(SnackBar(
        content: Text(tr(private ? 'family.now_private' : 'family.now_shared', {'count': ids.length})),
      ));
    } catch (_) {
      messenger.showSnackBar(SnackBar(content: Text(tr('family.visibility_failed', {'pc': desktop.name}))));
    }
  }

  /// "Back up…": choose what and when to stop (whole library by default).
  Future<void> _backupAll() async {
    final desktop = widget.settings.current;
    if (desktop == null) {
      await _openConnect();
      return;
    }
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => BackupPage(settings: widget.settings, discovery: widget.discovery, desktop: desktop),
    ));
  }

  Future<void> _send() async {
    var desktop = widget.settings.current;
    final chosen = _assets.where((a) => _selected.contains(a.id)).toList();
    if (chosen.isEmpty) return;
    NearbyPhone? phone;
    final preset = _sendTarget;
    if (preset is PairedDesktop) {
      desktop = preset;
    } else if (preset is NearbyPhone) {
      phone = preset;
      desktop = PairedDesktop(id: preset.id, name: preset.name, hosts: preset.hosts, port: preset.port, token: '');
    } else if (widget.discovery.phones.isNotEmpty || desktop == null || widget.settings.desktops.length > 1) {
      // Phones nearby, two PCs (or no PC yet): ask where to.
      if (desktop == null && widget.discovery.phones.isEmpty) {
        await _openConnect();
        return;
      }
      final target = await chooseSendTarget(context, widget.settings, widget.discovery);
      if (!mounted || target == null) return;
      if (target is NearbyPhone) {
        phone = target;
        desktop = PairedDesktop(id: target.id, name: target.name, hosts: target.hosts, port: target.port, token: '');
      } else if (target is PairedDesktop) {
        desktop = target;
      }
    }
    if (desktop == null) return;
    final to = desktop;
    final finished = await Navigator.of(context).push<bool>(MaterialPageRoute(
      builder: (_) => TransferPage(
        settings: widget.settings,
        discovery: widget.discovery,
        desktop: to,
        assets: chosen,
        phone: phone,
      ),
    ));
    if (finished == true && mounted) {
      setState(() {
        _selected.clear();
        _sendTarget = null;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      // Discovery too: online dots and "online now" follow it.
      listenable: Listenable.merge([widget.settings, widget.discovery]),
      builder: (context, _) {
        final desktop = widget.settings.current;
        final sent = desktop == null ? const <String>{} : widget.settings.sentTo(desktop.id);
        final visible = _onlyUnsent ? _assets.where((a) => !sent.contains(a.id)).toList() : _assets;
        if (widget.settings.simpleMode && !_browse) {
          return SimpleHome(
            settings: widget.settings,
            auto: _auto,
            onConnect: _openConnect,
            onSettings: _openSettings,
            onPick: () => setState(() {
              _browse = true;
              _onlyUnsent = true;
            }),
            devices: DeviceStrip(
              settings: widget.settings,
              discovery: widget.discovery,
              onTap: _onDevice,
              onAdd: _openConnect,
              big: true,
            ),
          );
        }
        if (widget.settings.simpleMode) return _photos(context, desktop, sent, visible);
        return Scaffold(
          body: switch (_tab) {
            0 => _home(context, desktop),
            1 => _photos(context, desktop, sent, visible),
            2 => MyLibraryPage(settings: widget.settings, discovery: widget.discovery),
            _ => _pcTabPage(context),
          },
          bottomNavigationBar: NavigationBar(
            selectedIndex: _tab,
            onDestinationSelected: _selectTab,
            destinations: [
              NavigationDestination(icon: const Icon(Icons.home_outlined), selectedIcon: const Icon(Icons.home_rounded), label: tr('nav.home')),
              NavigationDestination(
                  icon: const Icon(Icons.photo_library_outlined), selectedIcon: const Icon(Icons.photo_library_rounded), label: tr('nav.photos')),
              NavigationDestination(
                  icon: const Icon(Icons.folder_outlined), selectedIcon: const Icon(Icons.folder_rounded), label: tr('nav.files')),
              NavigationDestination(icon: const Icon(Icons.computer_outlined), selectedIcon: const Icon(Icons.computer_rounded), label: tr('nav.pc')),
            ],
          ),
        );
      },
    );
  }

  /// "PC" tab: the PC's library (the backup PC, or the one picked at the
  /// top); no PC yet: pair one.
  Widget _pcTabPage(BuildContext context) {
    final pcs = widget.settings.desktops;
    final pc = (_pcTab == null ? null : widget.settings.byId(_pcTab!)) ?? widget.settings.current ?? pcs.firstOrNull;
    if (pc == null) {
      return ConnectPage(settings: widget.settings, discovery: widget.discovery, onDone: () => _selectTab(0));
    }
    return PcLibraryPage(
      key: ValueKey('pclib-${pc.id}'),
      settings: widget.settings,
      discovery: widget.discovery,
      desktop: pc,
      server: _server,
      onSwitch: pcs.length < 2
          ? null
          : () async {
              final id = await showModalBottomSheet<String>(
                context: context,
                showDragHandle: true,
                builder: (c) => SafeArea(
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    for (final d in pcs)
                      ListTile(
                        leading: DeviceBadge(
                          icon: d.icon,
                          color: d.color,
                          image: d.avatarUrl == null ? null : NetworkImage(d.avatarUrl!),
                          size: 36,
                        ),
                        title: Text(d.name),
                        subtitle: Text(tr(widget.discovery.isOnline(d.id) ? 'home.pc_online' : 'home.pc_offline')),
                        trailing: d.id == pc.id ? const Icon(Icons.check_rounded, color: LrColors.safelight) : null,
                        onTap: () => Navigator.pop(c, d.id),
                      ),
                  ]),
                ),
              );
              if (id != null && mounted) setState(() => _pcTab = id);
            },
    );
  }

  Widget _photos(BuildContext context, PairedDesktop? desktop, Set<String> sent, List<AssetEntity> visible) {
    return Scaffold(
          appBar: AppBar(
            // Simple mode: a clear way back from the photo grid.
            leading: widget.settings.simpleMode
                ? IconButton(
                    onPressed: () => setState(() {
                      _browse = false;
                      _selected.clear();
                    }),
                    icon: const Icon(Icons.arrow_back_rounded),
                  )
                : null,
            title: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(widget.settings.simpleMode ? appName : tr('photos.title')),
                // Simple mode picks photos to send: where to stays in sight.
                if (widget.settings.simpleMode || _sendTarget != null) Row(
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
                        switch (_sendTarget) {
                          PairedDesktop p => tr('home.send_to', {'name': p.name}),
                          NearbyPhone p => tr('home.send_to', {'name': p.name}),
                          _ => desktop == null ? tr('home.not_connected') : tr('home.send_to', {'name': desktop.name}),
                        },
                        style: Theme.of(context).textTheme.bodySmall,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ],
            ),
            actions: [
              if (!widget.settings.simpleMode && _selected.isEmpty)
                TextButton(onPressed: () => setState(() => _choosing = true), child: Text(tr('photos.select'))),
              if (!widget.settings.simpleMode)
                PopupMenuButton<String>(
                  onSelected: (v) {
                    if (v == 'deleted') _whereDeleted();
                  },
                  itemBuilder: (_) => [
                    PopupMenuItem(
                      value: 'deleted',
                      child: ListTile(leading: const Icon(Icons.history_rounded), title: Text(tr('photos.find_deleted'))),
                    ),
                  ],
                ),
              IconButton(
                tooltip: tr('settings.title'),
                onPressed: _openSettings,
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
          // Browsing: the bar comes when something is chosen.
          bottomNavigationBar: _assets.isEmpty || (!widget.settings.simpleMode && _selected.isEmpty && !_choosing)
              ? null
              : _bottomBar(context, visible, sent),
        );
  }

  /// "Select" pressed on the Photos tab: a tap chooses until done.
  bool _choosing = false;

  /// Full screen: swipe through; send or delete from there.
  Future<void> _view(List<AssetEntity> visible, int index, Set<String> sent) async {
    final r = await Navigator.of(context).push<(PhotoAction, String)>(MaterialPageRoute(
      builder: (_) => PhonePhotoViewer(assets: visible, start: index, sent: sent),
    ));
    if (r == null || !mounted) return;
    final (action, id) = r;
    if (action == PhotoAction.send) {
      setState(() => _selected
        ..clear()
        ..add(id));
      await _send();
    } else {
      await _deletePhotos([id]);
    }
  }

  /// Deletes from this phone's photos (the system asks first); they go to
  /// the system's own "Recently Deleted".
  Future<void> _deletePhotos(List<String> ids) async {
    if (ids.isEmpty) return;
    try {
      final gone = (await removeFromPhone(ids)).ids;
      if (!mounted || gone.isEmpty) return;
      setState(() {
        _selected.removeAll(gone);
        if (_selected.isEmpty) _choosing = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('photos.deleted_hint', {'count': gone.length}))));
      await _reload();
    } catch (e) {
      DiagLog.error('photos', e);
    }
  }

  /// Where deleted photos are, in the system's own app.
  void _whereDeleted() => showDialog<void>(
        context: context,
        builder: (c) => AlertDialog(
          icon: const Icon(Icons.history_rounded),
          title: Text(tr('photos.find_deleted')),
          content: Text(tr(Platform.isIOS ? 'photos.find_deleted_ios' : 'photos.find_deleted_android')),
          actions: [FilledButton(onPressed: () => Navigator.pop(c), child: Text(tr('common.ok')))],
        ),
      );

  /// Home: the devices (one row), what still needs backing up, three
  /// actions, notices when there are any, and what arrived lately.
  Widget _home(BuildContext context, PairedDesktop? d) {
    final theme = Theme.of(context);
    final last = d == null ? null : widget.settings.lastBackup(d.id);
    final pending = _pending;
    Widget action(IconData icon, String title, String sub, VoidCallback onTap, {Color? color}) => Expanded(
          child: Material(
            color: LrColors.surface,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: const BorderSide(color: LrColors.line)),
            child: InkWell(
              borderRadius: BorderRadius.circular(16),
              onTap: onTap,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 6),
                child: Column(children: [
                  Icon(icon, color: color ?? LrColors.safelight, size: 26),
                  const SizedBox(height: 6),
                  Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
                  const SizedBox(height: 2),
                  Text(sub,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 11.5, color: color ?? LrColors.muted)),
                ]),
              ),
            ),
          ),
        );
    return Scaffold(
      appBar: AppBar(
        title: const Text(appName),
        actions: [
          IconButton(tooltip: tr('settings.title'), onPressed: _openSettings, icon: const Icon(Icons.settings_rounded)),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _pullDown,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
          children: [
            DeviceStrip(settings: widget.settings, discovery: widget.discovery, onTap: _onDevice, onAdd: _openConnect),
            ReceivingBanner(server: _server),
            _lostBanner(context),
            _autoBanner(context),
            const SizedBox(height: 14),
            // What is not on the backup PC yet.
            Container(
              padding: const EdgeInsets.fromLTRB(18, 16, 18, 6),
              decoration: BoxDecoration(
                color: LrColors.raised,
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: LrColors.line),
              ),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(d == null ? tr('home.not_connected') : tr('home.not_backed_up_to', {'pc': d.name}),
                    style: const TextStyle(color: LrColors.muted)),
                const SizedBox(height: 6),
                if (pending == null)
                  Row(children: [
                    const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
                    const SizedBox(width: 10),
                    Text(tr('home.counting')),
                  ])
                else
                  Text.rich(TextSpan(children: [
                    TextSpan(
                      text: tr('home.items', {'count': pending.assets.length}),
                      style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700),
                    ),
                    if (pending.sizesKnown && pending.totalBytes > 0)
                      TextSpan(text: '  ${tr('home.about', {'size': formatSize(pending.totalBytes)})}', style: const TextStyle(color: LrColors.muted)),
                  ])),
                if (last != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    tr('home.last_backup', {
                      'when': MaterialLocalizations.of(context).formatShortDate(last.time),
                      'time': TimeOfDay.fromDateTime(last.time).format(context),
                      'count': last.count,
                    }),
                    style: const TextStyle(color: LrColors.muted, fontSize: 13),
                  ),
                ],
                const SizedBox(height: 14),
                Row(children: [
                  Expanded(
                    child: SizedBox(
                      height: 50,
                      // The height is set here: no padding of its own on top
                      // (iPhone's Chinese font is taller and was cut off).
                      child: FilledButton(
                        style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 12)),
                        onPressed: d == null ? _openConnect : _backupNow,
                        child: Text(tr(d == null ? 'home.connect_pc' : 'home.backup_now'),
                            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                      ),
                    ),
                  ),
                  if (d != null) ...[
                    const SizedBox(width: 8),
                    SizedBox(
                      height: 50,
                      child: OutlinedButton(
                        style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 14)),
                        onPressed: () async {
                          await _backupAll();
                          unawaited(_refreshHome());
                        },
                        child: Text(tr('home.backup_choose')),
                      ),
                    ),
                  ],
                ]),
                const SizedBox(height: 6),
                const Divider(height: 18),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  value: widget.settings.autoSend,
                  title: Text(tr('home.auto_new'), style: const TextStyle(fontSize: 14)),
                  onChanged: d == null
                      ? null
                      : (on) async {
                          await widget.settings.setAutoSend(on);
                          await _onAutoSendChanged();
                        },
                ),
              ]),
            ),
            const SizedBox(height: 12),
            Row(children: [
              action(Icons.send_rounded, tr('home.act_send'), tr('home.act_send_sub'), () => _startSend()),
              const SizedBox(width: 10),
              action(Icons.document_scanner_rounded, tr('home.tile_scan'), tr('home.tile_scan_sub'), _openScan),
              const SizedBox(width: 10),
              action(
                Icons.cleaning_services_rounded,
                tr('home.cleanup'),
                _freeable > 0 ? tr('home.tile_free_sub', {'size': formatSize(_freeable)}) : tr('home.tile_free_none'),
                d == null ? _openConnect : () => _openCleanup(d),
                color: _freeable > 0 ? LrColors.verified : null,
              ),
            ]),
            _recentStrip(context),
          ],
        ),
      ),
    );
  }

  /// "Recently received": the latest few from My files.
  Widget _recentStrip(BuildContext context) {
    final items = MyLibrary.instance.items.take(4).toList();
    if (items.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 18),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: Text(tr('home.recent'), style: const TextStyle(fontWeight: FontWeight.w700))),
          TextButton(onPressed: () => _selectTab(2), child: Text(tr('home.recent_all'))),
        ]),
        Row(children: [
          for (var k = 0; k < 4; k++) ...[
            if (k > 0) const SizedBox(width: 6),
            Expanded(
              child: AspectRatio(
                aspectRatio: 1,
                child: k < items.length
                    ? InkWell(
                        borderRadius: BorderRadius.circular(10),
                        onTap: () => _selectTab(2),
                        child: ClipRRect(borderRadius: BorderRadius.circular(10), child: MyItemThumb(item: items[k])),
                      )
                    : const SizedBox.shrink(),
              ),
            ),
          ],
        ]),
      ]),
    );
  }

  /// Back up now: everything not on the backup PC yet, no questions.
  Future<void> _backupNow() async {
    final d = widget.settings.current;
    final pending = _pending;
    if (d == null) return _openConnect();
    if (pending == null || pending.assets.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('home.all_backed_up'))));
      return;
    }
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => TransferPage(settings: widget.settings, discovery: widget.discovery, desktop: d, assets: pending.assets),
    ));
    if (mounted) unawaited(_refreshHome());
  }

  /// A device chip tapped: its card, then what was chosen.
  Future<void> _onDevice(StripDevice dev) async {
    final a = await showDeviceSheet(context, dev, isBackupPc: dev.id == widget.settings.current?.id);
    if (a == null || !mounted) return;
    final target = dev.pc ?? dev.phone;
    switch (a) {
      case DeviceAction.sendPhotos:
        _sendPhotosTo(target);
      case DeviceAction.sendFiles:
        if (target != null) await _sendFilesTo(target);
      case DeviceAction.browse:
        final pc = dev.pc;
        if (pc == null) break;
        if (widget.settings.simpleMode) {
          await Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => PcLibraryPage(settings: widget.settings, discovery: widget.discovery, desktop: pc, server: _server),
          ));
        } else {
          setState(() => _pcTab = pc.id);
          _selectTab(3);
        }
      case DeviceAction.makeBackup:
        await widget.settings.selectDesktop(dev.id);
        if (mounted) unawaited(_refreshHome());
      case DeviceAction.settings:
        await _openConnect();
    }
  }

  /// "Send": what, then to whom.
  Future<void> _startSend() async {
    final r = await showSendSheet(context, widget.settings, widget.discovery);
    if (r == null || !mounted) return;
    final (kind, target) = r;
    switch (kind) {
      case SendKind.photos:
        _sendPhotosTo(target);
      case SendKind.files:
        if (target != null) await _sendFilesTo(target);
      case SendKind.scan:
        await _openScan();
    }
  }

  /// To the photo grid, ready to pick; "Send" there goes to [target].
  void _sendPhotosTo(Object? target) {
    setState(() {
      _sendTarget = target;
      _selected.clear();
      if (widget.settings.simpleMode) {
        _browse = true;
        _onlyUnsent = false;
      }
    });
    if (!widget.settings.simpleMode) _selectTab(1);
    final name = switch (target) {
      PairedDesktop p => p.name,
      NearbyPhone p => p.name,
      _ => null,
    };
    if (name != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('home.pick_for', {'name': name}))));
    }
  }

  /// Pick files, send them to [target] (a PC or a phone).
  Future<void> _sendFilesTo(Object target) async {
    final picked = await FilePicker.platform.pickFiles(allowMultiple: true);
    final files = [
      for (final f in picked?.files ?? const <PlatformFile>[])
        if (f.path != null) File(f.path!),
    ];
    if (files.isEmpty || !mounted) return;
    final sender = FileSender(
      settings: widget.settings,
      discovery: widget.discovery,
      files: files,
      desktop: target is PairedDesktop ? target : null,
      phone: target is NearbyPhone ? target : null,
    );
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => SendFilesPage(sender: sender)));
  }

  /// Chosen from a device card or the Send sheet: where the photo grid's
  /// "Send" goes (once).
  Object? _sendTarget;

  /// The PC shown in the "PC" tab (null: the backup PC).
  String? _pcTab;

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
              // The whole library, not just what is loaded on screen.
              FilledButton.tonalIcon(
                onPressed: _backupAll,
                icon: const Icon(Icons.backup_rounded, size: 18),
                label: Text(tr('home.backup_more')),
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
                itemBuilder: (context, i) => _tile(visible[i], sent.contains(visible[i].id), () => _view(visible, i, sent)),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _tile(AssetEntity a, bool alreadySent, VoidCallback open) {
    final selected = _selected.contains(a.id);
    final scheme = Theme.of(context).colorScheme;
    void toggle() => setState(() {
          selected ? _selected.remove(a.id) : _selected.add(a.id);
          if (_selected.isEmpty) _choosing = false;
        });
    // Tap: look at it (choosing: pick it). Long press: start choosing.
    // Simple mode picks photos to send: a tap picks.
    final picking = widget.settings.simpleMode || _choosing || _selected.isNotEmpty;
    return GestureDetector(
      onTap: picking ? toggle : open,
      onLongPress: toggle,
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
            if (_selected.isNotEmpty || _choosing)
              TextButton(
                  onPressed: () => setState(() {
                        _selected.clear();
                        _choosing = false;
                      }),
                  child: Text(tr('home.clear_selection'))),
            if (!widget.settings.simpleMode && _selected.isNotEmpty)
              IconButton(
                tooltip: tr('photos.delete'),
                onPressed: () => _deletePhotos(_selected.toList()),
                icon: const Icon(Icons.delete_outline_rounded),
              ),
            // Family group: already-sent items can be made "only me" / shared.
            if (_selected.any(sent.contains))
              PopupMenuButton<bool>(
                tooltip: tr('family.who_can_see'),
                icon: const Icon(Icons.lock_person_rounded),
                onSelected: (private) => _setVisibility(_selected.where(sent.contains).toList(), private: private),
                itemBuilder: (_) => [
                  PopupMenuItem(
                    value: false,
                    child: ListTile(leading: const Icon(Icons.groups_rounded), title: Text(tr('family.shared'))),
                  ),
                  PopupMenuItem(
                    value: true,
                    child: ListTile(leading: const Icon(Icons.lock_rounded), title: Text(tr('family.only_me'))),
                  ),
                ],
              ),
            const Spacer(),
            FilledButton.icon(
              onPressed: _selected.isEmpty ? null : _send,
              icon: const Icon(Icons.send),
              label: Text(_selected.isEmpty
                  ? tr('home.pick')
                  : _targetName() == null
                      ? tr('home.send_n', {'count': _selected.length})
                      : tr('photos.send_n_to', {'count': _selected.length, 'name': _targetName()!})),
            ),
          ],
        ),
      ),
    );
  }

  /// Where "Send" goes now (the PC, or the phone chosen for this visit).
  String? _targetName() => switch (_sendTarget) {
        PairedDesktop p => p.name,
        NearbyPhone p => p.name,
        _ => widget.settings.current?.name,
      };

  static String _duration(Duration d) {
    final m = d.inMinutes;
    final s = d.inSeconds % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }
}
