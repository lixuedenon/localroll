// apps/desktop/lib/ui/add_device_dialog.dart
import 'dart:async';

import 'package:flutter/material.dart';

import '../app_services.dart';
import '../l10n/l10n.dart';
import 'receive_page.dart' show PairingPanel;
import 'theme.dart';

/// "Add a device": a phone (tap this PC in LocalRoll on the phone; the QR
/// code / PIN when it can't find it), or another PC (search nearby).
Future<void> showAddDevice(BuildContext context, AppServices s) => showDialog<void>(
      context: context,
      builder: (ctx) => Dialog(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 820, maxHeight: 640),
          child: DefaultTabController(
            length: 2,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 18, 16, 16),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Row(children: [
                  Expanded(child: Text(tr('dev.add'), style: Theme.of(ctx).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700))),
                  IconButton(tooltip: tr('common.close'), onPressed: () => Navigator.pop(ctx), icon: const Icon(Icons.close_rounded)),
                ]),
                TabBar(
                  isScrollable: true,
                  tabAlignment: TabAlignment.start,
                  tabs: [
                    Tab(icon: const Icon(Icons.smartphone_rounded), text: tr('add.phone')),
                    Tab(icon: const Icon(Icons.computer_rounded), text: tr('add.pc')),
                  ],
                ),
                const SizedBox(height: 12),
                Expanded(
                  child: TabBarView(children: [
                    // A phone: the usual way first, the QR code / PIN below.
                    ListView(children: [
                      for (final (n, k) in [(1, 'add.step1'), (2, 'add.step2'), (3, 'add.step3')])
                        _step(n, tr(k, {'name': s.settings.deviceName})),
                      const SizedBox(height: 10),
                      Text(tr('add.qr_hint'), style: const TextStyle(color: LrColors.muted, fontSize: 13)),
                      ListenableBuilder(
                        listenable: Listenable.merge([s.server, s.server.pin, s.addresses]),
                        builder: (context, _) => PairingPanel(services: s, qrSize: 200),
                      ),
                      Text(tr('add.family_default'), style: const TextStyle(color: LrColors.muted, fontSize: 12)),
                    ]),
                    // Another PC: open LocalRoll there, then search here.
                    ListView(children: [
                      _step(1, tr('add.pc_step1')),
                      _step(2, tr('add.pc_step2')),
                      const SizedBox(height: 16),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: FilledButton.icon(
                          onPressed: () {
                            Navigator.pop(ctx);
                            unawaited(s.peers.scan());
                          },
                          icon: const Icon(Icons.radar_rounded),
                          label: Text(tr('add.pc_search')),
                        ),
                      ),
                    ]),
                  ]),
                ),
              ]),
            ),
          ),
        ),
      ),
    );

Widget _step(int n, String text) => Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(
          width: 26,
          height: 26,
          alignment: Alignment.center,
          decoration: const BoxDecoration(color: LrColors.safelight, shape: BoxShape.circle),
          child: Text('$n', style: const TextStyle(color: Color(0xFF2B1A00), fontWeight: FontWeight.w700)),
        ),
        const SizedBox(width: 12),
        Expanded(child: Padding(padding: const EdgeInsets.only(top: 3), child: Text(text, style: const TextStyle(fontSize: 15)))),
      ]),
    );
