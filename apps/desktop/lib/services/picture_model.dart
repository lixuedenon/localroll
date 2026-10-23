// apps/desktop/lib/services/picture_model.dart
import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:localroll_core/localroll_core.dart';
import 'package:onnxruntime/onnxruntime.dart';

/// One file of the picture-search model, as made by
/// scripts/models/export_clip.py and copied into this repo's "deps" release.
class ModelFile {
  const ModelFile(this.name, this.sha256, this.size);

  final String name;
  final String sha256;
  final int size;
}

/// The picture-search model (OpenCLIP ViT-B/32 + XLM-RoBERTa, LAION-5B, MIT
/// licence): downloaded once from LocalRoll's own GitHub release, checked,
/// kept in this PC's app data (not in the library), and run on this PC only.
class PictureModel extends ChangeNotifier {
  PictureModel(this.dataDir);

  final Directory dataDir;

  /// Bumped with a new model: pictures are read again.
  static const String version = 'clip-xlmr-b32-v1';

  static const String _base = 'https://github.com/lixuedenon/localroll/releases/download/deps';

  /// Filled from the export's report (sizes and SHA-256 of the "deps" files).
  static const List<ModelFile> files = [
    ModelFile('clip-picture.onnx', _picSha, _picSize),
    ModelFile('clip-text.onnx', _textSha, _textSize),
    ModelFile('clip-vocab.json', _vocabSha, _vocabSize),
  ];
  static const String _picSha = 'a680a7241ae78adad969d51f960987d963594e3763e345b29af7f30a2acd2b30';
  static const int _picSize = 95898416;
  static const String _textSha = '2811ecd724d98cf28470d89efbf434d1780afc847db6d449fdc697a523a69dbc';
  static const int _textSize = 278937646;
  static const String _vocabSha = 'f27aa37ae497682e684b0e0eb51e0eb1e090857f8896919f870d56524207db6c';
  static const int _vocabSize = 9263197;

  static int get downloadSize => files.fold(0, (a, f) => a + f.size);

  Directory get dir => Directory('${dataDir.path}${Platform.pathSeparator}models${Platform.pathSeparator}$version');
  String path(String name) => '${dir.path}${Platform.pathSeparator}$name';

  /// All files here (checked when they were downloaded).
  bool get ready => files.every((f) {
        final file = File(path(f.name));
        return file.existsSync() && file.lengthSync() == f.size;
      });

  /// Downloading: bytes so far / all (null when not downloading).
  (int, int)? downloading;
  String? error;

  Future<bool>? _download;
  DateTime _told = DateTime.fromMillisecondsSinceEpoch(0);

  /// Downloads what is missing; true when everything is here and checked.
  Future<bool> download() => _download ??= _downloadAll().whenComplete(() => _download = null);

  Future<bool> _downloadAll() async {
    error = null;
    await dir.create(recursive: true);
    final total = downloadSize;
    var done = 0;
    final http = HttpClient()..connectionTimeout = const Duration(seconds: 20);
    try {
      for (final f in files) {
        final target = File(path(f.name));
        if (target.existsSync() && target.lengthSync() == f.size) {
          done += f.size;
          continue;
        }
        final part = File('${target.path}.part');
        final req = await http.getUrl(Uri.parse('$_base/${f.name}'));
        final res = await req.close();
        if (res.statusCode != 200) {
          await res.drain<void>();
          throw HttpException('HTTP ${res.statusCode} for ${f.name}');
        }
        final sink = part.openWrite();
        final hasher = StreamingSha256();
        try {
          await for (final chunk in res) {
            sink.add(chunk);
            hasher.add(chunk);
            done += chunk.length;
            downloading = (done, total);
            // A few times a second is enough for the progress shown.
            final now = DateTime.now();
            if (now.difference(_told).inMilliseconds > 300) {
              _told = now;
              notifyListeners();
            }
          }
        } finally {
          await sink.close();
        }
        final sha = hasher.finish();
        if (sha != f.sha256 || part.lengthSync() != f.size) {
          await part.delete();
          throw StateError('${f.name} did not match (got $sha)');
        }
        await part.rename(target.path);
      }
      DiagLog.log('search', 'picture model downloaded');
      return true;
    } catch (e) {
      error = '$e';
      DiagLog.log('search', 'picture model download failed: $e');
      return false;
    } finally {
      http.close(force: true);
      downloading = null;
      notifyListeners();
    }
  }

