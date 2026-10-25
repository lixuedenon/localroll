// apps/desktop/lib/ui/player/player_page.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show FontFeature;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:localroll_core/localroll_core.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:window_manager/window_manager.dart';

import '../../app_services.dart';
import '../../l10n/l10n.dart';
import '../../services/annotations.dart';
import '../../services/converter.dart';
import '../../services/ffmpeg.dart';
import '../../services/library_index.dart';
import '../../services/mic.dart';
import '../../services/network.dart';
import '../../services/peers.dart';
import '../../services/player_memory.dart';
import '../app_nav.dart';
import '../files_view.dart';
import '../format.dart';
import '../media_thumb.dart';
import '../send_page.dart';
import '../theme.dart';
import '../trash_actions.dart';
import 'clip_dialog.dart';
import 'clip_export.dart';
import 'ink_editor.dart';
import 'ink_paint.dart';
import 'narration.dart';
import 'narration_dialogs.dart';
import 'notes_panel.dart';
import 'player_entry.dart';
import 'snapshot.dart';

part 'player_side.dart';
part 'player_video.dart';

/// Opens files from this PC (Explorer's "Open with", drag and drop, the
/// open dialog). One file: the photos and videos of its folder come along,
/// so the arrows go through them.
Future<void> openInPlayer(BuildContext context, AppServices s, List<String> paths, {int? startMs}) async {
  final wanted = [for (final p in paths) if (PlayerEntry.playable(p)) p];
  if (wanted.isEmpty) {
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(tr('player.nothing_playable'))));
    return;
  }
  var range = wanted;
  var start = wanted.first;
  if (wanted.length == 1) {
    final all = PlayerEntry.inFolder(File(start).parent.path);
    if (all.any((p) => p.toLowerCase() == start.toLowerCase())) range = all;
  }
  final entries = <PlayerEntry>[];
  var at = 0;
  for (final p in range) {
    final e = PlayerEntry.fromPath(p, library: s.library);
    if (e == null) continue;
    if (p.toLowerCase() == start.toLowerCase()) at = entries.length;
    entries.add(e);
  }
  if (entries.isEmpty) {
    if (context.mounted) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(tr('player.missing'))));
    }
    return;
  }
  if (!context.mounted) return;
  await openPlayer(context, s, entries, at, startMs: startMs);
}

/// Files asked for from outside the window (Explorer's "Open with", a
/// second copy of LocalRoll started with a file, files dropped on the
/// window): a few arriving close together open as one list, over
/// whatever page was open.
class PlayerLauncher {
  PlayerLauncher._();

  static final List<String> _pending = [];
  static Timer? _timer;

  static void request(AppServices s, List<String> paths) {
    if (paths.isEmpty) return;
    _pending.addAll(paths);
    _timer?.cancel();
    _timer = Timer(const Duration(milliseconds: 900), () => _launch(s, 0));
  }

  static Future<void> _launch(AppServices s, int tries) async {
    final nav = AppNav.instance.navigatorKey.currentState;
    final ctx = AppNav.instance.navigatorKey.currentContext;
    if (nav == null || ctx == null) {
      // Still starting.
      if (tries < 30) _timer = Timer(const Duration(milliseconds: 300), () => _launch(s, tries + 1));
      return;
    }
    final paths = {for (final p in _pending) p.toLowerCase(): p}.values.toList();
    _pending.clear();
    nav.popUntil((r) => r.isFirst);
    await openInPlayer(ctx, s, paths);
  }
}

/// Library items (the list shown, in its order: the arrows go through it).
Future<void> openLibraryItems(BuildContext context, AppServices s, List<MediaItem> items, int index) =>
    openPlayer(context, s, [for (final i in items) PlayerEntry.fromItem(s.library, i)], index < 0 ? 0 : index);

/// [startMs]: a video starts there (an annotation found by search).
Future<void> openPlayer(BuildContext context, AppServices s, List<PlayerEntry> entries, int index, {int? startMs}) =>
    Navigator.of(context).push(MaterialPageRoute(
      settings: const RouteSettings(name: 'player'),
      builder: (_) => PlayerPage(services: s, entries: entries, initialIndex: index.clamp(0, entries.length - 1), initialMs: startMs),
    ));

/// For "Recent" and "Continue".
RecentEntry recentOf(PlayerEntry e) => RecentEntry(
      path: e.path,
      relPath: e.item?.relPath,
      name: e.name,
      video: e.video,
      openedMs: DateTime.now().millisecondsSinceEpoch,
    );

/// "1:05" / "1:02:05".
String playerTime(Duration d) {
  final h = d.inHours;
  final m = d.inMinutes % 60;
  final s = (d.inSeconds % 60).toString().padLeft(2, '0');
  return h > 0 ? '$h:${m.toString().padLeft(2, '0')}:$s' : '$m:$s';
}

/// What a photo or video view on the page does with keys and buttons.
abstract class _ViewHandle {
  /// True when the key was used.
  bool onKey(KeyEvent e);

  /// Where the video is (photos: 0).
  int get nowMs;

  /// How long the video is (photos: 0).
  int get durationMs;

  bool get playing;

  double get rate;

  /// The part of the picture on screen now (0–1; all of it: 0,0,1,1).
  Rect get zoomRect;

  /// Marks drawn while paused being drawn again now (videos).
  FreezeNow? get freezeNow;

  /// The picture's own size in pixels, once known.
  Size? get pictureSize;

  void seekTo(int ms, {bool play = false});
}

/// The part of a picture of [pic] pixels, fitted in [box], that is on
/// screen after zooming with [m] (0–1).
Rect _visibleRect(Matrix4 m, Size box, Size? pic) {
  const all = Rect.fromLTWH(0, 0, 1, 1);
  if (pic == null || pic.isEmpty || box.isEmpty || m.getMaxScaleOnAxis() < 1.01) return all;
  final fit = (box.width / pic.width) < (box.height / pic.height) ? box.width / pic.width : box.height / pic.height;
  final p = Rect.fromCenter(center: box.center(Offset.zero), width: pic.width * fit, height: pic.height * fit);
  final inv = Matrix4.tryInvert(m);
  if (inv == null) return all;
  final v = MatrixUtils.transformRect(inv, Offset.zero & box).intersect(p);
  if (v.isEmpty) return all;
  return Rect.fromLTWH((v.left - p.left) / p.width, (v.top - p.top) / p.height, v.width / p.width, v.height / p.height);
}

/// The tabs of the list on the right.
enum _Tab { list, notes, info }

/// Typing somewhere (a text mark, a search box): keys are letters then.
bool _typing() => FocusManager.instance.primaryFocus?.context?.findAncestorStateOfType<EditableTextState>() != null;

/// An explanation being recorded: its clock (stops while paused), the
/// voice in parts, what the player did, what was drawn.
class _Rec {
  _Rec({required this.session, required this.dir, required this.mic, required this.device});

  final NarrationSession session;
  final Directory dir;
  final MicRecorder mic;
  final String device;
  final Stopwatch clock = Stopwatch();
  final List<({File file, int headMs, int lengthMs})> parts = [];
  final Map<PlayerEntry, int> fileIndex = {};
  final Map<String, NarrationInk> inks = {};
  Timer? sampler;
  bool paused = false;
  InkEditor? lastEditor;
  Set<String> lastIds = {};

  File? _part;
  int _partStart = 0;

  /// Starts the microphone into a new part (true: it is listening).
  Future<bool> startPart() async {
    final f = File('${dir.path}${Platform.pathSeparator}voice_${parts.length}.wav');
    _part = f;
    return mic.start(device, f);
  }

  /// The clock goes on from now; the part's sound before now is cut.
  void go() {
    final first = mic.firstSound ?? DateTime.now();
    final head = DateTime.now().difference(first).inMilliseconds;
    _partStart = clock.elapsedMilliseconds;
    _head = head < 0 ? 0 : head;
    clock.start();
  }

  int _head = 0;

  Future<void> stopPart() async {
    clock.stop();
    await mic.stop();
    final f = _part;
    if (f != null) parts.add((file: f, headMs: _head, lengthMs: clock.elapsedMilliseconds - _partStart));
    _part = null;
  }

  int fileOf(PlayerEntry e, Size? pic) => fileIndex.putIfAbsent(e, () {
        session.files.add(NarrationFile(
          path: e.path,
          name: e.name,
          video: e.video,
          width: (pic?.width ?? 1920).round(),
          height: (pic?.height ?? 1080).round(),
          rel: e.item?.relPath,
        ));
        return session.files.length - 1;
      });
}

