// apps/desktop/lib/services/keep_awake.dart
import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:flutter/foundation.dart';

typedef _LocalAllocC = IntPtr Function(Uint32 flags, IntPtr bytes);
typedef _LocalAllocD = int Function(int flags, int bytes);
typedef _PowerCreateC = IntPtr Function(IntPtr context);
typedef _PowerCreateD = int Function(int context);
typedef _PowerSetC = Int32 Function(IntPtr handle, Int32 type);
typedef _PowerSetD = int Function(int handle, int type);

/// Stops Windows from going to sleep while phones are sending, then lets it
/// sleep again ~90 s after the last chunk. Uses a power request (shows up in
/// `powercfg /requests` as "LocalRoll is receiving files"); the screen may
/// still turn off.
class KeepAwake {
  KeepAwake._();

  static final KeepAwake instance = KeepAwake._();

  static const int _powerRequestSystemRequired = 1;
  static const Duration _idle = Duration(seconds: 90);

  int _handle = 0;
  bool _active = false;
  bool _failed = false;
  Timer? _timer;

  _PowerSetD? _set;
  _PowerSetD? _clear;

  /// Call on every received chunk.
  void ping() {
    if (!Platform.isWindows || _failed) return;
    _timer?.cancel();
    _timer = Timer(_idle, _release);
    if (!_active) _acquire();
  }

  void _acquire() {
    try {
      if (_handle == 0) {
        final k32 = DynamicLibrary.open('kernel32.dll');
        final localAlloc = k32.lookupFunction<_LocalAllocC, _LocalAllocD>('LocalAlloc');
        final create = k32.lookupFunction<_PowerCreateC, _PowerCreateD>('PowerCreateRequest');
        _set = k32.lookupFunction<_PowerSetC, _PowerSetD>('PowerSetRequest');
        _clear = k32.lookupFunction<_PowerSetC, _PowerSetD>('PowerClearRequest');

        // UTF-16 reason string (kept for the life of the process).
        const reason = 'LocalRoll is receiving files';
        final str = Pointer<Uint16>.fromAddress(localAlloc(0x40, (reason.length + 1) * 2));
        for (var i = 0; i < reason.length; i++) {
          str[i] = reason.codeUnitAt(i);
        }
        // REASON_CONTEXT { ULONG Version; DWORD Flags; union { LPWSTR SimpleReasonString; ... } }
        // x64 layout: 4 + 4 bytes, then the pointer at offset 8 (union is 24 bytes).
        final ctx = Pointer<Uint8>.fromAddress(localAlloc(0x40, 32));
        ctx.cast<Uint32>()[0] = 0; // POWER_REQUEST_CONTEXT_VERSION
        ctx.cast<Uint32>()[1] = 1; // POWER_REQUEST_CONTEXT_SIMPLE_STRING
        (ctx + 8).cast<IntPtr>().value = str.address;

        final h = create(ctx.address);
        if (h == 0 || h == -1) {
          _failed = true;
          return;
        }
        _handle = h;
      }
      if (_set!(_handle, _powerRequestSystemRequired) != 0) _active = true;
    } catch (e) {
      debugPrint('keep-awake unavailable: $e');
      _failed = true;
    }
  }

  void _release() {
    if (!_active) return;
    try {
      _clear!(_handle, _powerRequestSystemRequired);
    } catch (_) {}
    _active = false;
  }
}
