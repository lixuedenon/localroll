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
import '../services/file_actions.dart';
import '../services/library_index.dart';
import '../services/network.dart';
import '../services/peers.dart';
import '../services/picture_model.dart';
import '../services/received_files.dart';
import '../services/smart_query.dart';
import '../services/text_index.dart';
import '../services/text_indexer.dart';
import '../services/win_dialogs.dart';
import 'app_nav.dart';
import 'convert_dialog.dart';
import 'files_view.dart';
import 'format.dart';
import 'hover_tip.dart';
import 'library_recovery.dart';
import 'library_tools.dart';
import 'light_look.dart';
import 'media_thumb.dart';
import 'people_page.dart';
import 'select_by_dialog.dart';
import 'send_page.dart';
import 'trash_actions.dart';
import 'tools/tools.dart';
import 'trash_page.dart';
import 'player/player_page.dart';

enum _Filter { all, photos, videos, made, docs, other }

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

  // Compact layout: the squares in order, where each day / month / year
  // starts, and the grid's geometry (for the date at the top and the date
  // beside the scrollbar).
  List<_Cell> _flat = const [];
  List<int> _starts = const [];
  List<int> _groupOf = const [];
  int _cols = 1;
  double _rowH = 1;
  static const double _gridTop = 8;
  int _zoomShown = 0;

  /// First square in the top row (-1: at the top, no date bar).
  final ValueNotifier<int> _topIndex = ValueNotifier(-1);

  /// Scrolling now: show the date beside the scrollbar.
  final ValueNotifier<bool> _scrollTip = ValueNotifier(false);
  Timer? _tipTimer;

  /// Ctrl is down: the wheel changes the zoom instead of scrolling.
  bool _ctrl = false;
  DateTime _lastZoom = DateTime(0);

  /// Search box: words found in photos / files (and their names).
  final TextEditingController _searchCtrl = TextEditingController();
  SearchQuery _search = SearchQuery('');

  /// A search naming people ("Mum beach"): their photos (the rest of the
  /// words search as usual). Null: no name in it.
  Set<String>? _who;

  /// Showing one person's photos (from the People page).
  int? _person;
  Set<String> _personItems = const {};

  bool get _searching => _searchCtrl.text.trim().isNotEmpty;

  /// In the person / named people being shown (always true when none).
  bool _keepKey(String key) => (_person == null || _personItems.contains(key)) && (_who == null || _who!.contains(key));

  /// The search said in ordinary words: when / what taken out.
  SmartQuery _smart = const SmartQuery(rest: '');

  /// A smart album chosen (screenshots, receipts…): what it looks like.
  _Category? _cat;

  void _onSearch(String v) {
    final s = widget.services;
    unawaited(s.server.textIndex.load());
    setState(() {
      _cat = null;
      _smart = SmartQuery.parse(v);
      var words = _smart.rest;
      _who = null;
      if (s.settings.faces) {
        final split = s.server.people.split(v);
        if (split != null) {
          _who = split.$1;
          words = split.$2;
        }
      }
      _search = SearchQuery(words);
      _findPictures(words);
      // Results come from everything: photos, videos and files.
      if (_searching && _filesTab) _filter = _Filter.all;
      _clearSelection();
    });
  }

  /// A smart album: found by what the photo looks like (and its words /
  /// name), on this PC.
  void _openCategory(_Category c) {
    _searchCtrl.text = tr(c.label);
    setState(() {
      _smart = const SmartQuery(rest: '');
      _search = SearchQuery('');
      _who = null;
      _cat = c;
      _findPictures(c.looks);
      _filter = _Filter.all;
      _clearSelection();
    });
  }

  /// Search by picture: items that look like the words (key → how alike).
  Map<String, double> _picHits = const {};
  Timer? _picSoon;
  String _picQuery = '';

  void _findPictures(String q) {
    _picSoon?.cancel();
    _picQuery = q;
    final ix = widget.services.pictureIndexer;
    if (q.trim().isEmpty || !ix.ready) {
      _picHits = const {};
      return;
    }
    _picSoon = Timer(const Duration(milliseconds: 400), () async {
      final hits = await ix.find(q);
      if (!mounted || _picQuery != q) return;
      setState(() => _picHits = {for (final (k, sc) in hits) k: sc});
    });
  }

  String _searchKey(_Cell c) {
    final m = c.media;
    if (m != null) return TextIndex.mediaKey(m);
    final f = c.file!;
    return TextIndex.fileKey(widget.services.server.files.relOf(f.path) ?? f.path, f.size);
  }

  /// Found only because it looks like the words (not by its text / name).
  bool _onlyPicture(_Cell c) {
    final name = c.media?.name ?? c.file!.name;
    return !widget.services.server.textIndex.matches(_searchKey(c), name, _search);
  }

  void _clearSearch() {
    _searchCtrl.clear();
    _onSearch('');
  }

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
    AppNav.instance.libraryRecent.addListener(_showRecent);
    if (AppNav.instance.takeLibraryRecent()) _byReceived = true;
    final asked = AppNav.instance.libraryMember.value;
    if (asked != null) {
      _member = asked;
      AppNav.instance.libraryMember.value = null;
    }
    AppNav.instance.libraryMember.addListener(_showMember);
    unawaited(widget.services.server.people.load());
    unawaited(_loadFiles());
    unawaited(_watchFiles());
    _scroll.addListener(_onScroll);
    HardwareKeyboard.instance.addHandler(_onCtrlKey);
  }

  @override
  void dispose() {
    widget.services.hub.removeListener(_onHub);
    widget.services.server.files.changes.removeListener(_reloadFilesSoon);
    AppNav.instance.libraryRecent.removeListener(_showRecent);
    AppNav.instance.libraryMember.removeListener(_showMember);
    for (final w in _watches) {
      unawaited(w.cancel());
    }
    _filesSoon?.cancel();
    _autoScroll?.cancel();
    _tipTimer?.cancel();
    HardwareKeyboard.instance.removeHandler(_onCtrlKey);
    _topIndex.dispose();
    _scrollTip.dispose();
    _focus.dispose();
    _scroll.dispose();
    _searchCtrl.dispose();
    _picSoon?.cancel();
    _hovered.dispose();
    super.dispose();
  }

  /// "Their photos" on Devices: one person's / device's photos.
  void _showMember() {
    final m = AppNav.instance.libraryMember.value;
    if (!mounted || m == null) return;
    AppNav.instance.libraryMember.value = null;
    setState(() {
      _filter = _Filter.all;
      _member = m;
      _clearSelection();
    });
    if (_scroll.hasClients) _scroll.jumpTo(0);
  }

  /// "See all" on Home: everything, newest arrival first, from the top.
  void _showRecent() {
    if (!mounted || !AppNav.instance.takeLibraryRecent()) return;
    setState(() {
      _filter = _Filter.all;
      _member = null;
      _onlyRecent = false;
      _byReceived = true;
      _clearSelection();
    });
    if (_scroll.hasClients) _scroll.jumpTo(0);
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
    // A smart album, or photos / videos asked for: no files.
    if (_cat != null || _smart.kind != null) return const [];
    var list = _files;
    if (_onlyRecent) {
      final since = DateTime.now().subtract(const Duration(hours: 24));
      list = [for (final f in list) if (f.arrived.isAfter(since)) f];
    }
    if (_smart.hasWhen) list = [for (final f in list) if (_smart.contains(f.arrived)) f];
    if (!_search.isEmpty) {
      final idx = widget.services.server.textIndex;
      final files = widget.services.server.files;
      list = [
        for (final f in list)
          if (idx.matches(TextIndex.fileKey(files.relOf(f.path) ?? f.path, f.size), f.name, _search) ||
              _picHits.containsKey(TextIndex.fileKey(files.relOf(f.path) ?? f.path, f.size)))
            f,
      ];
    }
    if (_person != null || _who != null) {
      final files = widget.services.server.files;
      list = [for (final f in list) if (_keepKey(TextIndex.fileKey(files.relOf(f.path) ?? f.path, f.size))) f];
    }
    return list;
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

  /// The disk the library is on (the storage card).
  ({int free, int total})? _disk;
  String? _diskOf;

  void _checkDisk(String root) {
    if (_diskOf == root) return;
    _diskOf = root;
    unawaited(diskSpace(root).then((d) {
      if (mounted) setState(() => _disk = d);
    }));
  }

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
    if (_smart.hasWhen || _smart.kind != null) {
      list = [
        for (final i in list)
          if ((_smart.kind == null || i.kind == _smart.kind) &&
              (!_smart.hasWhen || _smart.contains(DateTime.fromMillisecondsSinceEpoch(i.captureMs > 0 ? i.captureMs : i.receivedMs))))
            i,
      ];
    }
    final cat = _cat;
    if (cat != null) {
      final idx = widget.services.server.textIndex;
      list = [
        for (final i in list)
          if (i.kind == MediaKind.image &&
              (_picHits.containsKey(TextIndex.mediaKey(i)) ||
                  cat.names.any((w) => i.name.toLowerCase().contains(w)) ||
                  cat.words.any((w) => idx.matches(TextIndex.mediaKey(i), i.name, SearchQuery(w)))))
            i,
      ];
    }
    if (!_search.isEmpty) {
      final idx = widget.services.server.textIndex;
      list = [
        for (final i in list)
          if (idx.matches(TextIndex.mediaKey(i), i.name, _search) || _picHits.containsKey(TextIndex.mediaKey(i))) i,
      ];
    }
    if (_person != null || _who != null) list = [for (final i in list) if (_keepKey(TextIndex.mediaKey(i))) i];
    if (_byReceived) list.sort((a, b) => b.receivedMs.compareTo(a.receivedMs));
    return list;
  }

  /// In LocalRoll's recordings folder.
  bool _made(MediaItem i) {
    final top = i.relPath.contains('/') ? i.relPath.substring(0, i.relPath.indexOf('/')) : '';
    return top.isNotEmpty && top.toLowerCase() == widget.services.recordings.folderName.toLowerCase();
  }

  List<MediaItem> _filtered(List<MediaItem> all, FamilyDirectory family) => [
        for (final i in all)
          if ((_filter == _Filter.all ||
                  (_filter == _Filter.photos && i.kind == MediaKind.image) ||
                  (_filter == _Filter.videos && i.kind == MediaKind.video) ||
                  (_filter == _Filter.made && _made(i))) &&
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
      final m = _memberOf(family, i);
      counts[m] = (counts[m] ?? 0) + 1;
      final t = i.deviceId == null ? null : st.trusted[i.deviceId!];
      if (t != null && isDesktopPlatform(t.platform)) pcs.add(m);
    }
    final members = counts.keys.toList();
    if (members.length < 2) return null;
    return HoverTip(
      text: tr('lib.senders_tip_long'),
      child: PopupMenuButton<String>(
      tooltip: '',
      onSelected: (v) => setState(() {
        if (v.isEmpty) {
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
              Text('${senderLabel(m)} · ${counts[m]}'),
            ]),
          ),
      ],
      child: ToolIcon(icon: Icons.groups_rounded, color: ToolColors.senders, label: _member == null ? null : senderLabel(_member!)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.services;
    return ListenableBuilder(
      listenable: Listenable.merge([s.library, s.settings, s.server.textIndex, s.pictureModel, s.server.people]),
      builder: (context, _) {
        final family = s.settings.family;
        // The person shown was merged away / People switched off.
        if (_person != null && (!s.settings.faces || s.server.people.person(_person!) == null)) _person = null;
        _personItems = _person == null ? const {} : s.server.people.itemsOf(_person!);
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
        _checkDisk(s.library.rootPath);
        final bar = AppBar(
            automaticallyImplyLeading: false,
            primary: false,
            toolbarHeight: 58,
            backgroundColor: Colors.transparent,
            surfaceTintColor: Colors.transparent,
            elevation: 0,
            scrolledUnderElevation: 0,
            titleSpacing: 12,
            title: _selecting
                ? Text(tr('lib.selected_size', {'count': _selected.length + _copies.length, 'size': formatBytes(_selectedSize(chosenMedia))}))
                : Row(children: [
                    _filters(all),
                    if (!_onlyRecent && _recent(all).isNotEmpty) ...[
                      const SizedBox(width: 8),
                      ActionChip(
                        avatar: const Icon(Icons.fiber_new_rounded, size: 18, color: LightLook.amberText),
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
                // Photos / videos and files alike.
                IconButton(
                  tooltip: tr('aipack.title'),
                  icon: const Icon(Icons.smart_toy_outlined),
                  onPressed: () => unawaited(packForAi(context, s, chosenMedia, _chosenFiles())),
                ),
                IconButton(
                  tooltip: tr('lib.export'),
                  icon: const Icon(Icons.drive_file_move_rounded),
                  onPressed: () => _export(chosenMedia, _chosenFiles()),
                ),
                IconButton(
                  tooltip: tr('send.to_pc'),
                  icon: const Icon(Icons.send_rounded),
                  onPressed: () => _sendToPc(chosenMedia, _chosenFiles()),
                ),
                if (_person != null)
                  IconButton(
                    tooltip: tr('people.not_this'),
                    icon: const Icon(Icons.person_remove_rounded),
                    onPressed: () => _notThisPerson(items),
                  ),
                IconButton(
                  tooltip: '${tr('lib.delete')} (Delete)',
                  icon: const Icon(Icons.delete_outline_rounded),
                  onPressed: () => _deleteSelected(items),
                ),
                if (chosenMedia.isNotEmpty)
                IconButton(
                  tooltip: tr('convert.selected_tooltip'),
                  icon: const Icon(Icons.auto_fix_high),
                  onPressed: () async {
                    // Documents and other files have nothing to convert.
                    final skipped = _files.where((f) => _selected.contains(fileKey(f.path))).length;
                    final video = chosenMedia.every((i) => i.kind == MediaKind.video);
                    final ok = await convertWithDialog(context, s, items: chosenMedia, video: video);
                    if (!ok || !mounted) return;
                    setState(_clearSelection);
                    if (skipped > 0) {
                      ScaffoldMessenger.of(this.context).showSnackBar(SnackBar(content: Text(tr('convert.skipped_files', {'count': skipped}))));
                    }
                  },
                ),
              ] else ...[
                _searchBox(),
                PopupMenuButton<_Category>(
                  tooltip: tr('smart.title'),
                  onSelected: _openCategory,
                  itemBuilder: (_) => [for (final c in _categories) PopupMenuItem(value: c, child: Row(children: [Icon(c.icon, size: 18), const SizedBox(width: 10), Text(tr(c.label))]))],
                  icon: const Icon(Icons.auto_awesome_rounded, color: ToolColors.people),
                ),
                if (!_filesTab)
                  HoverTip(
                    text: tr('clean.tip'),
                    child: IconButton(
                      onPressed: () => unawaited(showCleanup(context, s)),
                      icon: const Icon(Icons.cleaning_services_rounded, color: ToolColors.trash),
                    ),
                  ),
                const SizedBox(width: 8),
                // New arrivals from a phone or PC can have old capture dates
                // and land far down the list; "by arrival" puts them on top.
                if (!_filesTab) ?_personMenu(all, family),
                const SizedBox(width: 8),
                HoverTip(
                  text: tr('library.sort_tip'),
                  child: PopupMenuButton<bool>(
                    tooltip: '',
                    initialValue: _byReceived,
                    onSelected: (v) => setState(() => _byReceived = v),
                    itemBuilder: (_) => [
                      CheckedPopupMenuItem(value: false, checked: !_byReceived, child: Text(tr('library.sort_taken'))),
                      CheckedPopupMenuItem(value: true, checked: _byReceived, child: Text(tr('library.sort_received'))),
                    ],
                    child: ToolIcon(
                      icon: Icons.swap_vert_rounded,
                      color: ToolColors.sort,
                      label: _byReceived ? tr('library.sort_received_short') : null,
                    ),
                  ),
                ),
                if (!_filesTab)
                  HoverTip(
                    text: tr('people.tip'),
                    child: IconButton(
                      onPressed: _openPeople,
                      icon: const Icon(Icons.face_retouching_natural_rounded, color: ToolColors.people),
                    ),
                  ),
                if (!_filesTab)
                  HoverTip(
                    text: tr('pick.tip'),
                    child: IconButton(
                      onPressed: () => _selectBy(all, family),
                      icon: const Icon(Icons.checklist_rounded, color: ToolColors.select),
                    ),
                  ),
                if (!_filesTab)
                  HoverTip(
                    text: tr('library.layout_tip'),
                    child: PopupMenuButton<String>(
                      tooltip: '',
                      onSelected: (v) => s.settings.update((x) {
                        switch (v) {
                          case 'compact':
                            x.libraryCompact = true;
                          case 'rows':
                            x.libraryCompact = false;
                          case 'z0':
                          case 'z1':
                          case 'z2':
                            x.libraryCompact = true;
                            x.libraryZoom = int.parse(v.substring(1));
                        }
                      }),
                      itemBuilder: (_) => [
                        CheckedPopupMenuItem(
                            value: 'compact', checked: s.settings.libraryCompact, child: Text(tr('library.layout_compact'))),
                        CheckedPopupMenuItem(
                            value: 'rows', checked: !s.settings.libraryCompact, child: Text(tr('library.layout_rows'))),
                        const PopupMenuDivider(),
                        for (final (v, k) in [(0, 'library.zoom_day'), (1, 'library.zoom_month'), (2, 'library.zoom_year')])
                          CheckedPopupMenuItem(
                            value: 'z$v',
                            checked: s.settings.libraryCompact && s.settings.libraryZoom == v,
                            child: Text(tr(k)),
                          ),
                      ],
                      icon: const Icon(Icons.calendar_view_month_rounded, color: ToolColors.size),
                    ),
                  ),
                if (!_filesTab)
                  HoverTip(
                    text: tr('library.size_tip'),
                    child: PopupMenuButton<int>(
                      tooltip: '',
                      initialValue: s.settings.thumbSize,
                      onSelected: (v) => s.settings.update((x) => x.thumbSize = v),
                      itemBuilder: (_) => [
                        for (final (v, k) in [(0, 'library.size_s'), (1, 'library.size_m'), (2, 'library.size_l')])
                          CheckedPopupMenuItem(value: v, checked: s.settings.thumbSize == v, child: Text(tr(k))),
                      ],
                      icon: const Icon(Icons.photo_size_select_large_rounded, color: ToolColors.size),
                    ),
                  ),
                HoverTip(
                  text: tr('trash.tip'),
                  child: IconButton(
                    onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => TrashPage(services: s))),
                    icon: const Icon(Icons.history_rounded, color: ToolColors.trash),
                  ),
                ),
                HoverTip(
                  text: tr('library.open_folder_tip'),
                  child: IconButton(
                    onPressed: () => revealInExplorer(s.library.rootPath),
                    icon: const Icon(Icons.folder_open_rounded, color: ToolColors.plain),
                  ),
                ),
              ],
              const SizedBox(width: 8),
            ],
          );
        // Light look: a band at the top (name + the disk), the tools on a
        // white strip, the photos on a white card.
        return Theme(
          data: LightLook.theme(Theme.of(context)),
          child: Focus(
            focusNode: _focus,
            autofocus: true,
            onKeyEvent: (_, e) => _onKey(e, items),
            child: Scaffold(
              backgroundColor: LightLook.page,
              body: DecoratedBox(
                decoration: LightLook.wash,
                child: Column(
                  children: [
                    if (!_selecting) _hero(context, all),
                    Padding(
                      padding: EdgeInsets.fromLTRB(20, _selecting ? 16 : 0, 20, 0),
                      child: Container(decoration: LightLook.card(), clipBehavior: Clip.antiAlias, child: bar),
                    ),
                    ..._banners(context, items.length + _visibleFiles().length),
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(20, 12, 20, 18),
                        child: Container(
                          decoration: LightLook.card(),
                          clipBehavior: Clip.antiAlias,
                          child: _filesTab
                              // Documents / other files from PCs: a file list, not photos.
                              ? FilesView(services: s, document: _filter == _Filter.docs)
                              : items.isEmpty && _visibleFiles().isEmpty
                                  ? (_searching ? _noResults(context) : _empty(context))
                                  : (s.settings.libraryCompact && _search.isEmpty)
                                      ? _compactGrid(context, items)
                                      : _grid(context, items),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  /// What to show: round, bright buttons (photos / videos with how many).
  Widget _filters(List<MediaItem> all) {
    final photos = all.where((i) => i.kind == MediaKind.image).length;
    final videos = all.where((i) => i.kind == MediaKind.video).length;
    final list = [
      (_Filter.all, Icons.apps_rounded, tr('library.filter_all'), all.length),
      (_Filter.photos, Icons.landscape_rounded, tr('library.filter_photos'), photos),
      (_Filter.videos, Icons.play_circle_rounded, tr('library.filter_videos'), videos),
      (_Filter.made, Icons.videocam_rounded, tr('recs.title'), null),
      (_Filter.docs, Icons.description_rounded, tr('library.filter_docs'), null),
      (_Filter.other, Icons.folder_rounded, tr('library.filter_other'), null),
    ];
    return Flexible(
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(children: [
          for (final (f, icon, label, n) in list)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: _Pill(
                icon: icon,
                label: n == null ? label : '$label ($n)',
                on: _filter == f,
                onTap: () => setState(() => _filter = f),
              ),
            ),
        ]),
      ),
    );
  }

  /// The band at the top: the name (rest the mouse on it: how to use the
  /// library) and the disk it is on.
  Widget _hero(BuildContext context, List<MediaItem> all) {
    final s = widget.services;
    final total = all.fold<int>(0, (n, i) => n + i.size);
    final d = _disk;
    final used = d == null || d.total == 0 ? null : 1 - d.free / d.total;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 14),
      child: SizedBox(
        height: 124,
        child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(18),
              child: DecoratedBox(
                decoration: const BoxDecoration(
                  gradient: LinearGradient(colors: [Color(0xFFE3ECFF), Color(0xFFCFE0FF), Color(0xFFB4D0FF)]),
                ),
                child: Row(children: [
                  const SizedBox(width: 18),
                  const _HeroArt(),
                  const SizedBox(width: 18),
                  Expanded(
                    child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
                      TipTitle(
                        text: tr('nav.library'),
                        tip: tr('library.title_tip'),
                        style: const TextStyle(fontSize: 30, fontWeight: FontWeight.w800, color: LightLook.text, letterSpacing: -0.5),
                      ),
                      const SizedBox(height: 6),
                      Text(tr('library.tagline'),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 15, color: Color(0xFF2A4A9A), fontWeight: FontWeight.w500)),
                    ]),
                  ),
                ]),
              ),
            ),
          ),
          const SizedBox(width: 16),
          SizedBox(
            width: 360,
            child: Container(
              decoration: LightLook.card(),
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
              child: Row(children: [
                SizedBox(
                  width: 82,
                  height: 82,
                  child: Stack(alignment: Alignment.center, children: [
                    SizedBox.expand(
                      child: CircularProgressIndicator(
                        value: used ?? 0,
                        strokeWidth: 9,
                        strokeCap: StrokeCap.round,
                        backgroundColor: const Color(0xFFE3E9F5),
                        color: (used ?? 0) > 0.9 ? LightLook.red : LightLook.green,
                      ),
                    ),
                    const LightBadge(icon: Icons.folder_rounded, colors: [Color(0xFF5B8CFF), Color(0xFF2F5BEA)], size: 46),
                  ]),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(tr('home.items_size', {'count': all.length, 'size': formatBytes(total)}),
                        maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: LightLook.text)),
                    const SizedBox(height: 3),
                    Text(
                      d == null ? tr('home.disk_unknown') : tr('home.disk_free_short', {'free': formatBytes(d.free)}),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 13, color: LightLook.muted),
                    ),
                    const SizedBox(height: 8),
                    SizedBox(
                      height: 30,
                      child: FilledButton.icon(
                        style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 12), visualDensity: VisualDensity.compact),
                        onPressed: () => revealInExplorer(s.library.rootPath),
                        icon: const Icon(Icons.folder_open_rounded, size: 16),
                        label: Text(tr('common.show_in_folder'), maxLines: 1, overflow: TextOverflow.ellipsis),
                      ),
                    ),
                  ]),
                ),
              ]),
            ),
          ),
        ]),
      ),
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
  /// The search box in the toolbar.
  Widget _searchBox() => SizedBox(
        width: 230,
        height: 38,
        child: TextField(
          controller: _searchCtrl,
          onChanged: _onSearch,
          textInputAction: TextInputAction.search,
          style: const TextStyle(fontSize: 13.5),
          decoration: InputDecoration(
            isDense: true,
            hintText: tr('search.hint'),
            prefixIcon: const Icon(Icons.search_rounded, size: 18),
            prefixIconConstraints: const BoxConstraints(minWidth: 34),
            suffixIcon: _search.isEmpty && _searchCtrl.text.isEmpty
                ? null
                : IconButton(
                    tooltip: tr('search.clear'),
                    iconSize: 16,
                    onPressed: _clearSearch,
                    icon: const Icon(Icons.close_rounded),
                  ),
            contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
          ),
        ),
      );

  /// While text is still being read: how far, and that the rest isn't found yet.
  String _searchNote() {
    final s = widget.services;
    final pic = s.pictureIndexer.progress.value;
    final picNote = s.settings.pictureSearch && (pic.state == IndexState.working || pic.state == IndexState.paused) && pic.total > 0
        ? tr('search.picture_progress_note', {'done': pic.done, 'total': pic.total})
        : '';
    final p = s.textIndexer.progress.value;
    final textNote = switch (p.state) {
      IndexState.working || IndexState.paused || IndexState.starting when p.total > 0 =>
        tr('search.progress_note', {'done': p.done, 'total': p.total}),
      IndexState.off => tr('search.off_note'),
      IndexState.noOcr => tr('search.no_ocr_note'),
      _ => '',
    };
    final f = s.faceIndexer.progress.value;
    final faceNote = s.settings.faces && (f.state == IndexState.working || f.state == IndexState.paused) && f.total > 0
        ? tr('people.working', {'done': f.done, 'total': f.total})
        : '';
    final notes = [textNote, picNote, faceNote].where((t) => t.isNotEmpty).toList();
    // Still reading: where to follow it.
    final textReading = textNote.isNotEmpty && p.state != IndexState.off && p.state != IndexState.noOcr;
    if (textReading || picNote.isNotEmpty || faceNote.isNotEmpty) notes.add(tr('search.progress_where'));
    return notes.join('  ·  ');
  }

  /// Turn picture search on: download the model (once), then read.
  Future<void> _enablePictures() async {
    final s = widget.services;
    await s.settings.update((x) {
      x.pictureSearch = true;
      x.pictureAsked = true;
    });
    final ok = await s.pictureModel.download();
    if (ok) {
      s.pictureIndexer.wake();
    } else if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('search.picture_download_failed'))));
    }
  }

  /// People: pick a person to see only their photos.
  Future<void> _openPeople() async {
    final id = await Navigator.of(context).push<int>(MaterialPageRoute(builder: (_) => PeoplePage(services: widget.services)));
    if (id == null || !mounted) return;
    setState(() {
      _person = id;
      _filter = _Filter.all;
      _member = null;
      _onlyRecent = false;
      _clearSelection();
    });
    if (_scroll.hasClients) _scroll.jumpTo(0);
  }

  Widget _personBanner(BuildContext context, Widget Function(IconData, Color, String, List<Widget>) banner, int found) {
    final s = widget.services;
    final p = s.server.people.person(_person!)!;
    return banner(Icons.face_rounded, LightLook.green, tr('people.showing', {'name': personLabel(p), 'count': found}), [
      TextButton(onPressed: () => namePerson(context, s, p.id), child: Text(tr(p.name == null ? 'people.name' : 'people.rename'))),
      const SizedBox(width: 4),
      TextButton(onPressed: _openPeople, child: Text(tr('people.everyone'))),
      const SizedBox(width: 4),
      TextButton(onPressed: () => setState(() => _person = null), child: Text(tr('people.show_all_photos'))),
    ]);
  }

  /// "Not this person": the selected photos come off the person shown.
  void _notThisPerson(List<MediaItem> items) {
    final s = widget.services;
    final id = _person;
    if (id == null) return;
    final keys = <String>[
      for (final i in items)
        if (_selected.contains(i.relPath)) TextIndex.mediaKey(i),
      for (final f in _files)
        if (_selected.contains(fileKey(f.path))) TextIndex.fileKey(s.server.files.relOf(f.path) ?? f.path, f.size),
    ];
    if (keys.isEmpty) return;
    s.server.people.notThisPerson(id, keys);
    setState(_clearSelection);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('people.removed', {'count': keys.length}))));
  }

  Widget _noResults(BuildContext context) => Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.search_off_rounded, size: 56, color: Theme.of(context).colorScheme.outline),
          const SizedBox(height: 10),
          Text(tr('search.none', {'q': _searchCtrl.text.trim()})),
          const SizedBox(height: 4),
          Text(_searchNote(), textAlign: TextAlign.center, style: const TextStyle(color: LightLook.muted, fontSize: 12.5)),
        ]),
      );

  List<Widget> _banners(BuildContext context, int found) {
    final lib = widget.services.library;
    final theme = Theme.of(context);
    Widget banner(IconData icon, Color color, String text, List<Widget> actions) => Container(
          margin: const EdgeInsets.fromLTRB(20, 10, 20, 0),
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
    final s = widget.services;
    final dl = s.pictureModel.downloading;
    return [
      // Searching for the first time: offer picture search, saying plainly
      // what the download is for and that nothing else depends on it.
      if (!_search.isEmpty && !s.settings.pictureSearch && !s.settings.pictureAsked)
        banner(Icons.image_search_rounded, LightLook.green,
            tr('search.picture_offer', {'size': formatBytes(PictureModel.downloadSize)}), [
          TextButton(
            onPressed: () => s.settings.update((x) => x.pictureAsked = true),
            child: Text(tr('search.picture_later')),
          ),
          const SizedBox(width: 4),
          FilledButton(onPressed: _enablePictures, child: Text(tr('search.picture_enable'))),
        ]),
      if (dl != null)
        banner(Icons.downloading_rounded, LightLook.green,
            tr('search.picture_downloading', {'done': formatBytes(dl.$1), 'total': formatBytes(dl.$2)}), const []),
      if (_person != null) _personBanner(context, banner, found),
      if (_searching)
        banner(Icons.search_rounded, Theme.of(context).colorScheme.primary,
            [tr('search.results', {'q': _searchCtrl.text.trim(), 'count': found}), _searchNote()].where((t) => t.isNotEmpty).join('  ·  '), [
          TextButton(onPressed: _clearSearch, child: Text(tr('search.clear'))),
        ]),
      if (_onlyRecent)
        banner(Icons.schedule_rounded, LightLook.amberText, tr('lib.recent_only'), [
          TextButton(onPressed: () => setState(() => _onlyRecent = false), child: Text(tr('lib.recent_all'))),
        ]),
      // Unplugged drive / deleted or moved folder: what can be done.
      if (lib.offline) LibraryRecovery(services: widget.services),
      // Converted copies picked with "Select by…" are not in the grid.
      if (_copies.isNotEmpty)
        banner(Icons.auto_fix_high_rounded, LightLook.amberText,
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
  /// Selected received files and converted copies (full paths).
  List<String> _chosenFiles() => [
        for (final f in _files)
          if (_selected.contains(fileKey(f.path))) f.path,
        ..._copies.keys,
      ];

  /// Send originals (with their Live Photo videos) and files to another
  /// PC or a phone.
  Future<void> _sendToPc(List<MediaItem> items, [List<String> paths = const []]) async {
    final lib = widget.services.library;
    final sep = Platform.pathSeparator;
    final files = [
      for (final i in lib.withLive(items)) ?SendFile.fromLibrary(lib, i),
      for (final p in paths) ?SendFile.plain(File(p), p.split(sep).last),
    ];
    if (files.isEmpty) return;
    final count = items.length + paths.length;
    final queued = await sendToPc(context, widget.services, files,
        count == 1 ? (items.isNotEmpty ? items.first.name : paths.first.split(sep).last) : tr('send.n_items', {'count': count}));
    // Kept selected if nothing was sent (cancelled, went back).
    if (queued && mounted) setState(_clearSelection);
  }

  /// Copy the originals (and files) into a folder of your choice.
  Future<void> _export(List<MediaItem> items, [List<String> paths = const []]) async {
    if (items.isEmpty && paths.isEmpty) return;
    final folder = await WinDialogs.pickFolder(title: tr('lib.export'));
    if (folder == null) return;
    var n = await exportItems(widget.services.library, items, folder);
    for (final p in paths) {
      try {
        await File(p).copy(LibraryIndex.uniquePath(folder, p.split(Platform.pathSeparator).last));
        n++;
      } catch (_) {}
    }
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
        for (final t in _toolsFor(targets)) PopupMenuItem(value: 'tool:${t.name}', child: _menuRow(t.icon, t.title)),
        PopupMenuItem(value: 'convert', child: _menuRow(Icons.auto_fix_high_rounded, tr('convert.menu'))),
        PopupMenuItem(value: 'export', child: _menuRow(Icons.drive_file_move_rounded, tr('lib.export'))),
        PopupMenuItem(value: 'send', child: _menuRow(Icons.send_rounded, tr('send.to_pc'))),
        if (targets.length == 1)
          PopupMenuItem(value: 'reveal', child: _menuRow(Icons.folder_open_rounded, tr('common.show_in_folder'))),
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
    if (choice.startsWith('tool:')) {
      final t = Tool.values.firstWhere((x) => x.name == choice.substring(5));
      await openTool(this.context, s, t, paths: [for (final i in targets) s.library.absPath(i)]);
      return;
    }
    switch (choice) {
      case 'open':
        await openLibraryItems(this.context, s, items, index);
      case 'select':
        _toggle(item.relPath);
      case 'export':
        await _export(targets);
      case 'send':
        await _sendToPc(targets);
      case 'reveal':
        revealInExplorer(s.library.absPath(item));
      case 'delete':
        await _delete(targets);
      case 'convert':
        final ok = await convertWithDialog(this.context, s, items: targets, video: targets.every((i) => i.kind == MediaKind.video));
        if (ok && mounted) setState(_clearSelection);
    }
  }

  /// The tools that fit what was right-clicked.
  static List<Tool> _toolsFor(List<MediaItem> items) {
    if (items.every((i) => i.kind == MediaKind.image)) {
      return [if (items.length == 1) Tool.editImage, Tool.heicJpg, Tool.photosPdf, Tool.compressPhoto];
    }
    if (items.every((i) => i.kind == MediaKind.video)) return [Tool.cutVideo, Tool.compressVideo, Tool.videoToAudio];
    return const [];
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
    final indexOf = {for (var k = 0; k < items.length; k++) items[k].relPath: k};
    // Groups: days — or, while searching, "the text has it" and "it looks
    // like it" (most alike first).
    final groups = <(String, List<_Cell>)>[];
    if (_search.isEmpty) {
      var start = 0;
      while (start < cells.length) {
        final t = cells[start].day;
        var end = start;
        while (end < cells.length && cells[end].day.year == t.year && cells[end].day.month == t.month && cells[end].day.day == t.day) {
          end++;
        }
        groups.add((formatDayFull(t), cells.sublist(start, end)));
        start = end;
      }
    } else {
      final q = _searchCtrl.text.trim();
      final byText = [for (final c in cells) if (!_onlyPicture(c)) c];
      final byPicture = [for (final c in cells) if (_onlyPicture(c)) c]
        ..sort((a, b) => (_picHits[_searchKey(b)] ?? 0).compareTo(_picHits[_searchKey(a)] ?? 0));
      if (byText.isNotEmpty) groups.add((tr('search.group_text', {'q': q}), byText));
      if (byPicture.isNotEmpty) groups.add((tr('search.group_picture', {'q': q}), byPicture));
    }
    _order = [for (final g in groups) for (final c in g.$2) c.key];
    if (_flat.isNotEmpty) {
      _flat = const [];
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _topIndex.value = -1;
      });
    }
    final slivers = <Widget>[];
    for (final (title, day) in groups) {
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
                    color: whole ? theme.colorScheme.primary : LightLook.muted,
                  ),
                ),
                const SizedBox(width: 4),
                Text(title, style: theme.textTheme.titleMedium),
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
    }
    slivers.add(const SliverToBoxAdapter(child: SizedBox(height: 24)));
    return _boxSelect(context, CustomScrollView(controller: _scroll, slivers: slivers));
  }

  /// Drag with the mouse to select with a box (Ctrl: add to what is
  /// selected). [over]: more layers above the grid.
  Widget _boxSelect(BuildContext context, Widget scroll, {List<Widget> over = const [], void Function(PointerSignalEvent)? onSignal}) {
    return Listener(
      onPointerDown: _boxDown,
      onPointerMove: _boxMove,
      onPointerUp: (_) => _boxEnd(),
      onPointerCancel: (_) => _boxEnd(),
      onPointerSignal: onSignal,
      child: Stack(key: _gridKey, children: [
        scroll,
        ...over,
        if (_boxing && _dragNow != null && _downAt != null)
          Positioned.fill(
            child: IgnorePointer(
              child: CustomPaint(painter: _BoxPainter(_boxRectLocal(), Theme.of(context).colorScheme.primary)),
            ),
          ),
      ]),
    );
  }

  // ------------------------------------------------------- compact layout

  int _unitKey(DateTime d, int zoom) => switch (zoom) {
        0 => d.year * 10000 + d.month * 100 + d.day,
        1 => d.year * 100 + d.month,
        _ => d.year,
      };

  /// A square's date label: short, so it never reaches the "select" circle.
  /// Days: "Nov 9" (another year: with the year); small squares only the day
  /// ("9"), the month where it changes ("11月"), the year where it changes.
  String _label(DateTime d, DateTime? before, int zoom, {required bool small}) {
    final thisYear = d.year == DateTime.now().year;
    if (zoom != 0) return zoom == 1 && small ? _monthName(d) : _unitShort(d, zoom);
    if (!small) return formatDayShort(d); // with the year when not this year
    if (before == null ? !thisYear : before.year != d.year) return '${d.year}';
    if (before == null || before.month != d.month) return _monthName(d);
    return '${d.day}';
  }

  static String _monthName(DateTime d) => translator.language.startsWith('zh') || translator.language.startsWith('ja')
      ? '${d.month}月'
      : const ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'][d.month - 1];

  String _unitShort(DateTime d, int zoom) => switch (zoom) {
        0 => formatDayShort(d),
        1 => formatMonthShort(d),
        _ => '${d.year}',
      };

  String _unitFull(DateTime d, int zoom) => switch (zoom) {
        0 => formatDayFull(d),
        1 => formatMonthYear(d),
        _ => '${d.year}',
      };

  /// Keys of the squares in day / month / year number [g].
  List<String> _unitKeys(int g) {
    final end = g + 1 < _starts.length ? _starts[g + 1] : _flat.length;
    return [for (var i = _starts[g]; i < end; i++) _flat[i].key];
  }

  void _toggleUnit(int g) {
    final keys = _unitKeys(g);
    final whole = keys.every(_selected.contains);
    _focus.requestFocus();
    setState(() {
      if (whole) {
        _selected.removeAll(keys);
      } else {
        _selected.addAll(keys);
        _anchor = keys.last;
      }
    });
  }

  String _unitTip(int g, bool whole) {
    final zoom = _zoomShown;
    final k = zoom == 0 ? 'day' : zoom == 1 ? 'month' : 'year';
    return tr(whole ? 'lib.unselect_$k' : 'lib.select_$k');
  }

  /// Days (months, years) run on in one grid: no half-empty rows. Each one's
  /// first square has a small date label (click it: select that day), and a
  /// line on its left. The date of the top row stays at the top; while
  /// scrolling the date shows beside the scrollbar.
  Widget _compactGrid(BuildContext context, List<MediaItem> items) {
    final settings = widget.services.settings;
    final zoom = settings.libraryZoom;
    final cells = _cells(items);
    final indexOf = {for (var k = 0; k < items.length; k++) items[k].relPath: k};
    final starts = <int>[];
    final groupOf = List<int>.filled(cells.length, 0);
    int? last;
    for (var i = 0; i < cells.length; i++) {
      final k = _unitKey(cells[i].day, zoom);
      if (k != last) {
        starts.add(i);
        last = k;
      }
      groupOf[i] = starts.length - 1;
    }
    _flat = cells;
    _starts = starts;
    _groupOf = groupOf;
    _zoomShown = zoom;
    _order = [for (final c in cells) c.key];
    final extent = switch (zoom) {
      0 => const [120.0, 180.0, 260.0][settings.thumbSize],
      1 => 72.0,
      _ => 44.0,
    };
    final theme = Theme.of(context);
    return LayoutBuilder(builder: (context, box) {
      const pad = 12.0, gap = 4.0;
      final w = max(1.0, box.maxWidth - 2 * pad);
      final cols = max(1, ((w + gap) / (extent + gap)).ceil());
      final side = (w - gap * (cols - 1)) / cols;
      _cols = cols;
      _rowH = side + gap;
      final grid = CustomScrollView(
        controller: _scroll,
        // Ctrl + wheel zooms; the list must not scroll as well.
        physics: _ctrl ? const NeverScrollableScrollPhysics() : null,
        slivers: [
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(pad, _gridTop, pad, 24),
            sliver: SliverGrid.builder(
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: cols,
                mainAxisSpacing: gap,
                crossAxisSpacing: gap,
              ),
              itemCount: cells.length,
              itemBuilder: (context, i) {
                final c = cells[i];
                final m = c.media;
                Widget child = m != null ? _cell(context, items, indexOf[m.relPath]!) : _fileCell(context, c.file!);
                final g = groupOf[i];
                if (starts[g] == i) child = _labelled(context, child, g, first: i == 0, side: side);
                return _Box(key: ValueKey(c.key), id: c.key, boxes: _boxes, child: child);
              },
            ),
          ),
        ],
      );
      return _boxSelect(
        context,
        grid,
        onSignal: _onWheel,
        over: [
          // The date of the top row.
          ValueListenableBuilder<int>(
            valueListenable: _topIndex,
            builder: (context, top, _) {
              if (top < 0 || _flat.isEmpty) return const SizedBox.shrink();
              final g = _groupOf[min(top, _flat.length - 1)];
              return Positioned(top: 6, left: 16, child: _dateBar(context, theme, g));
            },
          ),
          // The date beside the scrollbar while scrolling.
          AnimatedBuilder(
            animation: Listenable.merge([_scroll, _scrollTip]),
            builder: (context, _) {
              if (!_scrollTip.value || !_scroll.hasClients || _flat.isEmpty) return const SizedBox.shrink();
              final p = _scroll.position;
              if (!p.hasContentDimensions || p.maxScrollExtent < p.viewportDimension * 2) return const SizedBox.shrink();
              final f = (p.pixels / p.maxScrollExtent).clamp(0.0, 1.0);
              final mid = p.pixels + p.viewportDimension / 2 - _gridTop;
              final i = min(_flat.length - 1, max(0, (mid / _rowH).floor() * _cols));
              final h = box.maxHeight.isFinite ? box.maxHeight : p.viewportDimension;
              final y = 8 + f * max(0.0, h - 52);
              return Positioned(
                top: y,
                right: 22,
                child: IgnorePointer(
                  child: Material(
                    elevation: 3,
                    color: theme.colorScheme.inverseSurface,
                    borderRadius: BorderRadius.circular(8),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                      child: Text(
                        zoom == 0 ? formatDayShort(_flat[i].day, withYear: true) : _unitFull(_flat[i].day, zoom),
                        style: theme.textTheme.labelLarge?.copyWith(color: theme.colorScheme.onInverseSurface),
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ],
      );
    });
  }

  /// A day's (month's, year's) first square: its date label and a line on
  /// the left (not on the very first square).
  Widget _labelled(BuildContext context, Widget child, int g, {required bool first, required double side}) {
    final keys = _unitKeys(g);
    final whole = keys.isNotEmpty && keys.every(_selected.contains);
    final small = side < 60;
    final primary = Theme.of(context).colorScheme.primary;
    final d = _flat[_starts[g]].day;
    final before = g > 0 ? _flat[_starts[g - 1]].day : null;
    return Stack(children: [
      Positioned.fill(child: child),
      // Every day's first square: a line on its left (where a day starts).
      Positioned(left: 0, top: 0, bottom: 0, child: IgnorePointer(child: Container(width: 3, color: primary))),
      Positioned(
        left: small ? 3 : 5,
        top: small ? 2 : 5,
        child: ConstrainedBox(
          // At most half the square: the top right is the "select" circle's.
          constraints: BoxConstraints(maxWidth: max(18.0, side / 2)),
          child: Tooltip(
            message: _unitTip(g, whole),
            child: Material(
              color: whole ? primary : Colors.black.withValues(alpha: 0.6),
              borderRadius: BorderRadius.circular(small ? 4 : 6),
              child: InkWell(
                borderRadius: BorderRadius.circular(small ? 4 : 6),
                onTap: () => _toggleUnit(g),
                child: Padding(
                  padding: EdgeInsets.symmetric(horizontal: small ? 3 : 6, vertical: small ? 1 : 2),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    if (!small) ...[
                      Icon(whole ? Icons.check_circle_rounded : Icons.circle_outlined, size: 12, color: Colors.white),
                      const SizedBox(width: 4),
                    ],
                    Flexible(
                      child: Text(
                        _label(d, before, _zoomShown, small: small),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: Colors.white, fontSize: small ? 9 : 11, fontWeight: FontWeight.w600),
                      ),
                    ),
                  ]),
                ),
              ),
            ),
          ),
        ),
      ),
    ]);
  }

  /// The bar at the top: the full date of the top row, how many, select it.
  Widget _dateBar(BuildContext context, ThemeData theme, int g) {
    final keys = _unitKeys(g);
    final whole = keys.isNotEmpty && keys.every(_selected.contains);
    final end = g + 1 < _starts.length ? _starts[g + 1] : _flat.length;
    var photos = 0, videos = 0, files = 0;
    for (var i = _starts[g]; i < end; i++) {
      final c = _flat[i];
      if (c.file != null) {
        files++;
      } else if (c.media!.kind == MediaKind.video) {
        videos++;
      } else {
        photos++;
      }
    }
    return Material(
      elevation: 3,
      color: theme.colorScheme.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(20),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(4, 2, 14, 2),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          IconButton(
            tooltip: _unitTip(g, whole),
            iconSize: 18,
            visualDensity: VisualDensity.compact,
            onPressed: () => _toggleUnit(g),
            icon: Icon(
              whole ? Icons.check_circle_rounded : Icons.check_circle_outline_rounded,
              color: whole ? theme.colorScheme.primary : LightLook.muted,
            ),
          ),
          Text(_unitFull(_flat[_starts[g]].day, _zoomShown), style: theme.textTheme.titleSmall),
          const SizedBox(width: 10),
          Text(
            [
              if (photos > 0) tr('library.n_photos', {'count': photos}),
              if (videos > 0) tr('library.n_videos', {'count': videos}),
              if (files > 0) tr('library.n_files', {'count': files}),
            ].join('   '),
            style: theme.textTheme.bodySmall,
          ),
        ]),
      ),
    );
  }

  void _onScroll() {
    if (_flat.isEmpty || !_scroll.hasClients) return;
    final off = _scroll.offset;
    final row = max(0, ((off - _gridTop) / _rowH).floor());
    _topIndex.value = off > _rowH * 0.6 ? min(_flat.length - 1, row * _cols) : -1;
    _scrollTip.value = true;
    _tipTimer?.cancel();
    _tipTimer = Timer(const Duration(milliseconds: 900), () {
      if (mounted) _scrollTip.value = false;
    });
  }

  bool _onCtrlKey(KeyEvent e) {
    final c = HardwareKeyboard.instance.isControlPressed;
    if (c != _ctrl && mounted) {
      if (_flat.isEmpty) {
        _ctrl = c;
      } else {
        setState(() => _ctrl = c);
      }
    }
    return false;
  }

  /// Ctrl + wheel: year ↔ month ↔ day (small, medium, large squares).
  void _onWheel(PointerSignalEvent e) {
    if (e is! PointerScrollEvent || !HardwareKeyboard.instance.isControlPressed || _flat.isEmpty) return;
    final now = DateTime.now();
    if (now.difference(_lastZoom).inMilliseconds < 250 || e.scrollDelta.dy == 0) return;
    _lastZoom = now;
    final s = widget.services.settings;
    // Steps from far to near.
    const steps = [(2, -1), (1, -1), (0, 0), (0, 1), (0, 2)];
    var at = steps.indexWhere((x) => x.$1 == s.libraryZoom && (x.$1 != 0 || x.$2 == s.thumbSize));
    if (at < 0) at = 2;
    final to = (at + (e.scrollDelta.dy < 0 ? 1 : -1)).clamp(0, steps.length - 1);
    if (to == at) return;
    // Keep the top row's square in view.
    final keep = _topIndex.value < 0 ? 0 : _topIndex.value;
    s.update((x) {
      x.libraryZoom = steps[to].$1;
      if (steps[to].$2 >= 0) x.thumbSize = steps[to].$2;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients || keep == 0) return;
      final y = _gridTop + (keep ~/ _cols) * _rowH;
      _scroll.jumpTo(min(y, _scroll.position.maxScrollExtent));
    });
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

  /// The round "select" button at the top right (the top left is where a
  /// day's date sits): on hover, or always once selecting; ticked when selected.
  Widget _selectButton(String key, bool selected) => Positioned(
        right: 4,
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
        message: [
          f.name,
          if (!_search.isEmpty) ?s.server.textIndex.snippet(TextIndex.fileKey(s.server.files.relOf(f.path) ?? f.path, f.size), _search),
        ].join('\n'),
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
                  color: const Color(0xFFEFF2F8),
                  alignment: Alignment.center,
                  child: Icon(_iconFor(f.name), size: 40, color: LightLook.muted),
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
            if (f.owner?.private ?? false)
              Positioned(
                right: 3,
                bottom: 2,
                child: Tooltip(
                  message: tr('family.sender_tip', {
                    'name': s.settings.family.memberOf(f.owner!.deviceId) ?? f.owner!.deviceName,
                  }),
                  child: const Padding(
                    padding: EdgeInsets.all(2),
                    child: Icon(Icons.lock_rounded, size: 16, color: Colors.white, shadows: [Shadow(color: Colors.black54, blurRadius: 4)]),
                  ),
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
        if (Tool.pdfTools.takes(f.path)) PopupMenuItem(value: 'tool:pdfTools', child: _menuRow(Tool.pdfTools.icon, Tool.pdfTools.title)),
        if (Tool.officePdf.takes(f.path)) PopupMenuItem(value: 'tool:officePdf', child: _menuRow(Tool.officePdf.icon, Tool.officePdf.title)),
        PopupMenuItem(value: 'export', child: _menuRow(Icons.drive_file_move_rounded, tr('lib.export'))),
        PopupMenuItem(value: 'send', child: _menuRow(Icons.send_rounded, tr('send.to_pc'))),
        PopupMenuItem(value: 'rename', child: _menuRow(Icons.drive_file_rename_outline_rounded, tr('files.rename'))),
        PopupMenuItem(value: 'reveal', child: _menuRow(Icons.folder_open_rounded, tr('common.show_in_folder'))),
        const PopupMenuDivider(),
        PopupMenuItem(value: 'delete', child: _menuRow(Icons.delete_outline_rounded, tr('lib.delete'), danger: true)),
      ],
    );
    if (!mounted || choice == null) return;
    if (choice.startsWith('tool:')) {
      final t = Tool.values.firstWhere((x) => x.name == choice.substring(5));
      await openTool(this.context, widget.services, t, paths: _selected.contains(key) ? _chosenFiles() : [f.path]);
      return;
    }
    switch (choice) {
      case 'open':
        await openReceivedFile(this.context, widget.services, f.path);
      case 'export':
        await _export(const [], _selected.contains(key) ? _chosenFiles() : [f.path]);
      case 'send':
        await _sendToPc(const [], _selected.contains(key) ? _chosenFiles() : [f.path]);
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
    final found = _search.isEmpty ? null : s.server.textIndex.snippet(TextIndex.mediaKey(item), _search);
    return _hover(
      key,
      Tooltip(
        message: found ?? '',
        waitDuration: const Duration(milliseconds: 400),
        child: GestureDetector(
        onTap: () => _tap(
          key,
          () => openLibraryItems(context, s, items, index),
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
            // "Sender only": hover the lock to see who that is.
            if (item.private && item.deviceId != null)
              Positioned(
                right: item.kind == MediaKind.video ? 32 : 6,
                bottom: 6,
                child: Tooltip(
                  message: tr('family.sender_tip', {'name': _memberOf(s.settings.family, item)}),
                  child: const SizedBox(width: 18, height: 18),
                ),
              ),
            // Drawn on in the player: how many annotations.
            ListenableBuilder(
              listenable: s.notes,
              builder: (context, _) {
                final n = s.notes.countFor(item);
                if (n == 0) return const SizedBox.shrink();
                return Positioned(
                  left: 4,
                  bottom: 4,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                    decoration: BoxDecoration(color: const Color(0xCC000000), borderRadius: BorderRadius.circular(8)),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      const Icon(Icons.brush_rounded, size: 12, color: Color(0xFFFFB547)),
                      const SizedBox(width: 3),
                      Text('$n', style: const TextStyle(fontSize: 11, color: Colors.white)),
                    ]),
                  ),
                );
              },
            ),
            if (selected) _selectedFrame(context),
            _selectButton(key, selected),
          ],
        ),
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

/// A filter button: white, blue when on.
class _Pill extends StatelessWidget {
  const _Pill({required this.icon, required this.label, required this.on, required this.onTap});

  final IconData icon;
  final String label;
  final bool on;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Material(
        color: on ? LightLook.blue : Colors.white,
        shape: StadiumBorder(side: BorderSide(color: on ? LightLook.blue : const Color(0xFFDDE5F3))),
        elevation: on ? 2 : 0,
        shadowColor: LightLook.blue.withValues(alpha: 0.4),
        child: InkWell(
          customBorder: const StadiumBorder(),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(icon, size: 17, color: on ? Colors.white : LightLook.blue),
              const SizedBox(width: 6),
              Text(label, style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: on ? Colors.white : LightLook.text)),
            ]),
          ),
        ),
      );
}

