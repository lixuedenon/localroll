// apps/desktop/lib/ui/home_shell.dart
import 'package:flutter/material.dart';

import '../app_services.dart';
import '../l10n/l10n.dart';
import 'app_nav.dart';
import 'jobs_page.dart';
import 'library_page.dart';
import 'receive_page.dart';
import 'settings_page.dart';
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

  @override
  void initState() {
    super.initState();
    // First launch with an empty library: start on the pairing page.
    _nav.initialTab(widget.services.library.items.isEmpty ? 1 : 0);
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.services;
    final pages = [
      LibraryPage(services: s),
      ReceivePage(services: s),
      JobsPage(services: s),
      SettingsPage(services: s),
    ];
    return Scaffold(
      body: Row(
        children: [
          ListenableBuilder(
            listenable: Listenable.merge([s.hub, s.converter, _nav]),
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
                      icon: Icons.photo_library_outlined,
                      selectedIcon: Icons.photo_library_rounded,
                      label: tr('nav.library'),
                      selected: _nav.tab == 0,
                      onTap: () => _nav.selectTab(0),
                    ),
                    _RailItem(
                      icon: Icons.phone_iphone_outlined,
                      selectedIcon: Icons.phone_iphone_rounded,
                      label: tr('nav.receive'),
                      selected: _nav.tab == 1,
                      dot: receiving,
                      onTap: () => _nav.selectTab(1),
                    ),
                    _RailItem(
                      icon: Icons.auto_fix_high_outlined,
                      selectedIcon: Icons.auto_fix_high_rounded,
                      label: tr('nav.convert'),
                      selected: _nav.tab == 2,
                      count: s.converter.pending,
                      onTap: () => _nav.selectTab(2),
                    ),
                    _RailItem(
                      icon: Icons.tune_outlined,
                      selectedIcon: Icons.tune_rounded,
                      label: tr('nav.settings'),
                      selected: _nav.tab == 3,
                      onTap: () => _nav.selectTab(3),
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
          ),
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
  });

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

class _RailItemState extends State<_RailItem> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
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
