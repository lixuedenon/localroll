// apps/desktop/lib/ui/feature_list.dart
import 'package:flutter/material.dart';

import '../app_services.dart';
import '../l10n/l10n.dart';
import 'app_nav.dart';
import 'theme.dart';

/// One thing LocalRoll does, and where it is.
typedef _Feature = ({IconData icon, String key, int tab});

const List<_Feature> _features = [
  (icon: Icons.swap_horiz_rounded, key: 'transfer', tab: AppNav.devices),
  (icon: Icons.backup_rounded, key: 'backup', tab: AppNav.devices),
  (icon: Icons.photo_library_rounded, key: 'library', tab: AppNav.library),
  (icon: Icons.manage_search_rounded, key: 'search', tab: AppNav.library),
  (icon: Icons.play_circle_rounded, key: 'player', tab: AppNav.player),
  (icon: Icons.videocam_rounded, key: 'screen', tab: AppNav.screen),
  (icon: Icons.auto_fix_high_rounded, key: 'convert', tab: AppNav.convert),
  (icon: Icons.phone_iphone_rounded, key: 'phone', tab: AppNav.devices),
];

/// "What I can do": each line opens that part of LocalRoll.
class FeatureList extends StatelessWidget {
  const FeatureList({super.key, this.onOpen});

  /// Called before going there (a dialog closes itself).
  final VoidCallback? onOpen;

  @override
  Widget build(BuildContext context) => Wrap(spacing: 12, runSpacing: 4, children: [
        for (final f in _features)
          SizedBox(
            width: 360,
            child: ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 8),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              leading: Icon(f.icon, color: LrColors.safelight),
              title: Text(tr('features.${f.key}')),
              subtitle: Text(tr('features.${f.key}_tip'), style: const TextStyle(fontSize: 12.5, height: 1.4)),
              trailing: const Icon(Icons.chevron_right_rounded, color: LrColors.muted),
              onTap: () {
                onOpen?.call();
                AppNav.instance.selectTab(f.tab);
              },
            ),
          ),
      ]);
}

/// On Home until the person says they know it.
class FeatureCard extends StatelessWidget {
  const FeatureCard({super.key, required this.services});

  final AppServices services;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.fromLTRB(18, 14, 12, 12),
        decoration: BoxDecoration(
          color: LrColors.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: LrColors.safelight.withValues(alpha: 0.6)),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Icon(Icons.waving_hand_rounded, color: LrColors.safelight),
            const SizedBox(width: 10),
            Expanded(
              child: Text(tr('features.title'), style: Theme.of(context).textTheme.titleMedium),
            ),
            TextButton(
              onPressed: () => services.settings.update((x) => x.showFeatures = false),
              child: Text(tr('features.got_it')),
            ),
          ]),
          Padding(
            padding: const EdgeInsets.only(left: 34, bottom: 6),
            child: Text(tr('features.where'), style: const TextStyle(color: LrColors.muted, fontSize: 12.5)),
          ),
          const FeatureList(),
        ]),
      );
}

/// Settings › "What I can do" (any time).
Future<void> showFeatures(BuildContext context) => showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('features.title')),
        content: SizedBox(width: 744, child: SingleChildScrollView(child: FeatureList(onOpen: () => Navigator.pop(ctx)))),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: Text(tr('common.close')))],
      ),
    );