/// The band's picture: a folder with a photo, a film and a note floating
/// around it — drawn from icons.
class _HeroArt extends StatelessWidget {
  const _HeroArt();

  Widget _chip(IconData icon, List<Color> colors, double size, double angle) => Transform.rotate(
        angle: angle,
        child: Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(size * 0.28),
            gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: colors),
            boxShadow: [BoxShadow(color: colors.last.withValues(alpha: 0.4), blurRadius: 10, offset: const Offset(0, 4))],
          ),
          child: Icon(icon, color: Colors.white, size: size * 0.56),
        ),
      );

  @override
  Widget build(BuildContext context) => SizedBox(
        width: 150,
        height: 110,
        child: Stack(clipBehavior: Clip.none, children: [
          Positioned(
            left: 4,
            bottom: 6,
            child: Container(
              width: 120,
              height: 22,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(60),
                gradient: RadialGradient(colors: [const Color(0xFF7FB2FF).withValues(alpha: 0.7), const Color(0x007FB2FF)]),
              ),
            ),
          ),
          Positioned(left: 18, top: 18, child: _chip(Icons.folder_rounded, const [Color(0xFF6FB1FF), Color(0xFF2F6BFF)], 82, -0.06)),
          const Positioned(left: 46, top: 44, child: Icon(Icons.play_arrow_rounded, color: Colors.white, size: 34)),
          Positioned(left: 86, top: 0, child: _chip(Icons.image_rounded, const [Color(0xFFFFC56B), Color(0xFFFF8A3D)], 34, 0.18)),
          Positioned(right: 0, top: 40, child: _chip(Icons.movie_rounded, const [Color(0xFFA78BFA), Color(0xFF7C4DFF)], 32, -0.12)),
          Positioned(left: 0, top: 4, child: _chip(Icons.music_note_rounded, const [Color(0xFF63E6BE), Color(0xFF12B886)], 28, -0.2)),
        ]),
      );
}

