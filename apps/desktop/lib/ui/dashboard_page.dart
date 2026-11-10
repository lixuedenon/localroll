// apps/desktop/lib/ui/dashboard_page.dart
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:localroll_core/localroll_core.dart';

import '../app_services.dart';
import '../l10n/l10n.dart';
import '../services/file_actions.dart';
import '../services/library_index.dart';
import '../services/network.dart';
import '../services/peers.dart';
import '../services/received_files.dart';
import 'add_device_dialog.dart';
import 'app_nav.dart';
import 'feature_list.dart';
import 'breathing.dart';
import 'device_badge.dart';
import 'files_view.dart';
import 'format.dart';
import 'library_recovery.dart';
import 'library_tools.dart';
import 'light_look.dart';
import 'media_thumb.dart';
import 'send_page.dart';
import 'tools/tools.dart';
import 'trash_actions.dart';
import 'player/player_page.dart';

/// Home: this PC at a glance — status, the main actions, what came in
/// last, the family, disk space, and anything that needs attention.
class DashboardPage extends StatefulWidget {
  const DashboardPage({super.key, required this.services});

  final AppServices services;

  @override
  State<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends State<DashboardPage> {
  ({int free, int total})? _disk;
  NetworkHealth? _net;

  /// Received files (documents, scans…), for "Recently received".
  List<ReceivedFile> _files = const [];

  @override
  void initState() {
    super.initState();
    _refresh();
    // Re-check whenever the user comes back to Home.
    AppNav.instance.addListener(_onNav);
    widget.services.server.files.changes.addListener(_loadFiles);
    unawaited(_loadFiles());
  }

  @override
  void dispose() {
    AppNav.instance.removeListener(_onNav);
    widget.services.server.files.changes.removeListener(_loadFiles);
    super.dispose();
  }

  Future<void> _loadFiles() async {
    final f = await widget.services.server.files.list();
    if (mounted) setState(() => _files = f);
  }

  void _onNav() {
    if (AppNav.instance.tab == AppNav.home) _refresh();
  }

  Future<void> _refresh() async {
    final s = widget.services;
    final disk = await diskSpace(s.library.rootPath);
    final net = await checkNetworkHealth(s.server.port);
    if (!mounted) return;
    setState(() {
      _disk = disk;
      _net = net;
    });
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.services;
    return ListenableBuilder(
      listenable: Listenable.merge([s.library, s.settings, s.server, s.converter, s.hub, s.peers]),
      builder: (context, _) {
        final items = s.library.items;
        final total = items.fold<int>(0, (sum, i) => sum + i.size);
        // Home is light (bright blue, white cards); the other pages keep
        // their look for now.
        return Theme(
          data: LightLook.theme(Theme.of(context)),
          child: Scaffold(
            backgroundColor: LightLook.page,
            body: DecoratedBox(
              decoration: const BoxDecoration(
                gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [Color(0xFFEFF4FF), Color(0xFFF7F9FD), Color(0xFFEFF7FB)]),
              ),
              child: ListView(
                padding: const EdgeInsets.fromLTRB(28, 22, 28, 32),
                children: [
                  _header(context),
                  const SizedBox(height: 16),
                  _banner(),
                  // What LocalRoll can do (until the person says they know).
                  if (s.settings.showFeatures) ...[const SizedBox(height: 18), FeatureCard(services: s)],
                  // Library folder unreachable: say so first, with what can be done.
                  if (s.library.offline) LibraryRecovery(services: s),
                  const SizedBox(height: 18),
                  // Three numbers, each a way in.
                  IntrinsicHeight(
                    child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                      Expanded(
                        child: _stat(Icons.storage_rounded, const [Color(0xFF5B8CFF), Color(0xFF2F5BEA)], tr('nav.library'),
                            tr('home.items_size', {'count': items.length, 'size': formatBytes(total)}),
                            sub: tr('home.open_library'), onTap: () => AppNav.instance.selectTab(AppNav.library)),
                      ),
                      const SizedBox(width: 16),
                      Expanded(child: _diskStat(items)),
                      const SizedBox(width: 16),
                      Expanded(child: _statusStat()),
                    ]),
                  ),
                  const SizedBox(height: 22),
                  _quick(),
                  const SizedBox(height: 22),
                  _devicesGrid(context),
                  const SizedBox(height: 22),
                  _box(context, width: 2000, child: _recent(context, items)),
                  if (_issues().isNotEmpty) ...[
                    const SizedBox(height: 16),
                    KeyedSubtree(key: _attentionKey, child: _box(context, width: 2000, child: _attention(context), border: LightLook.amber)),
                  ],
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _stat(IconData icon, List<Color> tint, String kicker, String title,
          {String? sub, Color? subColor, Color? titleColor, Widget? extra, VoidCallback? onTap}) =>
      LightCard(
        onTap: onTap,
        padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          LightBadge(icon: icon, colors: tint, size: 52),
          const SizedBox(width: 16),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(kicker, overflow: TextOverflow.ellipsis, style: const TextStyle(color: LightLook.muted, fontSize: 13)),
              const SizedBox(height: 4),
              Text(title, style: TextStyle(fontSize: 21, fontWeight: FontWeight.w700, color: titleColor ?? LightLook.text)),
              if (extra != null) ...[const SizedBox(height: 10), extra],
              if (sub != null) ...[
                const SizedBox(height: 6),
                Text(sub, style: TextStyle(color: subColor ?? LightLook.blue, fontSize: 13, fontWeight: FontWeight.w500)),
              ],
            ]),
          ),
        ]),
      );

  Widget _diskStat(List<MediaItem> items) {
    final s = widget.services;
    final d = _disk;
    const tint = [Color(0xFF4FA3FF), Color(0xFF1D6FE8)];
    if (d == null) return _stat(Icons.dns_rounded, tint, tr('home.disk'), tr('home.disk_unknown'));
    final low = d.free < d.total * 0.1;
    return _stat(
      Icons.dns_rounded,
      tint,
      '${tr('home.disk')} · ${s.library.rootPath}',
      tr('home.disk_free_short', {'free': formatBytes(d.free)}),
      extra: ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: LinearProgressIndicator(
          value: d.total == 0 ? 0 : 1 - d.free / d.total,
          minHeight: 6,
          color: low ? LightLook.red : LightLook.blue,
          backgroundColor: const Color(0xFFE3E9F5),
        ),
      ),
      onTap: () => revealInExplorer(s.library.rootPath),
    );
  }

