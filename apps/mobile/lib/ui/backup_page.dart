// apps/mobile/lib/ui/backup_page.dart
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:photo_manager/photo_manager.dart';

import '../l10n/l10n.dart';
import '../services/backup_plan.dart';
import '../services/discovery.dart';
import '../services/mobile_settings.dart';
import '../services/uploader.dart';
import 'cleanup_page.dart' show formatSize;
import 'theme.dart';
import 'transfer_page.dart';

/// "Back up…": choose what (dates, count, type, albums, size, order) and
/// when to stop (MB, minutes, battery). The preview updates as you change
/// anything; the conditions are remembered for next time.
class BackupPage extends StatefulWidget {
  const BackupPage({super.key, required this.settings, required this.discovery, required this.desktop});

  final MobileSettings settings;
  final DesktopDiscovery discovery;
  final PairedDesktop desktop;

  @override
  State<BackupPage> createState() => _BackupPageState();
}

class _BackupPageState extends State<BackupPage> {
  late BackupFilter _f = widget.settings.backupFilter.copy();
  BackupPlan? _plan;
  bool _planning = false;
  int _seen = 0;
  int _run = 0;
  Timer? _debounce;
  List<AssetPathEntity> _albums = const [];

  @override
  void initState() {
    super.initState();
    _replan();
    PhotoManager.getAssetPathList(type: RequestType.common, hasAll: false).then((a) {
      if (mounted) setState(() => _albums = a);
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  void _change(void Function(BackupFilter f) edit) {
    setState(() => edit(_f));
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), _replan);
  }

  Future<void> _replan() async {
    final run = ++_run;
    setState(() {
      _planning = true;
      _seen = 0;
    });
    final plan = await BackupPlanner.plan(
      _f,
      widget.settings.sentTo(widget.desktop.id),
      onProgress: (n) {
        if (mounted && run == _run) setState(() => _seen = n);
      },
    );
    if (!mounted || run != _run) return;
    setState(() {
      _plan = plan;
      _planning = false;
    });
  }

  // ------------------------------------------------------------- presets

  void _preset(String name) {
    _change((f) {
      final keep = f.pauseOnLowBattery;
      final n = BackupFilter(pauseOnLowBattery: keep);
      switch (name) {
        case 'try':
          n.maxCount = 50;
        case 'month':
          n.range = 'd30';
        case 'videos':
          n.photos = false;
        case 'largest':
          n.order = BackupOrder.largest;
      }
      _copyInto(f, n);
    });
  }

  static void _copyInto(BackupFilter to, BackupFilter from) {
    final j = from.toJson();
    final c = BackupFilter.fromJson(j);
    to
      ..fromMs = c.fromMs
      ..toMs = c.toMs
      ..maxCount = c.maxCount
      ..photos = c.photos
      ..videos = c.videos
      ..liveOnly = c.liveOnly
      ..skipScreenshots = c.skipScreenshots
      ..favoritesOnly = c.favoritesOnly
      ..localOnly = c.localOnly
      ..albumIds = c.albumIds
      ..minFileMb = c.minFileMb
      ..maxFileMb = c.maxFileMb
      ..order = c.order
      ..stopAfterMb = c.stopAfterMb
      ..stopAfterMinutes = c.stopAfterMinutes
      ..pauseOnLowBattery = c.pauseOnLowBattery
      ..range = c.range;
  }

  bool get _isAll {
    final d = BackupFilter(pauseOnLowBattery: _f.pauseOnLowBattery).toJson();
    return d.toString() == _f.toJson().toString();
  }

  // ------------------------------------------------------------- texts

  String _dateText() {
    String d(int ms) => MaterialLocalizations.of(context).formatShortDate(DateTime.fromMillisecondsSinceEpoch(ms));
    if (_f.range != null) return tr('backup.range_${_f.range}');
    if (_f.fromMs == null && _f.toMs == null) return tr('backup.any');
    if (_f.fromMs != null && _f.toMs != null) return '${d(_f.fromMs!)} – ${d(_f.toMs!)}';
    if (_f.fromMs != null) return tr('backup.since', {'date': d(_f.fromMs!)});
    return tr('backup.until', {'date': d(_f.toMs!)});
  }

  String _typeText() {
    final parts = <String>[
      if (_f.photos && _f.videos) tr('backup.type_both') else if (_f.photos) tr('backup.type_photos') else tr('backup.type_videos'),
      if (_f.liveOnly) tr('backup.live_only'),
      if (_f.skipScreenshots) tr('backup.no_screenshots'),
      if (_f.favoritesOnly) tr('backup.favorites_only'),
    ];
    return parts.join(' · ');
  }

  String _sizeText() {
    if (_f.minFileMb == null && _f.maxFileMb == null) return tr('backup.any');
    if (_f.minFileMb != null && _f.maxFileMb != null) return '${_mbText(_f.minFileMb!)} – ${_mbText(_f.maxFileMb!)}';
    if (_f.minFileMb != null) return '≥ ${_mbText(_f.minFileMb!)}';
    return '≤ ${_mbText(_f.maxFileMb!)}';
  }

  static String _mbText(int mb) => mb >= 1024 && mb % 1024 == 0 ? '${mb ~/ 1024} GB' : '$mb MB';

  String _orderText() => tr(switch (_f.order) {
        BackupOrder.newest => 'backup.order_newest',
        BackupOrder.oldest => 'backup.order_oldest',
        BackupOrder.largest => 'backup.order_largest',
      });

  // ------------------------------------------------------------- editors

  Future<void> _editDates() async {
    // Quick relative ranges first; a calendar for anything else.
    final choice = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) {
        Widget item(String key, String label, bool selected) => ListTile(
              title: Text(label),
              trailing: selected ? const Icon(Icons.check_rounded, color: LrColors.verified) : null,
              onTap: () => Navigator.pop(ctx, key),
            );
        final custom = _f.range == null && (_f.fromMs != null || _f.toMs != null);
        return SafeArea(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.75),
            child: ListView(shrinkWrap: true, children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                child: Text(tr('backup.dates'), style: Theme.of(ctx).textTheme.titleMedium),
              ),
              item('any', tr('backup.any'), _f.range == null && !custom),
              for (final r in BackupFilter.ranges) item(r, tr('backup.range_$r'), _f.range == r),
              item('custom', tr('backup.range_custom'), custom),
            ]),
          ),
        );
      },
    );
    if (choice == null || !mounted) return;
    if (choice == 'any') {
      _change((f) {
        f.range = null;
        f.fromMs = null;
        f.toMs = null;
      });
      return;
    }
    if (choice != 'custom') {
      _change((f) {
        f.range = choice;
        f.fromMs = null;
        f.toMs = null;
      });
      return;
    }
    final now = DateTime.now();
    final r = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2000),
      lastDate: now,
      initialDateRange: _f.fromMs == null
          ? null
          : DateTimeRange(
              start: DateTime.fromMillisecondsSinceEpoch(_f.fromMs!),
              end: DateTime.fromMillisecondsSinceEpoch(_f.toMs ?? now.millisecondsSinceEpoch),
            ),
    );
    if (r == null) return;
    _change((f) {
      f.range = null;
      f.fromMs = r.start.millisecondsSinceEpoch;
      // Include the whole last day.
      f.toMs = DateTime(r.end.year, r.end.month, r.end.day, 23, 59, 59).millisecondsSinceEpoch;
    });
  }

  /// Number picker with quick choices and "no limit".
  Future<int?> _pickNumber({
    required String title,
    required List<int> quick,
    required String Function(int) label,
    int? current,
    String unit = '',
  }) async {
    final ctrl = TextEditingController(text: current?.toString() ?? '');
    final v = await showDialog<int>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(spacing: 8, runSpacing: 8, children: [
              ActionChip(label: Text(tr('backup.any')), onPressed: () => Navigator.pop(ctx, -1)),
              for (final q in quick) ActionChip(label: Text(label(q)), onPressed: () => Navigator.pop(ctx, q)),
            ]),
            const SizedBox(height: 12),
            TextField(
              controller: ctrl,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(suffixText: unit, hintText: tr('backup.custom')),
              onSubmitted: (t) => Navigator.pop(ctx, int.tryParse(t)),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(tr('common.cancel'))),
          FilledButton(onPressed: () => Navigator.pop(ctx, int.tryParse(ctrl.text)), child: Text(tr('common.ok'))),
        ],
      ),
    );
    ctrl.dispose();
    return v;
  }

  Future<void> _editCount() async {
    final v = await _pickNumber(
      title: tr('backup.max_count'),
      quick: const [20, 50, 100, 500, 1000],
      label: (n) => '$n',
      current: _f.maxCount,
    );
    if (v == null) return;
    _change((f) => f.maxCount = v <= 0 ? null : v);
  }

  Future<void> _editType() async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) {
          void edit(void Function(BackupFilter f) e) {
            _change(e);
            setLocal(() {});
          }

          return SafeArea(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              CheckboxListTile(
                value: _f.photos,
                title: Text(tr('backup.type_photos')),
                onChanged: (v) => edit((f) => f.photos = v ?? true),
              ),
              CheckboxListTile(
                value: _f.videos,
                title: Text(tr('backup.type_videos')),
                onChanged: (v) => edit((f) => f.videos = v ?? true),
              ),
              if (Platform.isIOS)
                SwitchListTile(
                  value: _f.liveOnly,
                  title: Text(tr('backup.live_only')),
                  onChanged: (v) => edit((f) => f.liveOnly = v),
                ),
              SwitchListTile(
                value: _f.skipScreenshots,
                title: Text(tr('backup.no_screenshots')),
                onChanged: (v) => edit((f) => f.skipScreenshots = v),
              ),
              SwitchListTile(
                value: _f.favoritesOnly,
                title: Text(tr('backup.favorites_only')),
                onChanged: (v) => edit((f) => f.favoritesOnly = v),
              ),
              const SizedBox(height: 8),
            ]),
          );
        },
      ),
    );
  }

  Future<void> _editAlbums() async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => SafeArea(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.7),
            child: ListView(shrinkWrap: true, children: [
              CheckboxListTile(
                value: _f.albumIds.isEmpty,
                title: Text(tr('backup.albums_all')),
                onChanged: (_) {
                  _change((f) => f.albumIds = []);
                  setLocal(() {});
                },
              ),
              const Divider(height: 1),
              for (final a in _albums)
                CheckboxListTile(
                  value: _f.albumIds.contains(a.id),
                  title: Text(a.name),
                  onChanged: (v) {
                    _change((f) {
                      final ids = List.of(f.albumIds);
                      v == true ? ids.add(a.id) : ids.remove(a.id);
                      f.albumIds = ids;
                    });
                    setLocal(() {});
                  },
                ),
            ]),
          ),
        ),
      ),
    );
  }

  Future<void> _editFileSize() async {
    final minCtrl = TextEditingController(text: _f.minFileMb?.toString() ?? '');
    final maxCtrl = TextEditingController(text: _f.maxFileMb?.toString() ?? '');
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('backup.file_size')),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(
            controller: minCtrl,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(labelText: tr('backup.file_min'), suffixText: 'MB'),
          ),
          TextField(
            controller: maxCtrl,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(labelText: tr('backup.file_max'), suffixText: 'MB'),
          ),
          const SizedBox(height: 8),
          Text(tr('backup.file_size_hint'), style: Theme.of(ctx).textTheme.bodySmall),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('common.cancel'))),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(tr('common.ok'))),
        ],
      ),
    );
    final min = int.tryParse(minCtrl.text);
    final max = int.tryParse(maxCtrl.text);
    minCtrl.dispose();
    maxCtrl.dispose();
    if (ok != true) return;
    _change((f) {
      f.minFileMb = (min ?? 0) > 0 ? min : null;
      f.maxFileMb = (max ?? 0) > 0 ? max : null;
    });
  }

  Future<void> _editOrder() async {
    final v = await showModalBottomSheet<BackupOrder>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          for (final o in BackupOrder.values)
            ListTile(
              leading: Icon(o == _f.order ? Icons.radio_button_checked_rounded : Icons.radio_button_off_rounded,
                  color: o == _f.order ? LrColors.safelight : null),
              title: Text(tr(switch (o) {
                BackupOrder.newest => 'backup.order_newest',
                BackupOrder.oldest => 'backup.order_oldest',
                BackupOrder.largest => 'backup.order_largest',
              })),
              onTap: () => Navigator.pop(ctx, o),
            ),
        ]),
      ),
    );
    if (v != null) _change((f) => f.order = v);
  }

  Future<void> _editStopSize() async {
    final v = await _pickNumber(
      title: tr('backup.stop_size'),
      quick: const [1, 5, 10, 50],
      label: (n) => '$n GB',
      current: _f.stopAfterMb == null ? null : (_f.stopAfterMb! / 1024).round(),
      unit: 'GB',
    );
    if (v == null) return;
    _change((f) => f.stopAfterMb = v <= 0 ? null : v * 1024);
  }

  Future<void> _editStopTime() async {
    final v = await _pickNumber(
      title: tr('backup.stop_time'),
      quick: const [5, 15, 30, 60],
      label: (n) => tr('transfer.minutes', {'m': n}),
      current: _f.stopAfterMinutes,
      unit: tr('backup.minutes_unit'),
    );
    if (v == null) return;
    _change((f) => f.stopAfterMinutes = v <= 0 ? null : v);
  }

  // ------------------------------------------------------------- start

  Future<void> _start() async {
    final plan = _plan;
    if (plan == null || plan.assets.isEmpty) return;
    await widget.settings.setBackupFilter(_f.copy());
    if (!mounted) return;
    await Navigator.of(context).pushReplacement(MaterialPageRoute(
      builder: (_) => TransferPage(
        settings: widget.settings,
        discovery: widget.discovery,
        desktop: widget.desktop,
        assets: plan.assets,
        limits: UploadLimits(
          maxBytes: _f.stopAfterMb == null ? null : _f.stopAfterMb! * 1024 * 1024,
          maxDuration: _f.stopAfterMinutes == null ? null : Duration(minutes: _f.stopAfterMinutes!),
          pauseOnLowBattery: _f.pauseOnLowBattery,
        ),
      ),
    ));
  }

  // ------------------------------------------------------------- UI

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    Widget row(String label, String value, VoidCallback onTap, {bool highlight = false}) => ListTile(
          title: Text(label),
          trailing: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 190),
            child: Text(
              '$value  ›',
              textAlign: TextAlign.end,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: highlight ? LrColors.safelight : LrColors.muted),
            ),
          ),
          onTap: onTap,
        );
    Widget chip(String key, String label, bool selected) => ChoiceChip(
          label: Text(label),
          selected: selected,
          onSelected: (_) => _preset(key),
        );

    final plan = _plan;
    return Scaffold(
      appBar: AppBar(title: Text(tr('backup.title', {'pc': widget.desktop.name}))),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
        children: [
          Wrap(spacing: 8, runSpacing: 8, children: [
            chip('all', tr('backup.preset_all'), _isAll),
            chip('try', tr('backup.preset_try'), false),
            chip('month', tr('backup.preset_month'), false),
            chip('videos', tr('backup.preset_videos'), false),
            chip('largest', tr('backup.preset_largest'), false),
          ]),
          const SizedBox(height: 16),
          Card(
            child: Column(children: [
              row(tr('backup.dates'), _dateText(), _editDates),
              row(tr('backup.max_count'), _f.maxCount?.toString() ?? tr('backup.any'), _editCount),
              row(tr('backup.type'), _typeText(), _editType),
              row(
                tr('backup.albums'),
                _f.albumIds.isEmpty ? tr('backup.albums_all') : tr('backup.albums_n', {'count': _f.albumIds.length}),
                _editAlbums,
              ),
              row(tr('backup.file_size'), _sizeText(), _editFileSize),
              row(tr('backup.order'), _orderText(), _editOrder),
              if (Platform.isIOS)
                SwitchListTile(
                  value: _f.localOnly,
                  title: Text(tr('backup.local_only')),
                  subtitle: Text(tr('backup.local_only_hint')),
                  onChanged: (v) => _change((f) => f.localOnly = v),
                ),
            ]),
          ),
          const SizedBox(height: 16),
          Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 6),
            child: Text(tr('backup.when_stop'), style: theme.textTheme.titleSmall),
          ),
          Card(
            child: Column(children: [
              row(
                tr('backup.stop_size'),
                _f.stopAfterMb == null ? tr('backup.any') : _mbText(_f.stopAfterMb!),
                _editStopSize,
                highlight: _f.stopAfterMb != null,
              ),
              row(
                tr('backup.stop_time'),
                _f.stopAfterMinutes == null ? tr('backup.any') : tr('transfer.minutes', {'m': _f.stopAfterMinutes}),
                _editStopTime,
                highlight: _f.stopAfterMinutes != null,
              ),
              SwitchListTile(
                value: _f.pauseOnLowBattery,
                title: Text(tr('backup.battery')),
                onChanged: (v) => _change((f) => f.pauseOnLowBattery = v),
              ),
            ]),
          ),
        ],
      ),
      bottomNavigationBar: SafeArea(
        child: Container(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          decoration: const BoxDecoration(
            color: LrColors.surface,
            border: Border(top: BorderSide(color: LrColors.line)),
          ),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(
              _planning || plan == null
                  ? tr('backup.counting', {'count': _seen})
                  : plan.assets.isEmpty
                      ? tr('backup.nothing')
                      : plan.sizesKnown
                          ? tr('backup.preview', {'count': plan.assets.length, 'size': formatSize(plan.totalBytes)})
                          : tr('backup.preview_count', {'count': plan.assets.length}),
              style: theme.textTheme.bodyMedium,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              height: 52,
              child: FilledButton.icon(
                onPressed: _planning || plan == null || plan.assets.isEmpty ? null : _start,
                icon: const Icon(Icons.backup_rounded),
                label: Text(tr('backup.start')),
              ),
            ),
          ]),
        ),
      ),
    );
  }
}
