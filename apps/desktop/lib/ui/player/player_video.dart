// apps/desktop/lib/ui/player/player_video.dart
part of 'player_page.dart';

/// Speeds offered (mpv keeps the voice's pitch).
const List<double> _speeds = [0.1, 0.25, 0.5, 0.75, 1, 1.25, 1.5, 2, 3, 4];

String _speedLabel(double r) => '${r == r.roundToDouble() ? r.toStringAsFixed(0) : r.toString()}×';

class _VideoView extends StatefulWidget {
  const _VideoView({
    super.key,
    required this.entry,
    required this.services,
    required this.active,
    required this.chrome,
    required this.overlay,
    required this.register,
    required this.notes,
    required this.markers,
    required this.editor,
    this.startMs,
    required this.onEnded,
    required this.onClip,
    required this.onFullscreen,
    required this.onChanged,
  });

  final PlayerEntry entry;
  final AppServices services;

  /// The page shown now (others pause).
  final bool active;

  /// Controls shown.
  final bool chrome;

  /// Full screen: controls float over the picture.
  final bool overlay;
  final void Function(PlayerEntry, _ViewHandle?) register;

  /// Annotations shown on it (each at its time).
  final List<Note> notes;

  /// Where annotations start (dots on the time line).
  final List<int> markers;

  /// Drawing on it now.
  final InkEditor? editor;

  /// Start here instead of where it was left.
  final int? startMs;
  final VoidCallback onEnded;

  /// Cut the clip chosen (ms).
  final void Function(int startMs, int endMs) onClip;
  final VoidCallback onFullscreen;
  final VoidCallback onChanged;

  @override
  State<_VideoView> createState() => _VideoViewState();
}

class _VideoViewState extends State<_VideoView> implements _ViewHandle {
  late final Player _player = Player();
  late final VideoController _controller = VideoController(_player);
  final TransformationController _tc = TransformationController();
  final List<StreamSubscription<Object?>> _subs = [];
  Timer? _saveTimer;

  /// A-B loop: start and end (mpv repeats between them).
  Duration? _a, _b;

  /// The clip being chosen on the time line (ms), or null.
  int? _cin, _cout;

  /// A short line over the picture ("1.5×", "Continued from 1:23").
  String? _note;
  VoidCallback? _noteAction;
  Timer? _noteTimer;

  PlayerMemory get _memory => widget.services.player;
  PlayerEntry get _e => widget.entry;

  /// Where it is (the marks follow it).
  final ValueNotifier<int> _ms = ValueNotifier(0);
  int _lastMs = 0;

  /// Stopped at this annotation already (it plays on from there).
  String? _pausedFor;
  Size? _size;

  @override
  int get nowMs => _player.state.position.inMilliseconds;

  @override
  int get durationMs => _player.state.duration.inMilliseconds;

  @override
  bool get playing => _player.state.playing;

  @override
  double get rate => _player.state.rate;

  @override
  Rect get zoomRect => _visibleRect(_tc.value, _box, _size);

  /// The picture area's size (for what part is zoomed in on).
  Size _box = Size.zero;

  @override
  FreezeNow? get freezeNow => _freeze.value;

  /// Replaying marks drawn while paused (the video stands still for it).
  final ValueNotifier<FreezeNow?> _freeze = ValueNotifier(null);
  Timer? _freezeTimer;
  final Stopwatch _freezeClock = Stopwatch();

  /// The last stop made (not made again until played through again).
  String? _frozeFor;
  int _frozeAt = -1;

  void _startFreeze(FreezePlan f) {
    _frozeFor = '${f.noteId}|${f.atMs}';
    _frozeAt = f.atMs;
    unawaited(() async {
      await _player.pause();
      await _player.seek(Duration(milliseconds: f.atMs));
    }());
    _freeze.value = (plan: f, elapsedMs: 0);
    _freezeClock
      ..reset()
      ..start();
    _freezeTimer?.cancel();
    _freezeTimer = Timer.periodic(const Duration(milliseconds: 16), (_) {
      final e = _freezeClock.elapsedMilliseconds;
      if (e >= f.totalMs) {
        _endFreeze(play: true);
      } else {
        _freeze.value = (plan: f, elapsedMs: e);
      }
    });
  }

  /// [play]: the replay ended by itself; else the person played or moved on.
  void _endFreeze({required bool play}) {
    if (_freeze.value == null) return;
    _freezeTimer?.cancel();
    _freezeTimer = null;
    _freeze.value = null;
    if (play && mounted) unawaited(_player.play());
  }

  @override
  Size? get pictureSize => _size;

  @override
  void seekTo(int ms, {bool play = false}) {
    unawaited(() async {
      await _player.seek(Duration(milliseconds: ms));
      if (play) await _player.play();
    }());
  }

