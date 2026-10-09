// apps/desktop/lib/ui/settings_page.dart
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:localroll_core/localroll_core.dart';

import '../app_services.dart';
import '../l10n/l10n.dart';
import '../services/autostart.dart';
import '../services/network.dart';
import 'format.dart';
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
            _section(theme, tr('settings.paired_phones')),
            if (s.settings.trusted.isEmpty) Text(tr('settings.no_phones')),
            for (final d in s.settings.trusted.values)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(d.platform == 'ios' ? Icons.phone_iphone : Icons.phone_android),
                title: Text(d.name),
                subtitle: Text(tr('settings.paired_on',
                    {'date': formatDate(DateTime.fromMillisecondsSinceEpoch(d.pairedMs))})),
                trailing: TextButton(
                  onPressed: () async {
                    await s.settings.update((x) => x.trusted.remove(d.id));
                    _toast(tr('settings.unpaired', {'name': d.name}));
                  },
                  child: Text(tr('settings.unpair')),
                ),
              ),
          ],
        ),
      ),
    );
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
