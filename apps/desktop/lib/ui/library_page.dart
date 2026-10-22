// apps/desktop/lib/ui/library_page.dart
import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:localroll_core/localroll_core.dart';

import '../app_services.dart';
import '../l10n/l10n.dart';
import '../services/converter.dart';
import '../services/file_actions.dart';
import '../services/library_index.dart';
import '../services/network.dart';
import '../services/peers.dart';
import '../services/received_files.dart';
import '../services/win_dialogs.dart';
import 'files_view.dart';
import 'format.dart';
import 'library_recovery.dart';
import 'media_thumb.dart';
import 'select_by_dialog.dart';
import 'send_page.dart';
import 'theme.dart';
import 'trash_actions.dart';
import 'trash_page.dart';
import 'viewer_page.dart';

enum _Filter { all, photos, videos, docs, other }

/// One square on the "All" timeline: a library photo / video, or a received
/// file (Documents / Other).
class _Cell {
  _Cell.media(MediaItem this.media, this.day) : file = null;
  _Cell.file(ReceivedFile this.file) : media = null, day = file.arrived;

  final MediaItem? media;
  final ReceivedFile? file;
  final DateTime day;

  /// Its selection key: the item's path in the library, or "f:" + the
  /// received file's full path.
  String get key => media?.relPath ?? _LibraryPageState.fileKey(file!.path);
}

/// Received media grouped by capture day, newest first; All / Photos / Videos.
class LibraryPage extends StatefulWidget {
  const LibraryPage({super.key, required this.services});

  final AppServices services;