  void _position(Duration d) {
    final now = d.inMilliseconds;
    _ms.value = now;
    final fz = _freeze.value;
    if (fz != null && (now - fz.plan.atMs).abs() > 400) _endFreeze(play: false);
    if (_frozeAt >= 0 && now + 300 < _frozeAt) {
      _frozeFor = null;
      _frozeAt = -1;
    }
    // Drawn while paused: stop there and draw it again (playing on, not jumping).
    final playingOn = widget.editor == null && _player.state.playing && now - _lastMs < 1500;
    if (playingOn && _freeze.value == null) {
      for (final n in widget.notes) {
        for (final f in n.freezes) {
          final crossed = (f.atMs > _lastMs || (_lastMs == 0 && f.atMs == 0)) && f.atMs <= now;
          if (crossed && _frozeFor != '${f.noteId}|${f.atMs}') {
            _startFreeze(f);
            _pausedFor = n.id;
            _lastMs = now;
            return;
          }
        }
      }
    }
    // "Stop at each annotation": only while playing on, not when jumping.
    if (_memory.pauseAtNotes && widget.editor == null && _player.state.playing && now > _lastMs && now - _lastMs < 1500) {
      for (final n in widget.notes) {
        if (n.startMs > _lastMs && n.startMs <= now && _pausedFor != n.id) {
          _pausedFor = n.id;
          unawaited(_player.pause());
          _show(n.name, seconds: 3);
          break;
        }
      }
    }
    _lastMs = now;
  }

  void _dims() {
    final w = _player.state.width, h = _player.state.height;
    if (w == null || h == null || w <= 0 || h <= 0) return;
    final sz = Size(w.toDouble(), h.toDouble());
    if (sz != _size && mounted) {
      setState(() => _size = sz);
      widget.onChanged();
    }
  }

  NativePlayer? get _mpv {
    final p = _player.platform;
    return p is NativePlayer ? p : null;
  }

  @override
  void initState() {
    super.initState();
    widget.register(_e, this);
    unawaited(_open());
  }