  final GlobalKey _attentionKey = GlobalKey();

  /// What needs doing: one thing is named and opens where it is done;
  /// several: the list further down comes into view.
  Widget _statusStat() {
    final issues = _issues();
    final n = issues.length;
    void showList() {
      final c = _attentionKey.currentContext;
      if (c != null) Scrollable.ensureVisible(c, duration: const Duration(milliseconds: 300), curve: Curves.easeOut);
    }

    return _stat(
      n == 0 ? Icons.verified_user_rounded : Icons.error_rounded,
      n == 0 ? const [Color(0xFF3DDC97), Color(0xFF12A86B)] : const [Color(0xFFFFC56B), Color(0xFFF08A1C)],
      tr('home.status'),
      n == 0 ? tr('home.all_good_short') : tr('home.issues', {'count': n}),
      titleColor: n == 0 ? LightLook.green : LightLook.amberText,
      sub: n == 0 ? '${tr('home.report_tap')} ›' : (n == 1 ? '${issues.first.$2} ›' : '${tr('home.issues_see')} ›'),
      subColor: n == 0 ? LightLook.blue : LightLook.amberText,
      onTap: n == 0 ? () => unawaited(showBackupReport(context, widget.services)) : (n == 1 && issues.first.$3 != null ? issues.first.$3 : showList),
    );
  }

