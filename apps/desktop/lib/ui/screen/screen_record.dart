// apps/desktop/lib/ui/screen/screen_record.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:localroll_core/localroll_core.dart';
import 'package:window_manager/window_manager.dart';

import '../../app_services.dart';
import '../../l10n/l10n.dart';
import '../../services/library_index.dart';
import '../../services/mic.dart';
import '../../services/peers.dart';
import '../../services/video_encoders.dart';
import '../../services/win_screen.dart';
import '../app_nav.dart';
import '../player/ink_editor.dart';
import '../player/ink_paint.dart';
import '../player/narration.dart';
import '../player/narration_dialogs.dart';
import '../player/snapshot.dart';
import '../send_page.dart';
import '../theme.dart';
import '../../services/network.dart';

/// What is recorded.
enum ScreenMode { screen, window, area }

/// The choice made before recording.
class ScreenSetup {
  const ScreenSetup({required this.mode, required this.screen, this.window, this.area, required this.fps, required this.mic});

  final ScreenMode mode;
  final ScreenInfo screen;
  final WindowInfo? window;

  /// The area (screen pixels), for [ScreenMode.area].
  final Rect? area;
  final int fps;
  final String? mic;
}

/// ffmpeg's Windows screen copy (gdigrab) in real pixels: told it handles
/// display scaling itself, so 125 % / 150 % screens line up with the
/// windows' places (else it records the wrong part). Checked once against
/// the screens' size; what is still off is scaled.
class _Gdi {
  _Gdi._();

  static const Map<String, String> env = {'__COMPAT_LAYER': 'HighDpiAware'};
  static double? _k;
  static Rect? _for;

  /// Union of all screens (pixels).
  static Rect desktop() {
    final all = WinScreen.screens();
    if (all.isEmpty) return Rect.zero;
    return all.skip(1).fold(all.first.rect, (r, x) => r.expandToInclude(x.rect));
  }

  /// gdigrab's pixels per real pixel (1 when it sees the real pixels).
  static Future<double> scale(String exe) async {
    final d = desktop();
    if (_k != null && _for == d) return _k!;
    var k = 1.0;
    final f = File('${Directory.systemTemp.path}${Platform.pathSeparator}lr_gdi_${DateTime.now().microsecondsSinceEpoch}.png');
    try {
      await Process.run(exe, ['-hide_banner', '-loglevel', 'error', '-y', '-f', 'gdigrab', '-draw_mouse', '0', '-i', 'desktop', '-frames:v', '1', f.path],
          environment: env);
      if (f.existsSync()) {
        final b = await f.readAsBytes();
        if (b.length > 24 && d.width > 0) {
          final w = (b[16] << 24) | (b[17] << 16) | (b[18] << 8) | b[19];
          if (w > 0 && (w - d.width).abs() > 2) k = w / d.width;
          DiagLog.log('screen', 'desktop ${d.width.round()}x${d.height.round()}, gdigrab sees $w wide${k == 1 ? '' : ' (scale ${k.toStringAsFixed(3)})'}');
        }
      }
    } catch (_) {
    } finally {
      try {
        if (f.existsSync()) f.deleteSync();
      } catch (_) {}
    }
    _for = d;
    return _k = k;
  }

  /// ffmpeg's input options for [r] (real screen pixels).
  static List<String> input(Rect r, double k, {required int fps, bool mouse = true}) {
    final w = (r.width * k).round() ~/ 2 * 2, h = (r.height * k).round() ~/ 2 * 2;
    return [
      '-f', 'gdigrab', if (fps > 0) ...['-framerate', '$fps'], '-draw_mouse', mouse ? '1' : '0',
      '-offset_x', '${(r.left * k).round()}', '-offset_y', '${(r.top * k).round()}', '-video_size', '${w}x$h',
      '-i', 'desktop',
    ];
  }

  /// A still of [screen] (LocalRoll kept out of it).
  static Future<File?> still(String exe, ScreenInfo screen) async {
    final k = await scale(exe);
    final shot = File('${Directory.systemTemp.path}${Platform.pathSeparator}lr_still_${DateTime.now().microsecondsSinceEpoch}.png');
    WinScreen.excludeFromCapture(true);
    try {
      await Process.run(exe, ['-hide_banner', '-loglevel', 'error', '-y', ...input(screen.rect, k, fps: 0, mouse: false), '-frames:v', '1', shot.path],
          environment: env);
    } finally {
      WinScreen.excludeFromCapture(false);
    }
    return shot.existsSync() ? shot : null;
  }
}

/// ffmpeg filming a part of the screen (Windows' own screen copy) into a
/// file at good quality; how far it has got (to line it up with the voice).
class _Capture {
  Process? _p;
  int _outMs = 0;
  DateTime? _at;
  final StringBuffer _err = StringBuffer();

  Future<bool> start(String exe, Rect area, int fps, String enc, File out) async {
    final k = await _Gdi.scale(exe);
    final w = area.width.round() ~/ 2 * 2, h = area.height.round() ~/ 2 * 2;
    final p = _p = await Process.start(exe, [
      '-hide_banner', '-loglevel', 'error', '-y',
      ..._Gdi.input(area, k, fps: fps),
      // Back to real pixels when gdigrab saw others.
      '-vf', [if (k != 1) 'scale=$w:$h', 'format=nv12'].join(','),
      ...H264Encoders.args(enc, high: true, width: w, height: h, fps: fps.toDouble()),
      '-g', '${fps * 2}',
      '-progress', 'pipe:1', '-stats_period', '0.1',
      out.path,
    ], environment: _Gdi.env);
    p.stderr.transform(const Utf8Decoder(allowMalformed: true)).listen(_err.write);
    p.stdout.transform(const Utf8Decoder(allowMalformed: true)).transform(const LineSplitter()).listen((line) {
      if (line.startsWith('out_time_us=') || line.startsWith('out_time_ms=')) {
        final v = int.tryParse(line.substring(line.indexOf('=') + 1));
        if (v != null && v > 0) {
          _outMs = v ~/ 1000;
          _at = DateTime.now();
        }
      }
    });
    var ended = false;
    unawaited(p.exitCode.then((_) => ended = true));
    for (var i = 0; i < 100 && !ended; i++) {
      if (_at != null) return true;
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    if (_at != null) return true;
    DiagLog.log('screen', 'capture did not start: ${_err.toString().trim().split('\n').last}');
    p.kill();
    _p = null;
    return false;
  }

  /// How much video there is now (ms).
  int get recordedMs => _at == null ? 0 : _outMs + DateTime.now().difference(_at!).inMilliseconds;

  Future<void> stop() async {
    final p = _p;
    _p = null;
    if (p == null) return;
    try {
      p.stdin.write('q');
      await p.stdin.flush();
      await p.stdin.close();
    } catch (_) {}
    try {
      await p.exitCode.timeout(const Duration(seconds: 10));
    } catch (_) {
      p.kill();
    }
  }
}

/// One stretch of video filmed between pauses.
class _Part {
  _Part(this.file, this.startT, this.headMs);

