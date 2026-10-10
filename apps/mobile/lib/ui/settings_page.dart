// apps/mobile/lib/ui/settings_page.dart
import 'package:flutter/material.dart';
import 'package:localroll_core/localroll_core.dart';

import '../l10n/l10n.dart';
import '../services/discovery.dart';
import '../services/mobile_settings.dart';
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

              // Language.
              Text(tr('home.language'), style: theme.textTheme.titleMedium),
              const SizedBox(height: 8),
              Card(
                child: Column(
                  children: [
                    _LanguageTile(
                      label: tr('home.language_system'),
                      selected: settings.language == null,
                      onTap: () => settings.setLanguage(null),
                    ),
                    for (final l in supportedLanguages)
                      _LanguageTile(
                        label: l.nativeName,
                        selected: settings.language == l.code,
                        onTap: () => settings.setLanguage(l.code),
                      ),
                  ],
                ),
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