  /// Every paired device, small: click to open it on the Devices page.
  Widget _devicesGrid(BuildContext context) {
    final s = widget.services;
    final st = s.settings;
    final ids = {...st.trusted.keys, ...st.peers.keys}.toList()
      ..sort((a, b) {
        final on = (s.isOnline(b) ? 1 : 0) - (s.isOnline(a) ? 1 : 0);
        return on != 0 ? on : s.deviceName(a).toLowerCase().compareTo(s.deviceName(b).toLowerCase());
      });
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        _sectionTitle(Icons.devices_rounded, tr('nav.devices')),
        const Spacer(),
        TextButton.icon(
          onPressed: () => showAddDevice(context, s),
          icon: const Icon(Icons.add_rounded, size: 18),
          label: Text(tr('dev.add')),
        ),
      ]),
      const SizedBox(height: 8),
      if (ids.isEmpty)
        Text(tr('home.devices_none'), style: const TextStyle(color: LightLook.muted))
      else
        LayoutBuilder(builder: (context, c) {
          final cols = (c.maxWidth / 260).floor().clamp(1, 5);
          final w = (c.maxWidth - (cols - 1) * 12) / cols;
          return Wrap(spacing: 12, runSpacing: 12, children: [
            for (final id in ids)
              SizedBox(width: w, child: _deviceTile(id)),
          ]);
        }),
    ]);
  }

  Widget _deviceTile(String id) {
    final s = widget.services;
    final t = s.settings.trusted[id];
    final p = s.settings.peers[id];
    final isPc = p != null || isDesktopPlatform(t?.platform ?? '');
    final online = s.isOnline(id);
    final family = t?.familyMember ?? true;
    return LightCard(
      onTap: () => AppNav.instance.openDevice(id),
      border: online ? LightLook.green.withValues(alpha: 0.6) : null,
      padding: const EdgeInsets.all(12),
      child: Row(children: [
            if (p != null)
              DeviceBadge(icon: p.icon, color: p.color, size: 40)
            else
              CircleAvatar(
                radius: 20,
                backgroundColor: const Color(0xFFE8EEFB),
                child: Icon(isPc ? Icons.computer_rounded : Icons.smartphone_rounded,
                    size: 20, color: online ? LightLook.green : LightLook.muted),
              ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(s.deviceName(id), overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600, color: LightLook.text)),
                Text(
                  [
                    tr(online ? 'dev.online' : 'dev.offline'),
                    tr(family ? 'dev.role_family' : 'dev.role_guest'),
                  ].join(' · '),
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12, color: online ? LightLook.green : LightLook.muted),
                ),
              ]),
            ),
          ]),
    );
  }

  Widget _header(BuildContext context) {
    final s = widget.services;
    final st = s.settings;
    final theme = Theme.of(context);
    final online = s.onlineDevices.length;
    final ok = s.server.running && !s.library.offline;
    final color = ok ? LightLook.green : LightLook.red;
    return Row(children: [
      DeviceBadge(
        icon: st.iconKey,
        color: st.colorValue,
        image: st.avatarVersion != 0 ? FileImage(st.avatarFile) : null,
        size: 56,
      ),
      const SizedBox(width: 18),
      Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(tr('identity.title'), style: theme.textTheme.bodySmall?.copyWith(color: LightLook.muted)),
          Text(st.deviceName, style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700, color: LightLook.text)),
        ]),
      ),
      // The pill itself breathes while devices are online.
      if (ok)
        Breathing(
          online: online > 0,
          radius: 999,
          color: Colors.white,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
            child: Text(
              tr('home.status_online', {'count': online}),
              style: TextStyle(color: online > 0 ? LightLook.green : LightLook.muted, fontSize: 13, fontWeight: FontWeight.w600),
            ),
          ),
        )
      else
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: color.withValues(alpha: 0.5)),
          ),
          child: Text(tr('home.status_off'), style: TextStyle(color: color, fontSize: 13)),
        ),
    ]);
  }

  Widget _sectionTitle(IconData icon, String t) => Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 20, color: LightLook.blue),
        const SizedBox(width: 8),
        Text(t, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: LightLook.text)),
      ]);

  /// The big band at the top: the name, what it does, and a picture made
  /// of the app's own pieces (files, photos, video, PDF going between a
  /// computer and a phone).
  Widget _banner() => ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: Container(
          height: 168,
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.centerLeft,
              end: Alignment.centerRight,
              colors: [Color(0xFFE6EEFF), Color(0xFFCFE0FF), Color(0xFF9FC2FF)],
            ),
          ),
          child: Stack(children: [
            // Soft light streaks.
            Positioned(
              right: -60,
              top: -80,
              child: Container(
                width: 420,
                height: 420,
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(colors: [Color(0x88FFFFFF), Color(0x00FFFFFF)]),
                ),
              ),
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: -30,
              child: Transform.rotate(
                angle: -0.06,
                child: Container(height: 60, decoration: const BoxDecoration(gradient: LinearGradient(colors: [Color(0x00FFFFFF), Color(0x66FFFFFF), Color(0x00FFFFFF)]))),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(34, 24, 24, 24),
              child: Row(children: [
                Expanded(
                  flex: 5,
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisAlignment: MainAxisAlignment.center, children: [
                    ShaderMask(
                      shaderCallback: (r) => const LinearGradient(colors: [Color(0xFF0E2A8C), Color(0xFF2F6BFF)]).createShader(r),
                      child: const Text(appName,
                          style: TextStyle(fontSize: 46, fontWeight: FontWeight.w900, fontStyle: FontStyle.italic, color: Colors.white, letterSpacing: -1, height: 1.05)),
                    ),
                    const SizedBox(height: 10),
                    Text(tr('home.tagline'),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: Color(0xFF1B3A8F), fontStyle: FontStyle.italic)),
                    const SizedBox(height: 10),
                    Container(
                      width: 200,
                      height: 4,
                      decoration: BoxDecoration(borderRadius: BorderRadius.circular(4), gradient: const LinearGradient(colors: [Color(0xFF2F6BFF), Color(0x002F6BFF)])),
                    ),
                  ]),
                ),
                const Expanded(flex: 4, child: _BannerArt()),
              ]),
            ),
          ]),
        ),
      );

  /// Everyday tools: one click, or drop files on one.
  Widget _quick() => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _sectionTitle(Icons.handyman_rounded, tr('home.tools')),
        const SizedBox(height: 12),
        ToolsGrid(services: widget.services),
      ]);

  Widget _box(BuildContext context, {required double width, required Widget child, Color? border}) => ConstrainedBox(
        constraints: BoxConstraints(minWidth: 300, maxWidth: width),
        child: Container(
          width: width,
          padding: const EdgeInsets.all(20),
          decoration: LightLook.card(border: border),
          child: child,
        ),
      );

  Widget _title(String t, [String? side]) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Row(children: [
          _sectionTitle(Icons.schedule_rounded, t),
          const SizedBox(width: 10),
          if (side != null)
            Expanded(
              child: Text(side,
                  overflow: TextOverflow.ellipsis, style: const TextStyle(color: LightLook.muted, fontSize: 12)),
            ),
        ]),
      );

  /// What came in last: photos, videos and received files, newest first.
  /// A photo / video opens in the viewer (paging through these), a file
  /// opens the way it does in the library; right-click for more.
  Widget _recent(BuildContext context, List<MediaItem> items) {
    final s = widget.services;
    final latest = <(int, MediaItem?, ReceivedFile?)>[
      for (final i in items) (i.receivedMs, i, null),
      for (final f in _files) (f.arrived.millisecondsSinceEpoch, null, f),
    ]..sort((a, b) => b.$1.compareTo(a.$1));
    if (latest.isEmpty) {
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _title(tr('home.recent')),
        Text(tr('home.recent_none'), style: const TextStyle(color: LightLook.muted)),
      ]);
    }
    final shown = latest.take(6).toList();
    final media = [for (final e in shown) ?e.$2];
    final (lastMs, lastItem, lastFile) = shown.first;
    // The last batch: same sender, within an hour of the newest.
    final lastFrom = lastItem?.deviceId ?? lastFile?.owner?.deviceId;
    final batch = latest
        .where((e) => (e.$2?.deviceId ?? e.$3?.owner?.deviceId) == lastFrom && lastMs - e.$1 < const Duration(hours: 1).inMilliseconds)
        .length;
    final from = lastFrom == null
        ? (lastItem?.deviceName ?? lastFile?.owner?.deviceName)
        : (s.settings.family.labelOf(lastFrom) ?? lastItem?.deviceName ?? lastFile?.owner?.deviceName);
    final when = formatDate(DateTime.fromMillisecondsSinceEpoch(lastMs));
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Expanded(
          child: _title(
            tr('home.recent'),
            from == null ? '$when · ${tr('home.items', {'count': batch})}' : tr('home.recent_from', {'when': when, 'from': from, 'count': batch}),
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: TextButton(onPressed: AppNav.instance.openLibraryRecent, child: Text(tr('home.see_all'))),
        ),
      ]),
      Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        for (var i = 0; i < 6; i++) ...[
          if (i > 0) const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              AspectRatio(
                aspectRatio: 1.3,
                child: Container(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(10),
                    boxShadow: i < shown.length ? const [BoxShadow(color: Color(0x1A1D3B8A), blurRadius: 8, offset: Offset(0, 3))] : null,
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: i < shown.length ? _recentTile(context, shown[i].$2, shown[i].$3, media) : Container(color: const Color(0xFFEFF2F8)),
                  ),
                ),
              ),
              if (i < shown.length) ...[
                const SizedBox(height: 8),
                Text(shown[i].$2?.name ?? shown[i].$3!.name,
                    maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13, color: LightLook.text, fontWeight: FontWeight.w500)),
                Text(formatDate(DateTime.fromMillisecondsSinceEpoch(shown[i].$1)),
                    maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12, color: LightLook.muted)),
              ],
            ]),
          ),
        ],
      ]),
    ]);
  }

  Widget _recentTile(BuildContext context, MediaItem? item, ReceivedFile? file, List<MediaItem> media) {
    final s = widget.services;
    if (item != null) {
      return Tooltip(
        message: item.name,
        waitDuration: const Duration(milliseconds: 600),
        child: GestureDetector(
          onTap: () => openLibraryItems(context, s, media, media.indexOf(item)),
          onSecondaryTapUp: (d) => _recentMenu(context, d.globalPosition, item: item),
          child: MediaThumb(item: item, library: s.library, ffmpeg: s.ffmpeg),
        ),
      );
    }
    final f = file!;
    return Tooltip(
      message: f.name,
      waitDuration: const Duration(milliseconds: 600),
      child: GestureDetector(
        onTap: () => openReceivedFile(context, s, f.path),
        onSecondaryTapUp: (d) => _recentMenu(context, d.globalPosition, file: f),
        child: Stack(fit: StackFit.expand, children: [
          FileThumb(
            key: ValueKey(f.path),
            path: f.path,
            size: f.size,
            modified: f.modified,
            services: s,
            icon: Container(
              color: const Color(0xFFEFF2F8),
              alignment: Alignment.center,
              child: const Icon(Icons.insert_drive_file_rounded, size: 32, color: LightLook.muted),
            ),
          ),
        ]),
      ),
    );
  }

  /// Right-click on a recent item: open, send, show in its folder, delete.
  Future<void> _recentMenu(BuildContext context, Offset at, {MediaItem? item, ReceivedFile? file}) async {
    final s = widget.services;
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    Widget row(IconData icon, String text, {bool danger = false}) {
      final color = danger ? Theme.of(context).colorScheme.error : null;
      return Row(children: [Icon(icon, size: 18, color: color), const SizedBox(width: 12), Text(text, style: TextStyle(color: color))]);
    }

    final choice = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(at & const Size(1, 1), Offset.zero & overlay.size),
      items: [
        PopupMenuItem(value: 'open', child: row(Icons.open_in_full_rounded, tr('lib.open'))),
        PopupMenuItem(value: 'send', child: row(Icons.send_rounded, tr('send.to_pc'))),
        PopupMenuItem(value: 'reveal', child: row(Icons.folder_open_rounded, tr('common.show_in_folder'))),
        const PopupMenuDivider(),
        PopupMenuItem(value: 'delete', child: row(Icons.delete_outline_rounded, tr('lib.delete'), danger: true)),
      ],
    );
    if (!mounted || choice == null) return;
    final ctx = this.context;
    final path = item != null ? s.library.absPath(item) : file!.path;
    switch (choice) {
      case 'open':
        if (item != null) {
          await openLibraryItems(ctx, s, [item], 0);
        } else {
          await openReceivedFile(ctx, s, path);
        }
      case 'send':
        final files = item != null
            ? [for (final i in s.library.withLive([item])) ?SendFile.fromLibrary(s.library, i)]
            : [?SendFile.plain(File(path), file!.name)];
        if (files.isNotEmpty) await sendToPc(ctx, s, files, item?.name ?? file!.name);
      case 'reveal':
        revealInExplorer(path);
      case 'delete':
        await deleteToTrash(ctx, s, media: [?item], files: [if (file != null) file.path]);
    }
  }

  List<(IconData, String, VoidCallback?)> _issues() {
    final s = widget.services;
    final net = _net;
    return <(IconData, String, VoidCallback?)>[
      if (s.library.offline)
        (
          s.library.loss == LibraryLoss.gone ? Icons.folder_off_rounded : Icons.usb_off_rounded,
          tr(s.library.loss == LibraryLoss.gone ? 'home.issue_gone' : 'home.issue_offline'),
          () => AppNav.instance.selectTab(AppNav.library)
        ),
      if (s.library.pendingMissing.isNotEmpty)
        (Icons.help_outline_rounded, tr('home.issue_missing', {'count': s.library.pendingMissing.length}),
            () => AppNav.instance.selectTab(AppNav.library)),
      if (!s.server.running) (Icons.wifi_off_rounded, tr('home.issue_server'), () => AppNav.instance.selectTab(AppNav.receive)),
      if (net != null && !net.firewallRule)
        (Icons.shield_outlined, tr('home.issue_firewall'), () => AppNav.instance.selectTab(AppNav.receive)),
      if (!s.ffmpeg.available) (Icons.movie_filter_outlined, tr('home.issue_ffmpeg'), () => AppNav.instance.selectTab(AppNav.settings)),
      if (_disk != null && _disk!.free < 5 * 1024 * 1024 * 1024)
        (Icons.sd_storage_outlined, tr('home.issue_disk'), null),
    ];
  }

  Widget _attention(BuildContext context) {
    final issues = _issues();
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _title(tr('home.attention')),
      if (issues.isEmpty)
        Row(children: [
          const Icon(Icons.verified_rounded, color: LightLook.green, size: 20),
          const SizedBox(width: 8),
          Text(tr('home.all_good'), style: const TextStyle(color: LightLook.green)),
        ])
      else
        for (final (icon, text, onTap) in issues)
          InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(children: [
                Icon(icon, color: LightLook.amberText, size: 20),
                const SizedBox(width: 10),
                Expanded(child: Text(text, style: const TextStyle(fontSize: 14, color: LightLook.text))),
                if (onTap != null) const Icon(Icons.chevron_right_rounded, color: LightLook.muted),
              ]),
            ),
          ),
    ]);
  }
}