  Future<void> _open() async {
    final asked = widget.startMs;
    final from = asked != null ? Duration(milliseconds: asked) : _memory.positionOf(_e.key);
    _subs.add(_player.stream.position.listen(_position));
    // Played by hand during a replay: the replay ends.
    _subs.add(_player.stream.playing.listen((on) {
      if (on && _freeze.value != null && _freezeClock.elapsedMilliseconds > 300) _endFreeze(play: false);
    }));
    _subs.add(_player.stream.width.listen((_) => _dims()));
    _subs.add(_player.stream.height.listen((_) => _dims()));
    _subs.add(_player.stream.completed.listen((done) {
      if (done && mounted) widget.onEnded();
    }));
    _subs.add(_player.stream.error.listen((e) => DiagLog.log('player', 'mpv: $e')));
    await _player.setVolume(_memory.volume);
    if (_memory.endMode == EndMode.repeat) await _player.setPlaylistMode(PlaylistMode.single);
    await _player.open(Media(_e.path, start: from), play: widget.active);
    if (asked == null && from != null && mounted) {
      _show(tr('player.resumed', {'time': playerTime(from)}), action: () {
        unawaited(_player.seek(Duration.zero));
        _hideNote();
      }, seconds: 6);
    }
    _saveTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (_player.state.playing) _save();
    });
    if (widget.active) _memory.saveOpen = _save;
  }

  void _save() {
    final dur = _player.state.duration;
    if (dur <= Duration.zero) return;
    _memory.setPosition(_e.key, _player.state.position, dur, entry: recentOf(_e));
  }

  @override
  void didUpdateWidget(_VideoView old) {
    super.didUpdateWidget(old);
    if (old.active && !widget.active) {
      // Swiped away: pause so its sound stops, and remember where it was.
      unawaited(_player.pause());
      _save();
      if (_memory.saveOpen == _save) _memory.saveOpen = null;
    } else if (!old.active && widget.active) {
      unawaited(_player.play());
      _memory.saveOpen = _save;
    }
  }

  @override
  void dispose() {
    _save();
    if (_memory.saveOpen == _save) _memory.saveOpen = null;
    widget.register(_e, null);
    _saveTimer?.cancel();
    _noteTimer?.cancel();
    for (final s in _subs) {
      unawaited(s.cancel());
    }
    _tc.dispose();
    _ms.dispose();
    _freezeTimer?.cancel();
    _freeze.dispose();
    unawaited(_player.dispose());
    super.dispose();
  }

  void _show(String text, {VoidCallback? action, int seconds = 2}) {
    _noteTimer?.cancel();
    setState(() {
      _note = text;
      _noteAction = action;
    });
    _noteTimer = Timer(Duration(seconds: seconds), _hideNote);
  }

  void _hideNote() {
    _noteTimer?.cancel();
    if (mounted) {
      setState(() {
        _note = null;
        _noteAction = null;
      });
    }
  }

  // ------------------------------------------------------------- controls

  Future<void> _seekBy(Duration d) async {
    final dur = _player.state.duration;
    var to = _player.state.position + d;
    if (to < Duration.zero) to = Duration.zero;
    if (dur > Duration.zero && to > dur) to = dur;
    await _player.seek(to);
  }

  /// One picture on or back (it pauses).
  Future<void> _frame(bool forward) async {
    try {
      await _mpv?.command([forward ? 'frame-step' : 'frame-back-step']);
    } catch (_) {}
  }

  Future<void> _setRate(double r) async {
    await _player.setRate(r);
    if (mounted) _show(_speedLabel(r));
  }

  void _stepRate(int dir) {
    final now = _player.state.rate;
    var i = _speeds.indexWhere((s) => s >= now - 0.001);
    if (i < 0) i = _speeds.length - 1;
    if (dir > 0 && (_speeds[i] - now).abs() < 0.001) i++;
    if (dir < 0) i--;
    unawaited(_setRate(_speeds[i.clamp(0, _speeds.length - 1)]));
  }

  String _secs(Duration d) => (d.inMicroseconds / 1e6).toStringAsFixed(3);

  /// Set A, then B (it loops between them), then off.
  Future<void> _abStep() async {
    final mpv = _mpv;
    if (mpv == null) return;
    final pos = _player.state.position;
    try {
      if (_a == null) {
        _a = pos;
        await mpv.setProperty('ab-loop-a', _secs(pos));
        _show(tr('player.ab_set_a'), seconds: 3);
      } else if (_b == null && pos > _a!) {
        _b = pos;
        await mpv.setProperty('ab-loop-b', _secs(pos));
        _show(tr('player.ab_on', {'a': playerTime(_a!), 'b': playerTime(pos)}), seconds: 3);
        await _player.seek(_a!);
      } else {
        _a = null;
        _b = null;
        await mpv.setProperty('ab-loop-a', 'no');
        await mpv.setProperty('ab-loop-b', 'no');
        _show(tr('player.ab_off'));
      }
    } catch (_) {}
    if (mounted) setState(() {});
  }

  Future<void> _setVolume(double v) async {
    await _player.setVolume(v);
    _memory.setVolume(v);
  }

  Future<void> _setEnd(EndMode m) async {
    _memory.setEndMode(m);
    await _player.setPlaylistMode(m == EndMode.repeat ? PlaylistMode.single : PlaylistMode.none);
    if (mounted) setState(() {});
  }

  void _zoom(double f) {
    final box = context.size ?? Size.zero;
    final focal = box.center(Offset.zero);
    final m = _tc.value;
    final now = m.getMaxScaleOnAxis();
    final target = (now * f).clamp(1.0, 8.0);
    final k = target / now;
    _tc.value = Matrix4.translationValues(focal.dx, focal.dy, 0)
        .multiplied(Matrix4.diagonal3Values(k, k, 1))
        .multiplied(Matrix4.translationValues(-focal.dx, -focal.dy, 0))
        .multiplied(m);
  }

  int get _durMs => _player.state.duration.inMilliseconds;

  @override
  void pause() => unawaited(_player.pause());

  @override
  void clipStep() {
    if (_cin != null && _cout != null) {
      widget.onClip(_cin!, _cout!);
      return;
    }
    final now = _player.state.position.inMilliseconds;
    final dur = _durMs;
    int a, b;
    if (_a != null && _b != null) {
      a = _a!.inMilliseconds;
      b = _b!.inMilliseconds;
    } else {
      a = now - _memory.clipBefore * 1000;
      b = now + _memory.clipAfter * 1000;
    }
    a = a.clamp(0, dur > 0 ? dur : a.abs());
    if (dur > 0) b = b.clamp(a + 1000, math.max(a + 1000, dur));
    setState(() {
      _cin = a;
      _cout = b;
    });
    _show(tr('clip.range_tip'), seconds: 5);
  }

  /// I / O: the clip starts / ends here.
  void _setClipEdge(bool start) {
    final now = _player.state.position.inMilliseconds;
    final dur = _durMs;
    setState(() {
      if (start) {
        _cin = now;
        if (_cout == null || _cout! <= now + 500) _cout = dur > 0 ? math.min(dur, now + _memory.clipAfter * 1000) : now + 10000;
      } else {
        _cout = now;
        if (_cin == null || _cin! >= now - 500) _cin = math.max(0, now - _memory.clipBefore * 1000);
      }
    });
    _show(tr(start ? 'clip.in_set' : 'clip.out_set', {'time': playerTime(Duration(milliseconds: start ? _cin! : _cout!))}));
  }

  void _clipEdges(int a, int b) => setState(() {
        _cin = a;
        _cout = b;
      });

  void _clipOff() => setState(() {
        _cin = null;
        _cout = null;
      });

  @override
  bool onKey(KeyEvent e) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) return false;
    final k = e.logicalKey;
    final down = e is KeyDownEvent;
    // I is the info panel unless a clip is being chosen.
    if (down && k == LogicalKeyboardKey.keyI && _cin != null && !HardwareKeyboard.instance.isControlPressed) {
      _setClipEdge(true);
      return true;
    }
    if (down && k == LogicalKeyboardKey.keyO && !HardwareKeyboard.instance.isControlPressed) {
      _setClipEdge(false);
      return true;
    }
    if (down && k == LogicalKeyboardKey.escape && _cin != null) {
      _clipOff();
      return true;
    }
    if (down && (k == LogicalKeyboardKey.space || k == LogicalKeyboardKey.keyK)) {
      unawaited(_player.playOrPause());
    } else if (k == LogicalKeyboardKey.arrowLeft) {
      unawaited(_seekBy(const Duration(seconds: -5)));
    } else if (k == LogicalKeyboardKey.arrowRight) {
      unawaited(_seekBy(const Duration(seconds: 5)));
    } else if (k == LogicalKeyboardKey.keyJ) {
      unawaited(_seekBy(const Duration(seconds: -10)));
    } else if (k == LogicalKeyboardKey.keyL) {
      unawaited(_seekBy(const Duration(seconds: 10)));
    } else if (k == LogicalKeyboardKey.comma) {
      unawaited(_frame(false));
    } else if (k == LogicalKeyboardKey.period) {
      unawaited(_frame(true));
    } else if (down && k == LogicalKeyboardKey.bracketLeft) {
      _stepRate(-1);
    } else if (down && k == LogicalKeyboardKey.bracketRight) {
      _stepRate(1);
    } else if (down && k == LogicalKeyboardKey.backspace) {
      unawaited(_setRate(1));
    } else if (down && k == LogicalKeyboardKey.keyA) {
      unawaited(_abStep());
    } else if (down && k == LogicalKeyboardKey.keyM) {
      unawaited(_setVolume(_player.state.volume == 0 ? 100 : 0));
    } else if (k == LogicalKeyboardKey.arrowUp || k == LogicalKeyboardKey.arrowDown) {
      final v = (_player.state.volume + (k == LogicalKeyboardKey.arrowUp ? 5 : -5)).clamp(0, 100).toDouble();
      unawaited(_setVolume(v));
      _show('${v.round()}%');
    } else if (k == LogicalKeyboardKey.equal || k == LogicalKeyboardKey.add || k == LogicalKeyboardKey.numpadAdd) {
      _zoom(1.25);
    } else if (k == LogicalKeyboardKey.minus || k == LogicalKeyboardKey.numpadSubtract) {
      _zoom(1 / 1.25);
    } else if (k == LogicalKeyboardKey.digit0 || k == LogicalKeyboardKey.numpad0) {
      _tc.value = Matrix4.identity();
    } else {
      return false;
    }
    return true;
  }

  // ------------------------------------------------------------------ view

  Widget _picture() {
    final drawing = widget.editor != null;
    final sz = _size;
    final video = Video(controller: _controller, controls: NoVideoControls, fill: Colors.black);
    return GestureDetector(
      onTap: drawing ? null : () => unawaited(_player.playOrPause()),
      onDoubleTap: drawing ? null : widget.onFullscreen,
      child: LayoutBuilder(builder: (context, c) {
        _box = Size(c.maxWidth, c.maxHeight);
        return InteractiveViewer(
        transformationController: _tc,
        minScale: 1,
        maxScale: 8,
        // While drawing a drag draws.
        panEnabled: !drawing,
        scaleEnabled: !drawing,
        child: sz == null
            ? video
            : Center(
                child: AspectRatio(
                  aspectRatio: sz.width / sz.height,
                  child: Stack(fit: StackFit.expand, children: [
                    video,
                    InkLayer(notes: widget.notes, video: true, clock: _ms, freeze: _freeze, editor: widget.editor),
                  ]),
                ),
              ),
      );
      }),
    );
  }

  Widget _noteView() => Align(
        alignment: const Alignment(0, -0.75),
        child: AnimatedOpacity(
          opacity: _note == null ? 0 : 1,
          duration: const Duration(milliseconds: 150),
          child: _note == null
              ? const SizedBox.shrink()
              : Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                  decoration: BoxDecoration(color: const Color(0xCC000000), borderRadius: BorderRadius.circular(18)),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Text(_note!, style: const TextStyle(color: Colors.white, fontSize: 14)),
                    if (_noteAction != null) ...[
                      const SizedBox(width: 10),
                      TextButton(onPressed: _noteAction, child: Text(tr('player.from_start'))),
                    ],
                  ]),
                ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    // Keys stay with the player (a focused slider would take the arrows).
    final bar = ExcludeFocus(
        child: _ControlBar(
      player: _player,
      a: _a,
      b: _b,
      endMode: _memory.endMode,
      markers: widget.markers,
      overlay: widget.overlay,
      onFrame: _frame,
      onSeekBy: _seekBy,
      onRate: (r) => unawaited(_setRate(r)),
      onAb: () => unawaited(_abStep()),
      onVolume: (v) => unawaited(_setVolume(v)),
      onEnd: (m) => unawaited(_setEnd(m)),
      clipIn: _cin,
      clipOut: _cout,
      onClip: clipStep,
      onClipEdges: _clipEdges,
      onClipOff: _clipOff,
      onFullscreen: widget.onFullscreen,
    ));
    // One shape in and out of full screen (the picture is not rebuilt).
    return Column(children: [
      Expanded(
        child: Stack(children: [
          Positioned.fill(child: _picture()),
          _noteView(),
          if (widget.overlay)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: IgnorePointer(
                ignoring: !widget.chrome,
                child: AnimatedOpacity(opacity: widget.chrome ? 1 : 0, duration: const Duration(milliseconds: 200), child: bar),
              ),
            ),
        ]),
      ),
      // Otherwise the controls have their own bar below: never covering it.
      if (widget.overlay) const SizedBox.shrink() else bar,
    ]);
  }
}

