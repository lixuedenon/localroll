// apps/desktop/test/models_load_test.dart
//
// On the Windows build machine only (after `flutter build windows`): the
// bundled face models really load and answer through onnxruntime.dll, the
// way the app runs them. Elsewhere: skipped. Each step is written to
// models-steps.txt as it happens (a crash in native code ends the process
// before the test can report).
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:localroll_desktop/services/face_engine.dart';
import 'package:onnxruntime/onnxruntime.dart';

void main() {
  final sep = Platform.pathSeparator;
  final built = Directory('build${sep}windows${sep}x64${sep}runner${sep}Release${sep}models');
  final dir = Platform.isWindows && built.existsSync() ? built.absolute.path : null;
  final steps = File('models-steps.txt');
  void step(String s) => steps.writeAsStringSync('$s\n', mode: FileMode.append, flush: true);

  test('face models load here, directly', () {
    if (dir == null) {
      markTestSkipped('only on the Windows build machine');
      return;
    }
    step('folder: $dir');
    OrtEnv.instance.init();
    step('env ready');
    final opts = OrtSessionOptions()..setIntraOpNumThreads(1);
    step('options ready');
    final bytes = File('$dir${sep}face-detect.onnx').readAsBytesSync();
    step('read ${bytes.length} bytes');
    final s = OrtSession.fromBuffer(bytes, opts);
    step('session ready: ${s.inputNames} -> ${s.outputNames.length} outputs');
    s.release();
    opts.release();
    step('released');
  });

  test('face models load and read a picture (as the app does)', () async {
    if (dir == null) {
      markTestSkipped('only on the Windows build machine');
      return;
    }
    final engine = FaceEngine(folder: dir);
    expect(engine.available, isTrue, reason: 'models in $dir');
    step('engine: asking');
    final rgb = Uint8List(320 * 240 * 3)..fillRange(0, 320 * 240 * 3, 128);
    final faces = await engine.read(rgb, 320, 240);
    engine.close();
    step('face models: ${faces == null ? 'no answer: ${engine.lastError}' : 'ok, ${faces.length} faces'}');
    expect(engine.lastError, isNull, reason: engine.lastError);
    expect(faces, isNotNull, reason: engine.lastError);
    expect(faces, isEmpty);
  }, timeout: const Timeout(Duration(minutes: 2)));
}
