// apps/desktop/lib/ui/convert_dialog.dart
import 'package:flutter/material.dart';
import 'package:localroll_core/localroll_core.dart';

import '../app_services.dart';
import '../l10n/l10n.dart';
import '../services/converter.dart';
import 'app_nav.dart';
import 'theme.dart';

/// What to convert to: one of the two ready choices, or a file type.
typedef ConvertChoice = ({ConvertPreset? preset, ConvertFormat? format});

/// "Convert to…": the two ready choices first (plays anywhere / small to
/// share), then every file type this PC can write, for [video] or photos.
Future<ConvertChoice?> showConvertDialog(BuildContext context, AppServices s, {required bool video, bool presets = true}) async {
  final can = await s.converter.available();
  if (!context.mounted) return null;
  final formats = [for (final f in ConvertFormat.forSource(video: video)) if (can.contains(f)) f];
  Widget group(String title, Iterable<ConvertFormat> list, BuildContext ctx) {
    final items = list.toList();
    if (items.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(title, style: const TextStyle(color: LrColors.muted, fontSize: 12.5)),
        const SizedBox(height: 6),
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (final f in items)
            ActionChip(
              label: Text(f == ConvertFormat.gif ? tr('convert.gif') : f.label),
              onPressed: () => Navigator.pop(ctx, (preset: null, format: f)),
            ),
        ]),
      ]),
    );
  }

  return showDialog<ConvertChoice>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(tr('convert.title')),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (presets)
              for (final p in ConvertPreset.values)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(p == ConvertPreset.compatible ? Icons.verified_rounded : Icons.compress_rounded, color: LrColors.safelight),
                  title: Text(p.label),
                  subtitle: Text(tr('convert.preset_tip_${p.folder}')),
                  onTap: () => Navigator.pop(ctx, (preset: p, format: null)),
                ),
            if (video) ...[
              group(tr('convert.group_video'), formats.where((f) => f.kind == FormatKind.video), ctx),
              group(tr('convert.group_audio'), formats.where((f) => f.kind == FormatKind.audio), ctx),
            ] else
              group(tr('convert.group_image'), formats, ctx),
            const SizedBox(height: 12),
            Text(tr(video ? 'convert.note_video' : 'convert.note_image'), style: const TextStyle(color: LrColors.muted, fontSize: 12, height: 1.5)),
          ]),
        ),
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: Text(tr('common.cancel')))],
    ),
  );
}

/// Ask, start, and go to "Convert" (the rail follows what was started).
/// [items] from the library, or one [path] outside it.
Future<bool> convertWithDialog(BuildContext context, AppServices s, {List<MediaItem> items = const [], String? path, required bool video}) async {
  final c = await showConvertDialog(context, s, video: video, presets: items.isNotEmpty);
  if (c == null) return false;
  if (items.isNotEmpty) {
    s.converter.enqueue(items, c.preset ?? ConvertPreset.compatible, format: c.format);
  } else if (path != null && c.format != null) {
    s.converter.enqueueFile(path, c.format!);
  } else {
    return false;
  }
  AppNav.instance.selectTab(AppNav.convert);
  return true;
}
