// apps/desktop/lib/services/secret_box.dart
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

/// Secrets this PC must keep readable for itself (the tokens it uses to
/// sign in at other PCs), sealed with Windows' own per-user protection
/// (DPAPI): a copy of settings.json taken to another account or computer
/// can't be read. Elsewhere (tests on Linux) they are kept as they are.
abstract final class SecretBox {
  static const _dpapi = 'dpapi:';
  static const _plain = 'plain:';

  static String seal(String secret) {
    if (secret.isEmpty || !Platform.isWindows) return '$_plain$secret';
    try {
      final out = _crypt(protect: true, Uint8List.fromList(utf8.encode(secret)));
      if (out != null) return '$_dpapi${base64.encode(out)}';
    } catch (_) {}
    return '$_plain$secret';
  }

  /// The secret, or null when it can't be opened here (another Windows
  /// account or computer).
  static String? open(String sealed) {
    if (sealed.startsWith(_plain)) return sealed.substring(_plain.length);
    if (!sealed.startsWith(_dpapi) || !Platform.isWindows) return null;
    try {
      final out = _crypt(protect: false, base64.decode(sealed.substring(_dpapi.length)));
      return out == null ? null : utf8.decode(out);
    } catch (_) {
      return null;
    }
  }

  static const int _uiForbidden = 0x1; // CRYPTPROTECT_UI_FORBIDDEN

  static Uint8List? _crypt(Uint8List input, {required bool protect}) {
    final crypt32 = DynamicLibrary.open('crypt32.dll');
    final kernel32 = DynamicLibrary.open('kernel32.dll');
    final fn = crypt32.lookupFunction<_CryptNative, _CryptDart>(protect ? 'CryptProtectData' : 'CryptUnprotectData');
    final localFree = kernel32.lookupFunction<IntPtr Function(Pointer<Void>), int Function(Pointer<Void>)>('LocalFree');
    final inBlob = calloc<_Blob>();
    final outBlob = calloc<_Blob>();
    final buf = calloc<Uint8>(input.isEmpty ? 1 : input.length);
    try {
      buf.asTypedList(input.length).setAll(0, input);
      inBlob.ref
        ..cbData = input.length
        ..pbData = buf;
      final ok = fn(inBlob, nullptr, nullptr, nullptr, nullptr, _uiForbidden, outBlob);
      if (ok == 0 || outBlob.ref.pbData == nullptr) return null;
      final out = Uint8List.fromList(outBlob.ref.pbData.asTypedList(outBlob.ref.cbData));
      localFree(outBlob.ref.pbData.cast());
      return out;
    } finally {
      calloc.free(buf);
      calloc.free(inBlob);
      calloc.free(outBlob);
    }
  }
}

/// DATA_BLOB
final class _Blob extends Struct {
  @Uint32()
  external int cbData;
  external Pointer<Uint8> pbData;
}

typedef _CryptNative = Int32 Function(
  Pointer<_Blob> dataIn,
  Pointer<Void> description,
  Pointer<_Blob> entropy,
  Pointer<Void> reserved,
  Pointer<Void> prompt,
  Uint32 flags,
  Pointer<_Blob> dataOut,
);
typedef _CryptDart = int Function(
  Pointer<_Blob> dataIn,
  Pointer<Void> description,
  Pointer<_Blob> entropy,
  Pointer<Void> reserved,
  Pointer<Void> prompt,
  int flags,
  Pointer<_Blob> dataOut,
);
