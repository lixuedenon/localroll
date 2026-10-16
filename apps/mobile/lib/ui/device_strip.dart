// apps/mobile/lib/ui/device_strip.dart
import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import '../services/discovery.dart';
import '../services/mobile_settings.dart';
import 'breathing.dart';
import 'device_badge.dart';
import 'theme.dart';

/// One device as Home shows it: a paired PC, or a phone nearby.
class StripDevice {
  const StripDevice({required this.id, required this.name, required this.online, this.pc, this.phone, this.isPc = true});

  final String id;
  final String name;
  final bool online;
  final PairedDesktop? pc;
  final NearbyPhone? phone;
  final bool isPc;
}

/// Everything Home lists: our PCs (the backup PC first), then phones nearby.
List<StripDevice> stripDevices(MobileSettings settings, DesktopDiscovery discovery) {
  final cur = settings.current;
  final pcs = [
    ?cur,
    for (final d in settings.desktops)
      if (d.id != cur?.id) d,
  ];
  return [
    for (final d in pcs) StripDevice(id: d.id, name: d.name, online: discovery.isOnline(d.id), pc: d),
    for (final p in discovery.phones) StripDevice(id: p.id, name: p.name, online: true, phone: p, isPc: false),
  ];
}

/// Home's device row: one small chip each (online ones glow), "+" to add.
class DeviceStrip extends StatelessWidget {
  const DeviceStrip({super.key, required this.settings, required this.discovery, required this.onTap, required this.onAdd, this.big = false});

  final MobileSettings settings;
  final DesktopDiscovery discovery;
  final void Function(StripDevice d) onTap;
  final VoidCallback onAdd;

  /// Simple mode: larger chips.
  final bool big;

  @override
  Widget build(BuildContext context) {
    final list = stripDevices(settings, discovery);
    final cur = settings.current?.id;
    final h = big ? 64.0 : 52.0;
    return SizedBox(
      height: h,
      child: ListView(
        scrollDirection: Axis.horizontal,
        children: [
          for (final d in list)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Material(
                color: LrColors.surface,
                shape: StadiumBorder(
                  side: BorderSide(color: d.online ? onlineGlow : LrColors.line, width: d.online ? 1.5 : 1),
                ),
                child: InkWell(
                  customBorder: const StadiumBorder(),
                  onTap: () => onTap(d),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(6, 6, 14, 6),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      _avatar(d, h - 14),
                      const SizedBox(width: 8),
                      Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(d.name, style: TextStyle(fontWeight: FontWeight.w700, fontSize: big ? 16 : 14)),
                        Text(
                          d.id == cur
                              ? '● ${tr('home.backup_pc')}'
                              : d.online
                                  ? '● ${tr(d.isPc ? 'home.kind_pc' : 'home.kind_phone')}'
                                  : tr('home.pc_offline'),
                          style: TextStyle(fontSize: big ? 13 : 11, color: d.online ? onlineGlow : LrColors.muted),
                        ),
                      ]),
                    ]),
                  ),
                ),
              ),
            ),
          Center(
            child: SizedBox(
              width: h - 4,
              height: h - 4,
              child: OutlinedButton(
                style: OutlinedButton.styleFrom(shape: const CircleBorder(), padding: EdgeInsets.zero),
                onPressed: onAdd,
                child: Icon(Icons.add_rounded, semanticLabel: tr('home.add_device')),
              ),
            ),
          ),
        ],
      ),
    );
  }

  static Widget _avatar(StripDevice d, double size) {
    final pc = d.pc;
    if (pc != null) {
      return DeviceBadge(
        icon: pc.icon,
        color: pc.color,
        image: pc.avatarUrl == null ? null : NetworkImage(pc.avatarUrl!),
        size: size,
      );
    }
    return CircleAvatar(
      radius: size / 2,
      backgroundColor: LrColors.raised,
      child: Icon(d.isPc ? Icons.computer_rounded : Icons.smartphone_rounded, color: LrColors.muted, size: size * 0.55),
    );
  }
}

/// What can be done with a device (from its card).
enum DeviceAction { sendPhotos, sendFiles, browse, makeBackup, settings }

/// Tapped a device: its card with what can be done with it.
Future<DeviceAction?> showDeviceSheet(BuildContext context, StripDevice d, {required bool isBackupPc}) =>
    showModalBottomSheet<DeviceAction>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (c) {
        Widget item(DeviceAction a, IconData icon, String title, String sub, {bool enabled = true}) => ListTile(
              enabled: enabled,
              leading: Icon(icon, color: enabled ? LrColors.safelight : LrColors.muted),
              title: Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
              subtitle: Text(sub),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () => Navigator.pop(c, a),
            );
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 12),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              ListTile(
                leading: DeviceStrip._avatar(d, 52),
                title: Text(d.name, style: Theme.of(c).textTheme.titleLarge),
                subtitle: Text(
                  [
                    tr(d.isPc ? 'home.kind_pc' : 'home.kind_phone'),
                    tr(d.online ? 'home.pc_online' : 'home.pc_offline'),
                    if (isBackupPc) tr('home.backup_pc'),
                  ].join(' · '),
                  style: TextStyle(color: d.online ? onlineGlow : LrColors.muted),
                ),
              ),
              const Divider(),
              item(DeviceAction.sendPhotos, Icons.photo_library_rounded, tr('dev.send_photos'), tr('dev.send_photos_sub'), enabled: d.online),
              item(DeviceAction.sendFiles, Icons.insert_drive_file_rounded, tr('dev.send_files'), tr('dev.send_files_sub'), enabled: d.online),
              if (d.pc != null) ...[
                item(DeviceAction.browse, Icons.photo_rounded, tr('dev.browse'), tr('dev.browse_sub'), enabled: d.online),
                if (!isBackupPc) item(DeviceAction.makeBackup, Icons.backup_rounded, tr('dev.make_backup'), tr('dev.make_backup_sub')),
                item(DeviceAction.settings, Icons.settings_rounded, tr('dev.settings'), tr('dev.settings_sub')),
              ],
            ]),
          ),
        );
      },
    );