/// The clip being chosen on the time line.
const Color _clipColor = Color(0xFF5AB0FF);

/// Seek bar and buttons below a video.
class _ControlBar extends StatelessWidget {
  const _ControlBar({
    required this.player,
    required this.a,
    required this.b,
    required this.endMode,
    required this.markers,
    required this.overlay,
    required this.onFrame,
    required this.onSeekBy,
    required this.onRate,
    required this.onAb,
    required this.onVolume,
    required this.onEnd,
    required this.onClip,
    required this.onClipEdges,
    required this.onClipOff,
    required this.onFullscreen,
    this.clipIn,
    this.clipOut,
  });

  final Player player;

  /// The clip being chosen (ms).
  final int? clipIn, clipOut;
  final void Function(int, int) onClipEdges;
  final VoidCallback onClipOff;
  final Duration? a, b;
  final EndMode endMode;
  final List<int> markers;
  final bool overlay;
  final Future<void> Function(bool forward) onFrame;
  final Future<void> Function(Duration) onSeekBy;
  final ValueChanged<double> onRate;
  final VoidCallback onAb;
  final ValueChanged<double> onVolume;
  final ValueChanged<EndMode> onEnd;
  final VoidCallback onClip;
  final VoidCallback onFullscreen;

  Widget _icon(IconData i, String tip, VoidCallback? onTap, {bool on = false}) => IconButton(
        tooltip: tip,
        onPressed: onTap,
        color: on ? LrColors.safelight : Colors.white,
        icon: Icon(i, size: 22),
      );

