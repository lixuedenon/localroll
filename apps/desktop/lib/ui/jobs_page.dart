// apps/desktop/lib/ui/jobs_page.dart
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../app_services.dart';
import '../l10n/l10n.dart';
import '../services/converter.dart';
import '../services/network.dart';
import 'app_nav.dart';
import 'player/player_entry.dart';
import 'player/player_page.dart';
import 'send_paths.dart';
import 'theme.dart';
import 'tools/tool_records.dart';
import 'tools/tools.dart';

/// Convert: the queue of conversions started from the library or viewer.
class JobsPage extends StatelessWidget {
  const JobsPage({super.key, required this.services});

  final AppServices services;

  @override
  Widget build(BuildContext context) {
    final s = services;
    final c = s.converter;
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: Listenable.merge([c, s.ffmpeg]),
      builder: (context, _) => Scaffold(
        body: ListView(
          padding: const EdgeInsets.fromLTRB(28, 22, 28, 28),
          children: [
            Row(children: [
              Text(tr('nav.convert'), style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700)),
              const SizedBox(width: 14),
              Expanded(
                child: Text(tr('jobs.hint'),
                    overflow: TextOverflow.ellipsis, style: const TextStyle(color: LrColors.muted, fontSize: 13)),
              ),
              if (c.jobs.any((j) => j.state == JobState.done || j.state == JobState.failed))
                TextButton(onPressed: c.clearFinished, child: Text(tr('common.clear_finished'))),
              const SizedBox(width: 8),
            ]),
            const SizedBox(height: 14),
            ToolRecordsView(services: s),
            const SizedBox(height: 18),
            ToolsGrid(services: s, all: true),
            const SizedBox(height: 22),
            Text(tr('jobs.queue'), style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
            const SizedBox(height: 10),
            if (!s.ffmpeg.available) ...[
              _box(
                border: LrColors.safelight,
                child: Row(children: [
                  const Icon(Icons.warning_amber_rounded, color: LrColors.safelight),
                  const SizedBox(width: 12),
                  Expanded(child: Text(tr('jobs.ffmpeg_missing'))),
                  const SizedBox(width: 12),
                  FilledButton.tonal(
                    onPressed: () => AppNav.instance.selectTab(AppNav.settings),
                    child: Text(tr('nav.settings')),
                  ),
                ]),
              ),
              const SizedBox(height: 14),
            ],
            if (c.jobs.isEmpty)
              _box(
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 28),
                  child: Column(children: [
                    const Icon(Icons.auto_awesome_rounded, size: 40, color: LrColors.muted),
                    const SizedBox(height: 12),
                    Text(tr('jobs.empty'), textAlign: TextAlign.center, style: const TextStyle(color: LrColors.muted)),
                    const SizedBox(height: 16),
                    FilledButton.icon(
                      onPressed: () => AppNav.instance.selectTab(AppNav.library),
                      icon: const Icon(Icons.photo_library_rounded),
                      label: Text(tr('jobs.go_library')),
                    ),
                  ]),
                ),
              )
            else
              _box(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Column(children: [
                  for (var i = 0; i < c.jobs.length; i++) ...[
                    if (i > 0) const Divider(height: 1, indent: 16, endIndent: 16),
                    _JobTile(job: c.jobs[i], services: s),
                  ],
                ]),
              ),
          ],
        ),
      ),
    );
  }
}

Widget _box({required Widget child, Color? border, EdgeInsets padding = const EdgeInsets.all(18)}) => Container(
      padding: padding,
      decoration: BoxDecoration(
        color: LrColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: border ?? LrColors.line),
      ),
      child: child,
    );

class _JobTile extends StatelessWidget {
  const _JobTile({required this.job, required this.services});

  final ConvertJob job;
  final AppServices services;

  @override
  Widget build(BuildContext context) {
    final status = switch (job.state) {
      JobState.queued => tr('jobs.queued'),
      JobState.running => tr('jobs.running', {'percent': (job.progress * 100).toStringAsFixed(0)}),
      JobState.done => job.hdrTonemapped ? tr('jobs.done_hdr') : tr('jobs.done'),
      JobState.failed => tr('common.failed'),
    };
    final color = switch (job.state) {
      JobState.running => LrColors.safelight,
      JobState.done => LrColors.verified,
      JobState.failed => LrColors.danger,
      JobState.queued => LrColors.muted,
    };
    return ListTile(
      leading: Icon(switch (job.state) {
        JobState.queued => Icons.schedule_rounded,
        JobState.running => Icons.autorenew_rounded,
        JobState.done => Icons.check_circle_rounded,
        JobState.failed => Icons.error_outline_rounded,
      }, color: color),
      title: Text('${job.item.name}  →  ${job.label}', overflow: TextOverflow.ellipsis),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (job.state == JobState.running) ...[
            const SizedBox(height: 6),
            LinearProgressIndicator(value: job.progress > 0 ? job.progress : null),
          ],
          const SizedBox(height: 4),
          Text(status, style: TextStyle(color: color, fontSize: 13)),
          if (job.error != null)
            Text(job.error!, maxLines: 4, overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: LrColors.danger, fontSize: 12)),
        ],
      ),
      onTap: job.state == JobState.done && job.outputPath != null && PlayerEntry.playable(job.outputPath!)
          ? () => openInPlayer(context, services, [job.outputPath!])
          : null,
      trailing: job.state == JobState.done && job.outputPath != null
          ? PopupMenuButton<String>(
              tooltip: tr('ink.more'),
              onSelected: (a) {
                final out = job.outputPath!;
                if (a == 'open') openInPlayer(context, services, [out]);
                if (a == 'send') {
                  unawaited(() async {
                    final ids = await pickDevices(context, services, count: 1, first: out.split(Platform.pathSeparator).last);
                    if (ids != null && ids.isNotEmpty && context.mounted) await sendPathsTo(context, services, ids, [out]);
                  }());
                }
                if (a == 'guest') services.guest.share([out]);
                if (a == 'reveal') revealInExplorer(out);
              },
              itemBuilder: (_) => [
                if (PlayerEntry.playable(job.outputPath!)) PopupMenuItem(value: 'open', child: Text(tr('recs.play'))),
                PopupMenuItem(value: 'send', child: Text(tr('tool.send'))),
                PopupMenuItem(value: 'guest', child: Text(tr('tool.to_guest'))),
                const PopupMenuDivider(),
                PopupMenuItem(value: 'reveal', child: Text(tr('common.show_in_folder'))),
              ],
            )
          : null,
    );
  }
}
