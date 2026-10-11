// apps/mobile/lib/ui/transfer_page.dart
import 'package:flutter/material.dart';
import 'package:photo_manager/photo_manager.dart';

import '../l10n/l10n.dart';
import '../services/background_transfer.dart';
import '../services/desktop_client.dart';
import '../services/discovery.dart';
import '../services/mobile_settings.dart';
import '../services/uploader.dart';
import 'cleanup_page.dart';

/// Connects to the PC, sends the selected assets and shows per-file progress.
/// Pops with `true` when everything finished so the selection can be cleared.
class TransferPage extends StatefulWidget {
  const TransferPage({
    super.key,
    required this.settings,
    required this.discovery,
    required this.desktop,
    required this.assets,
  });

  final MobileSettings settings;
  final DesktopDiscovery discovery;
  final PairedDesktop desktop;
  final List<AssetEntity> assets;

  @override
  State<TransferPage> createState() => _TransferPageState();
}

class _TransferPageState extends State<TransferPage> {
  DesktopClient? _client;
  Uploader? _uploader;
  String? _error;

  @override
  void initState() {
    super.initState();
    _start(widget.assets);
  }

  Future<void> _start(List<AssetEntity> assets) async {
    setState(() => _error = null);
    try {
      _client ??= await connectToDesktop(
        widget.settings,
        widget.desktop,
        discovered: widget.discovery.found,
      );
      final up = Uploader(
        client: _client!,
        settings: widget.settings,
        desktop: widget.desktop,
        assets: assets,
      );
      setState(() => _uploader = up);
      await up.run();
    } catch (e) {
      if (mounted) setState(() => _error = e.toString().replaceFirst('Exception: ', ''));
    }
  }

  @override
  void dispose() {
    _uploader?.cancel();
    _client?.close();
    super.dispose();
  }

  bool get _busy {
    final up = _uploader;
    return up != null && up.running && !up.finished;
  }

