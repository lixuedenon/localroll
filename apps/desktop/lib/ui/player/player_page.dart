// apps/desktop/lib/ui/player/player_page.dart
import 'dart:async';
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
import '../../services/converter.dart';
import '../../services/ffmpeg.dart';
import '../../services/library_index.dart';
import '../../services/network.dart';
import '../../services/peers.dart';
import '../../services/player_memory.dart';
import '../app_nav.dart';
import '../format.dart';
import '../send_page.dart';
import '../theme.dart';
import '../trash_actions.dart';
import 'player_entry.dart';

part 'player_video.dart';

/// Opens files from this PC (Explorer's "Open with", drag and drop, the
/// open dialog). One file: the photos and videos of its folder come along,
/// so the arrows go through them.
Future<void> openInPlayer(BuildContext context, AppServices s, List<String> paths) async {
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
  await openPlayer(context, s, entries, at);
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

Future<void> openPlayer(BuildContext context, AppServices s, List<PlayerEntry> entries, int index) =>
    Navigator.of(context).push(MaterialPageRoute(
      settings: const RouteSettings(name: 'player'),
      builder: (_) => PlayerPage(services: s, entries: entries, initialIndex: index.clamp(0, entries.length - 1)),
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
}

/// The one player for photos and videos — library, received files, files
/// anywhere on this PC. Videos (HEVC, HDR, Dolby Vision, MKV…) play
/// through libmpv; HEIC, AVIF, TIFF, camera RAW are shown as they are.
class PlayerPage extends StatefulWidget {
  const PlayerPage({super.key, required this.services, required this.entries, required this.initialIndex});

  final AppServices services;
  final List<PlayerEntry> entries;
  final int initialIndex;

  @override
  State<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends State<PlayerPage> {
  late final PageController _pages = PageController(initialPage: widget.initialIndex);
  late int _index = widget.initialIndex;
  late final List<PlayerEntry> _entries = List.of(widget.entries);
  final FocusNode _focus = FocusNode(debugLabel: 'player');
  final Map<PlayerEntry, _ViewHandle> _handles = {};

  bool _info = false;
  bool _fullscreen = false;

  /// Bars shown (in full screen they step aside when the mouse rests).
  bool _chrome = true;
  Timer? _hide;

  bool _slideshow = false;
  Timer? _slide;

  PlayerEntry get _entry => _entries[_index];
  _ViewHandle? get _active => _handles[_entry];
  PlayerMemory get _memory => widget.services.player;

  @override
  void initState() {
    super.initState();
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
    setState(() => _index = i);
    _memory.opened(recentOf(_entries[i]));
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
    if (e is KeyUpEvent) return KeyEventResult.ignored;
    final k = e.logicalKey;
    final shift = HardwareKeyboard.instance.isShiftPressed;
    final down = e is KeyDownEvent;
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
    if (_active?.onKey(e) ?? false) return KeyEventResult.handled;
    if (!down) return KeyEventResult.ignored;
    if (k == LogicalKeyboardKey.keyF || k == LogicalKeyboardKey.f11) {
      _setFullscreen(!_fullscreen);
    } else if (k == LogicalKeyboardKey.keyI) {
      setState(() => _info = !_info);
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
        if (_entries.length > 1)
          _btn(_slideshow ? Icons.stop_circle_outlined : Icons.slideshow_rounded,
              tr(_slideshow ? 'player.slideshow_stop' : 'player.slideshow'), () => _setSlideshow(!_slideshow),
              on: _slideshow),
        _btn(Icons.info_outline_rounded, tr('player.info'), () => setState(() => _info = !_info), on: _info),
        _btn(Icons.send_rounded, tr('player.send'), () => _send(e)),
        if (item != null)
          PopupMenuButton<ConvertPreset>(
            tooltip: tr('convert.keep_original_tooltip'),
            icon: const Icon(Icons.auto_fix_high_rounded, color: Colors.white, size: 22),
            onSelected: (p) => _convert(e, p),
            itemBuilder: (_) => [
              for (final p in ConvertPreset.values) PopupMenuItem(value: p, child: Text(tr('convert.to', {'preset': p.label}))),
            ],
          ),
        _btn(Icons.folder_open_rounded, tr('common.show_in_folder'), () => revealInExplorer(e.path)),
        if (item != null) _btn(Icons.delete_outline_rounded, tr('lib.delete'), () => _delete(e)),
        _btn(Icons.keyboard_rounded, tr('player.shortcuts'), _shortcuts),
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
                  onEnded: _ended,
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
          _arrows(),
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
    return Focus(
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
            if (_info) _InfoPanel(key: ObjectKey(_entry), entry: _entry, services: widget.services, from: _entry.item == null ? null : _from(_entry.item!)),
          ]),
        ),
      ),
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
    required this.onFullscreen,
    required this.onChanged,
  });

  final PlayerEntry entry;
  final AppServices services;
  final void Function(PlayerEntry, _ViewHandle?) register;
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

  /// Playing the Live Photo's video over the still.
  bool _playingLive = false;

  PlayerEntry get _e => widget.entry;
  bool get _direct => nativelyDecodableImages.contains(_e.extension);

  @override
  void initState() {
    super.initState();
    widget.register(_e, this);
    if (!_direct) {
      final ff = widget.services.ffmpeg;
      final item = _e.item;
      _preview = item != null ? ff.preview(item) : ff.previewFile(_e.path, size: _e.size, modifiedMs: _e.modifiedMs);
    }
    // The page's zoom buttons need this view registered first.
    WidgetsBinding.instance.addPostFrameCallback((_) => widget.onChanged());
  }

  @override
  void dispose() {
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
    } else if (k == LogicalKeyboardKey.keyR && e is KeyDownEvent) {
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

  @override
  Widget build(BuildContext context) {
    final view = LayoutBuilder(builder: (context, c) {
      _box = Size(c.maxWidth, c.maxHeight);
      return GestureDetector(
        onDoubleTapDown: (d) => _tapAt = d.localPosition,
        onDoubleTap: () {
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
          child: SizedBox(
            width: c.maxWidth,
            height: c.maxHeight,
            child: Center(child: RotatedBox(quarterTurns: _turns, child: _still())),
          ),
        ),
      );
    });
    final item = _e.item;
    final live = item == null ? null : widget.services.library.liveFor(item);
    if (live == null) return view;
    return Stack(children: [
      Positioned.fill(child: view),
      if (_playingLive)
        Positioned.fill(
          child: _LivePlayback(
            path: widget.services.library.absPath(live),
            onDone: () {
              if (mounted) setState(() => _playingLive = false);
            },
          ),
        ),
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
    return Container(
      width: 300,
      decoration: const BoxDecoration(color: LrColors.surface, border: Border(left: BorderSide(color: LrColors.line))),
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
