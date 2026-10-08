// apps/desktop/lib/ui/jobs_page.dart
import 'package:flutter/material.dart';

import '../app_services.dart';
import '../l10n/l10n.dart';
import '../services/converter.dart';
import '../services/network.dart';

class JobsPage extends StatelessWidget {
  const JobsPage({super.key, required this.services});

  final AppServices services;

  @override
  Widget build(BuildContext context) {
    final c = services.converter;
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) => Scaffold(
        appBar: AppBar(
          title: Text(tr('jobs.title')),
          actions: [
            if (c.jobs.isNotEmpty) TextButton(onPressed: c.clearFinished, child: Text(tr('common.clear_finished'))),
            const SizedBox(width: 8),
          ],
        ),
        body: c.jobs.isEmpty
            ? Center(
                child: Padding(
                  padding: const EdgeInsets.all(32),
                  child: Text(tr('jobs.empty'), textAlign: TextAlign.center),
                ),
              )
            : ListView.separated(
                padding: const EdgeInsets.all(16),
                itemCount: c.jobs.length,
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemBuilder: (context, i) => _JobTile(job: c.jobs[i]),
              ),
      ),
    );
  }
}

class _JobTile extends StatelessWidget {
  const _JobTile({required this.job});

  final ConvertJob job;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final status = switch (job.state) {
      JobState.queued => tr('jobs.queued'),
      JobState.running => tr('jobs.running', {'percent': (job.progress * 100).toStringAsFixed(0)}),
      JobState.done => job.hdrTonemapped ? tr('jobs.done_hdr') : tr('jobs.done'),
      JobState.failed => tr('common.failed'),
    };
    return ListTile(
      leading: Icon(switch (job.state) {
        JobState.queued => Icons.schedule,
        JobState.running => Icons.autorenew,
        JobState.done => Icons.check_circle,
        JobState.failed => Icons.error_outline,
      }, color: job.state == JobState.failed ? theme.colorScheme.error : null),
      title: Text('${job.item.name}  →  ${job.preset.label}'),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (job.state == JobState.running) ...[
            const SizedBox(height: 4),
            LinearProgressIndicator(value: job.progress > 0 ? job.progress : null),
          ],
          const SizedBox(height: 4),
          Text(status),
          if (job.error != null)
            Text(job.error!, maxLines: 4, overflow: TextOverflow.ellipsis,
                style: TextStyle(color: theme.colorScheme.error, fontSize: 12)),
        ],
      ),
      trailing: job.state == JobState.done && job.outputPath != null
          ? IconButton(
              tooltip: tr('common.show_in_folder'),
              onPressed: () => revealInExplorer(job.outputPath!),
              icon: const Icon(Icons.folder_open),
            )
          : null,
    );
  }
}
