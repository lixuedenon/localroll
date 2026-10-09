// apps/mobile/lib/ui/transfer_page.dart
import 'package:flutter/material.dart';
import 'package:photo_manager/photo_manager.dart';

import '../l10n/l10n.dart';
import '../services/background_transfer.dart';
import '../services/desktop_client.dart';
import '../services/discovery.dart';
import '../services/mobile_settings.dart';
import '../services/uploader.dart';

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

  @override
  Widget build(BuildContext context) {
    final up = _uploader;
    return Scaffold(
      appBar: AppBar(title: Text(tr('transfer.title', {'name': widget.desktop.name}))),
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
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: Text(summary, style: theme.textTheme.titleSmall),
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