/// The banner's picture: a computer and a phone, with files, photos, video
/// and PDF floating between them — drawn from icons, nothing copied.
class _BannerArt extends StatelessWidget {
  const _BannerArt();

  Widget _chip(IconData icon, List<Color> colors, double size, double angle) => Transform.rotate(
        angle: angle,
        child: Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(size * 0.28),
            gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: colors),
            boxShadow: [BoxShadow(color: colors.last.withValues(alpha: 0.4), blurRadius: 14, offset: const Offset(0, 6))],
          ),
          child: Icon(icon, color: Colors.white, size: size * 0.55),
        ),
      );

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, c) {
        final w = c.maxWidth, h = c.maxHeight;
        if (w < 240) return const SizedBox.shrink();
        return Stack(clipBehavior: Clip.none, children: [
          // Computer.
          Positioned(
            right: w * 0.12,
            top: h * 0.08,
            child: Container(
              width: 190,
              height: 118,
              decoration: BoxDecoration(
                color: const Color(0xFF1A2440),
                borderRadius: BorderRadius.circular(10),
                boxShadow: const [BoxShadow(color: Color(0x401A2440), blurRadius: 20, offset: Offset(0, 10))],
              ),
              padding: const EdgeInsets.all(6),
              child: Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(5),
                  gradient: const LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [Color(0xFF3D7BFF), Color(0xFF1B3FB8)]),
                ),
                child: const Icon(Icons.play_circle_fill_rounded, color: Colors.white, size: 46),
              ),
            ),
          ),
          Positioned(
            right: w * 0.12 - 14,
            top: h * 0.08 + 118,
            child: Container(
              width: 218,
              height: 9,
              decoration: const BoxDecoration(color: Color(0xFFB9C6E4), borderRadius: BorderRadius.vertical(bottom: Radius.circular(8))),
            ),
          ),
          // Phone.
          Positioned(
            right: 0,
            top: h * 0.24,
            child: Container(
              width: 58,
              height: 104,
              decoration: BoxDecoration(
                color: const Color(0xFF1A2440),
                borderRadius: BorderRadius.circular(12),
                boxShadow: const [BoxShadow(color: Color(0x401A2440), blurRadius: 16, offset: Offset(0, 8))],
              ),
              padding: const EdgeInsets.all(4),
              child: Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(9),
                  gradient: const LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Color(0xFF63A0FF), Color(0xFF2A55D6)]),
                ),
                child: const Icon(Icons.swap_horiz_rounded, color: Colors.white, size: 26),
              ),
            ),
          ),
          // What travels between them.
          Positioned(left: w * 0.02, top: h * 0.30, child: _chip(Icons.folder_rounded, const [Color(0xFF5AA9FF), Color(0xFF2F6BFF)], 46, -0.12)),
          Positioned(left: w * 0.22, top: -h * 0.04, child: _chip(Icons.play_arrow_rounded, const [Color(0xFFA78BFA), Color(0xFF7C4DFF)], 42, 0)),
          Positioned(left: w * 0.20, bottom: -h * 0.02, child: _chip(Icons.picture_as_pdf_rounded, const [Color(0xFFFF7A7A), Color(0xFFE5383B)], 40, 0.14)),
          Positioned(right: w * 0.10 + 150, top: -h * 0.10, child: _chip(Icons.image_rounded, const [Color(0xFFFFC56B), Color(0xFFFF8A3D)], 40, 0.18)),
        ]);
      });
}
