// apps/desktop/lib/ui/settings_page.dart
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:localroll_core/localroll_core.dart';

import '../app_services.dart';
import '../l10n/l10n.dart';
import '../services/autostart.dart';
import '../services/network.dart';
import 'app_nav.dart';
import 'identity_card.dart';
import 'search_settings.dart';
import 'theme.dart';

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
        body: ListView(
          padding: const EdgeInsets.fromLTRB(28, 22, 28, 28),
          children: [
            Text(tr('nav.settings'), style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: 18),
            Align(
              alignment: AlignmentDirectional.topStart,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 860),
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  // How phones see this PC.
                  _group(theme, tr('identity.title'), [IdentityCard(services: s)], bare: true),
                  _group(theme, tr('settings.g_general'), [
                    _row(
                      Icons.translate_rounded,
                      tr('settings.language'),
                      trailing: DropdownButton<String?>(
                        value: s.settings.language,
                        underline: const SizedBox.shrink(),
                        borderRadius: BorderRadius.circular(10),
                        onChanged: (v) => s.settings.update((x) => x.language = v),
                        items: [
                          DropdownMenuItem<String?>(value: null, child: Text(tr('settings.language_system'))),
                          for (final l in supportedLanguages)
                            DropdownMenuItem<String?>(value: l.code, child: Text(l.nativeName)),
                        ],
                      ),
                    ),
                    const Divider(height: 1),
                    const _AutoStartSwitch(),
                  ]),
                  _group(theme, tr('settings.receiving'), [
                    // Who needs "Accept" is decided per device (family / guest).
                    _row(
                      Icons.verified_user_outlined,
                      tr('settings.accept_rule'),
                      sub: tr('settings.accept_rule_hint'),
                      trailing: OutlinedButton(
                        onPressed: () => AppNav.instance.selectTab(AppNav.devices),
                        child: Text(tr('nav.transfer')),
                      ),
                    ),
                  ]),
                  // Text in photos and files, for the search box.
                  _group(theme, tr('search.title'), [SearchSettings(services: s)]),
                  _group(theme, tr('settings.g_storage'), [
                    _row(Icons.photo_library_outlined, tr('settings.library_folder'), sub: tr('settings.library_hint')),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
                      child: Row(children: [
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
                    ),
                    const Divider(height: 1),
                    SwitchListTile(
                      contentPadding: const EdgeInsets.symmetric(horizontal: 16),
                      secondary: const Icon(Icons.folder_shared_outlined),
                      value: s.settings.folderPerMember,
                      onChanged: (v) => s.settings.update((x) => x.folderPerMember = v),
                      title: Text(tr('family.folder_per_member')),
                      subtitle: Text(tr('family.folder_per_member_hint')),
                    ),
                    const Divider(height: 1),
                    _row(
                      s.ffmpeg.available ? Icons.check_circle_rounded : Icons.error_outline_rounded,
                      tr('settings.ffmpeg_title'),
                      iconColor: s.ffmpeg.available ? LrColors.verified : LrColors.danger,
                      sub: s.ffmpeg.available ? (s.ffmpeg.version ?? s.ffmpeg.ffmpeg) : tr('settings.ffmpeg_missing'),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
                      child: Row(children: [
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
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
                      child: Text(tr('settings.ffmpeg_order'), style: theme.textTheme.bodySmall),
                    ),
                  ]),
                  _group(theme, tr('settings.network'), [
                    _row(
                      Icons.lan_outlined,
                      tr('settings.port', {'port': s.server.port}),
                      trailing: OutlinedButton.icon(
                        onPressed: () async => _toast(await addFirewallRules(s.server.port)
                            ? tr('receive.firewall_ok')
                            : tr('settings.firewall_not_added')),
                        icon: const Icon(Icons.shield_outlined, size: 18),
                        label: Text(tr('settings.firewall')),
                      ),
                    ),
                  ]),
                  _group(theme, tr('settings.g_about'), [
                    _row(Icons.description_outlined, tr('settings.log_title'), sub: tr('settings.log_hint')),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
                      child: Wrap(spacing: 12, runSpacing: 8, children: [
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
                    ),
                    const Divider(height: 1),
                    _row(Icons.info_outline_rounded, 'LocalRoll · ${tr('settings.version', {'version': lrVersion})}'),
                  ]),
                ]),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Diagnostics log → a text file in Downloads, shown in Explorer (no
  /// file dialog: on some PCs it hangs).
  Future<void> _exportLog() async {
    final d = DateTime.now();
    final stamp = '${d.year}${d.month.toString().padLeft(2, '0')}${d.day.toString().padLeft(2, '0')}-'
        '${d.hour.toString().padLeft(2, '0')}${d.minute.toString().padLeft(2, '0')}';
    try {
      final home = Platform.environment['USERPROFILE'] ?? Directory.systemTemp.path;
      final dir = Directory('$home${Platform.pathSeparator}Downloads');
      await dir.create(recursive: true);
      final path = '${dir.path}${Platform.pathSeparator}LocalRoll-log-$stamp.txt';
      await File(path).writeAsString(await DiagLog.read());
      _toast(tr('settings.log_saved', {'path': path}));
      unawaited(revealInExplorer(path));
    } catch (e) {
      DiagLog.error('settings', e);
      _toast(tr('settings.log_failed'));
    }
  }

  /// One settings group: a small heading, then its rows in one box.
  Widget _group(ThemeData theme, String title, List<Widget> rows, {bool bare = false}) => Padding(
        padding: const EdgeInsets.only(bottom: 22),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 8),
            child: Text(title, style: const TextStyle(color: LrColors.muted, fontSize: 13, fontWeight: FontWeight.w600)),
          ),
          if (bare)
            ...rows
          else
            Container(
              clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(
                color: LrColors.surface,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: LrColors.line),
              ),
              child: Material(
                type: MaterialType.transparency,
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: rows),
              ),
            ),
        ]),
      );

  Widget _row(IconData icon, String title, {String? sub, Widget? trailing, Color? iconColor}) => ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        leading: Icon(icon, color: iconColor),
        title: Text(title),
        subtitle: sub == null ? null : Text(sub),
        trailing: trailing,
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
    return SwitchListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16),
        secondary: const Icon(Icons.power_settings_new_rounded),
        value: _on ?? false,
        onChanged: _on == null
            ? null
            : (v) async {
                final ok = await AutoStart.setEnabled(v);
                if (mounted) setState(() => _on = ok ? v : _on);
              },
        title: Text(tr('settings.autostart')),
        subtitle: Text(tr('settings.autostart_hint')),
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
