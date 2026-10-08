// apps/desktop/lib/ui/home_shell.dart
import 'package:flutter/material.dart';

import '../app_services.dart';
import 'jobs_page.dart';
import 'library_page.dart';
import 'receive_page.dart';
import 'settings_page.dart';

class HomeShell extends StatefulWidget {
  const HomeShell({super.key, required this.services});

  final AppServices services;

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _index = 0;

  @override
  void initState() {
    super.initState();
    // First launch with an empty library: start on the pairing page.
    if (widget.services.library.items.isEmpty) _index = 1;
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
            listenable: Listenable.merge([s.hub, s.converter]),
            builder: (context, _) => NavigationRail(
              selectedIndex: _index,
              onDestinationSelected: (i) => setState(() => _index = i),
              labelType: NavigationRailLabelType.all,
              leading: Padding(
                padding: const EdgeInsets.symmetric(vertical: 16),
                child: Text('LocalRoll', style: Theme.of(context).textTheme.titleMedium),
              ),
              destinations: [
                const NavigationRailDestination(
                  icon: Icon(Icons.photo_library_outlined),
                  selectedIcon: Icon(Icons.photo_library),
                  label: Text('媒体库'),
                ),
                NavigationRailDestination(
                  icon: Badge(
                    isLabelVisible: s.hub.transfers.any((t) => t.fraction != null && t.fraction! < 1),
                    child: const Icon(Icons.phone_iphone_outlined),
                  ),
                  selectedIcon: const Icon(Icons.phone_iphone),
                  label: const Text('接收'),
                ),
                NavigationRailDestination(
                  icon: Badge(
                    isLabelVisible: s.converter.pending > 0,
                    label: Text('${s.converter.pending}'),
                    child: const Icon(Icons.auto_fix_high_outlined),
                  ),
                  selectedIcon: const Icon(Icons.auto_fix_high),
                  label: const Text('转换'),
                ),
                const NavigationRailDestination(
                  icon: Icon(Icons.settings_outlined),
                  selectedIcon: Icon(Icons.settings),
                  label: Text('设置'),
                ),
              ],
            ),
          ),
          const VerticalDivider(width: 1),
          Expanded(child: IndexedStack(index: _index, children: pages)),
        ],
      ),
    );
  }
}