  final File file;

  /// When it starts in the recording.
  final int startT;

  /// The file's own start that came before (cut).
  final int headMs;
  int lengthMs = 0;
}

/// A click, for the circle on it.
class _Click {
  const _Click(this.t, this.at, this.right);

  final int t;
  final Offset at;
  final bool right;
}

/// The screen recorder: one at a time, across LocalRoll.
class ScreenRecorder extends ChangeNotifier {
  ScreenRecorder._();

  static final ScreenRecorder instance = ScreenRecorder._();

  AppServices? _s;

  /// 3, 2, 1 before it starts (0: not counting).
  int countdown = 0;
  bool recording = false;
  bool paused = false;

  /// Drawing on the screen now (the window covers it, with a still of it).
  bool pen = false;
  File? penPicture;
  InkEditor? editor;

  /// One page of marks for each window drawn on: switching to another
  /// window hides them, coming back shows them again.
  final Map<int, InkEditor> _pages = {};
  final Map<String, int> _inkPage = {};
  int _page = 0;

  /// The window in use over time (not LocalRoll's own): whose page shows.
  final List<(int, int)> _front = [];
  int _own = 0, _firstPage = 0;

  /// Pen marks fade after 3 seconds (else they stay until deleted).
  bool fade = false;

  ScreenSetup? setup;
  final Stopwatch clock = Stopwatch();
  final _Capture _cap = _Capture();
  MicRecorder? _mic;
  Directory? _dir;
  final List<_Part> _parts = [];
  final List<({File file, int headMs, int lengthMs})> _voice = [];
  int _voiceStart = 0, _voiceHead = 0;
  File? _voiceFile;
  final List<_Click> _clicks = [];
  final List<(int, Rect)> _windowAt = [];
  final Map<String, NarrationInk> _inks = {};
  final Map<String, bool> _fades = {};
  Set<String> _lastIds = {};
  Timer? _poll;
  Rect? _savedWindow;
  bool _left = false, _right = false;
  bool _hkR = false, _hkP = false, _hkD = false;

  /// The area being filmed (screen pixels).
  Rect get area {
    final s = setup!;
    return s.mode == ScreenMode.area && s.area != null ? s.area! : s.screen.rect;
  }

  int get elapsedMs => clock.elapsedMilliseconds;
  double level() => _mic?.level() ?? 0;

  /// Global keys (also while LocalRoll is in the background):
  /// Ctrl+Shift+R start / stop, Ctrl+Shift+P pause, Ctrl+Shift+D pen.
  void watchKeys(AppServices s) {
    _s = s;
    if (!Platform.isWindows) return;
    Timer.periodic(const Duration(milliseconds: 40), (_) {
      final mod = WinScreen.down(0x11) && WinScreen.down(0x10);
      final r = mod && WinScreen.down(0x52), p = mod && WinScreen.down(0x50), d = mod && WinScreen.down(0x44);
      if (r && !_hkR) unawaited(recording || countdown > 0 ? stop() : startQuick());
      if (p && !_hkP && recording) unawaited(togglePause());
      if (d && !_hkD && recording) unawaited(togglePen());
      _hkR = r;
      _hkP = p;
      _hkD = d;
    });
  }

  /// Ctrl+Shift+R while not recording: the last choice, at once.
  Future<void> startQuick() async {
    final s = _s;
    if (s == null || recording || countdown > 0) return;
    final screens = WinScreen.screens();
    if (screens.isEmpty) return;
    final m = s.player;
    final scr = screens[m.screenIndex.clamp(0, screens.length - 1)];
    await begin(ScreenSetup(mode: ScreenMode.screen, screen: scr, fps: m.screenFps, mic: m.screenMic ? m.mic : null));
  }

  /// Start: LocalRoll shrinks to the bar (kept out of the video), 3-2-1,
  /// then the screen and the voice are recorded.
  Future<bool> begin(ScreenSetup su) async {
    final s = _s;
    final exe = s?.ffmpeg.ffmpeg;
    if (s == null || exe == null || recording || countdown > 0) return false;
    final enc = await s.converter.encoders.best();
    if (enc == null) return false;
    setup = su;
    final id = DateTime.now().millisecondsSinceEpoch.toRadixString(36);
    final dir = _dir = await Directory.systemTemp.createTemp('lr_screen_$id');
    _parts.clear();
    _voice.clear();
    _clicks.clear();
    _windowAt.clear();
    _inks.clear();
    _fades.clear();
    _pages.clear();
    _inkPage.clear();
    _front.clear();
    _lastIds = {};
    clock.reset();
    paused = false;
    pen = false;
    editor = null;
    _own = WinScreen.ownWindow();
    final fg = WinScreen.foreground();
    _page = fg == _own ? 0 : fg;

    // The bar: small, on top, at the top of the screen recorded, never in the video.
    _savedWindow = WinScreen.ownRect();
    AppNav.instance.fullscreen.value = true;
    await windowManager.setMinimumSize(const Size(200, 40));
    WinScreen.excludeFromCapture(true);
    _placeBar();
    AppNav.instance.navigatorKey.currentState?.push(MaterialPageRoute(settings: const RouteSettings(name: 'screen-record'), builder: (_) => const ScreenRecordPage()));
    // A window: in front, so nothing else is filmed over it.
    if (su.mode == ScreenMode.window && su.window != null) {
      WinScreen.bringToFront(su.window!.handle);
      _page = su.window!.handle;
    }
    _firstPage = _page;

    final mic = su.mic == null ? null : (_mic = MicRecorder(exe));
    final listening = mic == null ? Future.value(true) : _startVoice();
    final filming = _cap.start(exe, area, su.fps, enc, File('${dir.path}${Platform.pathSeparator}part_0.mkv'));
    for (var c = 3; c > 0; c--) {
      countdown = c;
      notifyListeners();
      await Future<void>.delayed(const Duration(seconds: 1));
    }
    final okV = await filming, okA = await listening;
    countdown = 0;
    if (!okV) {
      await _mic?.stop();
      await _restore();
      notifyListeners();
      _message(tr('screen.failed_start'));
      return false;
    }
    if (!okA) _message(tr('rec.mic_failed'));
    _go(dir, 0);
    recording = true;
    notifyListeners();
    _poll = Timer.periodic(const Duration(milliseconds: 16), (_) => _tick());
    DiagLog.log('screen', 'recording ${su.mode.name} ${area.width.round()}x${area.height.round()} @${su.fps}');
    return true;
  }

