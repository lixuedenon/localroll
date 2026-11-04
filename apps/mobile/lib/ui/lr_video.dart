// apps/mobile/lib/ui/lr_video.dart
import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:localroll_ink/localroll_ink.dart';
import 'package:video_player/video_player.dart';

import '../l10n/l10n.dart';
import '../services/phone_notes.dart';
import 'ink_editor_page.dart';
import 'inked_photo.dart' show InkPenButton;

/// The phone's video player: speed, one frame at a time, A-B loop, pinch to
/// zoom, full screen. The video itself plays on the system's player (no
/// extra size); these are the controls around it.
///
/// Tap: show / hide the controls. Pinch: zoom in, drag to move; double tap:
/// back to the whole picture.
class LrVideo extends StatefulWidget {
  const LrVideo({super.key, required this.controller, this.fullScreen = false, this.inkKey});

  final VideoPlayerController controller;

  /// Where its drawings are kept (null: no drawing on it).
  final String? inkKey;

  /// Shown in the full-screen page (its button leaves full screen).
  final bool fullScreen;

  @override
  State<LrVideo> createState() => _LrVideoState();
}

/// Speeds offered. The system players stay smooth (with sound) in this range.
const List<double> lrSpeeds = [0.25, 0.5, 0.75, 1, 1.25, 1.5, 2];

/// One frame (the players don't say the frame rate; 30 a second is the
/// usual phone video).
const Duration _frame = Duration(microseconds: 33333);

class _LrVideoState extends State<LrVideo> {
  VideoPlayerController get _c => widget.controller;

  final TransformationController _zoom = TransformationController();
  bool _zoomed = false;

  bool _shown = true;
  Timer? _hide;

  /// A-B loop: the start, then the end.
  Duration? _a;
  Duration? _b;

  /// Dragging the bar: was it playing.
  bool _wasPlaying = false;
  bool _dragging = false;

  /// Holding a frame button: keep stepping.
  Timer? _repeat;

  @override
  void initState() {
    super.initState();
    _c.addListener(_onTick);
    _hideSoon();
  }

  @override
  void didUpdateWidget(LrVideo old) {
    super.didUpdateWidget(old);
    if (old.controller != widget.controller) {
      old.controller.removeListener(_onTick);
      widget.controller.addListener(_onTick);
    }
  }

  @override
  void dispose() {
    _c.removeListener(_onTick);
    _hide?.cancel();
    _repeat?.cancel();
    _zoom.dispose();
    super.dispose();
  }

  void _onTick() {
    final a = _a, b = _b;
    if (a != null && b != null && !_dragging) {
      final v = _c.value;
      if (v.isPlaying && v.position >= b) unawaited(_c.seekTo(a));
    }
  }

  void _hideSoon() {
    _hide?.cancel();
    _hide = Timer(const Duration(seconds: 3), () {
      if (mounted && _c.value.isPlaying && !_dragging) setState(() => _shown = false);
    });
  }

  void _touch() {
    if (!_shown) setState(() => _shown = true);
    _hideSoon();
  }

  Future<void> _playPause() async {
    _touch();
    final v = _c.value;
    if (v.isPlaying) {
      await _c.pause();
    } else {
      // At the end: from the start (or from A).
      if (v.duration > Duration.zero && v.position >= v.duration) await _c.seekTo(_a ?? Duration.zero);
      await _c.play();
    }
  }

  Future<void> _step(int dir) async {
    _touch();
    if (_c.value.isPlaying) await _c.pause();
    final d = _c.value.duration;
    var to = _c.value.position + _frame * dir;
    if (to < Duration.zero) to = Duration.zero;
    if (to > d) to = d;
    await _c.seekTo(to);
  }

  void _holdStep(int dir) {
    _repeat?.cancel();
    _repeat = Timer.periodic(const Duration(milliseconds: 110), (_) => unawaited(_step(dir)));
  }

  void _stopHold() {
    _repeat?.cancel();
    _repeat = null;
  }

  /// A-B: first tap sets A, second sets B (loops from there), third clears.
  void _ab() {
    _touch();
    final now = _c.value.position;
    setState(() {
      if (_a == null) {
        _a = now;
      } else if (_b == null) {
        if (now <= _a!) {
          // B before A: swap them.
          _b = _a;
          _a = now;
        } else {
          _b = now;
        }
        unawaited(_c.seekTo(_a!));
      } else {
        _a = null;
        _b = null;
      }
    });
  }

  Future<void> _setSpeed(double s) async {
    _touch();
    await _c.setPlaybackSpeed(s);
    if (mounted) setState(() {});
  }

  void _resetZoom() {
    _zoom.value = Matrix4.identity();
    setState(() => _zoomed = false);
  }

