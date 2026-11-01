// apps/desktop/lib/services/camera_bubble.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show Rect;

import 'package:flutter/foundation.dart';
import 'package:localroll_core/localroll_core.dart';

import 'player_memory.dart';

/// Where the bubble was from a moment of a recording on (normalised to
/// the area it sits on: x, y of its top-left, side to that area's height).
class CameraMove {
  const CameraMove({required this.t, required this.x, required this.y, required this.side, required this.round});

  final int t;
  final double x, y, side;
  final bool round;

  Map<String, dynamic> toJson() => {'t': t, 'x': x, 'y': y, 's': side, 'r': round};

  static CameraMove fromJson(Map<String, dynamic> j) => CameraMove(
        t: (j['t'] as num).toInt(),
        x: (j['x'] as num).toDouble(),
        y: (j['y'] as num).toDouble(),
        side: (j['s'] as num).toDouble(),
        round: j['r'] != false,
      );
}

/// The camera bubble (lr_camera.exe next to LocalRoll's exe): the webcam
/// in a small round / rounded-square window on top, dragged anywhere,
/// double-click for the other shape. Only while getting ready to record
/// and recording, and only when it is switched on.
class CameraBubble extends ChangeNotifier {
  CameraBubble._();

  static final CameraBubble instance = CameraBubble._();

  static String get exe => '${File(Platform.resolvedExecutable).parent.path}${Platform.pathSeparator}lr_camera.exe';

  static bool get available => Platform.isWindows && File(exe).existsSync();

  static const List<int> sides = [160, 240, 320];

  Process? _p;
  final List<String> _lines = [];
  Completer<void>? _wait;

  /// Showing now.
  bool showing = false;

  /// Screen pixels (top-left, side) and shape now.
  int x = 0, y = 0, side = 0;
  bool round = true;

  /// The last thing that went wrong ("nocamera", "open").
  String? problem;

  PlayerMemory? _m;
  Rect? _area;
  double _scale = 1;

  /// Moves while recording (see [startRecording]).
  void Function(int x, int y, int side, bool round)? onMoved;

  Future<bool> _start() async {
    if (_p != null) return true;
    if (!available) return false;
    try {
      final p = _p = await Process.start(exe, const []);
      p.stdout.transform(const Utf8Decoder(allowMalformed: true)).transform(const LineSplitter()).listen(_line);
      p.stderr.drain<void>().ignore();
      unawaited(p.exitCode.then((code) {
        if (identical(_p, p)) {
          _p = null;
          showing = false;
          if (code != 0) DiagLog.log('camera', 'helper ended ($code)');
          notifyListeners();
        }
      }));
      final ok = await _answer((l) => l == 'ready' || l.startsWith('error'), const Duration(seconds: 6));
      if (ok != 'ready') {
        DiagLog.log('camera', 'helper did not start: $ok');
        await quit();
        return false;
      }
      return true;
    } catch (e) {
      DiagLog.log('camera', 'helper not started: $e');
      _p = null;
      return false;
    }
  }

  void _line(String l) {
    if (l.startsWith('pos ')) {
      final v = l.split(' ');
      if (v.length >= 5) {
        x = int.tryParse(v[1]) ?? x;
        y = int.tryParse(v[2]) ?? y;
        side = int.tryParse(v[3]) ?? side;
        final r = v[4] == 'round';
        if (r != round) _m?.setCamera(round: r);
        round = r;
        onMoved?.call(x, y, side, round);
        notifyListeners();
      }
      return;
    }
    if (l.startsWith('error lost')) DiagLog.log('camera', 'camera stopped sending');
    _lines.add(l);
    _wait?.complete();
    _wait = null;
  }

  /// The next line [match] accepts (null when none in time).
  Future<String?> _answer(bool Function(String) match, Duration limit) async {
    final end = DateTime.now().add(limit);
    while (true) {
      final i = _lines.indexWhere(match);
      if (i >= 0) {
        final l = _lines[i];
        _lines.removeRange(0, i + 1);
        return l;
      }
      final left = end.difference(DateTime.now());
      if (left.isNegative || _p == null) return null;
      final w = _wait = Completer<void>();
      await w.future.timeout(left, onTimeout: () {});
    }
  }

  void _send(String cmd) {
    try {
      _p?.stdin.add(utf8.encode('$cmd\n'));
    } catch (_) {}
  }

  /// The cameras there are (by name).
  Future<List<String>> cameras() async {
    if (!await _start()) return const [];
    _lines.clear();
    _send('list');
    final out = <String>[];
    while (true) {
      final l = await _answer((l) => l.startsWith('camera ') || l == 'end', const Duration(seconds: 5));
      if (l == null || l == 'end') break;
      out.add(l.substring(7));
    }
    return out;
  }

  /// Getting ready to record (or recording) on [area] (screen pixels, at
  /// [scale]): the bubble shows when it is switched on in [m].
  Future<void> begin(PlayerMemory m, Rect area, double scale) async {
    _m = m;
    _area = area;
    _scale = scale;
    await sync();
  }