  Future<bool> _startVoice() async {
    final f = _voiceFile = File('${_dir!.path}${Platform.pathSeparator}voice_${_voice.length}.wav');
    return _mic!.start(setup!.mic!, f);
  }

  /// The clock goes on; what was filmed / heard before now is cut.
  void _go(Directory dir, int partIndex) {
    final head = _cap.recordedMs;
    _parts.add(_Part(File('${dir.path}${Platform.pathSeparator}part_$partIndex.mkv'), clock.elapsedMilliseconds, head));
    if (_mic?.running ?? false) {
      final first = _mic!.firstSound ?? DateTime.now();
      _voiceHead = math.max(0, DateTime.now().difference(first).inMilliseconds);
      _voiceStart = clock.elapsedMilliseconds;
    }
    clock.start();
  }

  void _placeBar() {
    final scr = setup!.screen;
    final k = scr.scale;
    final w = 660 * k, h = 64 * k;
    WinScreen.place(Rect.fromLTWH(scr.rect.center.dx - w / 2, scr.rect.top + 12 * k, w, h), onTop: true, activate: false);
  }

  void _message(String text) {
    final ctx = AppNav.instance.navigatorKey.currentContext;
    if (ctx != null) ScaffoldMessenger.maybeOf(ctx)?.showSnackBar(SnackBar(content: Text(text)));
  }

  int _sample = 0;

  void _tick() {
    if (!recording || paused) return;
    final t = clock.elapsedMilliseconds;
    // Clicks (not on LocalRoll's own bar, not while drawing).
    final l = WinScreen.down(0x01), r = WinScreen.down(0x02);
    if (!pen && ((l && !_left) || (r && !_right))) {
      final at = WinScreen.cursor();
      final own = WinScreen.ownRect();
      if (own == null || !own.contains(at)) _clicks.add(_Click(t, at, r && !_right));
    }
    _left = l;
    _right = r;
    if (++_sample % 6 == 0) {
      final su = setup!;
      if (su.mode == ScreenMode.window && su.window != null) {
        final rect = WinScreen.windowRect(su.window!.handle);
        if (rect != null && (_windowAt.isEmpty || _windowAt.last.$2 != rect)) _windowAt.add((t, rect));
      }
      // The window in use (LocalRoll's own bar / pen screen does not count).
      final fg = WinScreen.foreground();
      if (fg != 0 && fg != _own && !pen && fg != _page) {
        _page = fg;
        _front.add((t, fg));
      }
    }
    // Fading marks go from the screen too.
    if (_sample % 6 == 0 && _fades.values.any((f) => f)) {
      for (final ed in _pages.values) {
        final gone = [
          for (final i in ed.inks)
            if (_fades[i.id] == true && t > (ed.sessionStart[i.id] ?? t) + (ed.sessionTimes[i.id]?.last ?? 0) + 3000) i,
        ];
        if (gone.isNotEmpty) {
          ed.inks.removeWhere(gone.contains);
          ed.touched();
        }
      }
    }
  }

  Timer? _snapTimer;

  /// A page changed: kept for the video a moment later (not at every
  /// point of a line, so drawing stays smooth).
  void _snapSoon() {
    if (_snapTimer?.isActive ?? false) return;
    _snapTimer = Timer(const Duration(milliseconds: 60), () {
      if (recording) _snapInks(clock.elapsedMilliseconds);
    });
  }

  /// The marks of every page as they are now (kept for the video): when
  /// each was drawn, and when it was rubbed out.
  void _snapInks(int t) {
    final now = <String, InkMark>{};
    for (final e in _pages.entries) {
      final ed = e.value;
      for (final i in [...ed.inks, ?ed.drawing]) {
        final st = ed.sessionStart[i.id];
        if (st == null) continue;
        now[i.id] = i;
        _inkPage[i.id] = e.key;
        _fades.putIfAbsent(i.id, () => fade);
        _inks[i.id] = NarrationInk(file: 0, ink: i.copy(), startT: st, times: List.of(ed.sessionTimes[i.id] ?? const [0]), removedT: null);
      }
    }
    for (final id in _lastIds) {
      if (!now.containsKey(id)) _inks[id]?.removedT ??= t;
    }
    // Back again (undo): shown again from now.
    for (final id in now.keys) {
      final old = _inks[id];
      if (old != null && old.removedT != null && !_lastIds.contains(id)) {
        _inks[id] = NarrationInk(file: 0, ink: old.ink, startT: math.max(old.startT, t), times: const [0], removedT: null);
      }
    }
    _lastIds = now.keys.toSet();
  }

  Future<void> togglePause() async {
    if (!recording) return;
    final exe = _s?.ffmpeg.ffmpeg;
    final enc = await _s?.converter.encoders.best();
    if (!paused) {
      clock.stop();
      paused = true;
      notifyListeners();
      await _cap.stop();
      _parts.last.lengthMs = clock.elapsedMilliseconds - _parts.last.startT;
      if (_mic?.running ?? false) {
        await _mic!.stop();
        _voice.add((file: _voiceFile!, headMs: _voiceHead, lengthMs: clock.elapsedMilliseconds - _voiceStart));
      }
    } else {
      if (exe == null || enc == null) return;
      final idx = _parts.length;
      final ok = await _cap.start(exe, area, setup!.fps, enc, File('${_dir!.path}${Platform.pathSeparator}part_$idx.mkv'));
      if (!ok) {
        _message(tr('screen.failed_start'));
        return;
      }
      if (_mic != null) await _startVoice();
      paused = false;
      _go(_dir!, idx);
      notifyListeners();
    }
  }

