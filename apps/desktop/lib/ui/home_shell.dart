// apps/desktop/lib/ui/home_shell.dart
import 'dart:async';

import 'package:flutter/material.dart';

import '../app_services.dart';
import '../l10n/l10n.dart';
import 'app_nav.dart';
import 'dashboard_page.dart';
import 'devices_page.dart';
import 'jobs_page.dart';
import 'library_page.dart';
import 'notices.dart';
import 'pair_prompt.dart';
import 'player/player_home.dart';
import 'screen/screen_page.dart';
import 'screen/screen_record.dart';
import 'settings_page.dart';
import 'text_window.dart';
import 'theme.dart';
import 'title_bar.dart';

class HomeShell extends StatefulWidget {
  const HomeShell({super.key, required this.services});

  final AppServices services;

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  final AppNav _nav = AppNav.instance;
  late final PairPrompter _prompter;
  late final Notices _notices;

  int _textsSeen = 0;
  bool _textOpen = false;

  /// Text from another device: show it in the text window, one at a time.
  Future<void> _showTexts() async {
    if (_textOpen) return;
    final hub = widget.services.hub;
    while (_textsSeen < hub.texts.length) {
      final t = hub.texts[_textsSeen++];
      final ctx = AppNav.instance.navigatorKey.currentContext;
      if (ctx == null) return;
      _textOpen = true;
      try {
        await showReceivedText(ctx, widget.services, t);
      } finally {
        _textOpen = false;
      }
    }
  }

  /// Texts from other devices pop up in the text window.
  void _onHub() {
    if (widget.services.hub.texts.length > _textsSeen) unawaited(_showTexts());
  }

  @override
  void dispose() {
    _prompter.dispose();
    _notices.dispose();
    widget.services.hub.removeListener(_onHub);
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _prompter = PairPrompter(widget.services.server); // tap-to-pair dialogs
    _notices = Notices(widget.services); // accept? / all received / all sent
    _textsSeen = widget.services.hub.texts.length;
    widget.services.hub.addListener(_onHub);
    // Always start on Home: status, main actions, what needs attention.
    _nav.initialTab(AppNav.home);
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.services;
    // Same order as AppNav.home … AppNav.settings.
    final pages = [
      DashboardPage(services: s),
      DevicesPage(services: s),
      LibraryPage(services: s),
      PlayerHome(services: s),
      ScreenPage(services: s),
      JobsPage(services: s),
      SettingsPage(services: s),
    ];
    return Scaffold(
      body: Row(
        children: [
          AppRail(services: s),
          Expanded(
            child: ListenableBuilder(
              listenable: _nav,
              builder: (context, _) => IndexedStack(index: _nav.tab, children: pages),
            ),
          ),
        ],
      ),
    );
  }
}

/// The left rail: the main sections. Also shown beside the player (so it
/// stays in reach); [onSelect] then leaves the player first.
class AppRail extends StatelessWidget {
  const AppRail({super.key, required this.services, this.selected, this.onSelect});

  final AppServices services;

  /// Shown as selected (null: the current section).
  final int? selected;
  final void Function(int tab)? onSelect;

  AppNav get _nav => AppNav.instance;

  void _go(int tab) => onSelect != null ? onSelect!(tab) : _nav.selectTab(tab);

  @override
  Widget build(BuildContext context) {
    final s = services;
    return ListenableBuilder(
      listenable: Listenable.merge([s.hub, s.converter, s.library, s.sender, _nav, _nav.attention, ScreenRecorder.instance]),
      builder: (context, _) {
        final receiving = s.hub.transfers.any((t) => t.fraction != null && t.fraction! < 1);
        return Container(
          width: 96,
          decoration: const BoxDecoration(
            color: LrColors.surface,
            border: Border(right: BorderSide(color: LrColors.line)),
          ),
          child: Column(
            children: [
              const SizedBox(height: 14),
              _RailItem(
                icon: Icons.home_outlined,
                selectedIcon: Icons.home_rounded,
                label: tr('nav.home'),
                selected: (selected ?? _nav.tab) == AppNav.home,
                onTap: () => _go(AppNav.home),
              ),
              _RailItem(
                icon: Icons.devices_other_outlined,
                selectedIcon: Icons.devices_other_rounded,
                label: tr('nav.transfer'),
                selected: (selected ?? _nav.tab) == AppNav.devices,
                dot: receiving || s.sender.busy,
                flash: _nav.attention.value > 0,
                onTap: () => _go(AppNav.devices),
              ),
              _RailItem(
                icon: Icons.photo_library_outlined,
                selectedIcon: Icons.photo_library_rounded,
                label: tr('nav.library'),
                selected: (selected ?? _nav.tab) == AppNav.library,
                dot: s.library.offline || s.library.pendingMissing.isNotEmpty,
                onTap: () => _go(AppNav.library),
              ),
              _RailItem(
                icon: Icons.play_circle_outline_rounded,
                selectedIcon: Icons.play_circle_rounded,
                label: tr('nav.player'),
                selected: (selected ?? _nav.tab) == AppNav.player,
                onTap: () => _go(AppNav.player),
              ),
              _RailItem(
                icon: Icons.videocam_outlined,
                selectedIcon: Icons.videocam_rounded,
                label: tr('nav.screen'),
                selected: (selected ?? _nav.tab) == AppNav.screen,
                dot: ScreenRecorder.instance.recording,
                onTap: () => _go(AppNav.screen),
              ),
              _RailItem(
                icon: Icons.auto_fix_high_outlined,
                selectedIcon: Icons.auto_fix_high_rounded,
                label: tr('nav.convert'),
                selected: (selected ?? _nav.tab) == AppNav.convert,
                count: s.converter.pending,
                onTap: () => _go(AppNav.convert),
              ),
              _RailItem(
                icon: Icons.tune_outlined,
                selectedIcon: Icons.tune_rounded,
                label: tr('nav.settings'),
                selected: (selected ?? _nav.tab) == AppNav.settings,
                onTap: () => _go(AppNav.settings),
              ),
              const Spacer(),
              _RailItem(
                icon: Icons.power_settings_new_rounded,
                selectedIcon: Icons.power_settings_new_rounded,
                label: tr('app.exit'),
                selected: false,
                quiet: true,
                onTap: () => confirmExit(s),
              ),
              const SizedBox(height: 12),
            ],
          ),
        );
      },
    );
  }
}

