// apps/desktop/lib/ui/dashboard_page.dart
import 'package:flutter/material.dart';
import 'package:localroll_core/localroll_core.dart';

import '../app_services.dart';
import '../l10n/l10n.dart';
import '../services/file_actions.dart';
import '../services/library_index.dart';
import '../services/network.dart';
import 'add_device_dialog.dart';
import 'app_nav.dart';
import 'breathing.dart';
import 'device_badge.dart';
import 'format.dart';
import 'library_recovery.dart';
import 'media_thumb.dart';
import 'theme.dart';

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

  @override
  void initState() {
    super.initState();
    _refresh();
    // Re-check whenever the user comes back to Home.
    AppNav.instance.addListener(_onNav);
  }

  @override
  void dispose() {
    AppNav.instance.removeListener(_onNav);
    super.dispose();
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
        return Scaffold(
          body: ListView(
            padding: const EdgeInsets.fromLTRB(36, 28, 36, 36),
            children: [
              _header(context),
              // Library folder unreachable: say so first, with what can be done.
              if (s.library.offline) LibraryRecovery(services: s),
              const SizedBox(height: 22),
              // Three numbers, each a way in.
              IntrinsicHeight(
                child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  Expanded(child: _stat(tr('nav.library'), tr('home.items_size', {'count': items.length, 'size': formatBytes(total)}),
                      sub: tr('home.open_library'), onTap: () => AppNav.instance.selectTab(AppNav.library))),
                  const SizedBox(width: 14),
                  Expanded(child: _diskStat(items)),
                  const SizedBox(width: 14),
                  Expanded(child: _statusStat()),
                ]),
              ),
              const SizedBox(height: 24),
              _devicesGrid(context),
              const SizedBox(height: 24),
              _box(context, width: 2000, child: _recent(context, items)),
              if (_issues().isNotEmpty) ...[
                const SizedBox(height: 16),
                _box(context, width: 2000, child: _attention(context), border: LrColors.safelight),
              ],
            ],
          ),
        );
      },
    );
  }

  Widget _stat(String kicker, String title, {String? sub, Color? subColor, Widget? extra, VoidCallback? onTap}) => Material(
        color: LrColors.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14), side: const BorderSide(color: LrColors.line)),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(18, 14, 18, 14),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(kicker, overflow: TextOverflow.ellipsis, style: const TextStyle(color: LrColors.muted, fontSize: 13)),
              const SizedBox(height: 6),
              Text(title, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
              if (extra != null) ...[const SizedBox(height: 8), extra],
              if (sub != null) ...[
                const SizedBox(height: 6),
                Text(sub, style: TextStyle(color: subColor ?? LrColors.safelight, fontSize: 13)),
              ],
            ]),
          ),
        ),
      );

  Widget _diskStat(List<MediaItem> items) {
    final s = widget.services;
    final d = _disk;
    if (d == null) return _stat(tr('home.disk'), tr('home.disk_unknown'));
    final low = d.free < d.total * 0.1;
    return _stat(
      '${tr('home.disk')} · ${s.library.rootPath}',
      tr('home.disk_free_short', {'free': formatBytes(d.free)}),
      extra: ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: LinearProgressIndicator(
          value: d.total == 0 ? 0 : 1 - d.free / d.total,
          minHeight: 6,
          color: low ? LrColors.danger : LrColors.verified,
          backgroundColor: LrColors.raised,
        ),
      ),
      onTap: () => revealInExplorer(s.library.rootPath),
    );
  }

  Widget _statusStat() {
    final n = _issues().length;
    return _stat(
      tr('home.status'),
      n == 0 ? tr('home.all_good_short') : tr('home.issues', {'count': n}),
      sub: n == 0 ? tr('home.all_good_sub') : null,
      subColor: LrColors.muted,
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
        Text(tr('nav.devices'), style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
        const Spacer(),
        TextButton.icon(
          onPressed: () => showAddDevice(context, s),
          icon: const Icon(Icons.add_rounded, size: 18),
          label: Text(tr('dev.add')),
        ),
      ]),
      const SizedBox(height: 8),
      if (ids.isEmpty)
        Text(tr('home.devices_none'), style: const TextStyle(color: LrColors.muted))
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
    return Material(
      color: LrColors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: online ? onlineGlow.withValues(alpha: 0.7) : LrColors.line, width: online ? 1.5 : 1),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () => AppNav.instance.openDevice(id),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(children: [
            if (p != null)
              DeviceBadge(icon: p.icon, color: p.color, size: 40)
            else
              CircleAvatar(
                radius: 20,
                backgroundColor: LrColors.raised,
                child: Icon(isPc ? Icons.computer_rounded : Icons.smartphone_rounded,
                    size: 20, color: online ? onlineGlow : LrColors.muted),
              ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(s.deviceName(id), overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600)),
                Text(
                  [
                    tr(online ? 'dev.online' : 'dev.offline'),
                    tr(family ? 'dev.role_family' : 'dev.role_guest'),
                  ].join(' · '),
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12, color: online ? onlineGlow : LrColors.muted),
                ),
              ]),
            ),
          ]),
        ),
      ),
    );
  }

  Widget _header(BuildContext context) {
    final s = widget.services;
    final st = s.settings;
    final theme = Theme.of(context);
    final online = s.onlineDevices.length;
    final ok = s.server.running && !s.library.offline;
    final color = ok ? LrColors.verified : LrColors.danger;
    return Row(children: [
      DeviceBadge(
        icon: st.iconKey,
        color: st.colorValue,
        image: st.avatarVersion != 0 ? FileImage(st.avatarFile) : null,
        size: 64,
      ),
      const SizedBox(width: 18),
      Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(tr('identity.title'), style: theme.textTheme.bodySmall?.copyWith(color: LrColors.muted)),
          Text(st.deviceName, style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700)),
        ]),
      ),
      // The pill itself breathes while devices are online.
      if (ok)
        Breathing(
          online: online > 0,
          radius: 999,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
            child: Text(
              tr('home.status_online', {'count': online}),
              style: TextStyle(color: online > 0 ? onlineGlow : LrColors.muted, fontSize: 13, fontWeight: FontWeight.w600),
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

  Widget _box(BuildContext context, {required double width, required Widget child, Color? border}) => ConstrainedBox(
        constraints: BoxConstraints(minWidth: 300, maxWidth: width),
        child: Container(
          width: width,
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: LrColors.surface,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: border ?? LrColors.line),
          ),
          child: child,
        ),
      );

  Widget _title(String t, [String? side]) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Row(children: [
          Text(t, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
          const SizedBox(width: 10),
          if (side != null)
            Expanded(
              child: Text(side,
                  overflow: TextOverflow.ellipsis, style: const TextStyle(color: LrColors.muted, fontSize: 12)),
            ),
        ]),
      );

  Widget _recent(BuildContext context, List<MediaItem> items) {
    final s = widget.services;
    if (items.isEmpty) {
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _title(tr('home.recent')),
        Text(tr('home.recent_none'), style: const TextStyle(color: LrColors.muted)),
      ]);
    }
    final byReceived = List.of(items)..sort((a, b) => b.receivedMs.compareTo(a.receivedMs));
    final last = byReceived.first;
    // The last batch: same phone, within an hour of the newest.
    final batch = byReceived
        .where((i) => i.deviceId == last.deviceId && last.receivedMs - i.receivedMs < const Duration(hours: 1).inMilliseconds)
        .length;
    final from = (last.deviceId == null ? null : s.settings.family.labelOf(last.deviceId!)) ?? last.deviceName;
    final when = formatDate(DateTime.fromMillisecondsSinceEpoch(last.receivedMs));
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _title(
        tr('home.recent'),
        from == null ? '$when · ${tr('home.items', {'count': batch})}' : tr('home.recent_from', {'when': when, 'from': from, 'count': batch}),
      ),
      Row(children: [
        for (var i = 0; i < 6; i++) ...[
          if (i > 0) const SizedBox(width: 8),
          Expanded(
            child: AspectRatio(
              aspectRatio: 1,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: i < byReceived.length
                    ? GestureDetector(
                        onTap: () => AppNav.instance.selectTab(AppNav.library),
                        child: MediaThumb(item: byReceived[i], library: s.library, ffmpeg: s.ffmpeg),
                      )
                    : Container(color: LrColors.raised),
              ),
            ),
          ),
        ],
      ]),
    ]);
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
          const Icon(Icons.verified_rounded, color: LrColors.verified, size: 20),
          const SizedBox(width: 8),
          Text(tr('home.all_good'), style: const TextStyle(color: LrColors.verified)),
        ])
      else
        for (final (icon, text, onTap) in issues)
          InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(children: [
                Icon(icon, color: LrColors.safelight, size: 20),
                const SizedBox(width: 10),
                Expanded(child: Text(text, style: const TextStyle(fontSize: 14))),
                if (onTap != null) const Icon(Icons.chevron_right_rounded, color: LrColors.muted),
              ]),
            ),
          ),
    ]);
  }
}
