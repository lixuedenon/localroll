// apps/desktop/lib/ui/hotspot_card.dart
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../l10n/l10n.dart';
import '../services/hotspot.dart';
import 'light_dialog.dart';
import 'light_look.dart';
import 'lr_dialog.dart';

/// Switches this PC's hotspot on and shows how a phone joins it (a QR code
/// with the name and password).
Future<void> showHotspot(BuildContext context) async {
  final h = Hotspot.instance;
  if (!h.on) unawaited(h.start());
  await showLrDialog<void>(context: context, builder: (_) => const _HotspotDialog());
}

/// How to use the phone's own hotspot instead.
Future<void> showPhoneHotspotHelp(BuildContext context) => showLrDialog<void>(
      context: context,
      builder: (ctx) => LightDialog(
        icon: Icons.phone_iphone_rounded,
        title: tr('hot.phone_title'),
        actions: [FilledButton(onPressed: () => Navigator.pop(ctx), child: Text(tr('common.done')))],
        child: Text(tr('hot.phone_body'), style: const TextStyle(color: LightLook.text, height: 1.7)),
      ),
    );

class _HotspotDialog extends StatelessWidget {
  const _HotspotDialog();

  @override
  Widget build(BuildContext context) {
    final h = Hotspot.instance;
    return ListenableBuilder(
      listenable: h,
      builder: (context, _) {
        final failed = !h.on && !h.busy && h.why != null;
        return LightDialog(
          icon: Icons.wifi_tethering_rounded,
          title: h.on ? tr('hot.on_title') : tr('hot.title'),
          subtitle: h.on ? tr('hot.on_sub', {'n': h.clients}) : tr('hot.sub'),
          actions: [
            if (h.on)
              OutlinedButton(
                onPressed: h.busy ? null : () => unawaited(h.stop()),
                child: Text(tr('hot.stop')),
              ),
            if (failed)
              OutlinedButton(onPressed: () => unawaited(showPhoneHotspotHelp(context)), child: Text(tr('hot.use_phone'))),
            if (failed) OutlinedButton(onPressed: () => unawaited(h.start()), child: Text(tr('net.again'))),
            FilledButton(onPressed: () => Navigator.pop(context), child: Text(tr('common.done'))),
          ],
          child: h.busy && !h.on
              ? const Padding(padding: EdgeInsets.all(30), child: Center(child: CircularProgressIndicator()))
              : failed
                  ? Text(tr(_whyKey(h.why!)), style: const TextStyle(color: LightLook.text, height: 1.7))
                  : !h.on
                      ? Text(tr('hot.off'), style: const TextStyle(color: LightLook.muted))
                      : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Container(
                              padding: const EdgeInsets.all(8),
                              decoration: BoxDecoration(
                                color: Colors.white,
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(color: const Color(0xFFE6ECF7)),
                              ),
                              child: QrImageView(data: h.qr, size: 170, backgroundColor: Colors.white),
                            ),
                            const SizedBox(width: 18),
                            Expanded(
                              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                _kv(tr('hot.name'), h.ssid),
                                const SizedBox(height: 8),
                                _kv(tr('hot.pass'), h.pass),
                                const SizedBox(height: 12),
                                Text(tr('hot.steps'), style: const TextStyle(color: LightLook.muted, fontSize: 13, height: 1.8)),
                              ]),
                            ),
                          ]),
                          const SizedBox(height: 12),
                          CheckboxListTile(
                            contentPadding: EdgeInsets.zero,
                            dense: true,
                            value: h.autoOff,
                            onChanged: (v) => h.setAutoOff(v ?? true),
                            title: Text(tr('hot.auto_off', {'min': Hotspot.idleOff.inMinutes})),
                          ),
                          Text(tr('hot.note'), style: const TextStyle(color: LightLook.muted, fontSize: 12, height: 1.6)),
                        ]),
        );
      },
    );
  }

  static String _whyKey(String why) => switch (why) {
        'no_internet' => 'hot.why_no_internet',
        'DisabledByHardwareLimitation' || 'DisabledBySku' || 'DisabledByRequiredAppNotInstalled' => 'hot.why_hardware',
        'DisabledByGroupPolicy' || 'DisabledBySystemCapability' || 'DisabledByOperator' => 'hot.why_policy',
        'WiFiDeviceOff' || 'DisabledByRadioOff' => 'hot.why_wifi_off',
        _ => 'hot.why_other',
      };

  static Widget _kv(String k, String v) => Row(children: [
        SizedBox(width: 52, child: Text(k, style: const TextStyle(color: LightLook.muted))),
        Flexible(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(color: const Color(0xFFF3F6FC), borderRadius: BorderRadius.circular(6)),
            child: SelectableText(v, style: const TextStyle(fontFamily: 'Consolas', fontSize: 15, color: LightLook.text)),
          ),
        ),
      ]);
}
