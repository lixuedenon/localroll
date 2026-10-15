// apps/desktop/lib/ui/settings_page.dart
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:localroll_core/localroll_core.dart';

import '../app_services.dart';
import '../l10n/l10n.dart';
import '../services/autostart.dart';
import '../services/network.dart';
import 'app_nav.dart';
import 'identity_card.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key, required this.services});

  final AppServices services;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late final TextEditingController _library =
      TextEditingController(text: widget.services.settings.libraryPath);
  late final TextEditingController _ffmpeg =
      TextEditingController(text: widget.services.settings.ffmpegPath ?? '');

  @override
  void dispose() {
    _library.dispose();
    _ffmpeg.dispose();
    super.dispose();
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.services;
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: Listenable.merge([s.settings, s.ffmpeg]),
      builder: (context, _) => Scaffold(
        appBar: AppBar(title: Text(tr('nav.settings'))),
        body: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            _section(theme, tr('settings.language')),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: DropdownButton<String?>(
                value: s.settings.language,
                onChanged: (v) => s.settings.update((x) => x.language = v),
                items: [
                  DropdownMenuItem<String?>(value: null, child: Text(tr('settings.language_system'))),
                  for (final l in supportedLanguages)
                    DropdownMenuItem<String?>(value: l.code, child: Text(l.nativeName)),
                ],
              ),
            ),
            const SizedBox(height: 28),
            _section(theme, tr('identity.title')),
            IdentityCard(services: s),
            const SizedBox(height: 28),
            _section(theme, tr('settings.receiving')),
            // Who needs "Accept" is decided per device (family / guest).
            Card(
              child: ListTile(
                leading: const Icon(Icons.verified_user_outlined),
                title: Text(tr('settings.accept_rule')),
                subtitle: Text(tr('settings.accept_rule_hint')),
                trailing: TextButton(
                  onPressed: () => AppNav.instance.selectTab(AppNav.family),
                  child: Text(tr('family.title')),
                ),
              ),
            ),
            const SizedBox(height: 28),
            _section(theme, tr('settings.startup')),
            const _AutoStartSwitch(),
            const SizedBox(height: 28),
            _section(theme, tr('settings.library_folder')),
            Row(children: [
              Expanded(child: TextField(controller: _library)),
              const SizedBox(width: 12),
              FilledButton(
                onPressed: () async {
                  final v = _library.text.trim();
                  if (v.isEmpty) return;
                  try {
                    await Directory(v).create(recursive: true);
                    await s.changeLibrary(v);
                    _toast(tr('settings.library_switched'));
                  } catch (e) {
                    _toast(tr('settings.folder_error', {'error': e}));
                  }
                },
                child: Text(tr('settings.switch')),
              ),
              const SizedBox(width: 8),
              OutlinedButton(
                onPressed: () => revealInExplorer(s.library.rootPath),
                child: Text(tr('common.open')),
              ),
            ]),
            const SizedBox(height: 4),
            Text(tr('settings.library_hint'), style: theme.textTheme.bodySmall),
            const SizedBox(height: 28),
            _section(theme, tr('settings.ffmpeg_title')),
            Text(
              s.ffmpeg.available
                  ? '✓ ${s.ffmpeg.version ?? s.ffmpeg.ffmpeg}\n${s.ffmpeg.ffmpeg}'
                  : tr('settings.ffmpeg_missing'),
              style: TextStyle(color: s.ffmpeg.available ? null : theme.colorScheme.error),
            ),
            const SizedBox(height: 8),
            Row(children: [
              Expanded(
                child: TextField(
                  controller: _ffmpeg,
                  decoration: InputDecoration(hintText: tr('settings.ffmpeg_field_hint')),
                ),
              ),
              const SizedBox(width: 12),
              FilledButton(
                onPressed: () async {
                  final v = _ffmpeg.text.trim();
                  await s.settings.update((x) => x.ffmpegPath = v.isEmpty ? null : v);
                  await s.ffmpeg.locate();
                  _toast(s.ffmpeg.available ? tr('settings.ffmpeg_found') : tr('settings.ffmpeg_not_here'));
                },
                child: Text(tr('settings.detect')),
              ),
            ]),
            const SizedBox(height: 4),
            Text(tr('settings.ffmpeg_order'), style: theme.textTheme.bodySmall),
            const SizedBox(height: 28),
            _section(theme, tr('settings.network')),
            Text(tr('settings.port', {'port': s.server.port})),
            const SizedBox(height: 8),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: OutlinedButton.icon(
                onPressed: () async => _toast(await addFirewallRules(s.server.port)
                    ? tr('receive.firewall_ok')
                    : tr('settings.firewall_not_added')),
                icon: const Icon(Icons.shield_outlined),
                label: Text(tr('settings.firewall')),
              ),
            ),
            const SizedBox(height: 28),
            _section(theme, tr('settings.log_title')),
            Text(tr('settings.log_hint'), style: theme.textTheme.bodySmall),
            const SizedBox(height: 8),
            Wrap(spacing: 12, runSpacing: 8, children: [
              FilledButton.tonalIcon(
                onPressed: _exportLog,
                icon: const Icon(Icons.download_rounded),
                label: Text(tr('settings.log_export')),
              ),
              OutlinedButton.icon(
                onPressed: () => showPrivacy(context),
                icon: const Icon(Icons.privacy_tip_outlined),
                label: Text(tr('privacy.title')),
              ),
            ]),
            const SizedBox(height: 28),
            Center(
              child: Text('LocalRoll · ${tr('settings.version', {'version': lrVersion})}',
                  style: theme.textTheme.bodySmall),
            ),
          ],
        ),
      ),
    );
  }

  /// Diagnostics log → a text file the user picks (to send to whoever helps).
  Future<void> _exportLog() async {
    final d = DateTime.now();
    final stamp = '${d.year}${d.month.toString().padLeft(2, '0')}${d.day.toString().padLeft(2, '0')}-'
        '${d.hour.toString().padLeft(2, '0')}${d.minute.toString().padLeft(2, '0')}';
    final where = await getSaveLocation(
      suggestedName: 'LocalRoll-log-$stamp.txt',
      acceptedTypeGroups: const [XTypeGroup(label: 'Text', extensions: ['txt'])],
    );
    if (where == null) return;
    try {
      await File(where.path).writeAsString(await DiagLog.read());
      _toast(tr('settings.log_saved', {'path': where.path}));
    } catch (e) {
      _toast(tr('settings.log_failed'));
    }
  }

  Widget _section(ThemeData theme, String title) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(title, style: theme.textTheme.titleMedium),
      );
}