  static String _endLabel(EndMode m) => switch (m) {
        EndMode.stop => tr('player.end_stop'),
        EndMode.next => tr('player.end_next'),
        EndMode.repeat => tr('player.end_repeat'),
      };

  static IconData _endIcon(EndMode m) => switch (m) {
        EndMode.stop => Icons.stop_rounded,
        EndMode.next => Icons.playlist_play_rounded,
        EndMode.repeat => Icons.repeat_one_rounded,
      };

  static String _trackName(String? title, String? language, int n) {
    final parts = [
      if (title != null && title.isNotEmpty) title,
      if (language != null && language.isNotEmpty) language,
    ];
    return parts.isEmpty ? tr('player.track_n', {'n': n}) : parts.join(' · ');
  }

  Widget _tracks() => StreamBuilder<Tracks>(
        stream: player.stream.tracks,
        initialData: player.state.tracks,
        builder: (context, snap) {
          bool real(String id) => id != 'auto' && id != 'no';
          final audio = [for (final t in snap.data?.audio ?? const <AudioTrack>[]) if (real(t.id)) t];
          final subs = [for (final t in snap.data?.subtitle ?? const <SubtitleTrack>[]) if (real(t.id)) t];
          if (audio.length < 2 && subs.isEmpty) return const SizedBox.shrink();
          final now = player.state.track;
          return PopupMenuButton<Object>(
            tooltip: tr('player.tracks'),
            icon: const Icon(Icons.subtitles_rounded, color: Colors.white, size: 22),
            onSelected: (v) {
              if (v is AudioTrack) unawaited(player.setAudioTrack(v));
              if (v is SubtitleTrack) unawaited(player.setSubtitleTrack(v));
            },
            itemBuilder: (_) => [
              if (audio.length > 1) ...[
                PopupMenuItem<Object>(enabled: false, child: Text(tr('player.audio'))),
                for (var i = 0; i < audio.length; i++)
                  CheckedPopupMenuItem<Object>(value: audio[i], checked: now.audio == audio[i], child: Text(_trackName(audio[i].title, audio[i].language, i + 1))),
              ],
              if (subs.isNotEmpty) ...[
                if (audio.length > 1) const PopupMenuDivider(),
                PopupMenuItem<Object>(enabled: false, child: Text(tr('player.subtitles'))),
                CheckedPopupMenuItem<Object>(value: SubtitleTrack.no(), checked: now.subtitle.id == 'no', child: Text(tr('player.subs_off'))),
                for (var i = 0; i < subs.length; i++)
                  CheckedPopupMenuItem<Object>(value: subs[i], checked: now.subtitle == subs[i], child: Text(_trackName(subs[i].title, subs[i].language, i + 1))),
              ],
            ],
          );
        },
      );

