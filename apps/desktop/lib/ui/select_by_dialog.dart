// apps/desktop/lib/ui/select_by_dialog.dart
import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import 'format.dart';
import 'theme.dart';

/// What "Select by…" can pick.
enum PickType { photo, video, doc, other, copy }

/// One thing in the library, described for "Select by…".
class PickCandidate {
  const PickCandidate({
    required this.key,
    required this.size,
    required this.taken,
    required this.received,
    required this.type,
    this.from,
  });

  /// The selection key on the library page.
  final String key;
  final int size;
  final DateTime taken;
  final DateTime received;
  final PickType type;

  /// Who sent it (family member / device); null: not known.
  final String? from;
}

/// "Select by…": a time span (taken or received), who sent it, what kind,
/// how big — and how many that is, before anything is selected. Returns the
/// chosen candidates (null: cancelled).
Future<List<PickCandidate>?> showSelectByDialog(BuildContext context, List<PickCandidate> all) =>
    showDialog<List<PickCandidate>>(context: context, builder: (_) => _SelectByDialog(all: all));

class _SelectByDialog extends StatefulWidget {
  const _SelectByDialog({required this.all});

  final List<PickCandidate> all;

  @override
  State<_SelectByDialog> createState() => _SelectByDialogState();
}

class _SelectByDialogState extends State<_SelectByDialog> {
  bool _byReceived = false;
  DateTimeRange? _range;
  String? _from;
  final Set<PickType> _types = {PickType.photo, PickType.video, PickType.doc, PickType.other};
  int _minSize = 0;

  static const List<int> _sizes = [0, 10 << 20, 100 << 20, 1 << 30];

  late final List<String> _senders = () {
    final s = {for (final c in widget.all) ?c.from}.toList()..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    return s;
  }();

  late final Map<PickType, int> _typeCounts = () {
    final m = <PickType, int>{};
    for (final c in widget.all) {
      m[c.type] = (m[c.type] ?? 0) + 1;
    }
    return m;
  }();

  bool _matches(PickCandidate c) {
    if (!_types.contains(c.type)) return false;
    if (c.size < _minSize) return false;
    if (_from != null && c.from != _from) return false;
    final r = _range;
    if (r != null) {
      final t = _byReceived ? c.received : c.taken;
      final start = DateTime(r.start.year, r.start.month, r.start.day);
      final end = DateTime(r.end.year, r.end.month, r.end.day).add(const Duration(days: 1));
      if (t.isBefore(start) || !t.isBefore(end)) return false;
    }
    return true;
  }

  Future<void> _pickRange() async {
    final now = DateTime.now();
    final r = await showDateRangePicker(
      context: context,
      firstDate: DateTime(1970),
      lastDate: DateTime(now.year, now.month, now.day).add(const Duration(days: 1)),
      initialDateRange: _range,
    );
    if (r != null) setState(() => _range = r);
  }

  String _typeLabel(PickType t) => switch (t) {
        PickType.photo => tr('library.filter_photos'),
        PickType.video => tr('library.filter_videos'),
        PickType.doc => tr('library.filter_docs'),
        PickType.other => tr('library.filter_other'),
        PickType.copy => tr('pick.copies'),
      };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hits = [for (final c in widget.all) if (_matches(c)) c];
    final size = hits.fold(0, (a, c) => a + c.size);
    final loc = MaterialLocalizations.of(context);
    Widget label(String t) => Padding(
          padding: const EdgeInsets.only(top: 16, bottom: 8),
          child: Text(t, style: theme.textTheme.titleSmall),
        );
    return AlertDialog(
      title: Text(tr('pick.title')),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            label(tr('pick.when')),
            Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
              SegmentedButton<bool>(
                showSelectedIcon: false,
                segments: [
                  ButtonSegment(value: false, label: Text(tr('library.sort_taken'))),
                  ButtonSegment(value: true, label: Text(tr('library.sort_received'))),
                ],
                selected: {_byReceived},
                onSelectionChanged: (v) => setState(() => _byReceived = v.first),
              ),
              OutlinedButton.icon(
                onPressed: _pickRange,
                icon: const Icon(Icons.date_range_rounded, size: 18),
                label: Text(_range == null
                    ? tr('pick.any_time')
                    : '${loc.formatMediumDate(_range!.start)} – ${loc.formatMediumDate(_range!.end)}'),
              ),
              if (_range != null)
                IconButton(
                  tooltip: tr('pick.any_time'),
                  onPressed: () => setState(() => _range = null),
                  icon: const Icon(Icons.close_rounded, size: 18),
                ),
            ]),
            if (_senders.isNotEmpty) ...[
              label(tr('pick.from')),
              DropdownButton<String?>(
                value: _from,
                onChanged: (v) => setState(() => _from = v),
                items: [
                  DropdownMenuItem(value: null, child: Text(tr('family.everyone'))),
                  for (final s in _senders) DropdownMenuItem(value: s, child: Text(s)),
                ],
              ),
            ],
            label(tr('pick.kinds')),
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (final t in PickType.values)
                if ((_typeCounts[t] ?? 0) > 0 || t != PickType.copy)
                  FilterChip(
                    label: Text('${_typeLabel(t)} · ${_typeCounts[t] ?? 0}'),
                    selected: _types.contains(t),
                    onSelected: (on) => setState(() => on ? _types.add(t) : _types.remove(t)),
                  ),
            ]),
            if ((_typeCounts[PickType.copy] ?? 0) > 0)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(tr('pick.copies_hint'), style: theme.textTheme.bodySmall?.copyWith(color: LrColors.muted)),
              ),
            label(tr('pick.size')),
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (final s in _sizes)
                ChoiceChip(
                  label: Text(s == 0 ? tr('pick.any_size') : tr('pick.at_least', {'size': formatBytes(s)})),
                  selected: _minSize == s,
                  onSelected: (_) => setState(() => _minSize = s),
                ),
            ]),
            const SizedBox(height: 20),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: LrColors.raised,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(children: [
                const Icon(Icons.checklist_rounded, size: 20, color: LrColors.safelight),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(tr('pick.result', {'count': hits.length, 'size': formatBytes(size)}),
                      style: theme.textTheme.bodyMedium),
                ),
              ]),
            ),
          ]),
        ),
      ),
      actions: [
        OutlinedButton(onPressed: () => Navigator.pop(context), child: Text(tr('common.cancel'))),
        FilledButton(
          onPressed: hits.isEmpty ? null : () => Navigator.pop(context, hits),
          child: Text(tr('pick.select')),
        ),
      ],
    );
  }
}