/// A smart album: shown by what the photo looks like (searched on this
/// PC), plus words in it and in its name.
class _Category {
  const _Category(this.label, this.icon, this.looks, {this.words = const [], this.names = const []});

  final String label;
  final IconData icon;
  final String looks;
  final List<String> words;
  final List<String> names;
}

const List<_Category> _categories = [
  _Category('smart.screens', Icons.screenshot_rounded, 'a screenshot of a phone or computer screen', names: ['screenshot', '截屏', '截图', 'screen shot']),
  _Category('smart.receipts', Icons.receipt_long_rounded, 'a photo of a paper receipt or invoice', words: ['发票', '合计', '小计', 'receipt', 'invoice', 'total']),
  _Category('smart.ids', Icons.badge_rounded, 'a photo of an id card, passport or driver license', words: ['身份证', 'passport', '驾驶证', 'license']),
  _Category('smart.docs', Icons.description_rounded, 'a photo of a printed document page with text'),
  _Category('smart.boards', Icons.developer_board_rounded, 'a whiteboard or blackboard with writing'),
  _Category('smart.food', Icons.restaurant_rounded, 'a photo of food on a plate'),
  _Category('smart.pets', Icons.pets_rounded, 'a photo of a cat or a dog'),
  _Category('smart.scenery', Icons.landscape_rounded, 'a landscape photo of mountains, sea or sky'),
  _Category('smart.people', Icons.groups_rounded, 'a group photo of several people'),
];