  @override
  Widget build(BuildContext context) {
    final p = player;
    return Container(
      decoration: BoxDecoration(
        color: overlay ? null : Colors.black,
        gradient: overlay
            ? const LinearGradient(begin: Alignment.bottomCenter, end: Alignment.topCenter, colors: [Color(0xCC000000), Color(0x00000000)])
            : null,
      ),
      padding: const EdgeInsets.fromLTRB(8, 4, 12, 8),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        if (clipIn != null && clipOut != null)
          Padding(
            padding: const EdgeInsets.only(left: 10, bottom: 2),
            child: Row(children: [
              const Icon(Icons.content_cut_rounded, size: 16, color: _clipColor),
              const SizedBox(width: 6),
              Text(
                '${playerTime(Duration(milliseconds: clipIn!))} – ${playerTime(Duration(milliseconds: clipOut!))}'
                '  (${playerTime(Duration(milliseconds: clipOut! - clipIn!))})',
                style: const TextStyle(color: Colors.white, fontSize: 12.5, fontFeatures: [FontFeature.tabularFigures()]),
              ),
              const SizedBox(width: 10),
              Flexible(
                child: Text(tr('clip.range_hint'), maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white60, fontSize: 12)),
              ),
              const SizedBox(width: 8),
              FilledButton.icon(
                style: FilledButton.styleFrom(visualDensity: VisualDensity.compact),
                onPressed: onClip,
                icon: const Icon(Icons.content_cut_rounded, size: 16),
                label: Text(tr('clip.cut_this')),
              ),
              IconButton(tooltip: tr('common.cancel'), onPressed: onClipOff, color: Colors.white70, icon: const Icon(Icons.close_rounded, size: 18)),
            ]),
          ),
        StreamBuilder<Duration>(
          stream: p.stream.position,
          initialData: p.state.position,
          builder: (context, snap) => _SeekBar(
            position: snap.data ?? Duration.zero,
            duration: p.state.duration,
            a: a,
            b: b,
            clipIn: clipIn,
            clipOut: clipOut,
            onClipEdges: onClipEdges,
            markers: markers,
            onSeek: (d) => unawaited(p.seek(d)),
          ),
        ),
        Row(children: [
          StreamBuilder<bool>(
            stream: p.stream.playing,
            initialData: p.state.playing,
            builder: (context, snap) => _icon(
              snap.data == true ? Icons.pause_rounded : Icons.play_arrow_rounded,
              tr('player.play_pause'),
              () => unawaited(p.playOrPause()),
            ),
          ),
          _icon(Icons.skip_previous_rounded, tr('player.frame_back'), () => unawaited(onFrame(false))),
          _icon(Icons.skip_next_rounded, tr('player.frame_next'), () => unawaited(onFrame(true))),
          _icon(Icons.replay_10_rounded, tr('player.back10'), () => unawaited(onSeekBy(const Duration(seconds: -10)))),
          _icon(Icons.forward_10_rounded, tr('player.fwd10'), () => unawaited(onSeekBy(const Duration(seconds: 10)))),
          const SizedBox(width: 8),
          StreamBuilder<Duration>(
            stream: p.stream.position,
            initialData: p.state.position,
            builder: (context, snap) => Text(
              '${playerTime(snap.data ?? Duration.zero)} / ${playerTime(p.state.duration)}',
              style: const TextStyle(color: Colors.white70, fontSize: 12.5, fontFeatures: [FontFeature.tabularFigures()]),
            ),
          ),
          const Spacer(),
          StreamBuilder<double>(
            stream: p.stream.rate,
            initialData: p.state.rate,
            builder: (context, snap) {
              final r = snap.data ?? 1;
              return PopupMenuButton<double>(
                tooltip: tr('player.speed'),
                onSelected: onRate,
                itemBuilder: (_) => [
                  for (final s in _speeds) CheckedPopupMenuItem(value: s, checked: (s - r).abs() < 0.001, child: Text(_speedLabel(s))),
                ],
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  child: Text(_speedLabel(r),
                      style: TextStyle(color: (r - 1).abs() < 0.001 ? Colors.white : LrColors.safelight, fontWeight: FontWeight.w600)),
                ),
              );
            },
          ),
          _icon(Icons.repeat_rounded, a == null ? tr('player.ab') : (b == null ? tr('player.ab_set_a') : tr('player.ab_on', {'a': playerTime(a!), 'b': playerTime(b!)})),
              onAb, on: a != null),
          _tracks(),
          _icon(Icons.content_cut_rounded, tr('clip.cut'), onClip),
          PopupMenuButton<EndMode>(
            tooltip: '${tr('player.at_end')}: ${_endLabel(endMode)}',
            icon: Icon(_endIcon(endMode), color: endMode == EndMode.stop ? Colors.white : LrColors.safelight, size: 22),
            onSelected: onEnd,
            itemBuilder: (_) => [
              PopupMenuItem(enabled: false, child: Text(tr('player.at_end'))),
              for (final m in EndMode.values) CheckedPopupMenuItem(value: m, checked: m == endMode, child: Text(_endLabel(m))),
            ],
          ),
          StreamBuilder<double>(
            stream: p.stream.volume,
            initialData: p.state.volume,
            builder: (context, snap) {
              final v = snap.data ?? 100;
              return Row(mainAxisSize: MainAxisSize.min, children: [
                _icon(v == 0 ? Icons.volume_off_rounded : Icons.volume_up_rounded, tr('player.mute'), () => onVolume(v == 0 ? 100 : 0)),
                SizedBox(
                  width: 90,
                  child: SliderTheme(
                    data: const SliderThemeData(trackHeight: 3, thumbShape: RoundSliderThumbShape(enabledThumbRadius: 6)),
                    child: Slider(value: v.clamp(0, 100).toDouble(), max: 100, onChanged: onVolume),
                  ),
                ),
              ]);
            },
          ),
          _icon(overlay ? Icons.fullscreen_exit_rounded : Icons.fullscreen_rounded,
              tr(overlay ? 'player.exit_fullscreen' : 'player.fullscreen'), onFullscreen),
        ]),
      ]),
    );
  }
}

