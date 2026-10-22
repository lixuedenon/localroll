// apps/mobile/lib/ui/settings_page.dart
import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:localroll_core/localroll_core.dart';

import '../l10n/l10n.dart';
import '../services/discovery.dart';
import '../services/media_saver.dart';
import '../services/mobile_settings.dart';
import '../services/phone_names.dart';
import '../services/visibility_sync.dart';
import 'connect_page.dart';
import 'device_badge.dart';
import 'theme.dart';

/// Phone settings: auto-send, language, PCs.
class SettingsPage extends StatelessWidget {
  const SettingsPage({
    super.key,
    required this.settings,
    required this.discovery,
    required this.onAutoSendChanged,
  });

  final MobileSettings settings;
  final DesktopDiscovery discovery;
  final Future<void> Function() onAutoSendChanged;

  /// New default for what this phone sends; asked whether what was sent
  /// already changes too (it does at once on every PC that is on).
  Future<void> _changeVisibility(BuildContext context, bool share) async {
    if (share == settings.shareWithFamily) return;
    final everything = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(tr(share ? 'family.all_shared_title' : 'family.all_private_title')),
        content: Text(tr('family.all_body')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: Text(tr('family.only_new'))),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: Text(tr('family.everything'))),
        ],
      ),
    );
    if (everything == null) return;
    await settings.setShareWithFamily(share, everything: everything);
    if (!everything) return;
    final left = await VisibilitySync.pushAll(settings, discovery);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(left == 0
          ? tr(share ? 'family.all_now_shared' : 'family.all_now_private')
          : tr('family.all_later', {'count': left})),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: settings,
      builder: (context, _) {
        final theme = Theme.of(context);
        final d = settings.current;
        return Scaffold(
          appBar: AppBar(title: Text(tr('settings.title'))),
          body: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              // Auto-send.
              Text(tr('home.auto_send'), style: theme.textTheme.titleMedium),
              const SizedBox(height: 8),
              Card(
                child: SwitchListTile(
                  secondary: const Icon(Icons.bolt_rounded, color: LrColors.safelight),
                  value: settings.autoSend,
                  onChanged: d == null
                      ? null
                      : (on) async {
                          await settings.setAutoSend(on);
                          if (on && context.mounted) {
                            ScaffoldMessenger.of(context)
                                .showSnackBar(SnackBar(content: Text(tr('auto.enabled', {'pc': d.name}))));
                          }
                          await onAutoSendChanged();
                        },
                  title: Text(tr('settings.auto_send')),
                  subtitle: Text(d == null ? tr('home.not_connected') : tr('settings.auto_send_hint', {'pc': d.name})),
                ),
              ),
              const SizedBox(height: 24),

              // PC.
              Text(tr('settings.pc'), style: theme.textTheme.titleMedium),
              const SizedBox(height: 8),
              Card(
                child: ListTile(
                  leading: d == null
                      ? const Icon(Icons.add_link_rounded)
                      : DeviceBadge(
                          icon: d.icon,
                          color: d.color,
                          image: d.avatarUrl == null ? null : NetworkImage(d.avatarUrl!),
                          size: 40,
                        ),
                  title: Text(d?.name ?? tr('home.not_connected')),
                  subtitle: Text(tr('settings.manage_pcs')),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: () => Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => ConnectPage(settings: settings, discovery: discovery),
                  )),
                ),
              ),
              const SizedBox(height: 24),

              // Family group.
              Text(tr('family.title'), style: theme.textTheme.titleMedium),
              const SizedBox(height: 8),
              Card(
                child: Column(
                  children: [
                    // This phone's own name (like a PC's): its own, or a
                    // pleasant random one.
                    ListTile(
                      leading: Icon(Platform.isIOS ? Icons.phone_iphone_rounded : Icons.phone_android_rounded),
                      title: Text(tr('phone.name_title')),
                      subtitle: Text(settings.deviceName),
                      trailing: const Icon(Icons.edit_rounded, size: 20),
                      onTap: () => _editPhoneName(context),
                    ),
                    const Divider(height: 1),
                    ListTile(
                      leading: const Icon(Icons.badge_rounded),
                      title: Text(tr('family.your_name')),
                      subtitle: Text(settings.ownerName.isEmpty ? tr('family.your_name_hint') : settings.ownerName),
                      trailing: const Icon(Icons.edit_rounded, size: 20),
                      onTap: () => _editName(context),
                    ),
                    const Divider(height: 1),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                      child: Align(
                        alignment: AlignmentDirectional.centerStart,
                        child: Text(tr('family.default_visibility'), style: theme.textTheme.bodyMedium),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                      child: SizedBox(
                        width: double.infinity,
                        child: SegmentedButton<bool>(
                          segments: [
                            ButtonSegment(value: true, icon: const Icon(Icons.groups_rounded), label: Text(tr('family.shared'))),
                            ButtonSegment(value: false, icon: const Icon(Icons.lock_rounded), label: Text(tr('family.only_me'))),
                          ],
                          selected: {settings.shareWithFamily},
                          onSelectionChanged: (v) => _changeVisibility(context, v.first),
                        ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                      child: Text(tr('family.visibility_hint'), style: theme.textTheme.bodySmall),
                    ),
                    const Divider(height: 1),
                    SwitchListTile(
                      secondary: const Icon(Icons.elderly_rounded),
                      value: settings.simpleMode,
                      onChanged: (on) async {
                        await settings.setSimpleMode(on);
                        await onAutoSendChanged();
                        if (on && context.mounted) Navigator.of(context).pop();
                      },
                      title: Text(tr('simple.title')),
                      subtitle: Text(tr('simple.hint')),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),

              // Language: one line; the list opens in a sheet.
              Card(
                child: ListTile(
                  leading: const Icon(Icons.translate_rounded),
                  title: Text(tr('home.language')),
                  trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                    Text(
                      supportedLanguages.where((l) => l.code == settings.language).firstOrNull?.nativeName ??
                          tr('home.language_system'),
                      style: const TextStyle(color: LrColors.muted),
                    ),
                    const Icon(Icons.chevron_right_rounded, color: LrColors.muted),
                  ]),
                  onTap: () => _pickLanguage(context, settings),
                ),
              ),
              const SizedBox(height: 24),
              Text(tr('settings.log_title'), style: theme.textTheme.titleMedium),
              const SizedBox(height: 8),
              Card(
                child: Column(children: [
                  ListTile(
                    leading: const Icon(Icons.receipt_long_outlined),
                    title: Text(tr('settings.log_export')),
                    subtitle: Text(tr('settings.log_hint')),
                    onTap: () => _exportLog(context),
                  ),
                  ListTile(
                    leading: const Icon(Icons.privacy_tip_outlined),
                    title: Text(tr('privacy.title')),
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: () => _showPrivacy(context),
                  ),
                ]),
              ),
              const SizedBox(height: 24),
              Center(child: Text('LocalRoll · ${tr('settings.version', {'version': lrVersion})}', style: theme.textTheme.bodySmall)),
            ],
          ),
        );
      },
    );
  }
}