  /// Pen on: a still of the screen under it, the window over the whole
  /// screen, drawing; off: back to the bar.
  Future<void> togglePen() async {
    if (!recording) return;
    final s = _s!;
    if (!pen) {
      final exe = s.ffmpeg.ffmpeg;
      if (exe == null) return;
      final scr = setup!.screen;
      final shot = File('${_dir!.path}${Platform.pathSeparator}pen_${DateTime.now().millisecondsSinceEpoch}.png');
      final k = await _Gdi.scale(exe);
      await Process.run(exe, ['-hide_banner', '-loglevel', 'error', '-y', ..._Gdi.input(scr.rect, k, fps: 0, mouse: false), '-frames:v', '1', shot.path],
          environment: _Gdi.env);
      penPicture = shot.existsSync() ? shot : null;
      // The page of the window in use (a new one the first time).
      editor = _pages.putIfAbsent(_page, () {
        final ed = InkEditor(video: false, clock: () => 0, sessionClock: () => clock.elapsedMilliseconds);
        ed.addListener(_snapSoon);
        return ed;
      });
      pen = true;
      WinScreen.place(scr.rect, onTop: true);
    } else {
      _snapInks(clock.elapsedMilliseconds);
      pen = false;
      _placeBar();
    }
    notifyListeners();
  }

  void setFade(bool on) {
    fade = on;
    notifyListeners();
  }

  /// Stop: back to the normal window, then save / send / throw away.
  Future<void> stop() async {
    if (countdown > 0) return;
    if (!recording) return;
    _poll?.cancel();
    _snapInks(clock.elapsedMilliseconds);
    if (!paused) {
      clock.stop();
      await _cap.stop();
      _parts.last.lengthMs = clock.elapsedMilliseconds - _parts.last.startT;
      if (_mic?.running ?? false) {
        await _mic!.stop();
        _voice.add((file: _voiceFile!, headMs: _voiceHead, lengthMs: clock.elapsedMilliseconds - _voiceStart));
      }
    }
    recording = false;
    paused = false;
    pen = false;
    final length = clock.elapsedMilliseconds;
    await _restore();
    notifyListeners();
    DiagLog.log('screen', 'recorded ${length ~/ 1000} s');
    await _afterwards(length);
  }

  Future<void> _restore() async {
    WinScreen.excludeFromCapture(false);
    final r = _savedWindow;
    if (r != null) WinScreen.place(r, onTop: false);
    await windowManager.setMinimumSize(const Size(960, 620));
    AppNav.instance.fullscreen.value = false;
    final nav = AppNav.instance.navigatorKey.currentState;
    nav?.popUntil((route) => route.settings.name != 'screen-record');
    try {
      await windowManager.focus();
    } catch (_) {}
  }

  Future<void> _afterwards(int length) async {
    final s = _s!;
    final dir = _dir!;
    final ctx = AppNav.instance.navigatorKey.currentContext;
    if (ctx == null) return;
    final exe = s.ffmpeg.ffmpeg!;
    final voice = File('${dir.path}${Platform.pathSeparator}voice.wav');
    if (_voice.isNotEmpty) await joinVoice(exe, _voice, voice);
    while (true) {
      final c = AppNav.instance.navigatorKey.currentContext;
      if (c == null || !c.mounted) return;
      final r = await recordedDialog(c, length, OriginalSound.none, screen: true);
      if (r == null) return;
      final c2 = AppNav.instance.navigatorKey.currentContext;
      if (c2 == null || !c2.mounted) return;
      if (r.$1 == RecordedChoice.discard) {
        final ok = await confirmDiscard(c2, drew: false);
        if (ok == null) continue;
        await _cleanup();
        _message(tr('rec.discarded'));
        return;
      }
      await _make(c2, length, voice.existsSync() ? voice : null, send: r.$1 == RecordedChoice.saveSend);
      return;
    }
  }

  Future<void> _cleanup() async {
    try {
      await _dir?.delete(recursive: true);
    } catch (_) {}
  }

  Future<void> _make(BuildContext context, int length, File? voice, {required bool send}) async {
    final s = _s!;
    final maker = _ScreenComposer(s);
    final progress = ValueNotifier<double>(0);
    final done = maker.make(
      parts: _parts,
      length: length,
      area: area,
      screen: setup!.screen,
      windowAt: setup!.mode == ScreenMode.window ? _windowAt : const [],
      clicks: _clicks,
      inks: _inks.values.toList(),
      fades: _fades,
      pageOf: _inkPage,
      front: _front,
      firstPage: _firstPage,
      voice: voice,
      fps: setup!.fps,
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
          title: Text(tr('screen.making')),
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
    await _cleanup();
    final c = AppNav.instance.navigatorKey.currentContext;
    if (c == null || !c.mounted) return;
    final messenger = ScaffoldMessenger.of(c);
    if (f == null) {
      messenger.showSnackBar(SnackBar(content: Text(tr('rec.failed'))));
      return;
    }
    Future<void> sendIt() async {
      final lib = s.library;
      final root = '${lib.rootPath}${Platform.pathSeparator}';
      final item = f.path.toLowerCase().startsWith(root.toLowerCase())
          ? lib.findByRel(f.path.substring(root.length).replaceAll(Platform.pathSeparator, '/'))
          : null;
      final name = f.path.split(Platform.pathSeparator).last;
      final file = item != null ? SendFile.fromLibrary(lib, item) : SendFile.plain(f, name);
      final cc = AppNav.instance.navigatorKey.currentContext;
      if (file != null && cc != null && cc.mounted) await sendToPc(cc, s, [file], name);
    }

    if (send) {
      await sendIt();
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
            unawaited(sendIt());
          },
          icon: const Icon(Icons.send_rounded, size: 16),
          label: Text(tr('player.send')),
        ),
      ]),
    ));
  }
}

/// One stretch of the finished video: from one part, one framing.
class _Piece {
  _Piece(this.part, this.startT, this.endT, this.crop);

  final _Part part;
  final int startT;
  int endT;

  /// Inside the filmed area (pixels).
  final Rect crop;
}

/// Makes the finished video: the filmed parts (between pauses), framed on
/// the window if a window was recorded (following it), with the pen marks
/// and click circles drawn on, and the voice.
class _ScreenComposer {
  _ScreenComposer(this.s);

  final AppServices s;
  Process? _proc;
  bool _cancelled = false;

  void cancel() {
    _cancelled = true;
    _proc?.kill();
  }

  static String _secs(int ms) => (ms / 1000).toStringAsFixed(3);
  static int _even(double v) => math.max(2, (v / 2).floor() * 2);

  Future<bool> _run(String exe, List<String> args, {Future<void> Function(IOSink)? feed}) async {
    if (_cancelled) return false;
    final p = _proc = await Process.start(exe, args);
    final err = StringBuffer();
    p.stderr.transform(const Utf8Decoder(allowMalformed: true)).listen(err.write);
    unawaited(p.stdout.drain<void>());
    if (feed != null) {
      try {
        await feed(p.stdin);
      } catch (e) {
        DiagLog.log('screen', 'marks not handed over: $e');
      }
      try {
        await p.stdin.close();
      } catch (_) {}
    }
    final code = await p.exitCode;
    _proc = null;
    if (code != 0 && !_cancelled) DiagLog.log('screen', 'ffmpeg failed: ${err.toString().trim().split('\n').last}');
    return code == 0;
  }