/// Rail entry. The selected one glows like a safelight; nothing else moves.
class _RailItem extends StatefulWidget {
  const _RailItem({
    required this.icon,
    required this.selectedIcon,
    required this.label,
    required this.selected,
    required this.onTap,
    this.dot = false,
    this.count = 0,
    this.quiet = false,
    this.flash = false,
  });

  /// Needs the person: pulses until answered.
  final bool flash;

  final IconData icon;
  final IconData selectedIcon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  /// Something is happening here (e.g. a phone is sending).
  final bool dot;

  /// Pending items (conversion queue).
  final int count;

  /// Exit: muted until hovered.
  final bool quiet;

  @override
  State<_RailItem> createState() => _RailItemState();
}

class _RailItemState extends State<_RailItem> with SingleTickerProviderStateMixin {
  bool _hover = false;
  late final AnimationController _pulse = AnimationController(vsync: this, duration: const Duration(milliseconds: 700));

  @override
  void initState() {
    super.initState();
    if (widget.flash) _pulse.repeat(reverse: true);
  }

  @override
  void didUpdateWidget(_RailItem old) {
    super.didUpdateWidget(old);
    if (widget.flash && !_pulse.isAnimating) _pulse.repeat(reverse: true);
    if (!widget.flash && _pulse.isAnimating) {
      _pulse
        ..stop()
        ..value = 0;
    }
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.flash) {
      return AnimatedBuilder(
        animation: _pulse,
        builder: (context, child) => DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            color: LrColors.safelight.withValues(alpha: 0.10 + 0.35 * _pulse.value),
          ),
          child: child,
        ),
        child: _item(context),
      );
    }
    return _item(context);
  }

  Widget _item(BuildContext context) {
    final sel = widget.selected;
    final color = sel
        ? const Color(0xFF2B1A00)
        : widget.quiet
            ? (_hover ? LrColors.danger : LrColors.muted)
            : (_hover ? LrColors.text : LrColors.muted);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: widget.onTap,
          child: Column(
            children: [
              AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                curve: Curves.easeOut,
                width: 60,
                height: 36,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(18),
                  color: sel ? LrColors.safelight : (_hover ? LrColors.raised : Colors.transparent),
                  boxShadow: sel ? const [BoxShadow(color: Color(0x66FFB547), blurRadius: 16)] : null,
                ),
                child: Stack(
                  alignment: Alignment.center,
                  clipBehavior: Clip.none,
                  children: [
                    Icon(sel ? widget.selectedIcon : widget.icon, color: color, size: 22),
                    if (widget.dot)
                      Positioned(
                        right: 12,
                        top: 6,
                        child: Container(
                          width: 8,
                          height: 8,
                          decoration: const BoxDecoration(color: LrColors.verified, shape: BoxShape.circle),
                        ),
                      ),
                    if (widget.count > 0)
                      Positioned(
                        right: 4,
                        top: 2,
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                          decoration: BoxDecoration(
                            color: LrColors.verified,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text('${widget.count}',
                              style: const TextStyle(color: Color(0xFF00201C), fontSize: 10, fontWeight: FontWeight.w700)),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 4),
              Text(
                widget.label,
                textAlign: TextAlign.center,
                maxLines: 2,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: sel ? FontWeight.w600 : FontWeight.w400,
                  color: sel ? LrColors.text : color,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