/// The time line: played part, the A-B loop, a dot to drag. Dragging
/// moves the picture along (a few times a second).
class _SeekBar extends StatefulWidget {
  const _SeekBar({
    required this.position,
    required this.duration,
    required this.onSeek,
    this.a,
    this.b,
    this.markers = const [],
    this.clipIn,
    this.clipOut,
    this.onClipEdges,
  });

  final Duration position;
  final Duration duration;
  final Duration? a, b;

  /// The clip being chosen (ms): its two ends can be dragged.
  final int? clipIn, clipOut;
  final void Function(int, int)? onClipEdges;

  /// Annotations (ms): small marks above the line.
  final List<int> markers;
  final ValueChanged<Duration> onSeek;

  @override
  State<_SeekBar> createState() => _SeekBarState();
}

class _SeekBarState extends State<_SeekBar> {
  double? _drag;

  /// Dragging an end of the clip: 0 start, 1 end.
  int? _edge;
  double? _hover;
  DateTime _lastSeek = DateTime.fromMillisecondsSinceEpoch(0);

  double _frac(Duration d) {
    final total = widget.duration.inMilliseconds;
    return total <= 0 ? 0 : (d.inMilliseconds / total).clamp(0.0, 1.0);
  }

  Duration _at(double f) => Duration(milliseconds: (widget.duration.inMilliseconds * f.clamp(0.0, 1.0)).round());

