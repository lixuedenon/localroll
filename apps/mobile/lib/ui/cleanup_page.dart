// apps/mobile/lib/ui/cleanup_page.dart
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:localroll_core/localroll_core.dart';
import 'package:photo_manager/photo_manager.dart';

import '../l10n/l10n.dart';
import '../services/desktop_client.dart';
import '../services/discovery.dart';
import '../services/mobile_settings.dart';
import 'theme.dart';
import 'transfer_page.dart';

enum _Stage { finding, checking, ready, deleting, done, error }

/// Safe cleanup: only items the PC proves it still holds (same size, same
/// SHA-256 as when received) are offered for deletion. Deleting goes through
/// the system's own confirmation; on iPhone items stay in "Recently Deleted"
/// for 30 days.
class CleanupPage extends StatefulWidget {
  const CleanupPage({super.key, required this.settings, required this.discovery, required this.desktop});

  final MobileSettings settings;
  final DesktopDiscovery discovery;
  final PairedDesktop desktop;

  @override
  State<CleanupPage> createState() => _CleanupPageState();
}

class _CleanupPageState extends State<CleanupPage> {
  _Stage _stage = _Stage.finding;
  String? _error;
  int _done = 0;
  int _total = 0;

  final List<AssetEntity> _safe = [];
  final Map<String, int> _sizes = {};
  final Set<String> _selected = {};