  Future<void> _fullScreen() async {
    if (widget.fullScreen) {
      unawaited(Navigator.of(context).maybePop());
      return;
    }
    final wide = _c.value.aspectRatio >= 1;
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    if (wide) {
      await SystemChrome.setPreferredOrientations([DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]);
    }
    if (!mounted) return;
    await Navigator.of(context).push(PageRouteBuilder<void>(
      opaque: true,
      pageBuilder: (_, _, _) => Scaffold(
        backgroundColor: Colors.black,
        body: SafeArea(child: LrVideo(controller: _c, fullScreen: true, inkKey: widget.inkKey)),
      ),
    ));
    await SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    if (mounted) setState(() {});
  }

  /// Pause and draw on this frame.
  Future<void> _draw() async {
    final key = widget.inkKey;
    if (key == null) return;
    _hide?.cancel();
    if (_c.value.isPlaying) await _c.pause();
    if (!mounted) return;
    await openInkEditor(
      context,
      inkKey: key,
      aspect: _c.value.aspectRatio,
      background: VideoPlayer(_c),
      atMs: _c.value.position.inMilliseconds,
    );
    _touch();
  }

  String _time(Duration d) {
    final h = d.inHours, m = d.inMinutes % 60, s = d.inSeconds % 60;
    String two(int n) => n.toString().padLeft(2, '0');
    return h > 0 ? '$h:${two(m)}:${two(s)}' : '${two(m)}:${two(s)}';
  }

  String _speedText(double s) => '${s == s.roundToDouble() ? s.toInt() : s}×';

