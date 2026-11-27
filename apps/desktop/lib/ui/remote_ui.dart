// apps/desktop/lib/ui/remote_ui.dart
import 'package:flutter/material.dart';

import '../app_services.dart';
import '../l10n/l10n.dart';
import '../services/remote_control.dart';
import 'app_nav.dart';
import 'light_look.dart';
import 'lr_dialog.dart';

/// "May this phone control this PC?" — asked once; the answer says how long.
Future<RemoteGrant> askRemote(String name) async {
  final context = AppNav.instance.navigatorKey.currentContext;
  if (context == null || !context.mounted) return RemoteGrant.no;
  final g = await showLrDialog<RemoteGrant>(
    context: context,
    barrierDismissible: false,
    builder: (c) => AlertDialog(
      icon: const Icon(Icons.phonelink_lock_rounded, color: LightLook.blue, size: 34),
      title: Text(tr('remote.ask_title', {'name': name})),
      content: SizedBox(width: 460, child: Text(tr('remote.ask_body', {'name': name}))),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c, RemoteGrant.no), child: Text(tr('remote.no'))),
        OutlinedButton(onPressed: () => Navigator.pop(c, RemoteGrant.once), child: Text(tr('remote.once'))),
        OutlinedButton(onPressed: () => Navigator.pop(c, RemoteGrant.hour), child: Text(tr('remote.hour'))),
        FilledButton(onPressed: () => Navigator.pop(c, RemoteGrant.always), child: Text(tr('remote.always'))),
      ],
    ),
  );
  return g ?? RemoteGrant.no;
}

/// While a phone is controlling this PC: who, and a button to stop it
/// (top right, over every page).
class RemoteBadge extends StatelessWidget {
  const RemoteBadge({super.key, required this.services});

  final AppServices services;

  @override
  Widget build(BuildContext context) {
    final r = services.remote;
    return Positioned(
      top: 8,
      right: 160,
      child: ListenableBuilder(
        listenable: r,
        builder: (context, _) {
          final id = r.activeId;
          if (id == null) return const SizedBox.shrink();
          return Material(
            color: const Color(0xFF16213E),
            borderRadius: BorderRadius.circular(18),
            elevation: 6,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                const Icon(Icons.phone_iphone_rounded, size: 16, color: Colors.white),
                const SizedBox(width: 6),
                Text(tr('remote.active', {'name': r.activeName ?? ''}), style: const TextStyle(color: Colors.white, fontSize: 12)),
                const SizedBox(width: 6),
                PopupMenuButton<bool>(
                  tooltip: '',
                  onSelected: (forGood) => r.stop(id, forGood: forGood),
                  itemBuilder: (_) => [
                    PopupMenuItem(value: false, child: Text(tr('remote.stop_now'))),
                    PopupMenuItem(value: true, child: Text(tr('remote.stop_always'))),
                  ],
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                    decoration: BoxDecoration(color: const Color(0xFFE5484D), borderRadius: BorderRadius.circular(14)),
                    child: Text(tr('remote.stop'), style: const TextStyle(color: Colors.white, fontSize: 12)),
                  ),
                ),
              ]),
            ),
          );
        },
      ),
    );
  }
}