/// "Start with Windows" switch (reads the real state from the registry).
class _AutoStartSwitch extends StatefulWidget {
  const _AutoStartSwitch();

  @override
  State<_AutoStartSwitch> createState() => _AutoStartSwitchState();
}

class _AutoStartSwitchState extends State<_AutoStartSwitch> {
  bool? _on;

  @override
  void initState() {
    super.initState();
    AutoStart.isEnabled().then((v) {
      if (mounted) setState(() => _on = v);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      child: SwitchListTile(
        value: _on ?? false,
        onChanged: _on == null
            ? null
            : (v) async {
                final ok = await AutoStart.setEnabled(v);
                if (mounted) setState(() => _on = ok ? v : _on);
              },
        title: Text(tr('settings.autostart')),
        subtitle: Text(tr('settings.autostart_hint')),
      ),
    );
  }
}

/// What LocalRoll does and doesn't do with your data.
Future<void> showPrivacy(BuildContext context) => showDialog<void>(
      context: context,
      builder: (c) => AlertDialog(
        icon: const Icon(Icons.privacy_tip_outlined, size: 32),
        title: Text(tr('privacy.title')),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              for (final k in ['p1', 'p2', 'p3', 'p4', 'perms', 'p5', 'p6'])
                Padding(padding: const EdgeInsets.only(bottom: 10), child: Text('• ${tr('privacy.$k')}')),
            ]),
          ),
        ),
        actions: [FilledButton(onPressed: () => Navigator.pop(c), child: Text(tr('common.ok')))],
      ),
    );
