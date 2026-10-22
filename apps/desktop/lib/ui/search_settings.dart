// apps/desktop/lib/ui/search_settings.dart
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:localroll_core/localroll_core.dart';

import '../app_services.dart';
import '../l10n/l10n.dart';
import '../services/text_indexer.dart';
import '../services/windows_ocr.dart';
import 'theme.dart';

/// Settings › Text search: on / off, how far reading is, and — when Windows
/// can't read Chinese yet — how to add it (one click, or step by step).
class SearchSettings extends StatefulWidget {
  const SearchSettings({super.key, required this.services});

  final AppServices services;

  @override
  State<SearchSettings> createState() => _SearchSettingsState();
}

class _SearchSettingsState extends State<SearchSettings> {
  bool _installing = false;
  String? _message;

  TextIndexer get _ix => widget.services.textIndexer;

  @override
  void initState() {
    super.initState();
    if (_ix.languages.value == null && WindowsOcr.supported) unawaited(_ix.checkLanguages());
  }

  Future<void> _recheck() async {
    setState(() => _message = null);
    final l = await _ix.checkLanguages();
    if (!mounted) return;
    setState(() => _message = l.chinese ? tr('search.cn_ready') : tr('search.cn_still_missing'));
    if (l.chinese) _ix.wake();
  }

  /// Windows' own "add a feature" for Chinese text recognition; Windows
  /// asks the person to allow it (administrator).
  Future<void> _install() async {
    setState(() {
      _installing = true;
      _message = tr('search.installing');
    });
    try {
      await Process.run('powershell', [
        '-NoProfile',
        '-Command',
        "Start-Process powershell -Verb RunAs -Wait -WindowStyle Hidden -ArgumentList "
            "'-NoProfile -Command Add-WindowsCapability -Online -Name Language.OCR~~~zh-CN~0.0.1.0'",
      ]);
    } catch (e) {
      DiagLog.log('search', 'install failed: $e');
    }
    final l = await _ix.checkLanguages();
    if (!mounted) return;
    setState(() {
      _installing = false;
      _message = l.chinese ? tr('search.cn_ready') : tr('search.install_failed');
    });
    if (l.chinese) _ix.wake();
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.services;
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: Listenable.merge([s.settings, _ix.progress, _ix.languages]),
      builder: (context, _) {
        final on = s.settings.textSearch;
        final p = _ix.progress.value;
        final langs = _ix.languages.value;
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          SwitchListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 16),
            secondary: const Icon(Icons.manage_search_rounded),
            value: on,
            onChanged: (v) async {
              await s.settings.update((x) => x.textSearch = v);
              _ix.wake();
            },
            title: Text(tr('search.enable')),
            subtitle: Text(tr('search.enable_hint')),
          ),
          if (on) ...[
            const Divider(height: 1),
            ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
              leading: Icon(
                p.state == IndexState.done ? Icons.check_circle_outline_rounded : Icons.hourglass_top_rounded,
                color: p.state == IndexState.done ? LrColors.verified : LrColors.muted,
              ),
              title: Text(_stateText(p)),
            ),
          ],
          if (on && WindowsOcr.supported && langs != null) ...[
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
              child: langs.chinese ? _langsLine(langs) : _addChinese(theme, langs),
            ),
          ],
        ]);
      },
    );
  }

  String _stateText(IndexProgress p) => switch (p.state) {
        IndexState.off => tr('search.state_off'),
        IndexState.noOcr => tr('search.state_no_ocr'),
        IndexState.starting => tr('search.state_starting'),
        IndexState.working => tr('search.state_working', {'done': p.done, 'total': p.total}),
        IndexState.paused => tr('search.state_paused', {'done': p.done, 'total': p.total}),
        IndexState.done => tr('search.state_done', {'count': p.total}),
      };

  Widget _langsLine(OcrLanguages l) => Row(children: [
        const Icon(Icons.translate_rounded, size: 18, color: LrColors.muted),
        const SizedBox(width: 10),
        Expanded(child: Text(tr('search.langs', {'langs': l.available.join(', ')}), style: const TextStyle(color: LrColors.muted))),
        TextButton(onPressed: _recheck, child: Text(tr('search.recheck'))),
      ]);

  /// No Chinese yet: what it means, one click to add it, or the steps.
  Widget _addChinese(ThemeData theme, OcrLanguages l) {
    final steps = [
      tr('search.step1'),
      tr('search.step2'),
      tr('search.step3'),
      tr('search.step4'),
      tr('search.step5'),
    ];
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        const Icon(Icons.info_outline_rounded, size: 18, color: LrColors.safelight),
        const SizedBox(width: 8),
        Expanded(child: Text(tr('search.cn_missing_title'), style: theme.textTheme.titleSmall)),
      ]),
      const SizedBox(height: 6),
      Text(
        tr('search.cn_missing_body', {'langs': l.any ? l.available.join(', ') : tr('search.none_lang')}),
        style: theme.textTheme.bodySmall,
      ),
      const SizedBox(height: 12),
      Wrap(spacing: 8, runSpacing: 8, children: [
        FilledButton.icon(
          onPressed: _installing ? null : _install,
          icon: _installing
              ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.download_rounded, size: 18),
          label: Text(tr('search.install_auto')),
        ),
        OutlinedButton.icon(
          onPressed: () => Process.run('explorer.exe', ['ms-settings:regionlanguage']),
          icon: const Icon(Icons.settings_outlined, size: 18),
          label: Text(tr('search.open_settings')),
        ),
        TextButton(onPressed: _installing ? null : _recheck, child: Text(tr('search.recheck'))),
      ]),
      if (_message != null) ...[
        const SizedBox(height: 8),
        Text(_message!, style: theme.textTheme.bodySmall?.copyWith(color: LrColors.safelight)),
      ],
      const SizedBox(height: 12),
      Text(tr('search.steps_title'), style: theme.textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w600)),
      const SizedBox(height: 4),
      for (var i = 0; i < steps.length; i++)
        Padding(
          padding: const EdgeInsets.only(top: 3),
          child: Text('${i + 1}. ${steps[i]}', style: theme.textTheme.bodySmall),
        ),
    ]);
  }
}