  /// Stop (or leave) mid-transfer: say what happens, then stop cleanly.
  Future<bool> _confirmStop() async {
    final up = _uploader;
    if (up == null || !_busy) return true;
    final stop = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.pause_circle_outline_rounded, size: 32),
        title: Text(tr('transfer.stop_title')),
        content: Text(tr('transfer.stop_body', {'done': up.doneCount + up.skippedCount, 'pc': widget.desktop.name})),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('transfer.keep_going'))),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(tr('transfer.stop'))),
        ],
      ),
    );
    if (stop == true) up.cancel();
    return stop == true;
  }

  @override
  Widget build(BuildContext context) {
    final up = _uploader;
    return PopScope(
      canPop: !_busy,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final navigator = Navigator.of(context);
        if (await _confirmStop()) navigator.pop(false);
      },
      child: _scaffold(up),
    );
  }

  Widget _scaffold(Uploader? up) {
    return Scaffold(
      appBar: AppBar(
        title: Text(tr('transfer.title', {'name': widget.desktop.name})),
        actions: [
          if (up != null)
            ListenableBuilder(
              listenable: up,
              builder: (context, _) => _busy
                  ? TextButton.icon(
                      onPressed: _confirmStop,
                      icon: const Icon(Icons.stop_circle_outlined),
                      label: Text(tr('transfer.stop')),
                    )
                  : const SizedBox.shrink(),
            ),
        ],
      ),
      body: _error != null
          ? _errorView()
          : up == null
              ? Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
                  const CircularProgressIndicator(),
                  const SizedBox(height: 12),
                  Text(tr('transfer.connecting')),
                ]))
              : ListenableBuilder(listenable: up, builder: (context, _) => _progressView(up)),
    );
  }

  Widget _errorView() => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.wifi_off, size: 48),
              const SizedBox(height: 12),
              Text(_error!, textAlign: TextAlign.center),
              const SizedBox(height: 16),
              FilledButton(onPressed: () => _start(widget.assets), child: Text(tr('common.retry'))),
            ],
          ),
        ),
      );

  Widget _progressView(Uploader up) {
    final theme = Theme.of(context);
    final summary = up.finished
        ? tr('transfer.summary', {'done': up.doneCount, 'skipped': up.skippedCount}) +
            (up.failedCount > 0 ? tr('transfer.summary_failed', {'failed': up.failedCount}) : '')
        : tr('transfer.sending');
    final total = up.items.length;
    final processed = up.processedCount;
    final left = up.timeLeft;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(summary, style: theme.textTheme.titleSmall),
              if (total > 1) ...[
                const SizedBox(height: 10),
                LinearProgressIndicator(
                  value: total == 0 ? null : processed / total,
                  minHeight: 6,
                  borderRadius: BorderRadius.circular(3),
                ),
                const SizedBox(height: 6),
                Text(
                  [
                    tr('transfer.count', {'done': processed, 'total': total}),
                    if (!up.finished && up.speed > 0) '${formatSize(up.speed.round())}/s',
                    if (left != null) tr('transfer.time_left', {'time': _formatDuration(left)}),
                  ].join(' · '),
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ],
          ),
        ),
        // Big batches take hours: say how to keep it going.
        if (!up.finished && total >= 200)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Row(children: [
              Icon(Icons.power_rounded, size: 18, color: theme.colorScheme.primary),
              const SizedBox(width: 8),
              Expanded(child: Text(tr('transfer.long_tip'), style: theme.textTheme.bodySmall)),
            ]),
          ),
        if (up.finished && up.noSpaceCount > 0)
          Container(
            margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: theme.colorScheme.errorContainer.withValues(alpha: 0.3),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(children: [
              Icon(Icons.sd_storage_rounded, color: theme.colorScheme.error),
              const SizedBox(width: 10),
              Expanded(
                child: Text(tr('transfer.no_space_summary', {'count': up.noSpaceCount}),
                    style: theme.textTheme.bodySmall),
              ),
            ]),
          ),
        if (!up.finished && up.backgroundMode != BackgroundMode.none)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Row(
              children: [
                Icon(
                  up.backgroundMode == BackgroundMode.short ? Icons.info_outline : Icons.lock_clock,
                  size: 18,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    tr(up.backgroundMode == BackgroundMode.short ? 'transfer.keep_open' : 'transfer.background_ok'),
                    style: theme.textTheme.bodySmall,
                  ),
                ),
              ],
            ),
          ),
        Expanded(
          child: ListView.builder(
            itemCount: up.items.length,
            itemBuilder: (context, i) => _ItemTile(item: up.items[i]),
          ),
        ),
        if (up.finished)
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  if (up.failedCount > 0)
                    OutlinedButton(
                      onPressed: () => _start(
                        up.items.where((i) => i.state == UploadState.failed).map((i) => i.asset).toList(),
                      ),
                      child: Text(tr('transfer.retry_failed')),
                    ),
                  const Spacer(),
                  if (up.doneCount + up.skippedCount > 0)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: OutlinedButton.icon(
                        onPressed: () => Navigator.of(context).pushReplacement(MaterialPageRoute(
                          builder: (_) => CleanupPage(
                            settings: widget.settings,
                            discovery: widget.discovery,
                            desktop: widget.desktop,
                          ),
                        )),
                        icon: const Icon(Icons.cleaning_services_rounded, size: 18),
                        label: Text(tr('home.cleanup')),
                      ),
                    ),
                  FilledButton(
                    onPressed: () => Navigator.of(context).pop(up.failedCount == 0),
                    child: Text(tr('transfer.done')),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

/// "2 h 05 min" / "12 min" / "< 1 min".
String _formatDuration(Duration d) {
  if (d.inMinutes < 1) return tr('transfer.under_minute');
  if (d.inHours < 1) return tr('transfer.minutes', {'m': d.inMinutes});
  return tr('transfer.hours', {'h': d.inHours, 'm': (d.inMinutes % 60).toString().padLeft(2, '0')});
}

class _ItemTile extends StatelessWidget {
  const _ItemTile({required this.item});

  final UploadItem item;

  @override
  Widget build(BuildContext context) {
    final (icon, label) = switch (item.state) {
      UploadState.waiting => (Icons.schedule, tr('state.waiting')),
      UploadState.preparing => (Icons.hourglass_top, tr('state.preparing')),
      UploadState.uploading => (Icons.upload, '${((item.fraction ?? 0) * 100).toStringAsFixed(0)}%'),
      UploadState.verifying => (Icons.verified_outlined, tr('state.verifying')),
      UploadState.done => (Icons.check_circle, tr('state.saved')),
      UploadState.skipped => (Icons.check_circle_outline, tr('state.skipped')),
      UploadState.failed => (Icons.error_outline, item.error ?? tr('state.failed')),
    };
    return ListTile(
      dense: true,
      leading: Icon(icon, color: item.state == UploadState.failed ? Theme.of(context).colorScheme.error : null),
      title: Text(item.name.isEmpty ? '…' : item.name, overflow: TextOverflow.ellipsis),
      subtitle: item.state == UploadState.uploading
          ? LinearProgressIndicator(value: item.fraction)
          : Text(label, maxLines: 2, overflow: TextOverflow.ellipsis),
      trailing: item.state == UploadState.uploading ? Text(label) : null,
    );
  }
}