extension on SettingsPage {
  Future<void> _editPhoneName(BuildContext context) async {
    final ctrl = TextEditingController(text: settings.deviceName);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('phone.name_title')),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: ctrl,
              autofocus: true,
              maxLength: 40,
              textCapitalization: TextCapitalization.words,
              onSubmitted: (v) => Navigator.pop(ctx, v),
              decoration: InputDecoration(
                suffixIcon: IconButton(
                  tooltip: tr('phone.name_random'),
                  icon: const Icon(Icons.casino_rounded),
                  onPressed: () => ctrl.text = PhoneNames.random(not: ctrl.text),
                ),
              ),
            ),
            Text(tr('phone.name_explain'), style: Theme.of(ctx).textTheme.bodySmall),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(tr('common.cancel'))),
          FilledButton(onPressed: () => Navigator.pop(ctx, ctrl.text), child: Text(tr('common.ok'))),
        ],
      ),
    );
    ctrl.dispose();
    if (name == null || name.trim().isEmpty) return;
    await PhoneNames.rename(settings, discovery, name);
  }

  Future<void> _editName(BuildContext context) async {
    final ctrl = TextEditingController(text: settings.ownerName);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('family.your_name')),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: ctrl,
              autofocus: true,
              textCapitalization: TextCapitalization.words,
              onSubmitted: (v) => Navigator.pop(ctx, v),
            ),
            const SizedBox(height: 8),
            Text(tr('family.your_name_explain'), style: Theme.of(ctx).textTheme.bodySmall),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(tr('common.cancel'))),
          FilledButton(onPressed: () => Navigator.pop(ctx, ctrl.text), child: Text(tr('common.ok'))),
        ],
      ),
    );
    ctrl.dispose();
    if (name != null) {
      await settings.setOwnerName(name);
      // Shown on the PCs at once (sent with the phone's name).
      await PhoneNames.rename(settings, discovery, settings.deviceName);
    }
  }
}