  @override
  State<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends State<LibraryPage> {
  _Filter _filter = _Filter.all;
  final Set<String> _selected = {};

  /// Family group: show one member only (null = everyone).
  String? _member;

  /// "Only me" items are hidden until this is switched on.
  bool _showPrivate = false;

  bool get _selecting => _selected.isNotEmpty || _copies.isNotEmpty;

  static String fileKey(String path) => 'f:$path';

  /// Converted copies picked with "Select by…" (not shown in the grid):
  /// full path → size.
  final Map<String, int> _copies = {};

  /// Keyboard: Ctrl+A, Delete, Esc.
  final FocusNode _focus = FocusNode(debugLabel: 'library');
  final ScrollController _scroll = ScrollController();

  /// The square under the mouse (its round "select" button shows).
  final ValueNotifier<String?> _hovered = ValueNotifier(null);

  /// Where Shift+click selects from.
  String? _anchor;

  /// Selection keys in the order shown (for Shift+click and Ctrl+A).
  List<String> _order = const [];

  /// Squares on screen now, for selecting with a box.
  final Map<String, BuildContext> _boxes = {};
  final GlobalKey _gridKey = GlobalKey();
  Offset? _downAt;
  double _downOffset = 0;
  Offset? _dragNow;
  bool _boxing = false;
  Set<String> _boxBase = {};
  final Set<String> _boxHits = {};
  Timer? _autoScroll;

  void _clearSelection() {
    _selected.clear();
    _copies.clear();
    _anchor = null;
  }

  /// Received files (Documents / Other), shown on the "All" timeline by the
  /// day they arrived.
  List<ReceivedFile> _files = const [];
  int _seenSaved = -1;
  String? _lastSaved;
  final List<StreamSubscription<FileSystemEvent>> _watches = [];
  Timer? _filesSoon;

  @override
  void initState() {
    super.initState();
    widget.services.hub.addListener(_onHub);
    widget.services.server.files.changes.addListener(_reloadFilesSoon);
    unawaited(_loadFiles());
    unawaited(_watchFiles());
  }

  @override
  void dispose() {
    widget.services.hub.removeListener(_onHub);
    widget.services.server.files.changes.removeListener(_reloadFilesSoon);
    for (final w in _watches) {
      unawaited(w.cancel());
    }
    _filesSoon?.cancel();
    _autoScroll?.cancel();
    _focus.dispose();
    _scroll.dispose();
    _hovered.dispose();
    super.dispose();
  }

  /// A file arrived: show it.
  void _onHub() {
    // The list keeps the last 200: compare the newest, not the count.
    final saved = widget.services.hub.savedFiles;
    final last = saved.isEmpty ? null : saved.last;
    if (saved.length != _seenSaved || last != _lastSaved) {
      _seenSaved = saved.length;
      _lastSaved = last;
      _reloadFilesSoon();
    }
  }

  void _reloadFilesSoon() {
    _filesSoon?.cancel();
    _filesSoon = Timer(const Duration(milliseconds: 800), () {
      widget.services.server.files.forget();
      unawaited(_loadFiles());
    });
  }

  Future<void> _loadFiles() async {
    final f = await widget.services.server.files.list();
    if (mounted) setState(() => _files = f);
  }

  /// Changes made in Explorer (deleted, renamed, copied in) show up too.
  Future<void> _watchFiles() async {
    for (final doc in [true, false]) {
      try {
        final dir = await widget.services.server.folderPath(document: doc);
        _watches.add(Directory(dir).watch(recursive: true).listen((_) => _reloadFilesSoon(), onError: (_) {}));
      } catch (_) {}
    }
  }

  /// Received files that belong on the "All" timeline now.
  List<ReceivedFile> _visibleFiles() {
    // Files carry no sender: hidden while one person is picked.
    if (_filter != _Filter.all || _member != null) return const [];
    if (!_onlyRecent) return _files;
    final since = DateTime.now().subtract(const Duration(hours: 24));
    return [for (final f in _files) if (f.arrived.isAfter(since)) f];
  }

  /// Photos / videos and received files, newest first, in one list.
  List<_Cell> _cells(List<MediaItem> items) {
    final out = [
      for (final i in items) _Cell.media(i, _dayOf(i)),
      for (final f in _visibleFiles()) _Cell.file(f),
    ]..sort((a, b) => b.day.compareTo(a.day));
    return out;
  }

  /// Who sent [i]: the family member of its phone, or the phone's name if it
  /// is no longer paired.
  String _memberOf(FamilyDirectory family, MediaItem i) =>
      (i.deviceId == null ? null : family.memberOf(i.deviceId!)) ?? i.deviceName ?? '?';

  bool get _filesTab => _filter == _Filter.docs || _filter == _Filter.other;

  /// Order by when it was taken (default) or when it arrived here.
  bool _byReceived = false;

  /// Only what arrived recently ("Just received"), still ordered by date.
  bool _onlyRecent = false;

  /// Arrivals of the last 24 hours not yet looked at: old photos sent today
  /// sit far down the timeline, so they are offered at the top as well.
  List<MediaItem> _recent(List<MediaItem> all) {
    final since = DateTime.now().subtract(const Duration(hours: 24)).millisecondsSinceEpoch;
    final from = since > widget.services.settings.recentSeenMs ? since : widget.services.settings.recentSeenMs;
    return [for (final i in all) if (i.receivedMs > from) i];
  }

  DateTime _dayOf(MediaItem i) => _byReceived ? DateTime.fromMillisecondsSinceEpoch(i.receivedMs) : i.captureTime;

  List<MediaItem> _visible(List<MediaItem> all, FamilyDirectory family) {
    var list = _filtered(all, family);
    if (_onlyRecent) {
      final since = DateTime.now().subtract(const Duration(hours: 24)).millisecondsSinceEpoch;
      list = [for (final i in list) if (i.receivedMs > since) i];
    }
    if (_byReceived) list.sort((a, b) => b.receivedMs.compareTo(a.receivedMs));
    return list;
  }

  List<MediaItem> _filtered(List<MediaItem> all, FamilyDirectory family) => [
        for (final i in all)
          if ((_filter == _Filter.all ||
                  (_filter == _Filter.photos && i.kind == MediaKind.image) ||
                  (_filter == _Filter.videos && i.kind == MediaKind.video)) &&
              (_showPrivate || !i.private) &&
              (_member == null || FamilyDirectory.keyOf(_memberOf(family, i)) == FamilyDirectory.keyOf(_member!)))
            i,
      ];

  /// Member chips + "show only-me items", shown once there is a family.
  /// "Everyone ▾": whose items to show (one entry per person / phone /
  /// other PC, with how many), and whether to show "only me" items.
  Widget? _personMenu(List<MediaItem> all, FamilyDirectory family) {
    final counts = <String, int>{};
    final pcs = <String>{};
    final st = widget.services.settings;
    for (final i in all) {
      if (i.private && !_showPrivate) continue;
      final m = _memberOf(family, i);
      counts[m] = (counts[m] ?? 0) + 1;
      final t = i.deviceId == null ? null : st.trusted[i.deviceId!];
      if (t != null && isDesktopPlatform(t.platform)) pcs.add(m);
    }
    final members = counts.keys.toList();
    final privateCount = all.where((i) => i.private).length;
    if (members.length < 2 && privateCount == 0) return null;
    return PopupMenuButton<String>(
      tooltip: tr('family.everyone'),
      onSelected: (v) => setState(() {
        if (v == '\u0000private') {
          _showPrivate = !_showPrivate;
        } else if (v.isEmpty) {
          _member = null;
        } else {
          _member = v;
        }
      }),
      itemBuilder: (_) => [
        CheckedPopupMenuItem(value: '', checked: _member == null, child: Text(tr('family.everyone'))),
        for (final m in members)
          CheckedPopupMenuItem(
            value: m,
            checked: _member != null && FamilyDirectory.keyOf(_member!) == FamilyDirectory.keyOf(m),
            child: Row(children: [
              if (pcs.contains(m)) const Padding(padding: EdgeInsets.only(right: 6), child: Icon(Icons.computer_rounded, size: 16)),
              Text('$m · ${counts[m]}'),
            ]),
          ),
        if (privateCount > 0) ...[
          const PopupMenuDivider(),
          CheckedPopupMenuItem(
            value: '\u0000private',
            checked: _showPrivate,
            child: Text(tr('family.show_private', {'count': privateCount})),
          ),
        ],
      ],
      child: _toolChip(Icons.groups_rounded, _member ?? tr('family.everyone')),
    );
  }

  /// A labelled dropdown-looking button for the toolbar.
  Widget _toolChip(IconData icon, String label) => Container(
        height: 36,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(borderRadius: BorderRadius.circular(10), border: Border.all(color: LrColors.line)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 18, color: LrColors.muted),
          const SizedBox(width: 6),
          Text(label, style: const TextStyle(fontSize: 13.5)),
          const Icon(Icons.arrow_drop_down_rounded, color: LrColors.muted),
        ]),
      );

  @override
  Widget build(BuildContext context) {
    final s = widget.services;
    return ListenableBuilder(
      listenable: Listenable.merge([s.library, s.settings]),
      builder: (context, _) {
        final family = s.settings.family;
        final all = s.library.items;
        final items = _visible(all, family);
        // What is no longer shown is no longer selected.
        if (_filesTab) {
          _clearSelection();
        } else if (_selected.isNotEmpty) {
          final shown = {for (final i in items) i.relPath, for (final f in _visibleFiles()) fileKey(f.path)};
          _selected.removeWhere((k) => !shown.contains(k));
        }
        final chosenMedia = _selected.isEmpty ? const <MediaItem>[] : [for (final i in items) if (_selected.contains(i.relPath)) i];
        return Focus(
          focusNode: _focus,
          autofocus: true,
          onKeyEvent: (_, e) => _onKey(e, items),
          child: Scaffold(
          appBar: AppBar(
            title: _selecting
                ? Text(tr('lib.selected_size', {'count': _selected.length + _copies.length, 'size': formatBytes(_selectedSize(chosenMedia))}))
                : Row(children: [
                    Text(tr('nav.library')),
                    const SizedBox(width: 12),
                    Flexible(
                      child: Text(tr('library.hover_hint'),
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(color: LrColors.muted, fontSize: 13, fontWeight: FontWeight.w400)),
                    ),
                    if (!_onlyRecent && _recent(all).isNotEmpty) ...[
                      const SizedBox(width: 12),
                      ActionChip(
                        avatar: const Icon(Icons.fiber_new_rounded, size: 18, color: LrColors.safelight),
                        label: Text(tr('lib.recent_chip', {'count': _recent(all).length})),
                        onPressed: () => setState(() => _onlyRecent = true),
                      ),
                      IconButton(
                        tooltip: tr('lib.recent_dismiss'),
                        iconSize: 16,
                        onPressed: () => s.settings.update((x) => x.recentSeenMs = DateTime.now().millisecondsSinceEpoch),
                        icon: const Icon(Icons.close_rounded),
                      ),
                    ],
                  ]),
            leading: _selecting
                ? IconButton(tooltip: tr('common.cancel'), icon: const Icon(Icons.close), onPressed: () => setState(_clearSelection))
                : null,
            actions: [
              if (_selecting) ...[
                if (chosenMedia.isNotEmpty) ...[
                IconButton(
                  tooltip: tr('lib.export'),
                  icon: const Icon(Icons.drive_file_move_rounded),
                  onPressed: () => _export(chosenMedia),
                ),
                IconButton(
                  tooltip: tr('send.to_pc'),
                  icon: const Icon(Icons.send_rounded),
                  onPressed: () => _sendToPc(chosenMedia),
                ),
                ],
                IconButton(
                  tooltip: '${tr('lib.delete')} (Delete)',
                  icon: const Icon(Icons.delete_outline_rounded),
                  onPressed: () => _deleteSelected(items),
                ),
                if (chosenMedia.isNotEmpty)
                PopupMenuButton<ConvertPreset>(
                  tooltip: tr('convert.selected_tooltip'),
                  icon: const Icon(Icons.auto_fix_high),
                  onSelected: (p) {
                    s.converter.enqueue(chosenMedia, p);
                    setState(_clearSelection);
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text(tr('convert.queued', {'preset': p.label}))),
                    );
                  },
                  itemBuilder: (_) => [
                    for (final p in ConvertPreset.values) PopupMenuItem(value: p, child: Text(tr('convert.to', {'preset': p.label}))),
                  ],
                ),
              ] else ...[
                SegmentedButton<_Filter>(
                  segments: [
                    ButtonSegment(value: _Filter.all, label: Text(tr('library.filter_all'))),
                    ButtonSegment(value: _Filter.photos, label: Text(tr('library.filter_photos'))),
                    ButtonSegment(value: _Filter.videos, label: Text(tr('library.filter_videos'))),
                    ButtonSegment(value: _Filter.docs, label: Text(tr('library.filter_docs'))),
                    ButtonSegment(value: _Filter.other, label: Text(tr('library.filter_other'))),
                  ],
                  selected: {_filter},
                  onSelectionChanged: (v) => setState(() => _filter = v.first),
                ),
                const SizedBox(width: 8),
                // New arrivals from a phone or PC can have old capture dates
                // and land far down the list; "by arrival" puts them on top.
                if (!_filesTab) ?_personMenu(all, family),
                // "Only me" items are hidden here: say so, one click shows them.
                if (!_filesTab && all.any((i) => i.private)) ...[
                  const SizedBox(width: 8),
                  FilterChip(
                    avatar: Icon(_showPrivate ? Icons.lock_open_rounded : Icons.lock_rounded, size: 16),
                    label: Text(tr('family.private_chip', {'count': all.where((i) => i.private).length})),
                    selected: _showPrivate,
                    showCheckmark: false,
                    tooltip: tr('family.private_chip_tip'),
                    onSelected: (v) => setState(() => _showPrivate = v),
                  ),
                ],
                const SizedBox(width: 8),
                PopupMenuButton<bool>(
                  tooltip: tr('library.sort'),
                  initialValue: _byReceived,
                  onSelected: (v) => setState(() => _byReceived = v),
                  itemBuilder: (_) => [
                    CheckedPopupMenuItem(value: false, checked: !_byReceived, child: Text(tr('library.sort_taken'))),
                    CheckedPopupMenuItem(value: true, checked: _byReceived, child: Text(tr('library.sort_received'))),
                  ],
                  child: _toolChip(Icons.sort_rounded, tr(_byReceived ? 'library.sort_received' : 'library.sort_taken')),
                ),
                if (!_filesTab)
                  PopupMenuButton<int>(
                    tooltip: tr('library.size'),
                    initialValue: s.settings.thumbSize,
                    onSelected: (v) => s.settings.update((x) => x.thumbSize = v),
                    itemBuilder: (_) => [
                      for (final (v, k) in [(0, 'library.size_s'), (1, 'library.size_m'), (2, 'library.size_l')])
                        CheckedPopupMenuItem(value: v, checked: s.settings.thumbSize == v, child: Text(tr(k))),
                    ],
                    icon: const Icon(Icons.photo_size_select_large_rounded),
                  ),
                if (!_filesTab)
                  IconButton(
                    tooltip: tr('pick.title'),
                    onPressed: () => _selectBy(all, family),
                    icon: const Icon(Icons.checklist_rounded),
                  ),
                IconButton(
                  tooltip: tr('trash.title'),
                  onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => TrashPage(services: s))),
                  icon: const Icon(Icons.restore_from_trash_rounded),
                ),
                IconButton(
                  tooltip: tr('library.open_folder'),
                  onPressed: () => revealInExplorer(s.library.rootPath),
                  icon: const Icon(Icons.folder_open),
                ),
              ],
              const SizedBox(width: 8),
            ],
          ),
          body: Column(
            children: [
              ..._banners(context),
              Expanded(
                child: _filesTab
                    // Documents / other files from PCs: a file list, not photos.
                    ? FilesView(services: s, document: _filter == _Filter.docs)
                    : items.isEmpty && _visibleFiles().isEmpty
                        ? _empty(context)
                        : _grid(context, items),
              ),
            ],
          ),
          ),
        );
      },
    );
  }

  /// Bytes of what is selected (Live Photo videos included).
  int _selectedSize(List<MediaItem> media) {
    var n = 0;
    for (final i in widget.services.library.withLive(media)) {
      n += i.size;
    }
    for (final f in _files) {
      if (_selected.contains(fileKey(f.path))) n += f.size;
    }
    for (final v in _copies.values) {
      n += v;
    }
    return n;
  }

  KeyEventResult _onKey(KeyEvent e, List<MediaItem> items) {
    if (e is! KeyDownEvent || _filesTab) return KeyEventResult.ignored;
    final ctrl = HardwareKeyboard.instance.isControlPressed;
    if (ctrl && e.logicalKey == LogicalKeyboardKey.keyA) {
      setState(() {
        _selected.addAll(_order);
        if (_order.isNotEmpty) _anchor ??= _order.first;
      });
      return KeyEventResult.handled;
    }
    if (e.logicalKey == LogicalKeyboardKey.escape && _selecting) {
      setState(_clearSelection);
      return KeyEventResult.handled;
    }
    if (e.logicalKey == LogicalKeyboardKey.delete && _selecting) {
      unawaited(_deleteSelected(items));
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  /// Click on a square: Shift = from the last one clicked to here; Ctrl, or
  /// while selecting = this one on / off; otherwise [open] it.
  void _tap(String key, VoidCallback open) {
    _focus.requestFocus();
    final kb = HardwareKeyboard.instance;
    final from = _anchor;
    if (kb.isShiftPressed && from != null) {
      final a = _order.indexOf(from);
      final b = _order.indexOf(key);
      if (a >= 0 && b >= 0) {
        setState(() {
          if (!kb.isControlPressed) _selected.clear();
          _selected.addAll(_order.sublist(min(a, b), max(a, b) + 1));
        });
        return;
      }
    }
    if (kb.isControlPressed || kb.isShiftPressed || _selecting) {
      _toggle(key);
      return;
    }
    open();
  }

  void _toggle(String key) {
    _focus.requestFocus();
    setState(() {
      if (!_selected.remove(key)) _selected.add(key);
      _anchor = key;
    });
  }

  /// Delete what is selected: photos / videos, received files and the
  /// converted copies picked with "Select by…".
  Future<void> _deleteSelected(List<MediaItem> items) async {
    final media = [for (final i in items) if (_selected.contains(i.relPath)) i];
    final files = [
      for (final f in _files)
        if (_selected.contains(fileKey(f.path))) f.path,
      ..._copies.keys,
    ];
    final n = await deleteToTrash(context, widget.services, media: media, files: files);
    if (n == 0 || !mounted) return;
    setState(_clearSelection);
    await _loadFiles();
  }

  /// "Select by…": everything (only-me items when shown), whatever the
  /// filter; the page then shows all so the selection can be seen.
  Future<void> _selectBy(List<MediaItem> all, FamilyDirectory family) async {
    final s = widget.services;
    final cands = <PickCandidate>[
      for (final i in all)
        if (_showPrivate || !i.private)
          PickCandidate(
            key: i.relPath,
            size: s.library.withLive([i]).fold(0, (a, x) => a + x.size),
            taken: i.captureTime,
            received: DateTime.fromMillisecondsSinceEpoch(i.receivedMs),
            type: i.kind == MediaKind.video ? PickType.video : PickType.photo,
            from: _memberOf(family, i),
          ),
      for (final f in _files)
        PickCandidate(
          key: fileKey(f.path),
          size: f.size,
          taken: f.arrived,
          received: f.arrived,
          type: f.document ? PickType.doc : PickType.other,
          from: f.owner == null ? null : (family.memberOf(f.owner!.deviceId) ?? f.owner!.deviceName),
        ),
      ...await _convertedCopies(),
    ];
    if (!mounted) return;
    final picked = await showSelectByDialog(context, cands);
    if (picked == null || !mounted) return;
    setState(() {
      _filter = _Filter.all;
      _member = null;
      _onlyRecent = false;
      _clearSelection();
      for (final c in picked) {
        if (c.type == PickType.copy) {
          _copies[c.key.substring(2)] = c.size;
        } else {
          _selected.add(c.key);
        }
      }
    });
    _focus.requestFocus();
  }

  /// Files in _converted (conversion results; the originals stay).
  Future<List<PickCandidate>> _convertedCopies() async {
    final dir = Directory('${widget.services.library.rootPath}${Platform.pathSeparator}_converted');
    final out = <PickCandidate>[];
    try {
      if (!await dir.exists()) return out;
      await for (final e in dir.list(recursive: true, followLinks: false)) {
        if (e is! File) continue;
        if (e.path.split(Platform.pathSeparator).last.toLowerCase() == 'desktop.ini') continue;
        try {
          final st = await e.stat();
          out.add(PickCandidate(
            key: 'c:${e.path}',
            size: st.size,
            taken: st.modified,
            received: st.modified,
            type: PickType.copy,
          ));
        } catch (_) {}
      }
    } catch (_) {}
    return out;
  }

  /// Library folder unreachable, or many files vanished at once.
  List<Widget> _banners(BuildContext context) {
    final lib = widget.services.library;
    final theme = Theme.of(context);
    Widget banner(IconData icon, Color color, String text, List<Widget> actions) => Container(
          margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: color.withValues(alpha: 0.6)),
          ),
          child: Row(children: [
            Icon(icon, color: color),
            const SizedBox(width: 12),
            Expanded(child: Text(text, style: theme.textTheme.bodyMedium)),
            ...actions,
          ]),
        );
    return [
      if (_onlyRecent)
        banner(Icons.schedule_rounded, LrColors.safelight, tr('lib.recent_only'), [
          TextButton(onPressed: () => setState(() => _onlyRecent = false), child: Text(tr('lib.recent_all'))),
        ]),
      // Unplugged drive / deleted or moved folder: what can be done.
      if (lib.offline) LibraryRecovery(services: widget.services),
      // Converted copies picked with "Select by…" are not in the grid.
      if (_copies.isNotEmpty)
        banner(Icons.auto_fix_high_rounded, LrColors.safelight,
            tr('lib.copies_selected', {'count': _copies.length, 'size': formatBytes(_copies.values.fold(0, (a, b) => a + b))}), [
          TextButton(onPressed: () => setState(_copies.clear), child: Text(tr('lib.copies_drop'))),
        ]),
      if (!lib.offline && lib.pendingMissing.isNotEmpty)
        banner(Icons.help_outline_rounded, Colors.amber, tr('lib.missing_ask', {'count': lib.pendingMissing.length}), [
          TextButton(onPressed: lib.retry, child: Text(tr('lib.missing_rescan'))),
          const SizedBox(width: 4),
          FilledButton(onPressed: lib.confirmMissing, child: Text(tr('lib.missing_confirm'))),
        ]),
    ];
  }

  /// Delete = into "Recently deleted" (30 days, with Undo). Phones are
  /// told next time.
  Future<void> _delete(List<MediaItem> items) async {
    final n = await deleteToTrash(context, widget.services, media: items);
    if (n > 0 && mounted) setState(_clearSelection);
  }

  /// Send originals (with their Live Photo videos) to another PC's library.
  Future<void> _sendToPc(List<MediaItem> items) async {
    if (items.isEmpty) return;
    final lib = widget.services.library;
    final files = [for (final i in lib.withLive(items)) ?SendFile.fromLibrary(lib, i)];
    if (files.isEmpty) return;
    setState(_clearSelection);
    await sendToPc(context, widget.services, files,
        items.length == 1 ? items.first.name : tr('send.n_items', {'count': items.length}));
  }

  /// Copy the originals into a folder of your choice.
  Future<void> _export(List<MediaItem> items) async {
    if (items.isEmpty) return;
    final folder = await WinDialogs.pickFolder(title: tr('lib.export'));
    if (folder == null) return;
    final n = await exportItems(widget.services.library, items, folder);
    if (!mounted) return;
    setState(_clearSelection);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(tr('lib.exported', {'count': n})),
      action: SnackBarAction(label: tr('common.open'), onPressed: () => revealInExplorer(folder)),
    ));
  }

  /// Right-click menu: acts on the selection if the item is part of it.
  Future<void> _contextMenu(BuildContext context, List<MediaItem> items, int index, Offset at) async {
    final item = items[index];
    final targets = _selected.contains(item.relPath)
        ? items.where((i) => _selected.contains(i.relPath)).toList()
        : [item];
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final choice = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(at & const Size(1, 1), Offset.zero & overlay.size),
      items: [
        if (targets.length == 1) PopupMenuItem(value: 'open', child: _menuRow(Icons.open_in_full_rounded, tr('lib.open'))),
        PopupMenuItem(
          value: 'select',
          child: _menuRow(Icons.check_circle_outline_rounded,
              _selected.contains(item.relPath) ? tr('lib.unselect') : tr('lib.select')),
        ),
        const PopupMenuDivider(),
        for (final p in ConvertPreset.values)
          PopupMenuItem(value: 'convert:${p.name}', child: _menuRow(Icons.auto_fix_high_rounded, tr('convert.to', {'preset': p.label}))),
        PopupMenuItem(value: 'export', child: _menuRow(Icons.drive_file_move_rounded, tr('lib.export'))),
        PopupMenuItem(value: 'send', child: _menuRow(Icons.send_rounded, tr('send.to_pc'))),
        if (targets.length == 1)
          PopupMenuItem(value: 'reveal', child: _menuRow(Icons.folder_open_rounded, tr('common.show_in_folder'))),
        // Family group: who may see it.
        if (targets.any((i) => !i.private))
          PopupMenuItem(value: 'private', child: _menuRow(Icons.lock_rounded, tr('family.make_private'))),
        if (targets.any((i) => i.private))
          PopupMenuItem(value: 'shared', child: _menuRow(Icons.groups_rounded, tr('family.make_shared'))),
        const PopupMenuDivider(),
        PopupMenuItem(
          value: 'delete',
          child: _menuRow(Icons.delete_outline_rounded,
              targets.length == 1 ? tr('lib.delete') : tr('lib.delete_n', {'count': targets.length}),
              danger: true),
        ),
      ],
    );
    if (!mounted || choice == null) return;
    final s = widget.services;
    switch (choice) {
      case 'open':
        await Navigator.of(this.context).push(MaterialPageRoute(
          builder: (_) => ViewerPage(services: s, items: items, initialIndex: index),
        ));
      case 'select':
        _toggle(item.relPath);
      case 'export':
        await _export(targets);
      case 'send':
        await _sendToPc(targets);
      case 'reveal':
        revealInExplorer(s.library.absPath(item));
      case 'private' || 'shared':
        final private = choice == 'private';
        final was = {for (final i in targets) i: i.private};
        s.library.setPrivate(targets, private);
        setState(_clearSelection);
        // Hidden here at once: say where they went, and offer to undo.
        ScaffoldMessenger.of(this.context)
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(
            duration: const Duration(seconds: 8),
            content: Text(tr(private && !_showPrivate ? 'family.made_private_hidden' : (private ? 'family.made_private' : 'family.made_shared'),
                {'count': targets.length})),
            action: SnackBarAction(
              label: tr('trash.undo'),
              onPressed: () {
                for (final e in was.entries) {
                  s.library.setPrivate([e.key], e.value);
                }
              },
            ),
          ));
      case 'delete':
        await _delete(targets);
      default:
        if (choice.startsWith('convert:')) {
          final p = ConvertPreset.values.firstWhere((x) => 'convert:${x.name}' == choice);
          s.converter.enqueue(targets, p);
          setState(_clearSelection);
          ScaffoldMessenger.of(this.context).showSnackBar(
            SnackBar(content: Text(tr('convert.queued', {'preset': p.label}))),
          );
        }
    }
  }

  Widget _menuRow(IconData icon, String text, {bool danger = false}) {
    final color = danger ? Theme.of(context).colorScheme.error : null;
    return Row(children: [
      Icon(icon, size: 18, color: color),
      const SizedBox(width: 12),
      Text(text, style: TextStyle(color: color)),
    ]);
  }

  Widget _empty(BuildContext context) => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.photo_library_outlined, size: 64, color: Theme.of(context).colorScheme.outline),
            const SizedBox(height: 12),
            Text(tr('library.empty')),
            const SizedBox(height: 4),
            Text(tr('library.empty_hint'), textAlign: TextAlign.center),
          ],
        ),
      );

  Widget _grid(BuildContext context, List<MediaItem> items) {
    // Group into days; photos / videos keep their index in [items] for the
    // viewer (it pages through photos and videos only).
    final cells = _cells(items);
    _order = [for (final c in cells) c.key];
    final indexOf = {for (var k = 0; k < items.length; k++) items[k].relPath: k};
    final slivers = <Widget>[];
    var start = 0;
    while (start < cells.length) {
      final t = cells[start].day;
      var end = start;
      while (end < cells.length && cells[end].day.year == t.year && cells[end].day.month == t.month && cells[end].day.day == t.day) {
        end++;
      }
      final day = cells.sublist(start, end);
      final photos = day.where((c) => c.media?.kind == MediaKind.image).length;
      final videos = day.where((c) => c.media?.kind == MediaKind.video).length;
      final files = day.where((c) => c.file != null).length;
      final keys = [for (final c in day) c.key];
      final whole = keys.every(_selected.contains);
      final theme = Theme.of(context);
      slivers
        ..add(SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 20, 16, 6),
            child: Row(
              children: [
                // The whole day on / off.
                IconButton(
                  tooltip: tr(whole ? 'lib.unselect_day' : 'lib.select_day'),
                  iconSize: 20,
                  visualDensity: VisualDensity.compact,
                  onPressed: () {
                    _focus.requestFocus();
                    setState(() {
                      if (whole) {
                        _selected.removeAll(keys);
                      } else {
                        _selected.addAll(keys);
                        _anchor = keys.last;
                      }
                    });
                  },
                  icon: Icon(
                    whole ? Icons.check_circle_rounded : Icons.check_circle_outline_rounded,
                    color: whole ? theme.colorScheme.primary : LrColors.muted,
                  ),
                ),
                const SizedBox(width: 4),
                Text(formatDayFull(t), style: theme.textTheme.titleMedium),
                const SizedBox(width: 12),
                Text(
                  [
                    if (photos > 0) tr('library.n_photos', {'count': photos}),
                    if (videos > 0) tr('library.n_videos', {'count': videos}),
                    if (files > 0) tr('library.n_files', {'count': files}),
                  ].join('   '),
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
          ),
        ))
        ..add(SliverPadding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          sliver: SliverGrid.builder(
            gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: const [120.0, 180.0, 260.0][widget.services.settings.thumbSize],
              mainAxisSpacing: 4,
              crossAxisSpacing: 4,
            ),
            itemCount: day.length,
            itemBuilder: (context, i) {
              final c = day[i];
              final m = c.media;
              return _Box(
                key: ValueKey(c.key),
                id: c.key,
                boxes: _boxes,
                child: m != null ? _cell(context, items, indexOf[m.relPath]!) : _fileCell(context, c.file!),
              );
            },
          ),
        ));
      start = end;
    }
    slivers.add(const SliverToBoxAdapter(child: SizedBox(height: 24)));
    // Drag with the mouse to select with a box (Ctrl: add to what is
    // selected).
    return Listener(
      onPointerDown: _boxDown,
      onPointerMove: _boxMove,
      onPointerUp: (_) => _boxEnd(),
      onPointerCancel: (_) => _boxEnd(),
      child: Stack(key: _gridKey, children: [
        CustomScrollView(controller: _scroll, slivers: slivers),
        if (_boxing && _dragNow != null && _downAt != null)
          Positioned.fill(
            child: IgnorePointer(
              child: CustomPaint(painter: _BoxPainter(_boxRectLocal(), Theme.of(context).colorScheme.primary)),
            ),
          ),
      ]),
    );
  }

  // ------------------------------------------------------- box select

  RenderBox? get _gridBox => _gridKey.currentContext?.findRenderObject() as RenderBox?;

  void _boxDown(PointerDownEvent e) {
    if (e.kind != PointerDeviceKind.mouse || e.buttons != kPrimaryMouseButton) return;
    final g = _gridBox;
    // Not on the scrollbar.
    if (g != null && g.globalToLocal(e.position).dx > g.size.width - 18) return;
    _downAt = e.position;
    _downOffset = _scroll.hasClients ? _scroll.offset : 0;
  }

  void _boxMove(PointerMoveEvent e) {
    final down = _downAt;
    if (down == null) return;
    if (!_boxing) {
      if ((e.position - down).distance < 20) return;
      _boxing = true;
      _focus.requestFocus();
      _boxBase = HardwareKeyboard.instance.isControlPressed ? {..._selected} : {};
      _boxHits.clear();
    }
    _dragNow = e.position;
    _updateBox();
    _autoScrollIfNearEdge();
  }

  void _boxEnd() {
    _downAt = null;
    _autoScroll?.cancel();
    _autoScroll = null;
    if (_boxing) setState(() => _boxing = false);
  }

  /// The box in screen coordinates (its start moves with the scrolling).
  Rect _boxRectGlobal() {
    final scrolled = (_scroll.hasClients ? _scroll.offset : 0) - _downOffset;
    final start = _downAt! - Offset(0, scrolled);
    return Rect.fromPoints(start, _dragNow!);
  }

  Rect _boxRectLocal() {
    final g = _gridBox;
    final r = _boxRectGlobal();
    if (g == null) return r;
    return Rect.fromPoints(g.globalToLocal(r.topLeft), g.globalToLocal(r.bottomRight));
  }

  void _updateBox() {
    final rect = _boxRectGlobal();
    // Squares on screen: in the box or not. Those scrolled away keep what
    // they were.
    for (final e in _boxes.entries) {
      final rb = e.value.findRenderObject();
      if (rb is! RenderBox || !rb.attached || !rb.hasSize) continue;
      final r = rb.localToGlobal(Offset.zero) & rb.size;
      if (r.overlaps(rect)) {
        _boxHits.add(e.key);
      } else {
        _boxHits.remove(e.key);
      }
    }
    setState(() {
      _selected
        ..clear()
        ..addAll(_boxBase)
        ..addAll(_boxHits);
      if (_boxHits.isNotEmpty) _anchor ??= _boxHits.first;
    });
  }

  /// Near the top or bottom edge while dragging: scroll on.
  void _autoScrollIfNearEdge() {
    final g = _gridBox;
    final at = _dragNow;
    if (g == null || at == null || !_scroll.hasClients) return;
    final y = g.globalToLocal(at).dy;
    const edge = 48.0;
    final speed = y < edge ? -(edge - y) : (y > g.size.height - edge ? y - (g.size.height - edge) : 0.0);
    if (speed == 0) {
      _autoScroll?.cancel();
      _autoScroll = null;
      return;
    }
    _autoScroll ??= Timer.periodic(const Duration(milliseconds: 16), (_) {
      if (!_boxing || !_scroll.hasClients || _dragNow == null) return;
      final y2 = g.globalToLocal(_dragNow!).dy;
      final v = y2 < edge ? -(edge - y2) : (y2 > g.size.height - edge ? y2 - (g.size.height - edge) : 0.0);
      if (v == 0) return;
      final p = _scroll.position;
      final to = (p.pixels + v * 0.5).clamp(p.minScrollExtent, p.maxScrollExtent);
      if (to == p.pixels) return;
      _scroll.jumpTo(to);
      _updateBox();
    });
  }

  // ------------------------------------------------------- squares

  /// The round "select" button at the top left: on hover, or always once
  /// selecting; ticked when selected.
  Widget _selectButton(String key, bool selected) => Positioned(
        left: 4,
        top: 4,
        child: ValueListenableBuilder<String?>(
          valueListenable: _hovered,
          builder: (context, hover, _) {
            if (!selected && hover != key && !_selecting) return const SizedBox.shrink();
            return GestureDetector(
              onTap: () => _toggle(key),
              child: Container(
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  boxShadow: [BoxShadow(color: Colors.black45, blurRadius: 4)],
                ),
                child: Icon(
                  selected ? Icons.check_circle : Icons.radio_button_unchecked_rounded,
                  size: 22,
                  color: selected ? Theme.of(context).colorScheme.primary : Colors.white,
                ),
              ),
            );
          },
        ),
      );

  Widget _hover(String key, Widget child) => MouseRegion(
        onEnter: (_) => _hovered.value = key,
        onExit: (_) {
          if (_hovered.value == key) _hovered.value = null;
        },
        child: child,
      );

  Widget _selectedFrame(BuildContext context) => IgnorePointer(
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(4),
            border: Border.all(color: Theme.of(context).colorScheme.primary, width: 3),
            color: Colors.black26,
          ),
        ),
      );

  /// A received file on the timeline: its first page and name; opens the
  /// way it does under Documents / Other.
  Widget _fileCell(BuildContext context, ReceivedFile f) {
    final s = widget.services;
    final key = fileKey(f.path);
    final selected = _selected.contains(key);
    return _hover(
      key,
      Tooltip(
        message: f.name,
        waitDuration: const Duration(milliseconds: 600),
        child: GestureDetector(
          onTap: () => _tap(key, () => openReceivedFile(context, s, f.path)),
          onLongPress: () => _toggle(key),
          onSecondaryTapUp: (d) => _fileMenu(context, f, d.globalPosition),
          child: Stack(fit: StackFit.expand, children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: FileThumb(
                key: ValueKey(f.path),
                path: f.path,
                size: f.size,
                modified: f.modified,
                services: s,
                icon: Container(
                  color: LrColors.raised,
                  alignment: Alignment.center,
                  child: Icon(_iconFor(f.name), size: 40, color: LrColors.muted),
                ),
              ),
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: Container(
                decoration: const BoxDecoration(
                  color: Colors.black54,
                  borderRadius: BorderRadius.vertical(bottom: Radius.circular(4)),
                ),
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                child: Row(children: [
                  Icon(_iconFor(f.name), size: 13, color: Colors.white),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(f.name,
                        maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11, color: Colors.white)),
                  ),
                ]),
              ),
            ),
            if (selected) _selectedFrame(context),
            _selectButton(key, selected),
          ]),
        ),
      ),
    );
  }

  static IconData _iconFor(String name) {
    final ext = extensionOf(name);
    if (ext == 'pdf') return Icons.picture_as_pdf_rounded;
    if (const {'doc', 'docx', 'odt', 'rtf', 'pages', 'wps', 'txt', 'md'}.contains(ext)) return Icons.description_rounded;
    if (const {'xls', 'xlsx', 'ods', 'csv', 'numbers', 'et'}.contains(ext)) return Icons.table_chart_rounded;
    if (const {'ppt', 'pptx', 'odp', 'key', 'dps'}.contains(ext)) return Icons.slideshow_rounded;
    if (const {'zip', 'rar', '7z', 'tar', 'gz'}.contains(ext)) return Icons.folder_zip_rounded;
    if (const {'mp3', 'm4a', 'wav', 'flac', 'aac', 'ogg'}.contains(ext)) return Icons.audio_file_rounded;
    if (MediaKind.fromName(name) == MediaKind.image) return Icons.image_rounded;
    if (MediaKind.fromName(name) == MediaKind.video) return Icons.movie_rounded;
    return Icons.insert_drive_file_rounded;
  }

  /// Right-click on a received file: open, select, show in its folder,
  /// delete.
  Future<void> _fileMenu(BuildContext context, ReceivedFile f, Offset at) async {
    final key = fileKey(f.path);
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final choice = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(at & const Size(1, 1), Offset.zero & overlay.size),
      items: [
        PopupMenuItem(value: 'open', child: _menuRow(Icons.open_in_full_rounded, tr('lib.open'))),
        PopupMenuItem(
          value: 'select',
          child: _menuRow(Icons.check_circle_outline_rounded, _selected.contains(key) ? tr('lib.unselect') : tr('lib.select')),
        ),
        PopupMenuItem(value: 'rename', child: _menuRow(Icons.drive_file_rename_outline_rounded, tr('files.rename'))),
        PopupMenuItem(value: 'reveal', child: _menuRow(Icons.folder_open_rounded, tr('common.show_in_folder'))),
        const PopupMenuDivider(),
        PopupMenuItem(value: 'delete', child: _menuRow(Icons.delete_outline_rounded, tr('lib.delete'), danger: true)),
      ],
    );
    if (!mounted || choice == null) return;
    switch (choice) {
      case 'open':
        await openReceivedFile(this.context, widget.services, f.path);
      case 'rename':
        if (await renameReceivedFile(this.context, widget.services, f.path) != null && mounted) {
          setState(() => _selected.remove(key));
          await _loadFiles();
        }
      case 'select':
        _toggle(key);
      case 'reveal':
        revealInExplorer(f.path);
      case 'delete':
        final n = await deleteToTrash(this.context, widget.services, files: [f.path]);
        if (n > 0 && mounted) {
          setState(() => _selected.remove(key));
          await _loadFiles();
        }
    }
  }

  Widget _cell(BuildContext context, List<MediaItem> items, int index) {
    final s = widget.services;
    final item = items[index];
    final key = item.relPath;
    final selected = _selected.contains(key);
    return _hover(
      key,
      GestureDetector(
        onTap: () => _tap(
          key,
          () => Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => ViewerPage(services: s, items: items, initialIndex: index),
          )),
        ),
        onLongPress: () => _toggle(key),
        onSecondaryTapUp: (d) => _contextMenu(context, items, index, d.globalPosition),
        child: Stack(
          fit: StackFit.expand,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: MediaThumb(
                key: ValueKey(item.relPath),
                item: item,
                library: s.library,
                ffmpeg: s.ffmpeg,
              ),
            ),
            if (item.private)
              const Positioned(
                right: 4,
                top: 4,
                child: Icon(Icons.lock_rounded, size: 16, color: Colors.white, shadows: [Shadow(color: Colors.black54, blurRadius: 4)]),
              ),
            if (selected) _selectedFrame(context),
            _selectButton(key, selected),
          ],
        ),
      ),
    );
  }
}

/// Keeps track of a square while it is on screen (for selecting with a box).
class _Box extends StatefulWidget {
  const _Box({super.key, required this.id, required this.boxes, required this.child});

  final String id;
  final Map<String, BuildContext> boxes;
  final Widget child;

  @override
  State<_Box> createState() => _BoxState();
}

class _BoxState extends State<_Box> {
  @override
  void initState() {
    super.initState();
    widget.boxes[widget.id] = context;
  }

  @override
  void didUpdateWidget(_Box old) {
    super.didUpdateWidget(old);
    if (old.id != widget.id) {
      if (old.boxes[old.id] == context) old.boxes.remove(old.id);
      widget.boxes[widget.id] = context;
    }
  }

  @override
  void dispose() {
    if (widget.boxes[widget.id] == context) widget.boxes.remove(widget.id);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// The selection box.
class _BoxPainter extends CustomPainter {
  _BoxPainter(this.rect, this.color);

  final Rect rect;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    canvas
      ..drawRect(rect, Paint()..color = color.withValues(alpha: 0.15))
      ..drawRect(
        rect,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5,
      );
  }

  @override
  bool shouldRepaint(_BoxPainter old) => old.rect != rect || old.color != color;
}