/// What to send (the first step of "Send").
enum SendKind { photos, files, scan }

/// "Send": what, then to whom (a [PairedDesktop] or a [NearbyPhone]).
/// Scanning needs no target here (the scan page asks after scanning).
Future<(SendKind, Object?)?> showSendSheet(BuildContext context, MobileSettings settings, DesktopDiscovery discovery) =>
    showModalBottomSheet<(SendKind, Object?)>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => _SendSheet(settings: settings, discovery: discovery),
    );

class _SendSheet extends StatefulWidget {
  const _SendSheet({required this.settings, required this.discovery});

  final MobileSettings settings;
  final DesktopDiscovery discovery;

  @override
  State<_SendSheet> createState() => _SendSheetState();
}

class _SendSheetState extends State<_SendSheet> {
  SendKind _kind = SendKind.photos;
  String? _to;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: widget.discovery,
      builder: (context, _) {
        final all = stripDevices(widget.settings, widget.discovery);
        final online = all.where((d) => d.online).toList();
        _to ??= online.isEmpty ? null : online.first.id;
        final target = online.where((d) => d.id == _to).firstOrNull;
        Widget kind(SendKind k, IconData icon, String label) => Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Material(
                  color: LrColors.surface,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                    side: BorderSide(color: _kind == k ? LrColors.safelight : LrColors.line, width: _kind == k ? 1.5 : 1),
                  ),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(14),
                    onTap: () => setState(() => _kind = k),
                    child: SizedBox(
                      height: 84,
                      child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                        Icon(icon, color: LrColors.safelight),
                        const SizedBox(height: 6),
                        Text(label, textAlign: TextAlign.center, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
                      ]),
                    ),
                  ),
                ),
              ),
            );
        final needsTarget = _kind != SendKind.scan;
        final ready = !needsTarget || target != null;
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text(tr('send.sheet_title'), style: theme.textTheme.titleLarge),
              const SizedBox(height: 14),
              Text(tr('send.step_what'), style: const TextStyle(color: LrColors.muted)),
              const SizedBox(height: 8),
              Row(children: [
                kind(SendKind.photos, Icons.photo_library_rounded, tr('send.kind_photos')),
                kind(SendKind.files, Icons.insert_drive_file_rounded, tr('send.kind_files')),
                kind(SendKind.scan, Icons.document_scanner_rounded, tr('send.kind_scan')),
              ]),
              if (needsTarget) ...[
                const SizedBox(height: 18),
                Text(tr('send.step_who'), style: const TextStyle(color: LrColors.muted)),
                const SizedBox(height: 4),
                if (online.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Text(tr('send.nobody_online'), style: const TextStyle(color: LrColors.muted)),
                  ),
                ConstrainedBox(
                  constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.35),
                  child: ListView(shrinkWrap: true, children: [
                    for (final d in online)
                      ListTile(
                        contentPadding: const EdgeInsets.symmetric(horizontal: 4),
                        leading: DeviceStrip._avatar(d, 40),
                        title: Text(d.name, style: const TextStyle(fontWeight: FontWeight.w600)),
                        subtitle: Text(
                          [
                            tr(d.isPc ? 'home.kind_pc' : 'home.kind_phone'),
                            if (d.id == widget.settings.current?.id) tr('home.backup_pc'),
                          ].join(' · '),
                          style: const TextStyle(color: onlineGlow),
                        ),
                        trailing: Icon(_to == d.id ? Icons.radio_button_checked_rounded : Icons.radio_button_off_rounded,
                            color: _to == d.id ? LrColors.safelight : LrColors.muted),
                        onTap: () => setState(() => _to = d.id),
                      ),
                  ]),
                ),
              ],
              const SizedBox(height: 16),
              SizedBox(
                height: 52,
                child: FilledButton(
                  onPressed: ready ? () => Navigator.pop(context, (_kind, target?.pc ?? target?.phone)) : null,
                  child: Text(tr(switch (_kind) {
                    SendKind.photos => 'send.next_photos',
                    SendKind.files => 'send.next_files',
                    SendKind.scan => 'send.next_scan',
                  }), style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
                ),
              ),
            ]),
          ),
        );
      },
    );
  }
}