  /// Sent before, but the PC no longer has them (deleted / changed there).
  /// The phone holds the only copy: offer to back them up again.
  final List<AssetEntity> _lost = [];
  final Map<String, String> _lostReason = {};
  int _freed = 0;
  final Map<String, Future<Uint8List?>> _thumbs = {};

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    setState(() {
      _stage = _Stage.finding;
      _error = null;
      _safe.clear();
      _selected.clear();
      _sizes.clear();
      _lost.clear();
      _lostReason.clear();
    });
    DesktopClient? client;
    try {
      // 1. Which sent items are still on this phone?
      final sent = widget.settings.sentTo(widget.desktop.id).toList();
      final onPhone = <String, AssetEntity>{};
      for (final id in sent) {
        final a = await AssetEntity.fromId(id);
        if (a != null) onPhone[id] = a;
      }
      if (onPhone.isEmpty) {
        setState(() => _stage = _Stage.ready);
        return;
      }

      // 2. Ask the PC to re-check every one of them.
      setState(() {
        _stage = _Stage.checking;
        _done = 0;
        _total = onPhone.length;
      });
      client = await connectToDesktop(widget.settings, widget.desktop, discovered: widget.discovery.found);
      final ids = onPhone.keys.toList();
      // Live Photos count as safe only if the PC also holds their video.
      const step = LrProtocol.verifyBatch ~/ 2;
      for (var i = 0; i < ids.length; i += step) {
        final batch = ids.sublist(i, (i + step).clamp(0, ids.length));
        final res = await client.verify([
          for (final id in batch) ...[id, if (onPhone[id]!.isLivePhoto) liveCompanionId(id)],
        ]);
        final byId = {for (final v in res.items) v.assetId: v};
        for (final id in batch) {
          final a = onPhone[id]!;
          final photo = byId[id];
          final video = a.isLivePhoto ? byId[liveCompanionId(id)] : null;
          final ok = photo != null && photo.ok && (!a.isLivePhoto || (video != null && video.ok));
          if (ok) {
            _safe.add(a);
            _sizes[a.id] = photo!.size + (video?.size ?? 0);
            _selected.add(a.id);
          } else {
            _lost.add(a);
            // Photo fine but its Live video never arrived (sent by an older
            // version): say so, "Back up again" sends just the video.
            _lostReason[a.id] = photo != null && photo.ok ? 'no_live' : (photo?.reason ?? 'missing');
          }
        }
        if (!mounted) return;
        setState(() => _done = (i + batch.length).clamp(0, ids.length));
      }
      // Newest first, like the photo library.
      _safe.sort((a, b) => b.createDateTime.compareTo(a.createDateTime));
      _lost.sort((a, b) => b.createDateTime.compareTo(a.createDateTime));
      // They are no longer backed up: remove the ✓ on the home grid.
      if (_lost.isNotEmpty) await widget.settings.unmarkSent(widget.desktop.id, _lost.map((a) => a.id));
      if (mounted) setState(() => _stage = _Stage.ready);
    } catch (e) {
      if (mounted) {
        setState(() {
          _stage = _Stage.error;
          _error = e is LrHttpException ? e.message : e.toString().replaceFirst('Exception: ', '');
        });
      }
    } finally {
      client?.close();
    }
  }

  int get _selectedBytes => _selected.fold(0, (sum, id) => sum + (_sizes[id] ?? 0));

  Future<void> _delete() async {
    final ids = _selected.toList();
    if (ids.isEmpty) return;
    final bytes = _selectedBytes;
    setState(() => _stage = _Stage.deleting);
    try {
      // The system shows its own confirmation dialog here.
      final deleted = await PhotoManager.editor.deleteWithIds(ids);
      final gone = deleted.toSet();
      if (!mounted) return;
      if (gone.isEmpty) {
        setState(() => _stage = _Stage.ready);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('cleanup.cancelled'))));
        return;
      }
      setState(() {
        _freed = gone.length == ids.length
            ? bytes
            : gone.fold(0, (sum, id) => sum + (_sizes[id] ?? 0));
        _safe.removeWhere((a) => gone.contains(a.id));
        _selected.removeAll(gone);
        _stage = _Stage.done;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _stage = _Stage.error;
          _error = e.toString();
        });
      }
    }
  }

  Future<Uint8List?> _thumb(AssetEntity a) =>
      _thumbs.putIfAbsent(a.id, () => a.thumbnailDataWithSize(const ThumbnailSize.square(200), quality: 75));

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(tr('cleanup.title'))),
      body: switch (_stage) {
        _Stage.finding || _Stage.deleting => const Center(child: CircularProgressIndicator()),
        _Stage.checking => _checking(context),
        _Stage.error => _errorView(context),
        _Stage.done => _doneView(context),
        _Stage.ready => _readyView(context),
      },
    );
  }

  Widget _checking(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 220,
                child: LinearProgressIndicator(value: _total == 0 ? null : _done / _total, minHeight: 6),
              ),
              const SizedBox(height: 16),
              Text(tr('cleanup.checking', {'done': _done, 'total': _total, 'pc': widget.desktop.name}),
                  textAlign: TextAlign.center),
            ],
          ),
        ),
      );

  Widget _errorView(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.link_off_rounded, size: 40, color: LrColors.danger),
              const SizedBox(height: 12),
              Text(_error ?? '', textAlign: TextAlign.center),
              const SizedBox(height: 16),
              FilledButton(onPressed: _run, child: Text(tr('common.retry'))),
            ],
          ),
        ),
      );

  Widget _doneView(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.verified_rounded, size: 56, color: LrColors.verified),
              const SizedBox(height: 16),
              Text(formatSize(_freed), style: Theme.of(context).textTheme.headlineMedium),
              const SizedBox(height: 8),
              Text(tr(Platform.isIOS ? 'cleanup.done_ios' : 'cleanup.done'), textAlign: TextAlign.center),
              const SizedBox(height: 24),
              FilledButton(onPressed: () => Navigator.of(context).pop(), child: Text(tr('transfer.done'))),
            ],
          ),
        ),
      );

  void _rebackup() {
    Navigator.of(context).pushReplacement(MaterialPageRoute(
      builder: (_) => TransferPage(
        settings: widget.settings,
        discovery: widget.discovery,
        desktop: widget.desktop,
        assets: List.of(_lost),
      ),
    ));
  }

  /// Reverse signal: these were on the PC once, but not any more.
  Widget _icloudNote(ThemeData theme) => Container(
        margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: LrColors.safelight.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: LrColors.safelight.withValues(alpha: 0.5)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(Icons.cloud_outlined, color: LrColors.safelight, size: 22),
            const SizedBox(width: 10),
            Expanded(
              child: Text(tr('cleanup.icloud', {'pc': widget.desktop.name}), style: theme.textTheme.bodySmall),
            ),
          ],
        ),
      );

  Widget _lostCard(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: LrColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: LrColors.safelight),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            const Icon(Icons.warning_amber_rounded, color: LrColors.safelight),
            const SizedBox(width: 10),
            Expanded(
              child: Text(tr('cleanup.lost_title', {'count': _lost.length, 'pc': widget.desktop.name}),
                  style: theme.textTheme.titleSmall),
            ),
          ]),
          const SizedBox(height: 6),
          Text(tr('cleanup.lost_body'), style: theme.textTheme.bodySmall),
          const SizedBox(height: 10),
          SizedBox(
            height: 64,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: _lost.length,
              separatorBuilder: (_, _) => const SizedBox(width: 6),
              itemBuilder: (context, i) {
                final a = _lost[i];
                final reason = _lostReason[a.id];
                return Stack(children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: SizedBox(
                      width: 64,
                      height: 64,
                      child: FutureBuilder<Uint8List?>(
                        future: _thumb(a),
                        builder: (context, snap) => snap.data == null
                            ? Container(color: LrColors.raised)
                            : Image.memory(snap.data!, fit: BoxFit.cover, gaplessPlayback: true),
                      ),
                    ),
                  ),
                  Positioned(
                    left: 2,
                    bottom: 2,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                      decoration: BoxDecoration(color: Colors.black87, borderRadius: BorderRadius.circular(4)),
                      child: Text(
                        tr(switch (reason) {
                          'changed' => 'cleanup.lost_changed',
                          'no_live' => 'cleanup.lost_no_live',
                          _ => 'cleanup.lost_missing',
                        }),
                        style: const TextStyle(color: Colors.white, fontSize: 9),
                      ),
                    ),
                  ),
                ]);
              },
            ),
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: _rebackup,
            icon: const Icon(Icons.cloud_upload_rounded, size: 18),
            label: Text(tr('cleanup.rebackup', {'count': _lost.length})),
          ),
        ],
      ),
    );
  }

  Widget _readyView(BuildContext context) {
    final theme = Theme.of(context);
    if (_safe.isEmpty) {
      return ListView(
        children: [
          if (_lost.isNotEmpty) _lostCard(context),
          Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.cleaning_services_outlined, size: 48, color: LrColors.muted),
              const SizedBox(height: 12),
              Text(tr('cleanup.none'), textAlign: TextAlign.center),
            ],
          ),
        ),
        ],
      );
    }
    return Column(
      children: [
        if (_lost.isNotEmpty) _lostCard(context),
        // Summary: what the PC has proven it holds.
        Container(
          margin: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: LrColors.surface,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: LrColors.verified.withValues(alpha: 0.5)),
          ),
          child: Row(
            children: [
              const Icon(Icons.verified_user_rounded, color: LrColors.verified, size: 32),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(tr('cleanup.ready', {'count': _safe.length, 'pc': widget.desktop.name}),
                        style: theme.textTheme.titleSmall),
                    const SizedBox(height: 4),
                    Text(tr('cleanup.how'), style: theme.textTheme.bodySmall),
                  ],
                ),
              ),
            ],
          ),
        ),
        // iCloud Photos syncs deletions: removing a photo here also removes it
        // from iCloud and every device on the same Apple ID. The PC copy is
        // what stays — say so before anyone taps Delete.
        if (Platform.isIOS) _icloudNote(theme),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            children: [
              TextButton(
                onPressed: () => setState(() => _selected
                  ..clear()
                  ..addAll(_safe.map((a) => a.id))),
                child: Text(tr('cleanup.select_all')),
              ),
              TextButton(onPressed: () => setState(_selected.clear), child: Text(tr('cleanup.select_none'))),
            ],
          ),
        ),
        Expanded(
          child: GridView.builder(
            padding: const EdgeInsets.all(2),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 4,
              mainAxisSpacing: 2,
              crossAxisSpacing: 2,
            ),
            itemCount: _safe.length,
            itemBuilder: (context, i) {
              final a = _safe[i];
              final sel = _selected.contains(a.id);
              return GestureDetector(
                onTap: () => setState(() => sel ? _selected.remove(a.id) : _selected.add(a.id)),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    FutureBuilder<Uint8List?>(
                      future: _thumb(a),
                      builder: (context, snap) => snap.data == null
                          ? Container(color: LrColors.raised)
                          : Image.memory(snap.data!, fit: BoxFit.cover, gaplessPlayback: true),
                    ),
                    if (!sel) Container(color: Colors.black54),
                    Positioned(
                      right: 4,
                      top: 4,
                      child: Icon(
                        sel ? Icons.check_circle_rounded : Icons.radio_button_unchecked_rounded,
                        color: sel ? LrColors.verified : Colors.white70,
                        size: 22,
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                style: FilledButton.styleFrom(backgroundColor: LrColors.danger, foregroundColor: Colors.white),
                onPressed: _selected.isEmpty ? null : _delete,
                icon: const Icon(Icons.delete_sweep_rounded),
                label: Text(tr('cleanup.delete', {'count': _selected.length, 'size': formatSize(_selectedBytes)})),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// 1.2 GB / 340 MB / 12 KB.
String formatSize(int bytes) {
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var v = bytes.toDouble();
  var u = 0;
  while (v >= 1024 && u < units.length - 1) {
    v /= 1024;
    u++;
  }
  return '${v >= 100 || u == 0 ? v.toStringAsFixed(0) : v.toStringAsFixed(1)} ${units[u]}';
}
