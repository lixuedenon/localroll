// apps/desktop/lib/services/remote_screen.dart
import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:localroll_core/localroll_core.dart' show DiagLog;

import 'win_screen.dart';

/// This PC's screen for a phone controlling it: pictures (JPEG, made by the
/// ffmpeg already here: nothing added) and the phone's touches done as
/// mouse and keyboard (Windows' own SendInput). Runs only while a phone
/// asks for pictures; stops 10 seconds after the last one.
class RemoteScreen {
  RemoteScreen(this.ffmpeg);

  /// ffmpeg.exe (null: none).
  final String? Function() ffmpeg;

  Process? _p;
  String _key = '';
  Uint8List? _last;
  int _id = 0;
  Completer<void>? _next;
  Timer? _idle;
  final BytesBuilder _buf = BytesBuilder(copy: false);

  /// The screen being sent (physical pixels).
  ScreenInfo? screen;

  /// The newest picture after [after] (waits up to 3 s for one); null: none.
  Future<(int, Uint8List)?> frame({required int index, required bool sharp, int after = 0}) async {
    final screens = WinScreen.screens();
    if (screens.isEmpty) return null;
    final scr = screens[index.clamp(0, screens.length - 1)];
    final key = '${scr.rect}|$sharp';
    if (_p == null || key != _key) await _start(scr, sharp, key);
    _idle?.cancel();
    _idle = Timer(const Duration(seconds: 10), stop);
    if (_last == null || _id <= after) {
      final c = _next ??= Completer<void>();
      try {
        await c.future.timeout(const Duration(seconds: 3));
      } catch (_) {}
    }
    final l = _last;
    return l == null ? null : (_id, l);
  }

  Future<void> _start(ScreenInfo scr, bool sharp, String key) async {
    stop();
    final exe = ffmpeg();
    if (exe == null) return;
    screen = scr;
    _key = key;
    final r = scr.rect;
    final w = r.width.round(), h = r.height.round();
    // Sharp: up to 1600 wide, 6 a second; smooth: up to 960 wide, 12 a second.
    final width = sharp ? 1600 : 960;
    final p = await Process.start(exe, [
      '-hide_banner', '-loglevel', 'error',
      '-f', 'gdigrab', '-framerate', sharp ? '6' : '12', '-draw_mouse', '1',
      '-offset_x', '${r.left.round()}', '-offset_y', '${r.top.round()}', '-video_size', '${w}x$h',
      '-i', 'desktop',
      '-vf', "scale='min($width,iw)':-2", '-q:v', sharp ? '5' : '8',
      '-f', 'mjpeg', 'pipe:1',
    ], environment: const {'__COMPAT_LAYER': 'HighDpiAware'});
    _p = p;
    DiagLog.log('remote', 'screen: sending ${w}x$h (${sharp ? 'sharp' : 'smooth'})');
    unawaited(p.stderr.drain<void>());
    p.stdout.listen(_onBytes, onDone: () {
      if (identical(_p, p)) _p = null;
    });
  }

  /// Cuts the stream into pictures (each one runs from FFD8 to FFD9).
  void _onBytes(List<int> chunk) {
    _buf.add(chunk);
    var b = _buf.takeBytes();
    while (true) {
      var start = -1;
      for (var i = 0; i + 1 < b.length; i++) {
        if (b[i] == 0xFF && b[i + 1] == 0xD8) {
          start = i;
          break;
        }
      }
      if (start < 0) {
        b = Uint8List(0);
        break;
      }
      var end = -1;
      for (var i = start + 2; i + 1 < b.length; i++) {
        if (b[i] == 0xFF && b[i + 1] == 0xD9) {
          end = i + 2;
          break;
        }
      }
      if (end < 0) {
        b = Uint8List.sublistView(b, start);
        break;
      }
      _last = Uint8List.fromList(Uint8List.sublistView(b, start, end));
      _id++;
      final c = _next;
      _next = null;
      c?.complete();
      b = Uint8List.sublistView(b, end);
    }
    if (b.isNotEmpty) _buf.add(b);
  }

  void stop() {
    _idle?.cancel();
    _p?.kill();
    _p = null;
    _key = '';
    _last = null;
  }

  // ------------------------------------------------------------ input

  static final DynamicLibrary? _u = Platform.isWindows ? DynamicLibrary.open('user32.dll') : null;

  /// Where (0–1 across the screen sent) in this PC's pixels.
  (int, int) _at(double x, double y) {
    final r = (screen ?? WinScreen.screens().firstOrNull)?.rect;
    if (r == null) return (0, 0);
    return ((r.left + x.clamp(0, 1) * r.width).round(), (r.top + y.clamp(0, 1) * r.height).round());
  }