  Future<File?> make({
    required List<_Part> parts,
    required int length,
    required Rect area,
    required ScreenInfo screen,
    required List<(int, Rect)> windowAt,
    required List<_Click> clicks,
    required List<NarrationInk> inks,
    required Map<String, bool> fades,
    required Map<String, int> pageOf,
    required List<(int, int)> front,
    required int firstPage,
    required File? voice,
    required int fps,
    required void Function(double) onProgress,
  }) async {
    final exe = s.ffmpeg.ffmpeg;
    final enc = await s.converter.encoders.best();
    if (exe == null || enc == null || parts.isEmpty) return null;
    final full = Rect.fromLTWH(0, 0, ((area.width.round() ~/ 2) * 2).toDouble(), ((area.height.round() ~/ 2) * 2).toDouble());
    Rect cropAt(int t) {
      if (windowAt.isEmpty) return full;
      var r = windowAt.first.$2;
      for (final (wt, wr) in windowAt) {
        if (wt > t) break;
        r = wr;
      }
      final c = r.translate(-area.left, -area.top).intersect(full);
      return c.isEmpty || c.width < 16 || c.height < 16 ? full : c;
    }

    // Pieces: each part, cut again wherever the window moved.
    final pieces = <_Piece>[];
    for (final p in parts) {
      if (p.lengthMs <= 0) continue;
      final end = p.startT + p.lengthMs;
      var cur = _Piece(p, p.startT, end, cropAt(p.startT));
      pieces.add(cur);
      for (final (wt, _) in windowAt) {
        if (wt <= cur.startT || wt >= end) continue;
        final c = cropAt(wt);
        if (c == cur.crop) continue;
        if (wt - cur.startT < 150) continue;
        cur.endT = wt;
        cur = _Piece(p, wt, end, c);
        pieces.add(cur);
      }
    }
    if (pieces.isEmpty) return null;
    final first = pieces.first.crop;
    final k = math.min(1.0, 3840 / math.max(first.width, first.height));
    final w = _even(first.width * k), h = _even(first.height * k);
    final ko = math.min(1.0, 1920 / math.max(w, h));
    final ow = _even(w * ko), oh = _even(h * ko);
    const ofps = 30;
    final dir = await Directory.systemTemp.createTemp('lr_screen_out');
    final sep = Platform.pathSeparator;
    try {
      final total = pieces.fold<int>(0, (a, p) => a + (p.endT - p.startT));
      var done = 0;
      final outs = <String>[];
      for (var i = 0; i < pieces.length && !_cancelled; i++) {
        final p = pieces[i];
        final len = p.endT - p.startT;
        final local = p.part.headMs + (p.startT - p.part.startT);
        final c = p.crop;
        final out = '${dir.path}${sep}p$i.mp4';
        final frames = (len / 1000 * ofps).ceil() + 1;
        final args = [
          '-hide_banner', '-loglevel', 'error', '-y',
          '-ss', _secs(local), '-t', _secs(len + 200), '-i', p.part.file.path,
          '-f', 'rawvideo', '-pix_fmt', 'rgba', '-s', '${ow}x$oh', '-framerate', '$ofps', '-i', 'pipe:0',
          '-filter_complex',
          '[0:v]crop=${_even(c.width)}:${_even(c.height)}:${c.left.round()}:${c.top.round()},'
              'scale=$w:$h:force_original_aspect_ratio=decrease,pad=$w:$h:(ow-iw)/2:(oh-ih)/2,setsar=1,fps=$fps,setpts=PTS-STARTPTS[base];'
              '[1:v]scale=$w:$h,format=rgba[ov];[base][ov]overlay=0:0:eof_action=repeat,format=nv12[v]',
          '-map', '[v]',
          ...H264Encoders.args(enc, high: true, width: w, height: h, fps: fps.toDouble()),
          '-g', '$fps', '-an', '-t', _secs(len),
          out,
        ];
        final start = done;
        final ok = await _run(exe, args, feed: (stdin) async {
          final size = Size(ow.toDouble(), oh.toDouble());
          for (var f = 0; f < frames && !_cancelled; f++) {
            final t = p.startT + (f * 1000 / ofps).round();
            final rec = ui.PictureRecorder();
            _paint(Canvas(rec), size, t, area, screen, c, clicks, inks, fades, _pageAt(t, front, firstPage), pageOf);
            final img = await rec.endRecording().toImage(ow, oh);
            final bytes = await img.toByteData(format: ui.ImageByteFormat.rawStraightRgba);
            img.dispose();
            if (bytes == null) break;
            stdin.add(bytes.buffer.asUint8List());
            await stdin.flush();
            if (f % 15 == 0) onProgress(((start + f * 1000 / ofps) / total * 0.92).clamp(0.0, 0.92));
          }
        });
        if (!ok) return null;
        outs.add(out);
        done += len;
      }
      if (_cancelled) return null;
      final list = File('${dir.path}${sep}list.txt');
      await list.writeAsString([for (final o in outs) "file '${o.replaceAll("'", "'\\''")}'"].join('\n'));
      final joined = '${dir.path}${sep}joined.mp4';
      if (!await _run(exe, ['-hide_banner', '-loglevel', 'error', '-y', '-f', 'concat', '-safe', '0', '-i', list.path, '-c', 'copy', joined])) return null;
      onProgress(0.96);
      final folder = Snapshots.folder(s, screen: true);
      await Directory(folder).create(recursive: true);
      final now = DateTime.now();
      String two(int v) => v.toString().padLeft(2, '0');
      final out = LibraryIndex.uniquePath(folder,
          sanitizeFileName('${tr('screen.file_name')}_${now.year}${two(now.month)}${two(now.day)}-${two(now.hour)}${two(now.minute)}${two(now.second)}.mp4'));
      final ok = await _run(exe, [
        '-hide_banner', '-loglevel', 'error', '-y',
        '-i', joined,
        if (voice != null) ...['-i', voice.path],
        '-map', '0:v', if (voice != null) ...['-map', '1:a'],
        '-c:v', 'copy', if (voice != null) ...['-c:a', 'aac', '-b:a', '160k', '-shortest'],
        '-movflags', '+faststart',
        out,
      ]);
      if (!ok || !File(out).existsSync()) return null;
      onProgress(1);
      return Snapshots.done(s, File(out), video: true);
    } catch (e) {
      DiagLog.log('screen', 'not made: $e');
      return null;
    } finally {
      try {
        await dir.delete(recursive: true);
      } catch (_) {}
    }
  }

