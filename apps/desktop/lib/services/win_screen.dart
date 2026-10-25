// apps/desktop/lib/services/win_screen.dart
import 'dart:ffi';
import 'dart:io';
import 'dart:ui' show Rect, Offset;

import 'package:ffi/ffi.dart';

final class _RECT extends Struct {
  @Int32()
  external int left;
  @Int32()
  external int top;
  @Int32()
  external int right;
  @Int32()
  external int bottom;
}

final class _POINT extends Struct {
  @Int32()
  external int x;
  @Int32()
  external int y;
}

final class _MONITORINFO extends Struct {
  @Uint32()
  external int cbSize;
  external _RECT rcMonitor;
  external _RECT rcWork;
  @Uint32()
  external int dwFlags;
}

/// A screen (pixels, as Windows has them).
class ScreenInfo {
  const ScreenInfo({required this.index, required this.rect, required this.primary, required this.scale});

  final int index;
  final Rect rect;
  final bool primary;

  /// Windows' scaling for it (1.0 = 100 %).
  final double scale;
}

/// A window that can be recorded.
class WindowInfo {
  const WindowInfo({required this.handle, required this.title, required this.rect});

  final int handle;
  final String title;
  final Rect rect;
}

/// The bits of Windows the screen recorder needs: the screens, the open
/// windows, where the mouse is and what is pressed, keeping LocalRoll's own
/// window out of the recording, moving it.
class WinScreen {
  WinScreen._();

  static final DynamicLibrary? _user32 = Platform.isWindows ? DynamicLibrary.open('user32.dll') : null;
  static final DynamicLibrary? _dwm = Platform.isWindows ? DynamicLibrary.open('dwmapi.dll') : null;
  static DynamicLibrary? _shcore;

  static final List<ScreenInfo> _found = [];
  static final List<WindowInfo> _windows = [];
  static int _skip = 0;

  static int _onMonitor(int hMon, int hdc, Pointer<_RECT> r, int data) {
    final info = calloc<_MONITORINFO>();
    try {
      info.ref.cbSize = sizeOf<_MONITORINFO>();
      final get = _user32!.lookupFunction<Int32 Function(IntPtr, Pointer<_MONITORINFO>), int Function(int, Pointer<_MONITORINFO>)>('GetMonitorInfoW');
      if (get(hMon, info) != 0) {
        final m = info.ref.rcMonitor;
        _found.add(ScreenInfo(
          index: _found.length,
          rect: Rect.fromLTRB(m.left.toDouble(), m.top.toDouble(), m.right.toDouble(), m.bottom.toDouble()),
          primary: info.ref.dwFlags & 1 != 0,
          scale: _dpiOf(hMon) / 96,
        ));
      }
    } finally {
      calloc.free(info);
    }
    return 1;
  }

  static int _dpiOf(int hMon) {
    try {
      _shcore ??= DynamicLibrary.open('shcore.dll');
      final get = _shcore!.lookupFunction<Int32 Function(IntPtr, Int32, Pointer<Uint32>, Pointer<Uint32>), int Function(int, int, Pointer<Uint32>, Pointer<Uint32>)>(
          'GetDpiForMonitor');
      final x = calloc<Uint32>(), y = calloc<Uint32>();
      try {
        return get(hMon, 0, x, y) == 0 && x.value > 0 ? x.value : 96;
      } finally {
        calloc
          ..free(x)
          ..free(y);
      }
    } catch (_) {
      return 96;
    }
  }

  /// The screens, the main one first.
  static List<ScreenInfo> screens() {
    final u = _user32;
    if (u == null) return const [];
    _found.clear();
    final enumMon = u.lookupFunction<Int32 Function(IntPtr, Pointer<Void>, Pointer<NativeFunction<Int32 Function(IntPtr, IntPtr, Pointer<_RECT>, IntPtr)>>, IntPtr),
        int Function(int, Pointer<Void>, Pointer<NativeFunction<Int32 Function(IntPtr, IntPtr, Pointer<_RECT>, IntPtr)>>, int)>('EnumDisplayMonitors');
    enumMon(0, nullptr, Pointer.fromFunction<Int32 Function(IntPtr, IntPtr, Pointer<_RECT>, IntPtr)>(_onMonitor, 0), 0);
    final out = List.of(_found)..sort((a, b) => (b.primary ? 1 : 0) - (a.primary ? 1 : 0));
    return [for (var i = 0; i < out.length; i++) ScreenInfo(index: i, rect: out[i].rect, primary: out[i].primary, scale: out[i].scale)];
  }

  static String _title(int hwnd) {
    final u = _user32!;
    final len = u.lookupFunction<Int32 Function(IntPtr), int Function(int)>('GetWindowTextLengthW')(hwnd);
    if (len <= 0) return '';
    final buf = calloc<Uint16>(len + 1);
    try {
      u.lookupFunction<Int32 Function(IntPtr, Pointer<Utf16>, Int32), int Function(int, Pointer<Utf16>, int)>('GetWindowTextW')(hwnd, buf.cast(), len + 1);
      return buf.cast<Utf16>().toDartString();
    } finally {
      calloc.free(buf);
    }
  }

