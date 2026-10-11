// apps/desktop/lib/ui/dashboard_page.dart
import 'package:flutter/material.dart';
import 'package:localroll_core/localroll_core.dart';

import '../app_services.dart';
import '../l10n/l10n.dart';
import '../services/file_actions.dart';
import '../services/library_index.dart';
import '../services/network.dart';
import 'app_nav.dart';
import 'device_badge.dart';
import 'format.dart';
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
      listenable: Listenable.merge([s.library, s.settings, s.server, s.converter, s.hub]),
      builder: (context, _) {
        final items = s.library.items;
        final total = items.fold<int>(0, (sum, i) => sum + i.size);
        return Scaffold(
          body: ListView(
            padding: const EdgeInsets.fromLTRB(36, 28, 36, 36),
            children: [
              _header(context),
              const SizedBox(height: 24),
              LayoutBuilder(builder: (context, c) {
                final cards = [
                  _actionCard(
                    color: LrColors.safelight,
                    kicker: tr('nav.receive'),
                    title: tr('home.receive_title'),
                    body: tr('home.receive_body'),
                    onTap: () => AppNav.instance.selectTab(AppNav.receive),
                  ),
                  _actionCard(
                    color: LrColors.verified,
                    kicker: tr('nav.library'),
                    title: tr('home.library_title', {'count': items.length, 'size': formatBytes(total)}),
                    body: tr('home.library_body'),
                    onTap: () => AppNav.instance.selectTab(AppNav.library),
                  ),
                  _actionCard(
                    color: const Color(0xFF7AA7FF),
                    kicker: tr('nav.convert'),
                    title: s.converter.pending > 0
                        ? tr('home.convert_busy', {'count': s.converter.pending})
                        : tr('home.convert_title'),
                    body: tr('home.convert_body'),
                    onTap: () => AppNav.instance.selectTab(AppNav.convert),
                  ),
                ];
                if (c.maxWidth < 760) {
                  return Column(children: [for (final w in cards) Padding(padding: const EdgeInsets.only(bottom: 12), child: w)]);
                }
                return IntrinsicHeight(
                  child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    for (var i = 0; i < cards.length; i++) ...[
                      if (i > 0) const SizedBox(width: 16),
                      Expanded(child: cards[i]),
                    ],
                  ]),
                );
              }),
              const SizedBox(height: 16),
              Wrap(spacing: 16, runSpacing: 16, children: [
                _box(context, width: 560, child: _recent(context, items)),
                _box(context, width: 360, child: _family(context, items)),
                _box(context, width: 460, child: _diskBox(context, items)),
                _box(context, width: 460, child: _attention(context)),
              ]),
            ],
          ),
        );
      },
    );
  }

  Widget _header(BuildContext context) {
    final s = widget.services;
    final st = s.settings;
    final theme = Theme.of(context);
    final phones = st.trusted.length;
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
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: color.withValues(alpha: 0.5)),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Container(width: 8, height: 8, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
          const SizedBox(width: 8),
          Text(
            ok ? tr('home.status_ok', {'count': phones}) : tr('home.status_off'),
            style: TextStyle(color: color, fontSize: 13),
          ),
        ]),
      ),
    ]);
  }

  Widget _actionCard({
    required Color color,
    required String kicker,
    required String title,
    required String body,
    required VoidCallback onTap,
  }) =>
      Material(
        color: LrColors.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: LrColors.line),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(kicker, style: TextStyle(color: color, fontSize: 13, fontWeight: FontWeight.w700)),
              const SizedBox(height: 8),
              Text(title, style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w700)),
              const SizedBox(height: 6),
              Text(body, style: const TextStyle(color: LrColors.muted, fontSize: 13)),
            ]),
          ),
        ),
      );

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

  Widget _family(BuildContext context, List<MediaItem> items) {
    final s = widget.services;
    final family = s.settings.family;
    // Last backup per person.
    final lastByMember = <String, int>{};
    for (final i in items) {
      final m = i.deviceId == null ? null : family.memberOf(i.deviceId!);
      if (m == null) continue;
      final k = FamilyDirectory.keyOf(m);
      if ((lastByMember[k] ?? 0) < i.receivedMs) lastByMember[k] = i.receivedMs;
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    final stale = [
      for (final m in family.members)
        if (now - (lastByMember[FamilyDirectory.keyOf(m)] ?? 0) > const Duration(days: 3).inMilliseconds) m,
    ];
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _title(tr('family.title')),
      if (family.members.isEmpty)
        Text(tr('settings.no_phones'), style: const TextStyle(color: LrColors.muted))
      else
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (final m in family.members)
            ActionChip(
              label: Text(family.devicesOf(m).length > 1 ? tr('home.member_devices', {'name': m, 'count': family.devicesOf(m).length}) : m),
              onPressed: () => AppNav.instance.selectTab(AppNav.family),
            ),
        ]),
      if (stale.isNotEmpty) ...[
        const SizedBox(height: 10),
        Text(tr('home.member_stale', {'names': stale.join(', ')}),
            style: const TextStyle(color: LrColors.muted, fontSize: 13)),
      ],
    ]);
  }

  Widget _diskBox(BuildContext context, List<MediaItem> items) {
    final s = widget.services;
    final d = _disk;
    final avg = items.isEmpty ? 4 * 1024 * 1024 : items.fold<int>(0, (a, i) => a + i.size) ~/ items.length;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _title(tr('home.disk'), s.library.rootPath),
      if (d == null)
        Text(tr('home.disk_unknown'), style: const TextStyle(color: LrColors.muted))
      else ...[
        ClipRRect(
          borderRadius: BorderRadius.circular(5),
          child: LinearProgressIndicator(
            value: d.total == 0 ? 0 : 1 - d.free / d.total,
            minHeight: 10,
            color: d.free < d.total * 0.1 ? LrColors.danger : LrColors.verified,
            backgroundColor: LrColors.raised,
          ),
        ),
        const SizedBox(height: 10),
        Text(
          tr('home.disk_free', {'free': formatBytes(d.free), 'count': (d.free ~/ avg).toString()}),
          style: const TextStyle(color: LrColors.muted, fontSize: 13),
        ),
      ],
    ]);
  }

  Widget _attention(BuildContext context) {
    final s = widget.services;
    final net = _net;
    final issues = <(IconData, String, VoidCallback?)>[
      if (s.library.offline) (Icons.usb_off_rounded, tr('home.issue_offline'), () => AppNav.instance.selectTab(AppNav.library)),
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
