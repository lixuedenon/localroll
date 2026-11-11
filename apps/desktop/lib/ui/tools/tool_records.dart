// apps/desktop/lib/ui/tools/tool_records.dart
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../../app_services.dart';
import '../../l10n/l10n.dart';
import '../../services/network.dart' show revealInExplorer;
import '../../services/tool_outputs.dart';
import '../light_look.dart';
import '../send_paths.dart';
import '../send_page.dart' show baseNameOf;
import 'tools.dart';

/// The Tools page's record: what each tool made, from what — open the
/// result, show the original, send it.
class ToolRecordsView extends StatefulWidget {
  const ToolRecordsView({super.key, required this.services});

  final AppServices services;

  @override
  State<ToolRecordsView> createState() => _ToolRecordsViewState();
}

class _ToolRecordsViewState extends State<ToolRecordsView> {
  bool _more = false;

  AppServices get s => widget.services;

  static String _when(int ms) {
    final t = DateTime.fromMillisecondsSinceEpoch(ms);
    final now = DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    final hm = '${two(t.hour)}:${two(t.minute)}';
    if (t.year == now.year && t.month == now.month && t.day == now.day) return hm;
    return t.year == now.year ? '${t.month}/${t.day} $hm' : '${t.year}/${t.month}/${t.day}';
  }

  static String _toolName(String name) {
    if (name == 'convert') return tr('tool.convert_name');
    for (final t in Tool.values) {
      if (t.name == name) return t.title;
    }
    return name;
  }

  void _gone() =>
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(tr('tool.file_gone'))));

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: s.tools,
        builder: (context, _) {
          final all = s.tools.items;
          final shown = _more ? all : all.take(6).toList();
          return Container(
            decoration: LightLook.card(),
            padding: const EdgeInsets.fromLTRB(16, 12, 12, 10),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Row(children: [
                const Icon(Icons.history_rounded, size: 20, color: LightLook.muted),
                const SizedBox(width: 8),
                Text(tr('tool.records'), style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: LightLook.text)),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(tr('tool.records_hint'),
                      overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12, color: LightLook.muted)),
                ),
                ToolSaveChip(services: s),
                TextButton.icon(
                  onPressed: () {
                    final dir = toolsFolderOf(s);
                    if (dir == null) return;
                    try {
                      Directory(dir).createSync(recursive: true);
                    } catch (_) {}
                    unawaited(revealInExplorer(dir));
                  },
                  icon: const Icon(Icons.folder_open_rounded, size: 18),
                  label: Text(tr('tool.open_folder')),
                ),
                if (all.isNotEmpty)
                  IconButton(
                    tooltip: tr('tool.records_clear'),
                    onPressed: s.tools.clear,
                    icon: const Icon(Icons.delete_sweep_outlined, size: 20, color: LightLook.muted),
                  ),
              ]),
              if (all.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  child: Text(tr('tool.records_empty'), textAlign: TextAlign.center, style: const TextStyle(color: LightLook.muted)),
                )
              else ...[
                for (final r in shown) _row(r),
                if (all.length > 6)
                  TextButton(
                    onPressed: () => setState(() => _more = !_more),
                    child: Text(_more ? tr('tool.records_less') : tr('tool.records_more', {'count': all.length})),
                  ),
              ],
            ]),
          );
        },
      );

  Widget _row(ToolRecord r) {
    final have = File(r.out).existsSync();
    final src = r.src;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(children: [
        SizedBox(width: 74, child: Text(_when(r.ms), style: const TextStyle(fontSize: 12, color: LightLook.muted))),
        SizedBox(
          width: 130,
          child: Text(_toolName(r.tool), overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13, color: LightLook.text)),
        ),
        Expanded(
          child: Tooltip(
            message: [if (src != null) src, r.out, ?r.copy].join('\n'),
            child: Text.rich(
              TextSpan(children: [
                if (src != null) TextSpan(text: '${baseNameOf(src)}  →  ', style: const TextStyle(color: LightLook.muted)),
                TextSpan(
                  text: baseNameOf(r.out),
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    color: have ? LightLook.text : LightLook.muted,
                    decoration: have ? null : TextDecoration.lineThrough,
                  ),
                ),
              ]),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 13),
            ),
          ),
        ),
        IconButton(
          tooltip: tr('common.open'),
          visualDensity: VisualDensity.compact,
          onPressed: () => have ? unawaited(Process.run('rundll32', ['url.dll,FileProtocolHandler', r.out])) : _gone(),
          icon: const Icon(Icons.open_in_new_rounded, size: 18),
        ),
        IconButton(
          tooltip: tr('common.show_in_folder'),
          visualDensity: VisualDensity.compact,
          onPressed: () => have ? unawaited(revealInExplorer(r.out)) : _gone(),
          icon: const Icon(Icons.folder_open_rounded, size: 18),
        ),
        IconButton(
          tooltip: src == null ? null : tr('tool.open_source', {'name': baseNameOf(src)}),
          visualDensity: VisualDensity.compact,
          onPressed: src == null ? null : () => File(src).existsSync() ? unawaited(revealInExplorer(src)) : _gone(),
          icon: const Icon(Icons.source_rounded, size: 18),
        ),
        IconButton(
          tooltip: tr('tool.send'),
          visualDensity: VisualDensity.compact,
          onPressed: !have
              ? null
              : () async {
                  final ids = await pickDevices(context, s, count: 1, first: baseNameOf(r.out));
                  if (ids != null && ids.isNotEmpty && mounted) await sendPathsTo(context, s, ids, [r.out]);
                },
          icon: const Icon(Icons.send_rounded, size: 18),
        ),
      ]),
    );
  }
}