  @override
  Widget build(BuildContext context) {
    final c = _c;
    return Stack(children: [
      // The picture: pinch to zoom; drag to move only when zoomed in, so a
      // swipe still goes to the next item.
      Positioned.fill(
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () {
            if (_shown) {
              _hide?.cancel();
              setState(() => _shown = false);
            } else {
              _touch();
            }
          },
          onDoubleTap: _zoomed ? _resetZoom : () => unawaited(_playPause()),
          child: InteractiveViewer(
            transformationController: _zoom,
            minScale: 1,
            maxScale: 6,
            panEnabled: _zoomed,
            onInteractionEnd: (_) {
              final z = _zoom.value.getMaxScaleOnAxis() > 1.01;
              if (z != _zoomed) setState(() => _zoomed = z);
            },
            child: Center(
              child: AspectRatio(
                aspectRatio: c.value.aspectRatio,
                child: Stack(fit: StackFit.expand, children: [
                  VideoPlayer(c),
                  // What was drawn, at its moment.
                  if (widget.inkKey != null)
                    ListenableBuilder(
                      listenable: PhoneNotes.instance,
                      builder: (_, _) => IgnorePointer(
                        child: CustomPaint(
                          painter: InkPainter(
                            notes: PhoneNotes.instance.of(widget.inkKey!),
                            video: true,
                            ms: () => c.value.position.inMilliseconds,
                            repaint: c,
                          ),
                        ),
                      ),
                    ),
                ]),
              ),
            ),
          ),
        ),
      ),
      Positioned.fill(
        child: IgnorePointer(
          ignoring: !_shown,
          child: AnimatedOpacity(
            opacity: _shown ? 1 : 0,
            duration: const Duration(milliseconds: 200),
            child: ValueListenableBuilder<VideoPlayerValue>(
              valueListenable: c,
              builder: (context, v, _) => _controls(context, v),
            ),
          ),
        ),
      ),
    ]);
  }

  Widget _controls(BuildContext context, VideoPlayerValue v) {
    const white = Colors.white;
    final dur = v.duration.inMilliseconds;
    final pos = min(v.position.inMilliseconds, max(dur, 0));
    final primary = Theme.of(context).colorScheme.primary;
    // Buttons that repeat while held say what they do without a tooltip
    // (a tooltip would also want the long press).
    Widget round(IconData icon, String tip, VoidCallback onTap, {double size = 30, VoidCallback? onHold}) => Semantics(
          label: tip,
          button: true,
          child: GestureDetector(
            onLongPressStart: onHold == null ? null : (_) => onHold(),
            onLongPressEnd: onHold == null ? null : (_) => _stopHold(),
            child: Material(
              color: Colors.black45,
              shape: const CircleBorder(),
              child: InkWell(
                customBorder: const CircleBorder(),
                onTap: onTap,
                child: Padding(padding: const EdgeInsets.all(10), child: Icon(icon, color: white, size: size)),
              ),
            ),
          ),
        );
    return Stack(children: [
      // Middle: a frame back, play / pause, a frame on.
      Center(
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          round(Icons.skip_previous_rounded, tr('player.frame_back'), () => unawaited(_step(-1)), onHold: () => _holdStep(-1)),
          const SizedBox(width: 28),
          round(v.isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded, tr(v.isPlaying ? 'player.pause' : 'player.play'),
              () => unawaited(_playPause()),
              size: 48),
          const SizedBox(width: 28),
          round(Icons.skip_next_rounded, tr('player.frame_fwd'), () => unawaited(_step(1)), onHold: () => _holdStep(1)),
        ]),
      ),
      // Draw on this frame.
      if (widget.inkKey != null)
        Positioned(left: 10, top: 10, child: InkPenButton(onPressed: () => unawaited(_draw()))),
      // Zoomed in: how much; tap to see the whole picture again.
      if (_zoomed)
        Positioned(
          top: 10,
          right: 10,
          child: ActionChip(
            avatar: const Icon(Icons.zoom_out_map_rounded, size: 16),
            label: Text('${_zoom.value.getMaxScaleOnAxis().toStringAsFixed(1)}× · ${tr('player.zoom_reset')}'),
            onPressed: _resetZoom,
          ),
        ),
      // Bottom: the bar with A / B marks, times and buttons.
      Positioned(
        left: 0,
        right: 0,
        bottom: 0,
        child: DecoratedBox(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.bottomCenter,
              end: Alignment.topCenter,
              colors: [Colors.black87, Colors.transparent],
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 24, 8, 12),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              SizedBox(
                height: 32,
                child: LayoutBuilder(builder: (context, box) {
                  // The slider's track runs between its side paddings.
                  const inset = 24.0;
                  final w = max(1.0, box.maxWidth - inset * 2);
                  double x(Duration d) => inset + w * (dur <= 0 ? 0 : d.inMilliseconds / dur).clamp(0.0, 1.0);
                  return Stack(clipBehavior: Clip.none, children: [
                    if (_a != null && _b != null)
                      Positioned(
                        left: x(_a!),
                        width: max(2.0, x(_b!) - x(_a!)),
                        top: 13,
                        height: 6,
                        child: IgnorePointer(child: ColoredBox(color: primary.withValues(alpha: 0.45))),
                      ),
                    for (final (d, t) in [(_a, 'A'), (_b, 'B')])
                      if (d != null)
                        Positioned(
                          left: x(d) - 6,
                          top: -6,
                          child: IgnorePointer(
                            child: Text(t, style: TextStyle(color: primary, fontSize: 11, fontWeight: FontWeight.w700)),
                          ),
                        ),
                    Positioned.fill(
                      child: Slider(
                        value: dur <= 0 ? 0 : pos / dur,
                        onChangeStart: (_) {
                          _dragging = true;
                          _wasPlaying = v.isPlaying;
                          _hide?.cancel();
                          unawaited(_c.pause());
                        },
                        onChanged: dur <= 0
                            ? null
                            : (f) => unawaited(_c.seekTo(Duration(milliseconds: (f * dur).round()))),
                        onChangeEnd: (_) {
                          _dragging = false;
                          if (_wasPlaying) unawaited(_c.play());
                          _hideSoon();
                        },
                      ),
                    ),
                  ]);
                }),
              ),
              Row(children: [
                const SizedBox(width: 12),
                Text('${_time(v.position)} / ${_time(v.duration)}', style: const TextStyle(color: white, fontSize: 12)),
                const Spacer(),
                // Speed.
                PopupMenuButton<double>(
                  tooltip: tr('player.speed'),
                  initialValue: v.playbackSpeed,
                  onSelected: (s) => unawaited(_setSpeed(s)),
                  itemBuilder: (_) => [
                    for (final s in lrSpeeds)
                      CheckedPopupMenuItem(value: s, checked: (v.playbackSpeed - s).abs() < 0.01, child: Text(_speedText(s))),
                  ],
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                    child: Text(
                      _speedText(v.playbackSpeed),
                      style: TextStyle(
                        color: (v.playbackSpeed - 1).abs() < 0.01 ? white : primary,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
                // A-B loop.
                Tooltip(
                  message: tr(_a == null
                      ? 'player.ab_set_a'
                      : _b == null
                          ? 'player.ab_set_b'
                          : 'player.ab_clear'),
                  child: TextButton(
                    onPressed: _ab,
                    style: TextButton.styleFrom(
                      foregroundColor: _a == null ? white : primary,
                      minimumSize: const Size(48, 36),
                    ),
                    child: Text(_a == null ? 'A-B' : (_b == null ? 'A-?' : 'A-B ✕'),
                        style: const TextStyle(fontWeight: FontWeight.w700)),
                  ),
                ),
                IconButton(
                  tooltip: tr(widget.fullScreen ? 'player.exit_fullscreen' : 'player.fullscreen'),
                  onPressed: () => unawaited(_fullScreen()),
                  icon: Icon(widget.fullScreen ? Icons.fullscreen_exit_rounded : Icons.fullscreen_rounded, color: white),
                ),
              ]),
            ]),
          ),
        ),
      ),
    ]);
  }
}