  void _move(double f, {bool done = false}) {
    setState(() => _drag = done ? null : f);
    final now = DateTime.now();
    if (done || now.difference(_lastSeek) > const Duration(milliseconds: 120)) {
      _lastSeek = now;
      widget.onSeek(_at(f));
    }
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, c) {
        const pad = 10.0;
        final w = (c.maxWidth - pad * 2).clamp(1.0, double.infinity);
        double f(Offset p) => ((p.dx - pad) / w).clamp(0.0, 1.0);
        final shown = _drag ?? _frac(widget.position);
        return MouseRegion(
          cursor: SystemMouseCursors.click,
          onHover: (e) => setState(() => _hover = f(e.localPosition)),
          onExit: (_) => setState(() => _hover = null),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapUp: (d) => _move(f(d.localPosition), done: true),
            onHorizontalDragStart: (d) {
              final ci = widget.clipIn, co = widget.clipOut;
              if (ci != null && co != null) {
                final x = d.localPosition.dx;
                final xi = pad + _frac(Duration(milliseconds: ci)) * w, xo = pad + _frac(Duration(milliseconds: co)) * w;
                final di = (x - xi).abs(), dO = (x - xo).abs();
                if (math.min(di, dO) < 12) {
                  _edge = di <= dO ? 0 : 1;
                  return;
                }
              }
              _move(f(d.localPosition));
            },
            onHorizontalDragUpdate: (d) {
              final e = _edge;
              if (e != null) {
                final ms = _at(f(d.localPosition)).inMilliseconds;
                final ci = widget.clipIn!, co = widget.clipOut!;
                if (e == 0) {
                  widget.onClipEdges?.call(math.min(ms, co - 1000).clamp(0, co), co);
                } else {
                  widget.onClipEdges?.call(ci, math.max(ms, ci + 1000));
                }
                // The picture follows the end being moved.
                final now = DateTime.now();
                if (now.difference(_lastSeek) > const Duration(milliseconds: 150)) {
                  _lastSeek = now;
                  widget.onSeek(Duration(milliseconds: e == 0 ? widget.clipIn! : widget.clipOut!));
                }
                return;
              }
              _move(f(d.localPosition));
            },
            onHorizontalDragEnd: (_) {
              if (_edge != null) {
                _edge = null;
                return;
              }
              if (_drag != null) _move(_drag!, done: true);
            },
            child: SizedBox(
              height: 26,
              child: Stack(clipBehavior: Clip.none, children: [
                Positioned.fill(
                  child: CustomPaint(
                    painter: _SeekPainter(
                      played: shown,
                      a: widget.a == null ? null : _frac(widget.a!),
                      b: widget.b == null ? null : _frac(widget.b!),
                      marks: [for (final m in widget.markers) _frac(Duration(milliseconds: m))],
                      clipIn: widget.clipIn == null ? null : _frac(Duration(milliseconds: widget.clipIn!)),
                      clipOut: widget.clipOut == null ? null : _frac(Duration(milliseconds: widget.clipOut!)),
                      pad: pad,
                    ),
                  ),
                ),
                if (_hover != null && widget.duration > Duration.zero)
                  Positioned(
                    left: (pad + _hover! * w - 24).clamp(0.0, c.maxWidth - 48),
                    top: -16,
                    child: Container(
                      width: 48,
                      alignment: Alignment.center,
                      child: Text(playerTime(_at(_hover!)), style: const TextStyle(color: Colors.white, fontSize: 11)),
                    ),
                  ),
              ]),
            ),
          ),
        );
      });
}

class _SeekPainter extends CustomPainter {
  _SeekPainter({required this.played, required this.pad, this.a, this.b, this.marks = const [], this.clipIn, this.clipOut});

  final double played;
  final double pad;
  final double? a, b;
  final double? clipIn, clipOut;
  final List<double> marks;

  @override
  void paint(Canvas canvas, Size size) {
    final y = size.height / 2;
    final w = size.width - pad * 2;
    final track = Paint()
      ..color = const Color(0x55FFFFFF)
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(Offset(pad, y), Offset(pad + w, y), track);
    if (a != null) {
      final loop = Paint()
        ..color = const Color(0xAA3FC79C)
        ..strokeWidth = 8;
      final end = b ?? a!;
      canvas.drawLine(Offset(pad + a! * w, y), Offset(pad + end * w + (b == null ? 2 : 0), y), loop);
    }
    final done = Paint()
      ..color = LrColors.safelight
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(Offset(pad, y), Offset(pad + played * w, y), done);
    if (clipIn != null && clipOut != null) {
      final x0 = pad + clipIn! * w, x1 = pad + clipOut! * w;
      canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTRB(x0, y - 6, x1, y + 6), const Radius.circular(3)), Paint()..color = _clipColor.withValues(alpha: 0.45));
      final handle = Paint()..color = _clipColor;
      for (final x in [x0, x1]) {
        canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromCenter(center: Offset(x, y), width: 6, height: 20), const Radius.circular(3)), handle);
      }
    }
    final mark = Paint()..color = const Color(0xFFFFB547);
    for (final m in marks) {
      canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromCenter(center: Offset(pad + m * w, y - 7), width: 4, height: 8), const Radius.circular(2)), mark);
    }
    canvas.drawCircle(Offset(pad + played * w, y), 7, Paint()..color = Colors.white);
  }

  @override
  bool shouldRepaint(_SeekPainter old) =>
      old.played != played || old.a != a || old.b != b || old.marks.length != marks.length || old.clipIn != clipIn || old.clipOut != clipOut;
}