  /// Whose page shows at [t]: the window in use then.
  static int _pageAt(int t, List<(int, int)> front, int first) {
    var p = first;
    for (final (ft, w) in front) {
      if (ft > t) break;
      p = w;
    }
    return p;
  }

  /// Pen marks (of [page]) and click circles at [t], on the finished frame.
  void _paint(Canvas c, Size out, int t, Rect area, ScreenInfo screen, Rect crop, List<_Click> clicks, List<NarrationInk> inks, Map<String, bool> fades,
      int page, Map<String, int> pageOf) {
    final fit = math.min(out.width / crop.width, out.height / crop.height);
    final padX = (out.width - crop.width * fit) / 2, padY = (out.height - crop.height * fit) / 2;
    c.save();
    c.clipRect(Offset.zero & out);
    c.translate(padX, padY);
    c.scale(fit);
    // From screen pixels to the filmed area's pixels, minus the framing.
    c.translate(-area.left - crop.left, -area.top - crop.top);
    // Pen marks (drawn over the whole screen they were made on).
    c.save();
    c.translate(screen.rect.left, screen.rect.top);
    final scr = screen.rect.size;
    for (final i in inks) {
      if (t < i.startT) continue;
      final p = pageOf[i.ink.id] ?? 0;
      if (p != 0 && p != page) continue;
      final drawn = i.times.isEmpty ? 0 : i.times.last;
      var until = i.removedT;
      double alpha = 1;
      if (fades[i.ink.id] == true) {
        final end = i.startT + drawn + 3000;
        until = until == null ? end : math.min(until, end);
        if (t > end - 500) alpha = ((end - t) / 500).clamp(0.0, 1.0);
      }
      if (until != null && t >= until) continue;
      final m = i.ink.copy()
        ..times = i.times
        ..live = true;
      if (alpha < 1) c.saveLayer(null, Paint()..color = Color.fromRGBO(0, 0, 0, alpha));
      InkGeometry.paint(c, scr, m, upto: t - i.startT);
      if (alpha < 1) c.restore();
    }
    c.restore();
    // Click circles: a ring that grows and fades in half a second.
    for (final k in clicks) {
      final d = t - k.t;
      if (d < 0 || d > 500) continue;
      final f = d / 500;
      final r = (10 + 26 * f) / fit;
      final color = k.right ? const Color(0xFF6FB3F0) : const Color(0xFFFFB547);
      c.drawCircle(k.at, r, Paint()..color = color.withValues(alpha: 0.25 * (1 - f)));
      c.drawCircle(
        k.at,
        r,
        Paint()
          ..color = color.withValues(alpha: 0.9 * (1 - f))
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3 / fit,
      );
    }
    c.restore();
  }
}

// ------------------------------------------------------------------ UI

/// Choose what to record: a whole screen, a window, or an area.
Future<ScreenSetup?> showScreenSetup(BuildContext context, AppServices s) async {
  final screens = WinScreen.screens();
  if (screens.isEmpty) return null;
  final windows = WinScreen.windows();
  final m = s.player;
  var mode = ScreenMode.values.firstWhere((x) => x.name == m.screenMode, orElse: () => ScreenMode.screen);
  if (mode == ScreenMode.window && windows.isEmpty) mode = ScreenMode.screen;
  var screen = screens[m.screenIndex.clamp(0, screens.length - 1)];
  WindowInfo? window = windows.isEmpty ? null : windows.first;
  var fps = m.screenFps;
  var withMic = m.screenMic;
  final mic = MicRecorder(s.ffmpeg.ffmpeg);
  var micName = m.mic;
  final choice = await showDialog<bool>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, set) => AlertDialog(
        title: Text(tr('screen.title')),
        content: SizedBox(
          width: 480,
          child: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              SegmentedButton<ScreenMode>(
                showSelectedIcon: false,
                segments: [
                  ButtonSegment(value: ScreenMode.screen, icon: const Icon(Icons.desktop_windows_rounded), label: Text(tr('screen.mode_screen'))),
                  ButtonSegment(value: ScreenMode.window, icon: const Icon(Icons.web_asset_rounded), label: Text(tr('screen.mode_window')), enabled: windows.isNotEmpty),
                  ButtonSegment(value: ScreenMode.area, icon: const Icon(Icons.crop_rounded), label: Text(tr('screen.mode_area'))),
                ],
                selected: {mode},
                onSelectionChanged: (v) => set(() => mode = v.first),
              ),
              const SizedBox(height: 14),
              if (screens.length > 1) ...[
                Text(tr('screen.which_screen'), style: const TextStyle(color: LrColors.muted)),
                const SizedBox(height: 6),
                Wrap(spacing: 8, children: [
                  for (final x in screens)
                    ChoiceChip(
                      selected: x.index == screen.index,
                      onSelected: (_) => set(() => screen = x),
                      label: Text('${tr('screen.screen_n', {'n': x.index + 1})}${x.primary ? ' · ${tr('screen.primary')}' : ''}  '
                          '${x.rect.width.round()}×${x.rect.height.round()}'),
                    ),
                ]),
                const SizedBox(height: 12),
              ],
              if (mode == ScreenMode.window) ...[
                FilledButton.tonalIcon(
                  onPressed: () async {
                    final w = await _pickWindow(ctx, s, screen);
                    if (w == null) return;
                    set(() {
                      if (!windows.any((x) => x.handle == w.handle)) windows.insert(0, w);
                      window = w;
                    });
                  },
                  icon: const Icon(Icons.ads_click_rounded, size: 18),
                  label: Text(tr('screen.pick_window')),
                ),
                const SizedBox(height: 10),
                Text(tr('screen.which_window'), style: const TextStyle(color: LrColors.muted)),
                const SizedBox(height: 6),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 220),
                  child: ListView(shrinkWrap: true, children: [
                    for (final x in windows)
                      RadioListTile<int>(
                        dense: true,
                        value: x.handle,
                        // ignore: deprecated_member_use
                        groupValue: window?.handle,
                        // ignore: deprecated_member_use
                        onChanged: (_) => set(() => window = x),
                        title: Text(x.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                        subtitle: Text('${x.rect.width.round()}×${x.rect.height.round()}'),
                        contentPadding: EdgeInsets.zero,
                      ),
                  ]),
                ),
                Text(tr('screen.window_tip'), style: const TextStyle(color: LrColors.muted, fontSize: 12.5)),
                const SizedBox(height: 12),
              ],
              if (mode == ScreenMode.area) ...[
                Text(tr('screen.area_tip'), style: const TextStyle(color: LrColors.muted, fontSize: 12.5)),
                const SizedBox(height: 12),
              ],
              CheckboxListTile(
                value: withMic,
                onChanged: (v) => set(() => withMic = v ?? true),
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                title: Text(tr('screen.with_mic')),
                subtitle: Text(micName ?? tr('screen.mic_choose')),
                secondary: TextButton(
                  onPressed: () async {
                    final n = await pickMicrophone(ctx, mic, current: micName);
                    if (n != null) set(() => micName = n);
                  },
                  child: Text(tr('screen.mic_change')),
                ),
              ),
              Row(children: [
                Text(tr('screen.fps'), style: const TextStyle(color: LrColors.muted)),
                const SizedBox(width: 12),
                SegmentedButton<int>(
                  showSelectedIcon: false,
                  segments: const [ButtonSegment(value: 30, label: Text('30')), ButtonSegment(value: 60, label: Text('60'))],
                  selected: {fps},
                  onSelectionChanged: (v) => set(() => fps = v.first),
                ),
              ]),
              const SizedBox(height: 10),
              Text(tr('screen.keys_tip'), style: const TextStyle(color: LrColors.muted, fontSize: 12.5, height: 1.5)),
            ]),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('common.cancel'))),
          FilledButton.icon(
            onPressed: () => Navigator.pop(ctx, true),
            icon: const Icon(Icons.fiber_manual_record_rounded, size: 18),
            label: Text(tr(mode == ScreenMode.area ? 'screen.pick_area' : 'screen.start')),
          ),
        ],
      ),
    ),
  );
  if (choice != true || !context.mounted) return null;
  if (withMic && micName == null) {
    micName = await pickMicrophone(context, mic);
    if (micName == null) withMic = false;
  }
  if (micName != null) m.setMic(micName);
  m.setScreen(mode: mode.name, index: screen.index, fps: fps, mic: withMic);
  if (mode == ScreenMode.window && window != null) {
    // Where it is now; the screen it is on.
    final now = WinScreen.windowRect(window!.handle);
    if (now != null) window = WindowInfo(handle: window!.handle, title: window!.title, rect: now);
    final c = window!.rect.center;
    screen = screens.firstWhere((x) => x.rect.contains(c), orElse: () => screen);
  }
  Rect? area;
  if (mode == ScreenMode.area) {
    if (!context.mounted) return null;
    area = await _pickArea(context, s, screen);
    if (area == null) return null;
  }
  return ScreenSetup(mode: mode, screen: screen, window: mode == ScreenMode.window ? window : null, area: area, fps: fps, mic: withMic ? micName : null);
}