/// The one player for photos and videos — library, received files, files
/// anywhere on this PC. Videos (HEVC, HDR, Dolby Vision, MKV…) play
/// through libmpv; HEIC, AVIF, TIFF, camera RAW are shown as they are.
class PlayerPage extends StatefulWidget {
  const PlayerPage({super.key, required this.services, required this.entries, required this.initialIndex, this.initialMs});

  final AppServices services;
  final List<PlayerEntry> entries;
  final int initialIndex;

  /// The first video starts here (instead of where it was left).
  final int? initialMs;

  @override
  State<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends State<PlayerPage> {
  late final PageController _pages = PageController(initialPage: widget.initialIndex);
  late int _index = widget.initialIndex;
  late final List<PlayerEntry> _entries = List.of(widget.entries);
  final FocusNode _focus = FocusNode(debugLabel: 'player');
  final Map<PlayerEntry, _ViewHandle> _handles = {};

  /// The list on the right: open, which tab, notes of this file or all.
  late bool _side = widget.services.player.sideOpen;
  late _Tab _tab = _Tab.values.firstWhere((t) => t.name == widget.services.player.sideTab, orElse: () => _Tab.list);
  bool _notesAll = false;

  /// Full screen: the list slid out from the right edge.
  bool _peek = false;
  bool _fullscreen = false;

  /// Annotations of each item, once read.
  final Map<PlayerEntry, NoteSet> _sets = {};

  /// Drawing now (null: not).
  InkEditor? _editor;

  /// Recording an explanation (null: not); the 3-2-1 before it starts.
  _Rec? _rec;
  int _countdown = 0;

  /// Explanations recorded on this PC (to make them again).
  List<NarrationSession> _narrations = const [];
  bool _showInk = true;

  /// Bars shown (in full screen they step aside when the mouse rests).
  bool _chrome = true;
  Timer? _hide;

  bool _slideshow = false;
  Timer? _slide;

  PlayerEntry get _entry => _entries[_index];
  _ViewHandle? get _active => _handles[_entry];
  PlayerMemory get _memory => widget.services.player;
  NoteSet? get _set => _sets[_entry];

  /// Where the first video starts (used once).
  late final Map<PlayerEntry, int> _startAt = {if (widget.initialMs != null) _entries[widget.initialIndex]: widget.initialMs!};

  Future<void> _loadNotes(PlayerEntry e) async {
    if (_sets.containsKey(e)) return;
    try {
      final set = await widget.services.notes.open(item: e.item, path: e.path, name: e.name, size: e.size, video: e.video);
      if (mounted) setState(() => _sets[e] = set);
    } catch (err) {
      DiagLog.log('player', 'annotations not opened: $err');
    }
  }

  Future<void> _loadNarrations() async {
    final all = await NarrationSession.all(widget.services.settings.dataDir);
    if (mounted) setState(() => _narrations = all);
  }

  @override
  void initState() {
    super.initState();
    unawaited(_loadNarrations());
    unawaited(_loadNotes(_entry));
    _memory.opened(recentOf(_entry));
    DiagLog.log('player', 'open ${_entry.video ? 'video' : 'photo'} .${_entry.extension} (${_entries.length} in list)');
  }

  @override
  void dispose() {
    _hide?.cancel();
    _slide?.cancel();
    if (_fullscreen) {
      AppNav.instance.fullscreen.value = false;
      unawaited(windowManager.setFullScreen(false).catchError((_) {}));
    }
    _pages.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _register(PlayerEntry e, _ViewHandle? h) {
    if (h == null) {
      _handles.remove(e);
    } else {
      _handles[e] = h;
    }
  }

  void _go(int delta) {
    final next = _index + delta;
    if (next < 0 || next >= _entries.length) {
      if (_slideshow) _setSlideshow(false);
      return;
    }
    _pages.jumpToPage(next);
  }

  void _changed(int i) {
    // Drawing on the one left: kept.
    if (_editor != null) unawaited(_finishDraw(on: _entry));
    setState(() => _index = i);
    _memory.opened(recentOf(_entries[i]));
    unawaited(_loadNotes(_entries[i]));
  }

  /// A video ended: on to the next one if asked to.
  void _ended() {
    if (_slideshow || _memory.endMode == EndMode.next) _go(1);
  }

  Future<void> _setFullscreen(bool on) async {
    if (on == _fullscreen) return;
    setState(() => _fullscreen = on);
    AppNav.instance.fullscreen.value = on;
    try {
      await windowManager.setFullScreen(on);
    } catch (_) {}
    _poke();
  }

  /// The mouse moved: show the bars; in full screen hide them again soon.
  void _poke() {
    _hide?.cancel();
    if (!_chrome) setState(() => _chrome = true);
    if (_fullscreen) {
      _hide = Timer(const Duration(milliseconds: 2500), () {
        if (mounted && _fullscreen) setState(() => _chrome = false);
      });
    }
  }

  void _setSlideshow(bool on) {
    _slide?.cancel();
    _slide = null;
    setState(() => _slideshow = on);
    if (on) {
      _slide = Timer.periodic(const Duration(seconds: 4), (_) {
        // A video plays to its end first.
        if (!_entry.video) _go(1);
      });
    }
  }

  KeyEventResult _key(FocusNode _, KeyEvent e) {
    if (e is KeyUpEvent || _typing()) return KeyEventResult.ignored;
    final k = e.logicalKey;
    final shift = HardwareKeyboard.instance.isShiftPressed;
    final ctrl = HardwareKeyboard.instance.isControlPressed;
    final down = e is KeyDownEvent;
    final ed = _editor;
    if (ed != null && down) {
      if (ctrl && k == LogicalKeyboardKey.keyZ) {
        shift ? ed.redo() : ed.undo();
        return KeyEventResult.handled;
      }
      if (ctrl && k == LogicalKeyboardKey.keyY) {
        ed.redo();
        return KeyEventResult.handled;
      }
      if ((k == LogicalKeyboardKey.delete || k == LogicalKeyboardKey.backspace) && ed.selected != null) {
        ed.deleteSelected();
        return KeyEventResult.handled;
      }
      if (k == LogicalKeyboardKey.escape) {
        unawaited(_finishDraw());
        return KeyEventResult.handled;
      }
    }
    if (down && k == LogicalKeyboardKey.escape) {
      if (_fullscreen) {
        _setFullscreen(false);
      } else if (_slideshow) {
        _setSlideshow(false);
      } else {
        Navigator.of(context).maybePop();
      }
      return KeyEventResult.handled;
    }
    if (down && _rec != null && k == LogicalKeyboardKey.keyR && !ctrl) {
      unawaited(_stopRecording());
      return KeyEventResult.handled;
    }
    if (_active?.onKey(e) ?? false) return KeyEventResult.handled;
    if (!down) return KeyEventResult.ignored;
    if (k == LogicalKeyboardKey.keyF || k == LogicalKeyboardKey.f11) {
      _setFullscreen(!_fullscreen);
    } else if (k == LogicalKeyboardKey.keyI) {
      _showTab(_Tab.info);
    } else if (k == LogicalKeyboardKey.keyN && !shift) {
      _showTab(_Tab.notes);
    } else if (k == LogicalKeyboardKey.keyL) {
      _toggleSide();
    } else if (k == LogicalKeyboardKey.keyD) {
      _editor == null ? _startDraw() : unawaited(_finishDraw());
    } else if (k == LogicalKeyboardKey.keyR && !ctrl) {
      // (Photos: R turns the picture; the record button starts there.)
      unawaited(_startRecording());
    } else if (k == LogicalKeyboardKey.keyC && !ctrl && _entry.video) {
      unawaited(_clip());
    } else if (k == LogicalKeyboardKey.keyS && !ctrl) {
      unawaited(_shoot(withInk: true));
    } else if (k == LogicalKeyboardKey.pageDown || (shift && k == LogicalKeyboardKey.keyN)) {
      _go(1);
    } else if (k == LogicalKeyboardKey.pageUp || (shift && k == LogicalKeyboardKey.keyP)) {
      _go(-1);
    } else if (!_entry.video && k == LogicalKeyboardKey.arrowRight) {
      _go(1);
    } else if (!_entry.video && k == LogicalKeyboardKey.arrowLeft) {
      _go(-1);
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  // ---------------------------------------------------------------- actions

  Future<void> _send(PlayerEntry e) async {
    final s = widget.services;
    final item = e.item;
    final files = item != null
        ? [for (final i in s.library.withLive([item])) ?SendFile.fromLibrary(s.library, i)]
        : [?SendFile.plain(File(e.path), e.name)];
    if (files.isEmpty) return;
    await sendToPc(context, s, files, e.name);
  }

  Future<void> _delete(PlayerEntry e) async {
    final item = e.item;
    if (item == null) return;
    final n = await deleteToTrash(context, widget.services, media: [item]);
    if (n <= 0 || !mounted) return;
    if (_entries.length == 1) {
      Navigator.of(context).maybePop();
      return;
    }
    setState(() {
      _entries.removeAt(_index);
      if (_index >= _entries.length) _index = _entries.length - 1;
    });
    _pages.jumpToPage(_index);
  }

  void _convert(PlayerEntry e, ConvertPreset p) {
    final item = e.item;
    if (item == null) return;
    widget.services.converter.enqueue([item], p);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('convert.queued_hint', {'preset': p.label}))));
  }

  /// Show [t] on the right (pressed again while shown: the list closes).
  void _showTab(_Tab t) {
    if (_fullscreen) {
      setState(() {
        _peek = !(_peek && _tab == t);
        _tab = t;
      });
    } else {
      setState(() {
        _side = !(_side && _tab == t);
        _tab = t;
      });
    }
    _memory.setSide(open: _fullscreen ? null : _side, tab: t.name);
  }

  void _openTab(_Tab t) {
    setState(() {
      _tab = t;
      if (_fullscreen) {
        _peek = true;
      } else {
        _side = true;
      }
    });
    _memory.setSide(open: _fullscreen ? null : true, tab: t.name);
  }

  void _toggleSide() {
    if (_fullscreen) {
      setState(() => _peek = !_peek);
      return;
    }
    setState(() => _side = !_side);
    _memory.setSide(open: _side);
  }

  /// Every annotation of the files in this list: (which file, note).
  List<(int, Note)> _allNotes() {
    final byRel = <String, int>{}, byPath = <String, int>{};
    for (var i = 0; i < _entries.length; i++) {
      final e = _entries[i];
      if (e.item != null) byRel[e.item!.relPath] = i;
      byPath[e.path.toLowerCase()] = i;
    }
    final seen = <String>{};
    final out = <(int, Note)>[];
    void add(NoteSet set, int? i) {
      if (i == null) return;
      for (final n in set.notes) {
        if (seen.add(n.id)) out.add((i, n));
      }
    }

    for (final e in _sets.entries) {
      add(e.value, _entries.indexOf(e.key) < 0 ? null : _entries.indexOf(e.key));
    }
    for (final set in widget.services.notes.sets) {
      add(set, set.rel != null ? byRel[set.rel] : byPath[set.path.toLowerCase()]);
    }
    out.sort((a, b) => a.$1 != b.$1 ? a.$1.compareTo(b.$1) : a.$2.startMs.compareTo(b.$2.startMs));
    return out;
  }

  /// Go to [n] on the [index]th file (from "all notes").
  void _goToNote(int index, Note n) {
    if (index == _index) {
      unawaited(_noteAction(n, _entry.video ? NoteAction.jump : NoteAction.edit));
      return;
    }
    final e = _entries[index];
    if (e.video) {
      final to = n.startMs - _memory.leadSec * 1000;
      _startAt[e] = to < 0 ? 0 : to;
    }
    _pages.jumpToPage(index);
  }

  // ------------------------------------------------------------- drawing

  /// Start drawing (on a video: at where it is; marks drawn while it
  /// plays remember their moment). [note]: change that one.
  void _startDraw({Note? note}) {
    if (_editor != null) return;
    final e = _entry;
    if (!_sets.containsKey(e)) return;
    setState(() {
      _showInk = true;
      _editor = InkEditor(
        video: e.video,
        clock: () => _active?.nowMs ?? 0,
        playing: () => _active?.playing ?? false,
        sessionClock: _rec == null ? null : () => _rec?.clock.elapsedMilliseconds ?? 0,
        inks: note?.inks,
        original: note,
      );
    });
    DiagLog.log('player', 'drawing ${note == null ? 'new' : 'edit'}');
  }

  /// Done drawing: kept as an annotation (nothing drawn: nothing kept).
  Future<void> _finishDraw({PlayerEntry? on}) async {
    final ed = _editor;
    if (ed == null) return;
    final e = on ?? _entry;
    final set = _sets[e];
    setState(() => _editor = null);
    FocusManager.instance.primaryFocus?.unfocus();
    _focus.requestFocus();
    if (set == null) return;
    final inks = ed.result;
    final old = ed.original;
    if (inks.isEmpty) {
      if (old != null) {
        set.notes.remove(old);
        await widget.services.notes.save(set);
      }
      return;
    }
    final start = e.video ? inks.map((i) => i.atMs ?? 0).reduce((a, b) => a < b ? a : b) : 0;
    final Note note;
    if (old != null) {
      note = old
        ..inks = inks
        ..startMs = start
        ..modifiedMs = DateTime.now().millisecondsSinceEpoch;
    } else {
      note = Note(
        id: InkMark.newId(),
        name: e.video ? tr('ink.note_at', {'time': playerTime(Duration(milliseconds: start))}) : tr('ink.note_n', {'n': set.notes.length + 1}),
        inks: inks,
        startMs: start,
      );
      set.notes.add(note);
      // Made while recording: the recording draws these itself.
      _rec?.session.noteIds.add(note.id);
    }
    await widget.services.notes.save(set);
    if (!mounted) return;
    setState(() {});
    if (_rec != null) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(tr('ink.saved', {'name': note.name})),
      action: SnackBarAction(
        label: tr('ink.view'),
        onPressed: () {
          if (mounted) _openTab(_Tab.notes);
        },
      ),
    ));
  }

  Future<void> _cancelDraw() async {
    final ed = _editor;
    if (ed == null) return;
    if (ed.inks.isNotEmpty && ed.original == null) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          content: Text(tr('ink.discard')),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('common.cancel'))),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(tr('ink.discard_yes'))),
          ],
        ),
      );
      if (ok != true) return;
    }
    if (!mounted) return;
    final rec = _rec;
    if (rec != null) {
      // Thrown away while recording: gone from the recording from now on.
      final t = rec.clock.elapsedMilliseconds;
      for (final id in ed.sessionStart.keys) {
        rec.inks[id]?.removedT ??= t;
      }
    }
    setState(() => _editor = null);
    _focus.requestFocus();
  }

  /// The annotations drawn on the picture now (others, not the one being
  /// changed).
  List<Note> _shownNotes(PlayerEntry e) {
    if (!_showInk) return const [];
    final all = _sets[e]?.notes ?? const <Note>[];
    final editing = e == _entry ? _editor?.original : null;
    return [for (final n in all) if (n != editing) n];
  }

  /// The marks a screenshot gets now: what is on the picture.
  List<InkMark> _inksNow() {
    final e = _entry;
    final ms = _active?.nowMs ?? 0;
    return [
      for (final n in _shownNotes(e))
        if (!e.video || n.shownAt(ms))
          for (final i in n.inks)
            if (!e.video || n.inkShownAt(i, ms)) i,
      ...?_editor?.result,
    ];
  }

  Future<void> _shoot({required bool withInk, Note? note}) async {
    final e = _entry;
    final ms = note != null ? note.lastMs : (_active?.nowMs ?? 0);
    final inks = note != null ? note.inks : (withInk ? _inksNow() : const <InkMark>[]);
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(SnackBar(content: Text(tr('ink.shooting')), duration: const Duration(seconds: 20)));
    final f = await Snapshots.take(widget.services, e, ms: ms, inks: inks);
    messenger.hideCurrentSnackBar();
    if (!mounted) return;
    if (f == null) {
      messenger.showSnackBar(SnackBar(content: Text(tr('ink.shot_failed'))));
      return;
    }
    messenger.showSnackBar(SnackBar(
      duration: const Duration(seconds: 8),
      content: Row(children: [
        Expanded(child: Text(tr('ink.shot_saved', {'folder': f.parent.path.split(Platform.pathSeparator).last}))),
        TextButton(onPressed: () => revealInExplorer(f.path), child: Text(tr('common.show_in_folder'))),
        const SizedBox(width: 4),
        FilledButton.icon(
          onPressed: () {
            messenger.hideCurrentSnackBar();
            unawaited(_sendFile(f));
          },
          icon: const Icon(Icons.send_rounded, size: 16),
          label: Text(tr('player.send')),
        ),
      ]),
    ));
  }

  /// A screenshot to another device (from the library when it is in it).
  Future<void> _sendFile(File f) async {
    final s = widget.services;
    final lib = s.library;
    final root = '${lib.rootPath}${Platform.pathSeparator}';
    final item = f.path.toLowerCase().startsWith(root.toLowerCase())
        ? lib.findByRel(f.path.substring(root.length).replaceAll(Platform.pathSeparator, '/'))
        : null;
    final name = f.path.split(Platform.pathSeparator).last;
    final file = item != null ? SendFile.fromLibrary(lib, item) : SendFile.plain(f, name);
    if (file == null || !mounted) return;
    await sendToPc(context, s, [file], name);
  }

  /// Cut a clip: around [note] (the seconds before / after from the
  /// settings), else around where the video is.
  Future<void> _clip({Note? note, bool send = false}) async {
    final e = _entry;
    final v = _active;
    if (!e.video || v == null) return;
    final m = _memory;
    final dur = v.durationMs;
    final from = note != null ? note.startMs - m.clipBefore * 1000 : v.nowMs - m.clipBefore * 1000;
    final to = note != null ? note.endMs + m.clipAfter * 1000 : v.nowMs + m.clipAfter * 1000;
    final notes = _sets[e]?.notes ?? const <Note>[];
    final choice = await showClipDialog(
      context,
      startMs: from < 0 ? 0 : from,
      endMs: dur > 0 && to > dur ? dur : to,
      durationMs: dur,
      hasInk: notes.isNotEmpty,
      send: send,
    );
    if (choice == null || !mounted) return;
    if (v.playing) v.seekTo(v.nowMs);
    final pic = v.pictureSize ?? const Size(1920, 1080);
    final exporter = ClipExporter(widget.services);
    final progress = ValueNotifier<double>(0);
    final done = exporter.run(
      e,
      startMs: choice.startMs,
      endMs: choice.endMs,
      withInk: choice.withInk,
      notes: _showInk ? notes : const [],
      picture: pic,
      onProgress: (p) => progress.value = p,
    );
    unawaited(showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        unawaited(done.whenComplete(() {
          if (ctx.mounted) Navigator.of(ctx).pop();
        }));
        return AlertDialog(
          title: Text(tr(choice.withInk ? 'clip.making_ink' : 'clip.making')),
          content: SizedBox(
            width: 360,
            child: ValueListenableBuilder<double>(
              valueListenable: progress,
              builder: (_, p, _) => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                LinearProgressIndicator(value: p <= 0 ? null : p),
                const SizedBox(height: 8),
                Text('${(p * 100).round()}%', style: const TextStyle(color: LrColors.muted)),
              ]),
            ),
          ),
          actions: [TextButton(onPressed: exporter.cancel, child: Text(tr('common.cancel')))],
        );
      },
    ));
    final f = await done;
    progress.dispose();
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    if (f == null) {
      messenger.showSnackBar(SnackBar(content: Text(tr('clip.failed'))));
      return;
    }
    if (choice.send) {
      await _sendFile(f);
      return;
    }
    messenger.showSnackBar(SnackBar(
      duration: const Duration(seconds: 8),
      content: Row(children: [
        Expanded(child: Text(tr('clip.saved', {'folder': f.parent.path.split(Platform.pathSeparator).last}))),
        TextButton(onPressed: () => revealInExplorer(f.path), child: Text(tr('common.show_in_folder'))),
        const SizedBox(width: 4),
        FilledButton.icon(
          onPressed: () {
            messenger.hideCurrentSnackBar();
            unawaited(_sendFile(f));
          },
          icon: const Icon(Icons.send_rounded, size: 16),
          label: Text(tr('player.send')),
        ),
      ]),
    ));
  }

  Future<void> _clipAround() async {
    final r = await showClipAroundDialog(context, _memory.clipBefore, _memory.clipAfter);
    if (r != null) _memory.setClipAround(r.$1, r.$2);
  }

  Future<void> _rename(PlayerEntry e, Note n) async {
    final set = _sets[e];
    if (set == null) return;
    final ctrl = TextEditingController(text: n.name);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('ink.rename')),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          onSubmitted: (v) => Navigator.pop(ctx, v),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(tr('common.cancel'))),
          FilledButton(onPressed: () => Navigator.pop(ctx, ctrl.text), child: Text(tr('common.ok'))),
        ],
      ),
    );
    ctrl.dispose();
    if (name == null || name.trim().isEmpty) return;
    n
      ..name = name.trim()
      ..modifiedMs = DateTime.now().millisecondsSinceEpoch;
    await widget.services.notes.save(set);
    if (mounted) setState(() {});
  }

  Future<void> _noteAction(Note n, NoteAction a) async {
    final e = _entry;
    final set = _sets[e];
    if (set == null) return;
    switch (a) {
      case NoteAction.jump:
        final to = n.startMs - _memory.leadSec * 1000;
        _active?.seekTo(to < 0 ? 0 : to, play: true);
      case NoteAction.edit:
        if (_editor != null) await _finishDraw();
        if (e.video) _active?.seekTo(n.startMs);
        _startDraw(note: n);
      case NoteAction.rename:
        await _rename(e, n);
      case NoteAction.shot:
        await _shoot(withInk: true, note: n);
      case NoteAction.send:
        final f = await Snapshots.take(widget.services, e, ms: n.lastMs, inks: n.inks);
        if (f != null && mounted) await _sendFile(f);
      case NoteAction.clip:
        await _clip(note: n);
      case NoteAction.sendClip:
        await _clip(note: n, send: true);
      case NoteAction.delete:
        final at = set.notes.indexOf(n);
        set.notes.remove(n);
        await widget.services.notes.save(set);
        if (!mounted) return;
        setState(() {});
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(tr('ink.deleted', {'name': n.name})),
          action: SnackBarAction(
            label: tr('trash.undo'),
            onPressed: () async {
              set.notes.insert(at.clamp(0, set.notes.length), n);
              await widget.services.notes.save(set);
              if (mounted) setState(() {});
            },
          ),
        ));
    }
  }

  Future<void> _hold(Note n, int ms) async {
    final set = _sets[_entry];
    if (set == null) return;
    n.holdMs = ms;
    await widget.services.notes.save(set);
    if (mounted) setState(() {});
  }

  // ----------------------------------------------------- explanations

  void _snack(String text) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  /// Start recording an explanation: the microphone (chosen once), 3-2-1,
  /// then what the player does and what is drawn is recorded with the voice.
  Future<void> _startRecording() async {
    if (_rec != null || _countdown > 0) return;
    final s = widget.services;
    if (!s.ffmpeg.available) {
      _snack(tr('viewer.needs_ffmpeg', {'ext': 'MP4'}));
      return;
    }
    final mic = MicRecorder(s.ffmpeg.ffmpeg);
    var device = _memory.mic;
    final devices = await mic.devices();
    if (!mounted) return;
    if (device == null || !devices.contains(device)) {
      device = await pickMicrophone(context, mic, current: device);
      if (device == null || !mounted) return;
      _memory.setMic(device);
    }
    if (_editor != null) await _finishDraw();
    _slide?.cancel();
    if (_slideshow) setState(() => _slideshow = false);
    final id = InkMark.newId();
    final dir = NarrationSession.folderOf(s.settings.dataDir, id);
    await dir.create(recursive: true);
    final rec = _Rec(session: NarrationSession(id: id, createdMs: DateTime.now().millisecondsSinceEpoch), dir: dir, mic: mic, device: device);
    // The microphone starts while counting down.
    final listening = rec.startPart();
    for (var c = 3; c > 0; c--) {
      if (!mounted) return;
      setState(() => _countdown = c);
      await Future<void>.delayed(const Duration(seconds: 1));
    }
    final ok = await listening;
    if (!mounted) {
      await mic.stop();
      return;
    }
    setState(() => _countdown = 0);
    if (!ok) {
      try {
        await dir.delete(recursive: true);
      } catch (_) {}
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(tr('rec.mic_failed')),
          content: SizedBox(width: 420, child: Text(tr('rec.no_mic_tip'))),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.pop(ctx);
                _memory.setMic(null);
              },
              child: Text(tr('rec.pick_other')),
            ),
            FilledButton(onPressed: () => Navigator.pop(ctx), child: Text(tr('common.close'))),
          ],
        ),
      );
      return;
    }
    rec.go();
    setState(() => _rec = rec);
    rec.sampler = Timer.periodic(const Duration(milliseconds: 50), (_) => _sample());
    _sample();
    DiagLog.log('player', 'explanation recording');
  }

  /// What the player is doing now, into the recording.
  void _sample() {
    final rec = _rec;
    if (rec == null || rec.paused) return;
    final a = _active;
    final e = _entry;
    final t = rec.clock.elapsedMilliseconds;
    final fi = rec.fileOf(e, a?.pictureSize);
    final fz = a?.freezeNow;
    rec.session.samples.add(NarrationSample(
      t: t,
      file: fi,
      pos: e.video ? (a?.nowMs ?? 0) : 0,
      playing: a?.playing ?? false,
      rate: a?.rate ?? 1,
      zoom: a?.zoomRect ?? const Rect.fromLTWH(0, 0, 1, 1),
      freezeNote: fz?.plan.noteId,
      freezeAt: fz?.plan.atMs,
      freezeMs: fz?.elapsedMs,
    ));
    final ed = _editor;
    if (ed != null) {
      final now = {for (final i in [...ed.inks, ?ed.drawing]) i.id: i};
      for (final i in now.values) {
        final st = ed.sessionStart[i.id];
        if (st == null) continue;
        final old = rec.inks[i.id];
        rec.inks[i.id] = NarrationInk(file: old?.file ?? fi, ink: i.copy(), startT: st, times: List.of(ed.sessionTimes[i.id] ?? const [0]));
      }
      if (identical(rec.lastEditor, ed)) {
        for (final id in rec.lastIds) {
          if (!now.containsKey(id)) rec.inks[id]?.removedT ??= t;
        }
      }
      rec.lastEditor = ed;
      rec.lastIds = now.keys.toSet();
    }
  }

  Future<void> _pauseRecording() async {
    final rec = _rec;
    if (rec == null) return;
    if (!rec.paused) {
      _sample();
      setState(() => rec.paused = true);
      await rec.stopPart();
    } else {
      final ok = await rec.startPart();
      if (!ok) {
        _snack(tr('rec.mic_failed'));
        return;
      }
      rec.go();
      if (mounted) setState(() => rec.paused = false);
    }
  }

  /// Stop: the voice in one file, the recording kept, then save / send /
  /// throw away.
  Future<void> _stopRecording() async {
    final rec = _rec;
    if (rec == null) return;
    rec.sampler?.cancel();
    _sample();
    if (_editor != null) await _finishDraw();
    if (!rec.paused) await rec.stopPart();
    rec.session.lengthMs = rec.clock.elapsedMilliseconds;
    rec.session.inks
      ..clear()
      ..addAll(rec.inks.values);
    if (mounted) setState(() => _rec = null);
    DiagLog.log('player', 'explanation recorded (${rec.session.lengthMs ~/ 1000} s)');
    final exe = widget.services.ffmpeg.ffmpeg;
    final voice = File('${rec.dir.path}${Platform.pathSeparator}voice.wav');
    if (exe != null) await joinVoice(exe, rec.parts, voice);
    for (final p in rec.parts) {
      try {
        await p.file.delete();
      } catch (_) {}
    }
    try {
      await File('${rec.dir.path}${Platform.pathSeparator}session.json').writeAsString(jsonEncode(rec.session.toJson()));
    } catch (e) {
      DiagLog.log('player', 'explanation not kept: $e');
    }
    await _loadNarrations();
    if (mounted) await _afterRecording(rec.session);
  }

  OriginalSound get _sound => OriginalSound.values.firstWhere((v) => v.name == _memory.sound, orElse: () => OriginalSound.quiet);

  /// Save / save and send / throw away (asked twice) a recording; [again]:
  /// making a kept one again.
  Future<void> _afterRecording(NarrationSession n, {bool again = false}) async {
    final voice = File('${NarrationSession.folderOf(widget.services.settings.dataDir, n.id).path}${Platform.pathSeparator}voice.wav');
    while (mounted) {
      final r = await recordedDialog(context, n.lengthMs, _sound, again: again);
      if (r == null || !mounted) return;
      _memory.setSound(r.$2.name);
      if (r.$1 == RecordedChoice.discard) {
        final ink = await confirmDiscard(context, drew: n.noteIds.isNotEmpty);
        if (ink == null) continue; // back to the first question
        await _deleteNarration(n, withInk: ink);
        _snack(tr('rec.discarded'));
        return;
      }
      await _makeNarration(n, voice, r.$2, send: r.$1 == RecordedChoice.saveSend);
      return;
    }
  }

  Future<void> _deleteNarration(NarrationSession n, {required bool withInk}) async {
    try {
      await NarrationSession.folderOf(widget.services.settings.dataDir, n.id).delete(recursive: true);
    } catch (_) {}
    if (withInk && n.noteIds.isNotEmpty) {
      for (final set in {..._sets.values, ...widget.services.notes.sets}) {
        final before = set.notes.length;
        set.notes.removeWhere((m) => n.noteIds.contains(m.id));
        if (set.notes.length != before) await widget.services.notes.save(set);
      }
    }
    await _loadNarrations();
    if (mounted) setState(() {});
  }

  Future<void> _makeNarration(NarrationSession n, File voice, OriginalSound sound, {required bool send}) async {
    final s = widget.services;
    // The annotations of each file (as the player showed them).
    final sets = <NoteSet?>[];
    for (final f in n.files) {
      final e = _entries.where((x) => x.path.toLowerCase() == f.path.toLowerCase()).firstOrNull;
      NoteSet? set = e == null ? null : _sets[e];
      if (set == null && File(f.path).existsSync()) {
        try {
          final item = f.rel == null ? null : s.library.findByRel(f.rel!);
          set = await s.notes.open(item: item, path: f.path, name: f.name, size: File(f.path).lengthSync(), video: f.video);
        } catch (_) {}
      }
      sets.add(set);
    }
    if (!mounted) return;
    final maker = NarrationComposer(s);
    final progress = ValueNotifier<double>(0);
    final done = maker.make(n, voice: voice, sound: sound, notes: sets, onProgress: (p) => progress.value = p);
    unawaited(showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        unawaited(done.whenComplete(() {
          if (ctx.mounted) Navigator.of(ctx).pop();
        }));
        return AlertDialog(
          title: Text(tr('rec.making')),
          content: SizedBox(
            width: 360,
            child: ValueListenableBuilder<double>(
              valueListenable: progress,
              builder: (_, p, _) => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                LinearProgressIndicator(value: p <= 0 ? null : p),
                const SizedBox(height: 8),
                Text('${(p * 100).round()}%', style: const TextStyle(color: LrColors.muted)),
              ]),
            ),
          ),
          actions: [TextButton(onPressed: maker.cancel, child: Text(tr('common.cancel')))],
        );
      },
    ));
    final f = await done;
    progress.dispose();
    if (!mounted) return;
    if (f == null) {
      _snack(tr('rec.failed'));
      return;
    }
    if (send) {
      await _sendFile(f);
      return;
    }
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(SnackBar(
      duration: const Duration(seconds: 8),
      content: Row(children: [
        Expanded(child: Text(tr('clip.saved', {'folder': f.parent.path.split(Platform.pathSeparator).last}))),
        TextButton(onPressed: () => revealInExplorer(f.path), child: Text(tr('common.show_in_folder'))),
        const SizedBox(width: 4),
        FilledButton.icon(
          onPressed: () {
            messenger.hideCurrentSnackBar();
            unawaited(_sendFile(f));
          },
          icon: const Icon(Icons.send_rounded, size: 16),
          label: Text(tr('player.send')),
        ),
      ]),
    ));
  }

  /// Kept recordings that include what is shown now.
  List<NarrationSession> get _narrationsHere {
    final p = _entry.path.toLowerCase();
    return [for (final n in _narrations) if (n.files.any((f) => f.path.toLowerCase() == p)) n];
  }

  Future<void> _narrationAction(NarrationSession n, String action) async {
    if (action == 'remake') {
      await _afterRecording(n, again: true);
    } else if (action == 'delete') {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(tr('rec.delete_record')),
          content: SizedBox(width: 420, child: Text(tr('rec.delete_record_tip'))),
          actions: [
            FilledButton(autofocus: true, onPressed: () => Navigator.pop(ctx, false), child: Text(tr('rec.back'))),
            TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              style: TextButton.styleFrom(foregroundColor: LrColors.danger),
              child: Text(tr('ink.delete')),
            ),
          ],
        ),
      );
      if (ok == true) await _deleteNarration(n, withInk: false);
    }
  }

  Future<void> _shortcuts() => showDialog<void>(
        context: context,
        builder: (ctx) {
          Widget row(String keys, String what) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  SizedBox(
                    width: 150,
                    child: Text(keys, style: const TextStyle(fontWeight: FontWeight.w600, color: LrColors.safelight)),
                  ),
                  Expanded(child: Text(what)),
                ]),
              );
          return AlertDialog(
            title: Text(tr('player.shortcuts')),
            content: SizedBox(
              width: 440,
              child: SingleChildScrollView(
                child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                  row('Space  K', tr('player.play_pause')),
                  row('←  →', tr('player.key_seek')),
                  row('J  L', tr('player.key_seek10')),
                  row(',  .', tr('player.key_frame')),
                  row('[  ]  Backspace', tr('player.key_speed')),
                  row('A', tr('player.ab')),
                  row('↑  ↓  M', tr('player.key_volume')),
                  row('PgUp  PgDn', tr('player.key_prev_next')),
                  row('+  −  0', tr('player.key_zoom')),
                  row('R  Shift+R', tr('player.rotate')),
                  row('F  F11  Esc', tr('player.fullscreen')),
                  row('I', tr('player.info')),
                  row('D', tr('ink.draw')),
                  row('N', tr('ink.notes_key')),
                  row('S', tr('ink.shot_key')),
                  row('C', tr('clip.title')),
                  row('R', tr('rec.start')),
                  row('Ctrl+Z  Ctrl+Y', tr('ink.key_undo')),
                  row('Shift', tr('ink.key_shift')),
                ]),
              ),
            ),
            actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: Text(tr('common.close')))],
          );
        },
      );

  // ------------------------------------------------------------------- view

  /// "Anna 2" (family member + device number), else the phone's name.
  String? _from(MediaItem item) =>
      (item.deviceId == null ? null : widget.services.settings.family.labelOf(item.deviceId!)) ?? item.deviceName;

  Widget _btn(IconData icon, String tip, VoidCallback? onTap, {bool on = false}) => IconButton(
        tooltip: tip,
        onPressed: onTap,
        color: on ? LrColors.safelight : Colors.white,
        icon: Icon(icon, size: 22),
      );

  Widget _topBar() {
    final e = _entry;
    final item = e.item;
    final from = item == null ? null : _from(item);
    final image = _active is _ImageViewState ? _active as _ImageViewState : null;
    final parts = [
      formatDate(e.time),
      formatBytes(e.size),
      if (from != null) tr('viewer.from', {'name': from}),
      if (item?.private ?? false) '🔒',
      if (_entries.length > 1) '${_index + 1} / ${_entries.length}',
    ];
    return Container(
      height: 56,
      padding: const EdgeInsets.only(left: 8, right: 8),
      decoration: BoxDecoration(
        color: _fullscreen ? null : Colors.black,
        gradient: _fullscreen
            ? const LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Color(0xCC000000), Color(0x00000000)])
            : null,
      ),
      child: Row(children: [
        if (_fullscreen) _btn(Icons.arrow_back_rounded, tr('player.exit_fullscreen'), () => _setFullscreen(false)),
        const SizedBox(width: 8),
        Expanded(
          child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(e.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 15, color: Colors.white)),
            Text(parts.join(' · '), maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12, color: Colors.white70)),
          ]),
        ),
        if (image != null) ...[
          _btn(Icons.zoom_out_rounded, tr('player.zoom_out'), () => image.zoomBy(1 / 1.5)),
          _btn(Icons.zoom_in_rounded, tr('player.zoom_in'), () => image.zoomBy(1.5)),
          _btn(Icons.fit_screen_rounded, tr('player.zoom_fit'), image.fit),
          _btn(Icons.rotate_right_rounded, tr('player.rotate'), () => image.rotate(1)),
        ],
        if (_entries.length > 1 && _editor == null)
          _btn(_slideshow ? Icons.stop_circle_outlined : Icons.slideshow_rounded,
              tr(_slideshow ? 'player.slideshow_stop' : 'player.slideshow'), () => _setSlideshow(!_slideshow),
              on: _slideshow),
        if (_rec == null)
          _btn(Icons.fiber_manual_record_rounded, tr('rec.start'), _countdown > 0 ? null : () => unawaited(_startRecording())),
        _btn(Icons.brush_rounded, tr('ink.draw'), _set == null ? null : () => _editor == null ? _startDraw() : unawaited(_finishDraw()),
            on: _editor != null),
        PopupMenuButton<bool>(
          tooltip: tr('ink.shot'),
          icon: const Icon(Icons.camera_alt_rounded, color: Colors.white, size: 22),
          onSelected: (w) => unawaited(_shoot(withInk: w)),
          itemBuilder: (_) => [
            PopupMenuItem(value: true, child: Text(tr('ink.shot_with'))),
            PopupMenuItem(value: false, child: Text(tr('ink.shot_without'))),
          ],
        ),
        Badge(
          isLabelVisible: (_set?.notes.length ?? 0) > 0,
          label: Text('${_set?.notes.length ?? 0}'),
          offset: const Offset(-4, 4),
          backgroundColor: LrColors.safelight,
          textColor: Colors.black,
          child: _btn(Icons.format_list_bulleted_rounded, tr('ink.notes_key'), () => _showTab(_Tab.notes),
              on: (_fullscreen ? _peek : _side) && _tab == _Tab.notes),
        ),
        _btn(Icons.view_sidebar_rounded, tr('player.side'), _toggleSide, on: _fullscreen ? _peek : _side),
        _btn(Icons.send_rounded, tr('player.send'), () => _send(e)),
        PopupMenuButton<String>(
          tooltip: tr('ink.more'),
          icon: const Icon(Icons.more_vert_rounded, color: Colors.white, size: 22),
          onSelected: (v) {
            if (v == 'reveal') revealInExplorer(e.path);
            if (v == 'delete') unawaited(_delete(e));
            if (v == 'keys') unawaited(_shortcuts());
            if (v.startsWith('convert:')) _convert(e, ConvertPreset.values.firstWhere((p) => 'convert:${p.name}' == v));
          },
          itemBuilder: (_) => [
            if (item != null)
              for (final p in ConvertPreset.values) PopupMenuItem(value: 'convert:${p.name}', child: Text(tr('convert.to', {'preset': p.label}))),
            PopupMenuItem(value: 'reveal', child: Text(tr('common.show_in_folder'))),
            PopupMenuItem(value: 'keys', child: Text(tr('player.shortcuts'))),
            if (item != null) ...[
              const PopupMenuDivider(),
              PopupMenuItem(value: 'delete', child: Text(tr('lib.delete'), style: const TextStyle(color: LrColors.danger))),
            ],
          ],
        ),
        _btn(_fullscreen ? Icons.fullscreen_exit_rounded : Icons.fullscreen_rounded,
            tr(_fullscreen ? 'player.exit_fullscreen' : 'player.fullscreen'), () => _setFullscreen(!_fullscreen)),
      ]),
    );
  }

  Widget _pageView() => PageView.builder(
        controller: _pages,
        itemCount: _entries.length,
        onPageChanged: _changed,
        itemBuilder: (context, i) {
          final it = _entries[i];
          return it.video
              ? _VideoView(
                  key: ObjectKey(it),
                  entry: it,
                  services: widget.services,
                  active: i == _index,
                  chrome: _chrome,
                  overlay: _fullscreen,
                  register: _register,
                  notes: _shownNotes(it),
                  markers: [for (final n in _sets[it]?.notes ?? const <Note>[]) n.startMs],
                  editor: i == _index ? _editor : null,
                  startMs: _startAt.remove(it),
                  onEnded: _ended,
                  onClip: () => unawaited(_clip()),
                  onFullscreen: () => _setFullscreen(!_fullscreen),
                  onChanged: () {
                    if (mounted) setState(() {});
                  },
                )
              : _ImageView(
                  key: ObjectKey(it),
                  entry: it,
                  services: widget.services,
                  register: _register,
                  notes: _shownNotes(it),
                  editor: i == _index ? _editor : null,
                  onFullscreen: () => _setFullscreen(!_fullscreen),
                  onChanged: () {
                    if (mounted) setState(() {});
                  },
                );
        },
      );

  Widget _arrows() => Positioned.fill(
        child: IgnorePointer(
          ignoring: !_chrome,
          child: AnimatedOpacity(
            opacity: _chrome ? 1 : 0,
            duration: const Duration(milliseconds: 200),
            child: Stack(children: [
              if (_index > 0)
                Align(
                  alignment: Alignment.centerLeft,
                  child: IconButton(color: Colors.white70, iconSize: 40, onPressed: () => _go(-1), icon: const Icon(Icons.chevron_left)),
                ),
              if (_index < _entries.length - 1)
                Align(
                  alignment: Alignment.centerRight,
                  child: IconButton(color: Colors.white70, iconSize: 40, onPressed: () => _go(1), icon: const Icon(Icons.chevron_right)),
                ),
            ]),
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    // One shape in and out of full screen, so the video keeps playing.
    final Widget main = Column(children: [
      if (_fullscreen) const SizedBox.shrink() else ExcludeFocus(child: _topBar()),
      Expanded(
        child: Stack(children: [
          Positioned.fill(child: _pageView()),
          if (_editor == null) _arrows(),
          if (_editor != null)
            Positioned(
              left: 0,
              right: 0,
              top: _fullscreen ? 56 : 0,
              child: Center(
                child: ExcludeFocus(
                  child: InkToolbar(editor: _editor!, onDone: () => unawaited(_finishDraw()), onCancel: () => unawaited(_cancelDraw())),
                ),
              ),
            ),
          if (_rec != null)
            Positioned(
              left: 0,
              right: 0,
              top: _editor != null ? 64 : (_fullscreen ? 56 : 0),
              child: Center(
                child: ExcludeFocus(
                  child: RecordingBar(
                    elapsed: () => _rec?.clock.elapsedMilliseconds ?? 0,
                    paused: _rec!.paused,
                    level: () => _rec?.mic.level() ?? 0,
                    onPause: () => unawaited(_pauseRecording()),
                    onStop: () => unawaited(_stopRecording()),
                  ),
                ),
              ),
            ),
          if (_countdown > 0)
            Positioned.fill(
              child: IgnorePointer(
                child: Container(
                  color: const Color(0x66000000),
                  alignment: Alignment.center,
                  child: Text('$_countdown', style: const TextStyle(fontSize: 120, fontWeight: FontWeight.w700, color: Colors.white)),
                ),
              ),
            ),
          // Full screen: the list slides out at the right edge.
          if (_fullscreen && !_peek)
            Positioned(
              right: 0,
              top: 80,
              bottom: 80,
              width: 10,
              child: MouseRegion(opaque: false, onEnter: (_) => setState(() => _peek = true)),
            ),
          if (_fullscreen && _peek)
            Positioned(
              right: 0,
              top: 56,
              bottom: 0,
              child: MouseRegion(onExit: (_) => setState(() => _peek = false), child: _sideBox()),
            ),
          if (_fullscreen)
            Positioned(
              left: 0,
              right: 0,
              top: 0,
              child: IgnorePointer(
                ignoring: !_chrome,
                child: AnimatedOpacity(
                  opacity: _chrome ? 1 : 0,
                  duration: const Duration(milliseconds: 200),
                  child: ExcludeFocus(child: _topBar()),
                ),
              ),
            ),
        ]),
      ),
    ]);
    return PopScope(
      // Recording: leaving asks first (stop, then save or not).
      canPop: _rec == null,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_stopRecording());
      },
      child: Focus(
      focusNode: _focus,
      autofocus: true,
      onKeyEvent: _key,
      child: MouseRegion(
        onHover: (_) => _poke(),
        cursor: _fullscreen && !_chrome ? SystemMouseCursors.none : MouseCursor.defer,
        child: Scaffold(
          backgroundColor: Colors.black,
          body: Row(children: [
            Expanded(child: main),
            if (!_fullscreen && _side) _sideBox(),
          ]),
        ),
      ),
      ),
    );
  }

  // ------------------------------------------------------- list on the right

  Widget _tabButton(_Tab t, String label, int count) {
    final on = _tab == t;
    return Expanded(
      child: InkWell(
        onTap: () => _openTab(t),
        child: Container(
          height: 42,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: on ? LrColors.safelight : Colors.transparent, width: 2)),
          ),
          child: Text(count > 0 ? '$label $count' : label,
              style: TextStyle(fontSize: 13.5, fontWeight: on ? FontWeight.w600 : FontWeight.w400, color: on ? LrColors.text : LrColors.muted)),
        ),
      ),
    );
  }

  Widget _scopeSwitch() => SegmentedButton<bool>(
        showSelectedIcon: false,
        style: const ButtonStyle(visualDensity: VisualDensity.compact, tapTargetSize: MaterialTapTargetSize.shrinkWrap),
        segments: [
          ButtonSegment(value: false, label: Text(tr('player.notes_this'), style: const TextStyle(fontSize: 12))),
          ButtonSegment(value: true, label: Text(tr('player.notes_all'), style: const TextStyle(fontSize: 12))),
        ],
        selected: {_notesAll},
        onSelectionChanged: (v) => setState(() => _notesAll = v.first),
      );

  Widget _sideBox() {
    final e = _entry;
    final all = _notesAll ? _allNotes() : const <(int, Note)>[];
    final Widget body = switch (_tab) {
      _Tab.list => _EntryList(
          key: const ValueKey('list'),
          services: widget.services,
          entries: _entries,
          index: _index,
          onPick: (i) => _pages.jumpToPage(i),
        ),
      _Tab.notes => _notesAll
          ? _AllNotes(
              services: widget.services,
              entries: _entries,
              notes: all,
              current: _index,
              header: _scopeSwitch(),
              onPick: _goToNote,
            )
          : NotesPanel(
              key: ObjectKey(e),
              services: widget.services,
              entry: e,
              set: _set,
              leading: Align(alignment: Alignment.centerLeft, child: _scopeSwitch()),
              aspect: () {
                final sz = _active?.pictureSize;
                return sz == null || sz.height == 0 ? 16 / 9 : sz.width / sz.height;
              }(),
              showInk: _showInk,
              onShowInk: (v) => setState(() => _showInk = v),
              onAction: (n, a) => unawaited(_noteAction(n, a)),
              onHold: (n, ms) => unawaited(_hold(n, ms)),
              onClipAround: () => unawaited(_clipAround()),
              narrations: _narrationsHere,
              onNarration: (n, a) => unawaited(_narrationAction(n, a)),
            ),
      _Tab.info => _InfoPanel(key: ObjectKey(e), entry: e, services: widget.services, from: e.item == null ? null : _from(e.item!)),
    };
    return Container(
      width: 330,
      decoration: const BoxDecoration(color: LrColors.surface, border: Border(left: BorderSide(color: LrColors.line))),
      child: Column(children: [
        Row(children: [
          _tabButton(_Tab.list, tr('player.tab_list'), _entries.length > 1 ? _entries.length : 0),
          _tabButton(_Tab.notes, tr('ink.notes'), _set?.notes.length ?? 0),
          _tabButton(_Tab.info, tr('player.tab_info'), 0),
          IconButton(
            tooltip: tr('player.side_close'),
            onPressed: _toggleSide,
            icon: const Icon(Icons.chevron_right_rounded, size: 20),
          ),
        ]),
        const Divider(height: 1),
        Expanded(child: body),
      ]),
    );
  }
}

