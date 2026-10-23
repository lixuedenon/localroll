// apps/desktop/lib/services/face_engine.dart
import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:onnxruntime/onnxruntime.dart';

import 'face_math.dart';

/// One face read from a photo: where it is (0–1 of the picture's width /
/// height), how sure the finder was, and the reader's 128 numbers (length 1).
class FaceRead {
  const FaceRead(this.score, this.x, this.y, this.w, this.h, this.vector);

  final double score;
  final double x, y, w, h;
  final Float32List vector;
}

/// The two face models that come with LocalRoll (next to LocalRoll.exe, in
/// "models"): YuNet finds faces (MIT), SFace reads them (Apache 2.0). Run in
/// their own isolate, on this PC only.
class FaceEngine {
  FaceEngine({String? folder}) : folder = folder ?? '${File(Platform.resolvedExecutable).parent.path}${Platform.pathSeparator}models';

  final String folder;

  String get _detect => '$folder${Platform.pathSeparator}face-detect.onnx';
  String get _read => '$folder${Platform.pathSeparator}face-id.onnx';

  /// Both models are here (they come with the Windows build).
  bool get available => File(_detect).existsSync() && File(_read).existsSync();

  /// Faces smaller than this (pixels of the picture read, at most 1280 on
  /// its long side) are too small to tell who it is.
  static const double minFace = 36;

  /// At most this many faces per photo (big group photos).
  static const int maxFaces = 20;

  SendPort? _to;
  Isolate? _isolate;
  ReceivePort? _from;
  Future<void>? _starting;
  final Map<int, Completer<List<FaceRead>?>> _waiting = {};
  int _next = 0;

  Future<void> _start() => _starting ??= () async {
        final from = _from = ReceivePort();
        final ready = Completer<SendPort>();
        from.listen((m) {
          if (m is SendPort) {
            ready.complete(m);
          } else if (m is List && m.length == 2) {
            final c = _waiting.remove(m[0] as int);
            final v = m[1];
            c?.complete(v is TransferableTypedData ? _faces(v.materialize().asFloat32List()) : null);
          }
        });
        _isolate = await Isolate.spawn(_worker, [from.sendPort, _detect, _read]);
        _to = await ready.future;
      }();

  /// Per face: score, x, y, w, h, 128 numbers.
  static const int _per = 5 + 128;

  static List<FaceRead> _faces(Float32List f) => [
        for (var i = 0; i + _per <= f.length; i += _per)
          FaceRead(f[i], f[i + 1], f[i + 2], f[i + 3], f[i + 4], Float32List.fromList(f.sublist(i + 5, i + _per))),
      ];

  /// The faces in a picture (RGB bytes, [w]×[h]); null if it couldn't be read.
  Future<List<FaceRead>?> read(Uint8List rgb, int w, int h) async {
    await _start();
    final id = _next++;
    final c = Completer<List<FaceRead>?>();
    _waiting[id] = c;
    _to!.send([id, TransferableTypedData.fromList([rgb]), w, h]);
    return c.future.timeout(const Duration(seconds: 60), onTimeout: () {
      _waiting.remove(id);
      return null;
    });
  }

  void close() {
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    _from?.close();
    _from = null;
    _to = null;
    _starting = null;
    for (final c in _waiting.values) {
      if (!c.isCompleted) c.complete(null);
    }
    _waiting.clear();
  }
}

Float32List _flat(Object? v) {
  final out = <double>[];
  void walk(Object? x) {
    if (x is List) {
      for (final y in x) {
        walk(y);
      }
    } else if (x is num) {
      out.add(x.toDouble());
    }
  }

  walk(v);
  return Float32List.fromList(out);
}

void _worker(List<Object> args) {
  final reply = args[0] as SendPort;
  final inbox = ReceivePort();
  reply.send(inbox.sendPort);
  OrtEnv.instance.init();
  final opts = OrtSessionOptions()
    ..setIntraOpNumThreads(2)
    ..setInterOpNumThreads(1);
  final detect = OrtSession.fromFile(File(args[1] as String), opts);
  final reader = OrtSession.fromFile(File(args[2] as String), opts);
  final outNames = detect.outputNames;
  inbox.listen((m) {
    final msg = m as List;
    final id = msg[0] as int;
    try {
      final rgb = (msg[1] as TransferableTypedData).materialize().asUint8List();
      final w = msg[2] as int, h = msg[3] as int;
      final (input, scale) = FaceMath.detectInput(rgb, w, h);
      final t = OrtValueTensor.createTensorWithDataList(input, [1, 3, FaceMath.detectSize, FaceMath.detectSize]);
      final run = OrtRunOptions();
      final outs = detect.run(run, {'input': t});
      final named = <String, Float32List>{};
      for (var i = 0; i < outs.length && i < outNames.length; i++) {
        named[outNames[i]] = _flat(outs[i]?.value);
        outs[i]?.release();
      }
      t.release();
      final found = [
        for (final f in FaceMath.decode(named))
          if (f.w / scale >= FaceEngine.minFace && f.h / scale >= FaceEngine.minFace) f.scaled(1 / scale),
      ].take(FaceEngine.maxFaces);
      final result = <double>[];
      for (final f in found) {
        final up = FaceMath.upright(rgb, w, h, FaceMath.similarity(f.points));
        final ft = OrtValueTensor.createTensorWithDataList(up, [1, 3, FaceMath.faceSize, FaceMath.faceSize]);
        final o = reader.run(run, {'data': ft});
        final v = FaceMath.unit(_flat(o.first?.value));
        for (final x in o) {
          x?.release();
        }
        ft.release();
        if (v.length != 128) continue;
        result
          ..addAll([f.score, f.x / w, f.y / h, f.w / w, f.h / h])
          ..addAll(v);
      }
      run.release();
      reply.send([id, TransferableTypedData.fromList([Float32List.fromList(result)])]);
    } catch (e) {
      reply.send([id, null]);
    }
  });
}