/// Point at a window on a still of [screen] (it lights up), click to take it.
Future<WindowInfo?> _pickWindow(BuildContext context, AppServices s, ScreenInfo screen) async {
  final exe = s.ffmpeg.ffmpeg;
  if (exe == null) return null;
  final saved = WinScreen.ownRect();
  final list = [for (final w in WinScreen.windows()) if (w.rect.overlaps(screen.rect)) w];
  final shot = await _Gdi.still(exe, screen);
  if (shot == null) return null;
  AppNav.instance.fullscreen.value = true;
  await windowManager.setMinimumSize(const Size(200, 40));
  WinScreen.place(screen.rect, onTop: true);
  if (!context.mounted) return null;
  final picked = await Navigator.of(context).push<WindowInfo>(MaterialPageRoute(builder: (_) => _WindowPicker(shot: shot, screen: screen, windows: list)));
  AppNav.instance.fullscreen.value = false;
  if (saved != null) WinScreen.place(saved, onTop: false);
  await windowManager.setMinimumSize(const Size(960, 620));
  try {
    await shot.delete();
  } catch (_) {}
  return picked;
}

class _WindowPicker extends StatefulWidget {
  const _WindowPicker({required this.shot, required this.screen, required this.windows});

  final File shot;
  final ScreenInfo screen;
  final List<WindowInfo> windows;

  @override
  State<_WindowPicker> createState() => _WindowPickerState();
}

class _WindowPickerState extends State<_WindowPicker> {
  WindowInfo? _over;

  WindowInfo? _at(Offset local, Size size) {
    final r = widget.screen.rect;
    final p = Offset(r.left + local.dx / size.width * r.width, r.top + local.dy / size.height * r.height);
    return WinScreen.windowAt(widget.windows, p);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: Colors.black,
        body: LayoutBuilder(builder: (context, c) {
          final size = Size(c.maxWidth, c.maxHeight);
          final r = widget.screen.rect;
          Rect? box;
          final o = _over;
          if (o != null) {
            box = Rect.fromLTRB(
              (o.rect.left - r.left) / r.width * size.width,
              (o.rect.top - r.top) / r.height * size.height,
              (o.rect.right - r.left) / r.width * size.width,
              (o.rect.bottom - r.top) / r.height * size.height,
            ).intersect(Offset.zero & size);
          }
          return Focus(
            autofocus: true,
            onKeyEvent: (_, e) {
              if (e is KeyDownEvent && e.logicalKey == LogicalKeyboardKey.escape) {
                Navigator.pop(context);
                return KeyEventResult.handled;
              }
              return KeyEventResult.ignored;
            },
            child: MouseRegion(
              cursor: SystemMouseCursors.click,
              onHover: (e) {
                final w = _at(e.localPosition, size);
                if (w?.handle != _over?.handle) setState(() => _over = w);
              },
              child: GestureDetector(
                onTapUp: (d) {
                  final w = _at(d.localPosition, size);
                  if (w != null) Navigator.pop(context, w);
                },
                child: Stack(fit: StackFit.expand, children: [
                  Image.file(widget.shot, fit: BoxFit.fill),
                  CustomPaint(painter: _AreaPainter(box)),
                  Positioned(
                    top: 24,
                    left: 0,
                    right: 0,
                    child: Center(
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                        decoration: BoxDecoration(color: const Color(0xE6202020), borderRadius: BorderRadius.circular(10)),
                        child: Text(o == null ? tr('screen.pick_window_tip') : o.title, style: const TextStyle(color: Colors.white)),
                      ),
                    ),
                  ),
                ]),
              ),
            ),
          );
        }),
      );
}