// ---------------------------------------------------------------- photos

class _ImageView extends StatefulWidget {
  const _ImageView({
    super.key,
    required this.entry,
    required this.services,
    required this.register,
    required this.notes,
    required this.editor,
    required this.onFullscreen,
    required this.onChanged,
  });

  final PlayerEntry entry;
  final AppServices services;
  final void Function(PlayerEntry, _ViewHandle?) register;

  /// Annotations drawn on it.
  final List<Note> notes;

  /// Drawing on it now.
  final InkEditor? editor;
  final VoidCallback onFullscreen;
  final VoidCallback onChanged;

  @override
  State<_ImageView> createState() => _ImageViewState();
}

class _ImageViewState extends State<_ImageView> implements _ViewHandle {
  final TransformationController _tc = TransformationController();
  Future<File?>? _preview;
  int _turns = 0;
  Size _box = Size.zero;
  Offset? _tapAt;

  /// The picture's own size (the marks sit exactly on it).
  Size? _size;
  ImageStream? _stream;
  ImageStreamListener? _listener;

  /// Playing the Live Photo's video over the still.
  bool _playingLive = false;

  PlayerEntry get _e => widget.entry;
  bool get _direct => nativelyDecodableImages.contains(_e.extension);

  @override
  int get nowMs => 0;

