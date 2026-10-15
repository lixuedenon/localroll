// apps/mobile/lib/ui/lost_notice.dart
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:photo_manager/photo_manager.dart';

import '../l10n/l10n.dart';
import 'theme.dart';

/// "Just deleted on the PC": a clear notice, the moment the PC tells us,
/// showing exactly which photos and videos lost their backup.
/// Returns true for "Back up again".
Future<bool> showLostNotice(BuildContext context, {required String pc, required List<String> ids}) async {
  HapticFeedback.mediumImpact();
  final r = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    backgroundColor: LrColors.raised,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
    builder: (context) {
      final theme = Theme.of(context);
      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(children: [
                const Icon(Icons.delete_sweep_rounded, color: LrColors.safelight, size: 28),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(tr('lost.just_title', {'pc': pc, 'count': ids.length}),
                      style: theme.textTheme.titleLarge),
                ),
              ]),
              const SizedBox(height: 10),
              Text(tr('lost.just_body'), style: theme.textTheme.bodyMedium),
              const SizedBox(height: 14),
              LostThumbs(ids: ids, max: 12, size: 76),
              const SizedBox(height: 16),
              Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                TextButton(onPressed: () => Navigator.of(context).pop(false), child: Text(tr('lost.later'))),
                const SizedBox(width: 8),
                FilledButton.icon(
                  onPressed: () => Navigator.of(context).pop(true),
                  icon: const Icon(Icons.backup_rounded),
                  label: Text(tr('lost.rebackup')),
                ),
              ]),
            ],
          ),
        ),
      );
    },
  );
  return r ?? false;
}

/// Small pictures of the given phone assets (the ones deleted on the PC),
/// at most [max], then "+N more".
class LostThumbs extends StatefulWidget {
  const LostThumbs({super.key, required this.ids, this.max = 6, this.size = 56});

  final List<String> ids;
  final int max;
  final double size;

  @override
  State<LostThumbs> createState() => _LostThumbsState();
}

class _LostThumbsState extends State<LostThumbs> {
  static final Map<String, Future<Uint8List?>> _cache = {};

  Future<Uint8List?> _thumb(String id) => _cache.putIfAbsent(id, () async {
        final a = await AssetEntity.fromId(id);
        return a?.thumbnailDataWithSize(const ThumbnailSize.square(200), quality: 80);
      });

  @override
  Widget build(BuildContext context) {
    final shown = widget.ids.take(widget.max).toList();
    final more = widget.ids.length - shown.length;
    final s = widget.size;
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        for (final id in shown)
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: SizedBox(
              width: s,
              height: s,
              child: FutureBuilder<Uint8List?>(
                future: _thumb(id),
                builder: (context, snap) {
                  final b = snap.data;
                  if (b == null) return Container(color: LrColors.surface);
                  return Image.memory(b, fit: BoxFit.cover, gaplessPlayback: true);
                },
              ),
            ),
          ),
        if (more > 0)
          Container(
            width: s,
            height: s,
            alignment: Alignment.center,
            decoration: BoxDecoration(color: LrColors.surface, borderRadius: BorderRadius.circular(8)),
            child: Text(tr('lost.more', {'count': more}), textAlign: TextAlign.center, style: const TextStyle(fontSize: 12)),
          ),
      ],
    );
  }
}