/// Drag a box on a still of the screen (LocalRoll covers that screen for it).
Future<Rect?> _pickArea(BuildContext context, AppServices s, ScreenInfo screen) async {
  final exe = s.ffmpeg.ffmpeg;
  if (exe == null) return null;
  final saved = WinScreen.ownRect();
  final shot = await _Gdi.still(exe, screen);
  if (shot == null) return null;
  AppNav.instance.fullscreen.value = true;
  await windowManager.setMinimumSize(const Size(200, 40));
  WinScreen.place(screen.rect, onTop: true);
  if (!context.mounted) return null;
  final picked = await Navigator.of(context).push<Rect>(MaterialPageRoute(builder: (_) => _AreaPicker(shot: shot)));
  AppNav.instance.fullscreen.value = false;
  if (saved != null) WinScreen.place(saved, onTop: false);
  await windowManager.setMinimumSize(const Size(960, 620));
  try {
    await shot.delete();
  } catch (_) {}
  if (picked == null) return null;
  // From 0–1 of the screen to its pixels (even sizes).
  final r = Rect.fromLTWH(
    screen.rect.left + picked.left * screen.rect.width,
    screen.rect.top + picked.top * screen.rect.height,
    picked.width * screen.rect.width,
    picked.height * screen.rect.height,
  );
  return r.width < 64 || r.height < 64 ? null : r;
}

class _AreaPicker extends StatefulWidget {
  const _AreaPicker({required this.shot});

  final File shot;

  @override
  State<_AreaPicker> createState() => _AreaPickerState();
}

class _AreaPickerState extends State<_AreaPicker> {
  Offset? _a, _b;

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: Colors.black,
        body: LayoutBuilder(builder: (context, c) {
          final size = Size(c.maxWidth, c.maxHeight);
          final r = _a == null || _b == null ? null : Rect.fromPoints(_a!, _b!);
          return Focus(
            autofocus: true,
            onKeyEvent: (_, e) {
              if (e is KeyDownEvent && e.logicalKey.keyLabel == 'Escape') {
                Navigator.pop(context);
                return KeyEventResult.handled;
              }
              return KeyEventResult.ignored;
            },
            child: GestureDetector(
              onPanStart: (d) => setState(() {
                _a = d.localPosition;
                _b = d.localPosition;
              }),
              onPanUpdate: (d) => setState(() => _b = d.localPosition),
              onPanEnd: (_) {
                if (r == null || r.width < 20 || r.height < 20) return;
                Navigator.pop(context, Rect.fromLTWH(r.left / size.width, r.top / size.height, r.width / size.width, r.height / size.height));
              },
              child: MouseRegion(
                cursor: SystemMouseCursors.precise,
                child: Stack(fit: StackFit.expand, children: [
                  if (widget.shot.existsSync()) Image.file(widget.shot, fit: BoxFit.fill),
                  CustomPaint(painter: _AreaPainter(r)),
                  Positioned(
                    top: 24,
                    left: 0,
                    right: 0,
                    child: Center(
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                        decoration: BoxDecoration(color: const Color(0xE6202020), borderRadius: BorderRadius.circular(10)),
                        child: Text(tr('screen.drag_area'), style: const TextStyle(color: Colors.white)),
                      ),
                    ),
                  ),
                ]),
              ),
            ),
          );
        }),
      );
}

class _AreaPainter extends CustomPainter {
  _AreaPainter(this.r);

  final Rect? r;

  @override
  void paint(Canvas canvas, Size size) {
    final dim = Paint()..color = const Color(0x88000000);
    final box = r;
    if (box == null) {
      canvas.drawRect(Offset.zero & size, dim);
      return;
    }
    canvas.drawPath(Path.combine(PathOperation.difference, Path()..addRect(Offset.zero & size), Path()..addRect(box)), dim);
    canvas.drawRect(
      box,
      Paint()
        ..color = LrColors.safelight
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
    final tp = TextPainter(
      text: TextSpan(text: '${box.width.round()} × ${box.height.round()}', style: const TextStyle(color: Colors.white, fontSize: 13)),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, box.bottomRight + const Offset(-80, 6));
  }

  @override
  bool shouldRepaint(_AreaPainter old) => old.r != r;
}

/// LocalRoll while recording the screen: just the bar (never in the video),
/// or — with the pen — the whole screen to draw on.
class ScreenRecordPage extends StatelessWidget {
  const ScreenRecordPage({super.key});

  @override
  Widget build(BuildContext context) {
    final r = ScreenRecorder.instance;
    return PopScope(
      canPop: false,
      child: ListenableBuilder(
        listenable: r,
        builder: (context, _) {
          final bar = _Bar(r: r);
          if (!r.pen || r.editor == null) {
            return Scaffold(backgroundColor: LrColors.ink, body: Center(child: bar));
          }
          final ed = r.editor!;
          return Scaffold(
            backgroundColor: Colors.black,
            body: Stack(fit: StackFit.expand, children: [
              if (r.penPicture != null) Image.file(r.penPicture!, fit: BoxFit.fill, gaplessPlayback: true),
              InkLayer(notes: const [], video: false, editor: ed),
              Positioned(
                top: 8,
                left: 0,
                right: 0,
                child: Center(
                  child: InkToolbar(
                    editor: ed,
                    onDone: () => unawaited(r.togglePen()),
                    doneLabel: tr('screen.pen_off'),
                    extra: [
                      FilterChip(
                        selected: r.fade,
                        onSelected: r.setFade,
                        label: Text(tr('screen.fade')),
                        tooltip: tr('screen.fade_tip'),
                      ),
                      const SizedBox(width: 6),
                    ],
                  ),
                ),
              ),
              Positioned(bottom: 16, left: 0, right: 0, child: Center(child: bar)),
            ]),
          );
        },
      ),
    );
  }
}

class _Bar extends StatelessWidget {
  const _Bar({required this.r});

  final ScreenRecorder r;

  @override
  Widget build(BuildContext context) {
    if (r.countdown > 0) {
      return Text(tr('screen.starting_in', {'n': r.countdown}), style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w600));
    }
    return Material(
      color: Colors.transparent,
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        RecordingBar(
          elapsed: () => r.elapsedMs,
          paused: r.paused,
          level: r.level,
          onPause: () => unawaited(r.togglePause()),
          onStop: () => unawaited(r.stop()),
        ),
        const SizedBox(width: 6),
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: IconButton.filledTonal(
            tooltip: tr(r.pen ? 'screen.pen_off' : 'screen.pen_on'),
            isSelected: r.pen,
            onPressed: () => unawaited(r.togglePen()),
            icon: const Icon(Icons.brush_rounded),
          ),
        ),
      ]),
    );
  }
}