  @override
  int get durationMs => 0;

  @override
  bool get playing => false;

  @override
  double get rate => 1;

  @override
  Rect get zoomRect => _turns != 0 ? const Rect.fromLTWH(0, 0, 1, 1) : _visibleRect(_tc.value, _box, _size);

  @override
  FreezeNow? get freezeNow => null;

  @override
  Size? get pictureSize => _size;

  @override
  void seekTo(int ms, {bool play = false}) {}

  @override
  void initState() {
    super.initState();
    widget.register(_e, this);
    if (_direct) {
      _measure(File(_e.path));
    } else {
      final ff = widget.services.ffmpeg;
      final item = _e.item;
      _preview = item != null ? ff.preview(item) : ff.previewFile(_e.path, size: _e.size, modifiedMs: _e.modifiedMs);
      _preview!.then((f) {
        if (f != null && mounted) _measure(f);
      });
    }
    // The page's zoom buttons need this view registered first.
    WidgetsBinding.instance.addPostFrameCallback((_) => widget.onChanged());
  }

  /// The same picture Image.file shows (decoded once, shared).
  void _measure(File f) {
    final stream = FileImage(f).resolve(ImageConfiguration.empty);
    final l = ImageStreamListener((info, _) {
      final sz = Size(info.image.width.toDouble(), info.image.height.toDouble());
      if (mounted && sz != _size) {
        setState(() => _size = sz);
        widget.onChanged();
      }
    }, onError: (_, _) {});
    _stream = stream;
    _listener = l;
    stream.addListener(l);
  }