class _LanguageTile extends StatelessWidget {
  const _LanguageTile({required this.label, required this.selected, required this.onTap});

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => ListTile(
        title: Text(label),
        trailing: selected ? const Icon(Icons.check_rounded, color: LrColors.safelight) : null,
        onTap: onTap,
      );
}

/// The language: on iPhone the system's own wheel picker (with "Done"),
/// elsewhere a list in a sheet (system default first, a check on the one in use).
Future<void> _pickLanguage(BuildContext context, MobileSettings settings) async {
  final codes = <String>['', for (final l in supportedLanguages) l.code];
  final names = [tr('home.language_system'), for (final l in supportedLanguages) l.nativeName];
  final now = codes.indexOf(settings.language ?? '').clamp(0, codes.length - 1);
  String? picked;
  if (Platform.isIOS) {
    var at = now;
    picked = await showCupertinoModalPopup<String>(
      context: context,
      builder: (c) => Container(
        height: 300,
        color: LrColors.raised,
        child: SafeArea(
          top: false,
          child: Column(children: [
            Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
              CupertinoButton(onPressed: () => Navigator.pop(c), child: Text(tr('common.cancel'))),
              CupertinoButton(onPressed: () => Navigator.pop(c, codes[at]), child: Text(tr('common.ok'))),
            ]),
            Expanded(
              child: CupertinoPicker(
                itemExtent: 36,
                scrollController: FixedExtentScrollController(initialItem: now),
                onSelectedItemChanged: (i) => at = i,
                children: [for (final n in names) Center(child: Text(n))],
              ),
            ),
          ]),
        ),
      ),
    );
  } else {
    picked = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (c) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.of(c).size.height * 0.6),
          child: ListView(shrinkWrap: true, children: [
            for (var i = 0; i < codes.length; i++)
              _LanguageTile(label: names[i], selected: i == now, onTap: () => Navigator.pop(c, codes[i])),
          ]),
        ),
      ),
    );
  }
  if (picked == null) return;
  await settings.setLanguage(picked.isEmpty ? null : picked);
}

/// Diagnostics log → a text file in Files › LocalRoll (iPhone) or
/// Download/LocalRoll (Android), to send to whoever helps.
Future<void> _exportLog(BuildContext context) async {
  final m = ScaffoldMessenger.of(context);
  try {
    final dir = await MediaSaver.filesFolder();
    final d = DateTime.now();
    final stamp = '${d.year}${d.month.toString().padLeft(2, '0')}${d.day.toString().padLeft(2, '0')}-'
        '${d.hour.toString().padLeft(2, '0')}${d.minute.toString().padLeft(2, '0')}';
    await File('${dir.path}/LocalRoll-log-$stamp.txt').writeAsString(await DiagLog.read());
    m.showSnackBar(SnackBar(content: Text(tr(Platform.isIOS ? 'settings.log_saved_ios' : 'settings.log_saved_android'))));
  } catch (_) {
    m.showSnackBar(SnackBar(content: Text(tr('settings.log_failed'))));
  }
}

/// What LocalRoll does and doesn't do with your data.
Future<void> _showPrivacy(BuildContext context) => Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => Scaffold(
        appBar: AppBar(title: Text(tr('privacy.title'))),
        body: ListView(padding: const EdgeInsets.all(20), children: [
          for (final k in ['p1', 'p2', 'p3', 'p4', 'perms', 'p5', 'p6'])
            Padding(
              padding: const EdgeInsets.only(bottom: 14),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Padding(padding: EdgeInsets.only(top: 2, right: 10), child: Icon(Icons.check_circle_outline_rounded, size: 18)),
                Expanded(child: Text(tr('privacy.$k'), style: const TextStyle(height: 1.4))),
              ]),
            ),
        ]),
      ),
    ));
