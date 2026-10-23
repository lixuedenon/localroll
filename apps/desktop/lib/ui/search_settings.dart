// apps/desktop/lib/ui/search_settings.dart
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:localroll_core/localroll_core.dart';

import '../app_services.dart';
import '../l10n/l10n.dart';
import '../services/picture_model.dart';
import 'people_page.dart' show clearPeople, peopleState;
import '../services/text_indexer.dart';
import '../services/windows_ocr.dart';
import 'format.dart';
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
    unawaited(widget.services.server.people.load());
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
      listenable: Listenable.merge([s.settings, _ix.progress, _ix.languages, s.pictureModel, s.pictureIndexer.progress, s.faceIndexer.progress, s.server.people]),
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
              // Windows' recognition didn't answer at all: say so (adding
              // Chinese would not help).
              child: _ix.ocr.problem != null && !langs.any
                  ? _ocrBroken(theme, _ix.ocr.problem!)
                  : langs.chinese
                      ? _langsLine(langs)
                      : _addChinese(theme, langs),
            ),
          ],
          const Divider(height: 1),
          ..._pictures(theme),
          const Divider(height: 1),
          ..._people(theme),
        ]);
      },
    );
  }

  /// Search by what pictures show: what it is, what the download is for,
  /// and that nothing else depends on it.
  List<Widget> _pictures(ThemeData theme) {
    final s = widget.services;
    final on = s.settings.pictureSearch;
    final model = s.pictureModel;
    final dl = model.downloading;
    final p = s.pictureIndexer.progress.value;
    final size = formatBytes(PictureModel.downloadSize);
    return [
      SwitchListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16),
        secondary: const Icon(Icons.image_search_rounded),
        value: on,
        onChanged: (v) async {
          await s.settings.update((x) {
            x.pictureSearch = v;
            x.pictureAsked = true;
          });
          if (v && !model.ready) {
            if (!await model.download() && mounted) setState(() {});
          }
          s.pictureIndexer.wake();
        },
        title: Text(tr('search.picture_title')),
        subtitle: Text(tr('search.picture_explain', {'size': size})),
      ),
      if (on || dl != null) ...[
        const Divider(height: 1),
        ListTile(
          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
          leading: dl != null
              ? SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(strokeWidth: 2.5, value: dl.$2 == 0 ? null : dl.$1 / dl.$2),
                )
              : Icon(
                  p.state == IndexState.done ? Icons.check_circle_outline_rounded : Icons.hourglass_top_rounded,
                  color: p.state == IndexState.done ? LrColors.verified : LrColors.muted,
                ),
          title: Text(dl != null
              ? tr('search.picture_downloading', {'done': formatBytes(dl.$1), 'total': formatBytes(dl.$2)})
              : model.error != null && !model.ready
                  ? tr('search.picture_download_failed')
                  : !model.ready
                      ? tr('search.picture_not_downloaded')
                      : _pictureState(p)),
          trailing: model.error != null && !model.ready && dl == null
              ? TextButton(onPressed: () => model.download(), child: Text(tr('common.retry')))
              : null,
        ),
      ],
      // Off, but the model is still here: it can go (frees the space).
      if (!on && model.ready && dl == null)
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          child: Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton.icon(
              onPressed: model.remove,
              icon: const Icon(Icons.delete_outline_rounded, size: 18),
              label: Text(tr('search.picture_remove', {'size': size})),
            ),
          ),
        ),
    ];
  }

  /// People: what it does, that it stays on this PC, and how to take every
  /// face off again.
  List<Widget> _people(ThemeData theme) {
    final s = widget.services;
    final on = s.settings.faces;
    final p = s.faceIndexer.progress.value;
    return [
      SwitchListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16),
        secondary: const Icon(Icons.face_retouching_natural_rounded),
        value: on,
        onChanged: (v) async {
          await s.settings.update((x) => x.faces = v);
          s.faceIndexer.wake();
        },
        title: Text(tr('people.settings_title')),
        subtitle: Text(tr('people.explain')),
      ),
      if (on) ...[
        const Divider(height: 1),
        ListTile(
          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
          leading: Icon(
            p.state == IndexState.done ? Icons.check_circle_outline_rounded : Icons.hourglass_top_rounded,
            color: p.state == IndexState.done ? LrColors.verified : LrColors.muted,
          ),
          title: Text(peopleState(p)),
          subtitle: Text(tr('people.stats', {'photos': s.server.people.photosRead, 'faces': s.server.people.facesFound})),
        ),
      ],
      if (s.server.people.photosRead > 0)
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          child: Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton.icon(
              onPressed: () => clearPeople(context, s),
              icon: const Icon(Icons.delete_outline_rounded, size: 18),
              label: Text(tr('people.clear')),
            ),
          ),
        ),
    ];
  }

  String _pictureState(IndexProgress p) => switch (p.state) {
        IndexState.working => tr('search.picture_working', {'done': p.done, 'total': p.total}),
        IndexState.paused => tr('search.state_paused', {'done': p.done, 'total': p.total}),
        IndexState.done => tr('search.picture_done', {'count': p.total}),
        IndexState.failed => tr('search.state_failed'),
        _ => tr('search.state_starting'),
      };

  String _stateText(IndexProgress p) => switch (p.state) {
        IndexState.off => tr('search.state_off'),
        IndexState.noOcr => tr('search.state_no_ocr'),
        IndexState.starting => tr('search.state_starting'),
        IndexState.working => tr('search.state_working', {'done': p.done, 'total': p.total}),
        IndexState.paused => tr('search.state_paused', {'done': p.done, 'total': p.total}),
        IndexState.done => tr('search.state_done', {'count': p.total}),
        IndexState.failed => tr('search.state_failed'),
      };

  /// Text recognition doesn't run on this PC: why, and trying again.
  Widget _ocrBroken(ThemeData theme, String why) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Icon(Icons.error_outline_rounded, size: 18, color: LrColors.safelight),
          const SizedBox(width: 8),
          Expanded(child: Text(tr('search.ocr_broken_title'), style: theme.textTheme.titleSmall)),
        ]),
        const SizedBox(height: 6),
        Text(tr('search.ocr_broken_body'), style: theme.textTheme.bodySmall),
        const SizedBox(height: 4),
        Text(why, style: theme.textTheme.bodySmall?.copyWith(color: LrColors.muted)),
        const SizedBox(height: 8),
        TextButton(onPressed: _recheck, child: Text(tr('search.recheck'))),
      ]);

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
