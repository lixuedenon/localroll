// apps/desktop/test/models_load_test.dart
//
// On the Windows build machine only (after `flutter build windows`): the bundled
// face models really load and answer through onnxruntime.dll, the way the
// app runs them. Elsewhere: skipped.
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:localroll_desktop/services/face_engine.dart';

void main() {
  // The Windows build's own models folder (only there after a Windows build).
  final built = Directory('build${Platform.pathSeparator}windows${Platform.pathSeparator}x64${Platform.pathSeparator}runner'
      '${Platform.pathSeparator}Release${Platform.pathSeparator}models');
  final dir = Platform.isWindows && built.existsSync() ? built.absolute.path : null;
  // ignore: avoid_print
  print('face models folder: ${dir ?? 'none (skipped)'}');
  test('face models load and read a picture', () async {
    if (dir == null || dir.isEmpty) {
      markTestSkipped('only on the Windows build machine');
      return;
    }
    final engine = FaceEngine(folder: dir);
    expect(engine.available, isTrue, reason: 'models in $dir');
    // A plain grey picture: no faces, but a real answer.
    final rgb = Uint8List(320 * 240 * 3)..fillRange(0, 320 * 240 * 3, 128);
    final faces = await engine.read(rgb, 320, 240);
    engine.close();
    // ignore: avoid_print
    print('face models: ${faces == null ? 'no answer: ${engine.lastError}' : 'ok, ${faces.length} faces'}');
    expect(engine.lastError, isNull, reason: engine.lastError);
    expect(faces, isNotNull, reason: engine.lastError);
    expect(faces, isEmpty);
  }, timeout: const Timeout(Duration(minutes: 2)));
}