  /// Where [hwnd] is (its visible frame), or null when it is gone or minimised.
  static Rect? windowRect(int hwnd) {
    final u = _user32;
    if (u == null) return null;
    if (u.lookupFunction<Int32 Function(IntPtr), int Function(int)>('IsWindow')(hwnd) == 0) return null;
    if (u.lookupFunction<Int32 Function(IntPtr), int Function(int)>('IsIconic')(hwnd) != 0) return null;
    final r = calloc<_RECT>();
    try {
      var ok = false;
      try {
        final get = _dwm!.lookupFunction<Int32 Function(IntPtr, Uint32, Pointer<Void>, Uint32), int Function(int, int, Pointer<Void>, int)>('DwmGetWindowAttribute');
        ok = get(hwnd, 9, r.cast(), sizeOf<_RECT>()) == 0; // the frame as seen
      } catch (_) {}
      if (!ok) ok = u.lookupFunction<Int32 Function(IntPtr, Pointer<_RECT>), int Function(int, Pointer<_RECT>)>('GetWindowRect')(hwnd, r) != 0;
      if (!ok) return null;
      return Rect.fromLTRB(r.ref.left.toDouble(), r.ref.top.toDouble(), r.ref.right.toDouble(), r.ref.bottom.toDouble());
    } finally {
      calloc.free(r);
    }
  }

  static int _onWindow(int hwnd, int data) {
    final u = _user32!;
    if (hwnd == _skip) return 1;
    if (u.lookupFunction<Int32 Function(IntPtr), int Function(int)>('IsWindowVisible')(hwnd) == 0) return 1;
    final ex = u.lookupFunction<IntPtr Function(IntPtr, Int32), int Function(int, int)>('GetWindowLongPtrW')(hwnd, -20);
    if (ex & 0x80 != 0) return 1; // tool windows
    try {
      final cloaked = calloc<Uint32>();
      try {
        final get = _dwm!.lookupFunction<Int32 Function(IntPtr, Uint32, Pointer<Void>, Uint32), int Function(int, int, Pointer<Void>, int)>('DwmGetWindowAttribute');
        if (get(hwnd, 14, cloaked.cast(), 4) == 0 && cloaked.value != 0) return 1; // hidden apps
      } finally {
        calloc.free(cloaked);
      }
    } catch (_) {}
    final t = _title(hwnd);
    if (t.trim().isEmpty || t == 'Program Manager') return 1;
    final r = windowRect(hwnd);
    if (r == null || r.width < 80 || r.height < 60) return 1;
    _windows.add(WindowInfo(handle: hwnd, title: t, rect: r));
    return 1;
  }

  /// The windows open now (not LocalRoll's own), front to back.
  static List<WindowInfo> windows() {
    final u = _user32;
    if (u == null) return const [];
    _windows.clear();
    _skip = ownWindow();
    final enumWin = u.lookupFunction<Int32 Function(Pointer<NativeFunction<Int32 Function(IntPtr, IntPtr)>>, IntPtr),
        int Function(Pointer<NativeFunction<Int32 Function(IntPtr, IntPtr)>>, int)>('EnumWindows');
    enumWin(Pointer.fromFunction<Int32 Function(IntPtr, IntPtr)>(_onWindow, 0), 0);
    return List.of(_windows);
  }

  /// LocalRoll's own window (0: not found).
  static int ownWindow() {
    final u = _user32;
    if (u == null) return 0;
    final find = u.lookupFunction<IntPtr Function(Pointer<Utf16>, Pointer<Utf16>), int Function(Pointer<Utf16>, Pointer<Utf16>)>('FindWindowW');
    final cls = 'FLUTTER_RUNNER_WIN32_WINDOW'.toNativeUtf16(), title = 'LocalRoll'.toNativeUtf16();
    try {
      final h = find(cls, title);
      return h != 0 ? h : find(nullptr, title);
    } finally {
      calloc
        ..free(cls)
        ..free(title);
    }
  }

  /// Keep LocalRoll's own window out of recordings and screenshots (shown
  /// to the person, never in the video). Windows 10 2004 and later.
  static bool excludeFromCapture(bool on) {
    final u = _user32;
    final h = ownWindow();
    if (u == null || h == 0) return false;
    try {
      final set = u.lookupFunction<Int32 Function(IntPtr, Uint32), int Function(int, int)>('SetWindowDisplayAffinity');
      return set(h, on ? 0x11 : 0) != 0;
    } catch (_) {
      return false;
    }
  }

  /// Puts LocalRoll's window at [r] (pixels), on top of everything or not.
  static void place(Rect r, {required bool onTop}) {
    final u = _user32;
    final h = ownWindow();
    if (u == null || h == 0) return;
    final set = u.lookupFunction<Int32 Function(IntPtr, IntPtr, Int32, Int32, Int32, Int32, Uint32), int Function(int, int, int, int, int, int, int)>('SetWindowPos');
    // SWP_SHOWWINDOW | SWP_NOACTIVATE? No: it is used, so activate.
    set(h, onTop ? -1 : -2, r.left.round(), r.top.round(), r.width.round(), r.height.round(), 0x0040);
  }

  /// Where LocalRoll's window is (pixels).
  static Rect? ownRect() {
    final h = ownWindow();
    return h == 0 ? null : windowRect(h);
  }

  /// The mouse, in screen pixels.
  static Offset cursor() {
    final u = _user32;
    if (u == null) return Offset.zero;
    final p = calloc<_POINT>();
    try {
      u.lookupFunction<Int32 Function(Pointer<_POINT>), int Function(Pointer<_POINT>)>('GetCursorPos')(p);
      return Offset(p.ref.x.toDouble(), p.ref.y.toDouble());
    } finally {
      calloc.free(p);
    }
  }

  static int Function(int)? _keyState;

  /// Whether key [vk] is held down now (anywhere, not only in LocalRoll).
  static bool down(int vk) {
    final u = _user32;
    if (u == null) return false;
    _keyState ??= u.lookupFunction<Int16 Function(Int32), int Function(int)>('GetAsyncKeyState');
    return _keyState!(vk) & 0x8000 != 0;
  }
}
