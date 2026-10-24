// apps/desktop/lib/services/single_instance.dart
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

typedef _CreateMutexC = IntPtr Function(Pointer<Void> attrs, Int32 owner, Pointer<Utf16> name);
typedef _CreateMutexDart = int Function(Pointer<Void> attrs, int owner, Pointer<Utf16> name);
typedef _WaitC = Uint32 Function(IntPtr handle, Uint32 ms);
typedef _WaitDart = int Function(int handle, int ms);

/// "Only one LocalRoll at a time", the Windows way: a named mutex for this
/// Windows user's session. The first copy owns it while it runs; any other
/// copy sees that and hands over instead of starting.
class SingleInstance {
  SingleInstance._();

  static const String _name = r'Local\LocalRoll.SingleInstance.v1';

  /// Kept for as long as the app runs (Windows lets go when it exits).
  static int _handle = 0;

  /// True: this is the only copy (or it can't be told — then the other
  /// checks decide). False: another LocalRoll is running.
  static bool claim() {
    if (!Platform.isWindows) return true;
    try {
      final k32 = DynamicLibrary.open('kernel32.dll');
      final create = k32.lookupFunction<_CreateMutexC, _CreateMutexDart>('CreateMutexW');
      final wait = k32.lookupFunction<_WaitC, _WaitDart>('WaitForSingleObject');
      final name = _name.toNativeUtf16();
      try {
        final h = create(nullptr, 0, name);
        if (h == 0) return true;
        // 0: ours now; 0x80: its owner died without letting go (ours too);
        // 0x102 (timed out): another copy owns it.
        final r = wait(h, 0);
        if (r == 0 || r == 0x80) {
          _handle = h;
          return true;
        }
        return false;
      } finally {
        malloc.free(name);
      }
    } catch (_) {
      return true;
    }
  }

  /// Held (for tests / logs).
  static bool get held => _handle != 0;
}
