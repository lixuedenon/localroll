// apps/desktop/test/models_load_test.dart
//
// On the Windows build machine only (LR_MODELS_DIR set by CI): the bundled
// face models really load and answer through onnxruntime.dll, the way the
// app runs them. Elsewhere: skipped.
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:localroll_desktop/services/face_engine.dart';

void main() {
  final dir = Platform.environment['LR_MODELS_DIR'];
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
    expect(engine.lastError, isNull);
    expect(faces, isNotNull);
    expect(faces, isEmpty);
  }, timeout: const Timeout(Duration(minutes: 2)));
}