  void _cursor(int x, int y) =>
      _u?.lookupFunction<Int32 Function(Int32, Int32), int Function(int, int)>('SetCursorPos')(x, y);

  ({int x, int y}) _pos() {
    final p = calloc<Int32>(2);
    try {
      _u?.lookupFunction<Int32 Function(Pointer<Int32>), int Function(Pointer<Int32>)>('GetCursorPos')(p);
      return (x: p[0], y: p[1]);
    } finally {
      calloc.free(p);
    }
  }

  void _mouse(int flags, [int data = 0]) =>
      _u?.lookupFunction<Void Function(Uint32, Uint32, Uint32, Int32, IntPtr), void Function(int, int, int, int, int)>('mouse_event')(
          flags, 0, 0, data, 0);

  static const _leftDown = 0x02, _leftUp = 0x04, _rightDown = 0x08, _rightUp = 0x10, _wheel = 0x800;

  /// One touch from the phone. [x], [y]: 0–1 across the picture.
  void input(Map<String, String> q) {
    final x = double.tryParse(q['x'] ?? '');
    final y = double.tryParse(q['y'] ?? '');
    void go() {
      if (x != null && y != null) {
        final (px, py) = _at(x, y);
        _cursor(px, py);
      }
    }

    switch (q['t']) {
      case 'move':
        go();
      case 'rel': // touchpad: pushed by (dx, dy) PC pixels
        final p = _pos();
        _cursor(p.x + (double.tryParse(q['dx'] ?? '') ?? 0).round(), p.y + (double.tryParse(q['dy'] ?? '') ?? 0).round());
      case 'click':
        go();
        _mouse(_leftDown);
        _mouse(_leftUp);
      case 'right':
        go();
        _mouse(_rightDown);
        _mouse(_rightUp);
      case 'down':
        go();
        _mouse(_leftDown);
      case 'up':
        go();
        _mouse(_leftUp);
      case 'scroll':
        go();
        _mouse(_wheel, ((double.tryParse(q['dy'] ?? '') ?? 0) * 120).round());
      case 'key':
        _keys(q['k'] ?? '');
      case 'text':
        _text(q['s'] ?? '');
    }
  }

  static const Map<String, List<int>> _named = {
    'esc': [0x1B], 'tab': [0x09], 'enter': [0x0D], 'back': [0x08], 'del': [0x2E], 'win': [0x5B],
    'up': [0x26], 'down': [0x28], 'left': [0x25], 'right': [0x27], 'home': [0x24], 'end': [0x23],
    'ctrl+c': [0x11, 0x43], 'ctrl+v': [0x11, 0x56], 'ctrl+z': [0x11, 0x5A], 'ctrl+a': [0x11, 0x41], 'ctrl+s': [0x11, 0x53],
    'alt+tab': [0x12, 0x09], 'alt+f4': [0x12, 0x73], 'win+d': [0x5B, 0x44],
  };

  void _keys(String name) {
    final ks = _named[name];
    if (ks == null) return;
    final f = _u?.lookupFunction<Void Function(Uint8, Uint8, Uint32, IntPtr), void Function(int, int, int, int)>('keybd_event');
    if (f == null) return;
    for (final k in ks) {
      f(k, 0, 0, 0);
    }
    for (final k in ks.reversed) {
      f(k, 0, 2, 0); // KEYEVENTF_KEYUP
    }
  }

  /// Typed text, as it is (any language): SendInput with KEYEVENTF_UNICODE.
  void _text(String s) {
    final u = _u;
    if (u == null || s.isEmpty) return;
    final send = u.lookupFunction<Uint32 Function(Uint32, Pointer<Uint8>, Int32), int Function(int, Pointer<Uint8>, int)>('SendInput');
    const size = 40; // INPUT on 64-bit Windows
    final units = s.codeUnits;
    final buf = calloc<Uint8>(size * units.length * 2);
    try {
      final bytes = buf.asTypedList(size * units.length * 2);
      final view = ByteData.sublistView(bytes);
      var i = 0;
      for (final c in units) {
        for (final up in [false, true]) {
          final o = i * size;
          view.setUint32(o, 1, Endian.little); // INPUT_KEYBOARD
          view.setUint16(o + 8, 0, Endian.little); // wVk
          view.setUint16(o + 10, c, Endian.little); // wScan
          view.setUint32(o + 12, 0x0004 | (up ? 0x0002 : 0), Endian.little); // UNICODE (| KEYUP)
          i++;
        }
      }
      send(i, buf, size);
    } finally {
      calloc.free(buf);
    }
  }
}