  @override
  void dispose() {
    final l = _listener;
    if (l != null) _stream?.removeListener(l);
    widget.register(_e, null);
    _tc.dispose();
    super.dispose();
  }

  void zoomBy(double factor, [Offset? at]) {
    final focal = at ?? _box.center(Offset.zero);
    final m = _tc.value;
    final now = m.getMaxScaleOnAxis();
    final target = (now * factor).clamp(1.0, 12.0);
    final f = target / now;
    if ((f - 1).abs() < 0.001) return;
    _tc.value = Matrix4.translationValues(focal.dx, focal.dy, 0)
        .multiplied(Matrix4.diagonal3Values(f, f, 1))
        .multiplied(Matrix4.translationValues(-focal.dx, -focal.dy, 0))
        .multiplied(m);
  }

  void fit() => _tc.value = Matrix4.identity();

  void rotate(int quarter) => setState(() {
        _turns = (_turns + quarter) % 4;
        _tc.value = Matrix4.identity();
      });

  @override
  bool onKey(KeyEvent e) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) return false;
    final k = e.logicalKey;
    if (k == LogicalKeyboardKey.equal || k == LogicalKeyboardKey.add || k == LogicalKeyboardKey.numpadAdd) {
      zoomBy(1.25);
    } else if (k == LogicalKeyboardKey.minus || k == LogicalKeyboardKey.numpadSubtract) {
      zoomBy(1 / 1.25);
    } else if (k == LogicalKeyboardKey.digit0 || k == LogicalKeyboardKey.numpad0) {
      fit();
    } else if (k == LogicalKeyboardKey.keyR && e is KeyDownEvent && widget.editor == null) {
      rotate(HardwareKeyboard.instance.isShiftPressed ? 3 : 1);
    } else {
      return false;
    }
    return true;
  }

  Widget _cannot() => Center(
        child: Text(
          widget.services.ffmpeg.available ? tr('viewer.cannot_decode') : tr('viewer.needs_ffmpeg', {'ext': _e.extension.toUpperCase()}),
          style: const TextStyle(color: Colors.white70),
        ),
      );

  Widget _picture(File f) => Image.file(
        f,
        fit: BoxFit.contain,
        filterQuality: FilterQuality.medium,
        gaplessPlayback: true,
        errorBuilder: (_, _, _) => _cannot(),
      );

  Widget _still() {
    if (_direct) return _picture(File(_e.path));
    return FutureBuilder<File?>(
      future: _preview,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) return const Center(child: CircularProgressIndicator());
        final f = snap.data;
        return f == null ? _cannot() : _picture(f);
      },
    );
  }

  /// The picture with its marks on top, exactly its shape.
  Widget _withInk() {
    final sz = _size;
    if (sz == null || sz.height == 0) return _still();
    return AspectRatio(
      aspectRatio: sz.width / sz.height,
      child: Stack(fit: StackFit.expand, children: [
        _still(),
        InkLayer(notes: widget.notes, video: false, editor: widget.editor),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final drawing = widget.editor != null;
    final view = LayoutBuilder(builder: (context, c) {
      _box = Size(c.maxWidth, c.maxHeight);
      return GestureDetector(
        onDoubleTapDown: drawing ? null : (d) => _tapAt = d.localPosition,
        onDoubleTap: drawing
            ? null
            : () {
                if (_tc.value.getMaxScaleOnAxis() > 1.01) {
                  fit();
                } else {
                  zoomBy(2.5, _tapAt);
                }
              },
        child: InteractiveViewer(
          transformationController: _tc,
          minScale: 1,
          maxScale: 12,
          // While drawing a drag draws (zoom with + − first).
          panEnabled: !drawing,
          scaleEnabled: !drawing,
          child: SizedBox(
            width: c.maxWidth,
            height: c.maxHeight,
            child: Center(child: RotatedBox(quarterTurns: _turns, child: _withInk())),
          ),
        ),
      );
    });
    final item = _e.item;
    final live = item == null || drawing ? null : widget.services.library.liveFor(item);
    // One shape with or without the Live Photo button (zoom is kept).
    return Stack(children: [
      Positioned.fill(child: view),
      if (live != null && _playingLive)
        Positioned.fill(
          child: _LivePlayback(
            path: widget.services.library.absPath(live),
            onDone: () {
              if (mounted) setState(() => _playingLive = false);
            },
          ),
        ),
      if (live != null)
      Positioned(
        left: 16,
        bottom: 16,
        child: MouseRegion(
          // Like pressing on a Live Photo on iPhone: hover (or click) plays it.
          onEnter: (_) => setState(() => _playingLive = true),
          child: ActionChip(
            avatar: const Icon(Icons.motion_photos_on_rounded, size: 18),
            label: Text(tr('viewer.live')),
            onPressed: () => setState(() => _playingLive = !_playingLive),
          ),
        ),
      ),
    ]);
  }
}

/// Plays a Live Photo's video once (with sound), then hands back to the still.
class _LivePlayback extends StatefulWidget {
  const _LivePlayback({required this.path, required this.onDone});

  final String path;
  final VoidCallback onDone;

  @override
  State<_LivePlayback> createState() => _LivePlaybackState();
}

class _LivePlaybackState extends State<_LivePlayback> {
  late final Player _player = Player();
  late final VideoController _controller = VideoController(_player);
  StreamSubscription<bool>? _sub;

  @override
  void initState() {
    super.initState();
    _sub = _player.stream.completed.listen((done) {
      if (done) widget.onDone();
    });
    _player.open(Media(widget.path));
  }

  @override
  void dispose() {
    _sub?.cancel();
    _player.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: widget.onDone,
        child: Video(controller: _controller, controls: NoVideoControls, fill: Colors.black),
      );
}

// ------------------------------------------------------------------ info

class _InfoPanel extends StatefulWidget {
  const _InfoPanel({super.key, required this.entry, required this.services, this.from});

  final PlayerEntry entry;
  final AppServices services;
  final String? from;

  @override
  State<_InfoPanel> createState() => _InfoPanelState();
}

class _InfoPanelState extends State<_InfoPanel> {
  late final Future<ProbeInfo> _probe = widget.services.ffmpeg.probe(widget.entry.path);

  Widget _row(String label, String value) => Padding(
        padding: const EdgeInsets.only(bottom: 14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label, style: const TextStyle(fontSize: 12, color: LrColors.muted)),
          const SizedBox(height: 2),
          SelectableText(value, style: const TextStyle(fontSize: 13.5)),
        ]),
      );

  @override
  Widget build(BuildContext context) {
    final e = widget.entry;
    return Material(
      color: Colors.transparent,
      child: FutureBuilder<ProbeInfo>(
        future: _probe,
        builder: (context, snap) {
          final p = snap.data;
          final codec = [
            if (p?.codec != null) p!.codec!.toUpperCase(),
            if (p?.isHdr ?? false) 'HDR',
          ];
          return ListView(padding: const EdgeInsets.all(20), children: [
            Text(tr('player.info'), style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            const SizedBox(height: 18),
            _row(tr('player.info_name'), e.name),
            _row(tr(e.item != null ? 'player.info_taken' : 'player.info_modified'), formatDate(e.time)),
            _row(tr('player.info_size'), formatBytes(e.size)),
            if (p?.width != null && p?.height != null) _row(tr('player.info_dims'), '${p!.width} × ${p.height}'),
            if (e.video && p?.durationSec != null)
              _row(tr('player.info_length'), playerTime(Duration(milliseconds: (p!.durationSec! * 1000).round()))),
            if (codec.isNotEmpty) _row(tr('player.info_codec'), codec.join(' · ')),
            if (widget.from != null) _row(tr('player.info_from'), widget.from!),
            _row(tr('player.info_where'), e.path),
          ]);
        },
      ),
    );
  }
}