  /// Takes the model off this PC (switched off for good).
  Future<void> remove() async {
    try {
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (_) {}
    notifyListeners();
  }
}

/// Runs the model in its own isolate (it takes a moment per picture; the
/// screen stays smooth): picture → numbers, text → numbers.
class PictureEncoder {
  PictureEncoder(this.model);

  final PictureModel model;
  SendPort? _to;
  Isolate? _isolate;
  ClipTokenizer? _tokenizer;
  final Map<int, Completer<Float32List?>> _waiting = {};
  int _next = 0;
  Future<void>? _starting;
  ReceivePort? _from;

  static const int dim = 512;

  Future<void> _start() => _starting ??= () async {
        _tokenizer = ClipTokenizer.fromJson(await File(model.path('clip-vocab.json')).readAsString());
        final from = _from = ReceivePort();
        final ready = Completer<SendPort>();
        from.listen((m) {
          if (m is SendPort) {
            ready.complete(m);
          } else if (m is List && m.length == 2) {
            final c = _waiting.remove(m[0] as int);
            final v = m[1];
            c?.complete(v is TransferableTypedData ? v.materialize().asFloat32List() : null);
          }
        });
        _isolate = await Isolate.spawn(_worker, [from.sendPort, model.path('clip-picture.onnx'), model.path('clip-text.onnx')]);
        _to = await ready.future;
      }();

  Future<Float32List?> _ask(String kind, Object data) async {
    await _start();
    final id = _next++;
    final c = Completer<Float32List?>();
    _waiting[id] = c;
    _to!.send([id, kind, data]);
    return c.future.timeout(const Duration(seconds: 60), onTimeout: () {
      _waiting.remove(id);
      return null;
    });
  }

  /// [rgb]: 224×224×3 bytes (FfmpegService.rgb224).
  Future<Float32List?> picture(Uint8List rgb) => _ask('p', TransferableTypedData.fromList([_pixels(rgb)]));

  Future<Float32List?> text(String query) async {
    await _start();
    final ids = Int64List.fromList(_tokenizer!.encodePadded(query));
    return _ask('t', TransferableTypedData.fromList([ids]));
  }

  /// RGB bytes → the model's input: channels first, scaled like it was
  /// trained (OpenAI CLIP mean / std).
  static Float32List _pixels(Uint8List rgb) {
    const mean = [0.48145466, 0.4578275, 0.40821073];
    const std = [0.26862954, 0.26130258, 0.27577711];
    const n = 224 * 224;
    final out = Float32List(3 * n);
    for (var i = 0; i < n; i++) {
      for (var c = 0; c < 3; c++) {
        out[c * n + i] = (rgb[i * 3 + c] / 255.0 - mean[c]) / std[c];
      }
    }
    return out;
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

/// The isolate: loads both models once, then answers.
void _worker(List<Object> args) {
  final reply = args[0] as SendPort;
  final inbox = ReceivePort();
  reply.send(inbox.sendPort);
  OrtEnv.instance.init();
  final opts = OrtSessionOptions()
    ..setIntraOpNumThreads(2)
    ..setInterOpNumThreads(1);
  final picture = OrtSession.fromFile(File(args[1] as String), opts);
  OrtSession? text; // loaded when first searched
  inbox.listen((m) {
    final msg = m as List;
    final id = msg[0] as int;
    try {
      final data = (msg[2] as TransferableTypedData).materialize();
      final OrtValueTensor input;
      final OrtSession session;
      final String name;
      if (msg[1] == 'p') {
        input = OrtValueTensor.createTensorWithDataList(data.asFloat32List(), [1, 3, 224, 224]);
        session = picture;
        name = 'pixels';
      } else {
        text ??= OrtSession.fromFile(File(args[2] as String), opts);
        final ids = data.asInt64List();
        input = OrtValueTensor.createTensorWithDataList(ids, [1, ids.length]);
        session = text!;
        name = 'ids';
      }
      final run = OrtRunOptions();
      final out = session.run(run, {name: input});
      final v = out.first?.value;
      input.release();
      run.release();
      for (final o in out) {
        o?.release();
      }
      final row = (v as List).first as List;
      final emb = Float32List.fromList([for (final x in row) (x as num).toDouble()]);
      reply.send([id, TransferableTypedData.fromList([emb])]);
    } catch (e) {
      reply.send([id, null]);
    }
  });
}