  /// Not recording any more: the camera goes off.
  Future<void> end() async {
    _m = null;
    _area = null;
    onMoved = null;
    await _hide();
  }

  /// Shows / hides as [PlayerMemory.cameraOn] says (in a recording only).
  Future<void> sync() async {
    final m = _m, area = _area;
    if (m == null || area == null) return;
    if (!m.cameraOn) return _hide();
    if (showing) {
      // Size / mirror changed: the bottom-right corner stays.
      final s = (sides[m.cameraSize] * _scale).round();
      if (s != side) {
        x += side - s;
        y += side - s;
        side = s;
        _send('place $x $y $side');
      }
      _send('mirror ${m.cameraMirror ? 1 : 0}');
      return;
    }
    if (!await _start()) {
      problem = 'helper';
      notifyListeners();
      return;
    }
    _lines.clear();
    _send('open ${m.camera ?? ''}');
    final l = await _answer((l) => l.startsWith('opened ') || l.startsWith('error'), const Duration(seconds: 10));
    if (l == null || !l.startsWith('opened ')) {
      problem = l == 'error nocamera' ? 'nocamera' : 'open';
      DiagLog.log('camera', 'camera not opened: $l');
      m.setCamera(on: false);
      notifyListeners();
      return;
    }
    problem = null;
    final name = l.split(' ').skip(3).join(' ');
    if (name.isNotEmpty && name != m.camera) m.setCamera(name: name);
    if (_m == null) return _hide();
    side = (sides[m.cameraSize] * _scale).round();
    final gap = (24 * _scale).round();
    x = area.right.round() - side - gap;
    y = area.bottom.round() - side - gap;
    round = m.cameraRound;
    _send('dpi $_scale');
    _send('mirror ${m.cameraMirror ? 1 : 0}');
    _send('shape ${round ? 'round' : 'square'}');
    _send('place $x $y $side');
    _send('show');
    showing = true;
    DiagLog.log('camera', 'on');
    notifyListeners();
  }

  /// Shape switched from LocalRoll.
  void setRound(bool r) {
    round = r;
    _send('shape ${r ? 'round' : 'square'}');
    onMoved?.call(x, y, side, round);
  }

  Future<void> _hide() async {
    if (!showing && _p == null) return;
    await stopRecording();
    showing = false;
    // Off: the camera light goes off too.
    await quit();
    notifyListeners();
  }

  bool _recording = false;

  /// What it shows into [out] (square, [px] a side) through ffmpeg [exe]
  /// with [encoder] args; the clock pauses with [pause].
  Future<bool> startRecording(String exe, List<String> encoder, File out, {int px = 480, int fps = 30}) async {
    if (!showing || _recording) return false;
    final args = [
      exe, '-hide_banner', '-loglevel', 'error', '-y',
      '-f', 'rawvideo', '-pix_fmt', 'bgra', '-s', '${px}x$px', '-framerate', '$fps', '-i', '-',
      '-vf', 'format=nv12', ...encoder, '-g', '$fps', out.path,
    ];
    _lines.clear();
    _send('record $fps $px ${args.map(winQuote).join(' ')}');
    final l = await _answer((l) => l == 'recording' || l.startsWith('error'), const Duration(seconds: 5));
    _recording = l == 'recording';
    if (!_recording) DiagLog.log('camera', 'not recorded: $l');
    return _recording;
  }

  void pause(bool on) {
    if (_recording) _send(on ? 'pause' : 'resume');
  }

  /// Ends the recording; how many frames it has.
  Future<int> stopRecording() async {
    if (!_recording) return 0;
    _recording = false;
    _lines.clear();
    _send('stoprec');
    final l = await _answer((l) => l.startsWith('saved '), const Duration(seconds: 35));
    return int.tryParse(l?.substring(6) ?? '') ?? 0;
  }

  Future<void> quit() async {
    final p = _p;
    _p = null;
    showing = false;
    if (p == null) return;
    try {
      p.stdin.writeln('quit');
      await p.stdin.flush();
      await p.stdin.close();
    } catch (_) {}
    await p.exitCode.timeout(const Duration(seconds: 5), onTimeout: () {
      p.kill();
      return -1;
    });
  }
}

/// One argument for a Windows command line (CommandLineToArgv rules).
String winQuote(String a) {
  if (a.isNotEmpty && !a.contains(RegExp(r'[\s"]'))) return a;
  final b = StringBuffer('"');
  var slashes = 0;
  for (final c in a.split('')) {
    if (c == r'\') {
      slashes++;
      continue;
    }
    if (c == '"') {
      b.write(r'\' * (slashes * 2 + 1));
    } else {
      b.write(r'\' * slashes);
    }
    slashes = 0;
    b.write(c);
  }
  b.write(r'\' * (slashes * 2));
  b.write('"');
  return b.toString();
}
