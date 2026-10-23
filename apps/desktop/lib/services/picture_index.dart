// apps/desktop/lib/services/picture_index.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:localroll_core/localroll_core.dart';

import 'library_index.dart';
import 'picture_model.dart';
import 'received_files.dart';
import 'text_index.dart';
import 'text_indexer.dart' show IndexProgress, IndexState;

/// What each photo / video looks like, as the picture model's numbers (512
/// per item, kept as small whole numbers): kept in the library's own
/// .localroll/search folder, so it goes wherever the library goes.
class PictureIndex extends ChangeNotifier {
  PictureIndex(this.library);

  final LibraryIndex library;

  final Map<String, int> _row = {};
  final List<String> _keys = [];
  final List<Int8List> _vectors = [];

  /// Per item: what one step of its small whole numbers is worth.
  final List<double> _scales = [];
  String? _loadedFor;
  Future<void>? _loading;
  Future<void> _saving = Future.value();
  bool _dirty = false;
  Timer? _saveSoon;

  static const int dim = PictureEncoder.dim;
  static final List<int> _magic = utf8.encode('LRP2');

  String get _sep => Platform.pathSeparator;
  /// "-2": beta.70 — before it, a model that failed to start marked
  /// pictures as unreadable; read again.
  File get _file => File('${library.metaDir}${_sep}search${_sep}pictures-${PictureModel.version}-2.bin');

  int get count => _keys.length;
  bool has(String key) => _row.containsKey(key);

  Future<void> load() {
    if (_loadedFor != library.rootPath) _loading = null;
    return _loading ??= _load();
  }

  Future<void> _load() async {
    _loadedFor = library.rootPath;
    _row.clear();
    _keys.clear();
    _vectors.clear();
    _scales.clear();
    try {
      final old = File('${library.metaDir}${_sep}search${_sep}pictures-${PictureModel.version}.bin');
      if (await old.exists()) await old.delete();
      if (await _file.exists()) {
        final b = await _file.readAsBytes();
        final d = ByteData.sublistView(b);
        if (b.length >= 8 && listEquals(b.sublist(0, 4), _magic)) {
          final n = d.getUint32(4, Endian.little);
          var at = 8;
          for (var i = 0; i < n && at + 2 <= b.length; i++) {
            final len = d.getUint16(at, Endian.little);
            at += 2;
            if (at + len + 4 + dim > b.length) break;
            final key = utf8.decode(b.sublist(at, at + len));
            at += len;
            final scale = d.getFloat32(at, Endian.little);
            at += 4;
            _add(key, Int8List.fromList(b.sublist(at, at + dim)), scale);
            at += dim;
          }
        }
      }
    } catch (e) {
      DiagLog.log('search', 'picture index unreadable, starting again: $e');
    }
    notifyListeners();
  }

  void _add(String key, Int8List v, double scale) {
    final r = _row[key];
    if (r != null) {
      _vectors[r] = v;
      _scales[r] = scale;
      return;
    }
    _row[key] = _keys.length;
    _keys.add(key);
    _vectors.add(v);
    _scales.add(scale);
  }

  /// [e]: the model's numbers (length 1).
  void put(String key, Float32List e) {
    var top = 0.0;
    for (var i = 0; i < dim && i < e.length; i++) {
      top = math.max(top, e[i].abs());
    }
    final scale = top == 0 ? 0.0 : top / 127;
    final v = Int8List(dim);
    for (var i = 0; i < dim && i < e.length && scale > 0; i++) {
      v[i] = (e[i] / scale).round().clamp(-127, 127);
    }
    _add(key, v, scale);
    _dirty = true;
    _saveSoon ??= Timer(const Duration(seconds: 30), () {
      _saveSoon = null;
      unawaited(save());
    });
  }

  /// Keeps only [keep] (deleted / changed items go).
  void prune(Set<String> keep) {
    if (_keys.every(keep.contains)) return;
    final kept = [
      for (var i = 0; i < _keys.length; i++)
        if (keep.contains(_keys[i])) (_keys[i], _vectors[i], _scales[i]),
    ];
    _row.clear();
    _keys.clear();
    _vectors.clear();
    _scales.clear();
    for (final (k, v, sc) in kept) {
      _add(k, v, sc);
    }
    _dirty = true;
    unawaited(save());
  }

  Future<void> save() => _saving = _saving.then((_) async {
        if (!_dirty || library.offline) return;
        _dirty = false;
        try {
          await _file.parent.create(recursive: true);
          final b = BytesBuilder(copy: false)..add(_magic);
          final n = ByteData(4)..setUint32(0, _keys.length, Endian.little);
          b.add(n.buffer.asUint8List());
          for (var i = 0; i < _keys.length; i++) {
            final k = utf8.encode(_keys[i]);
            final l = ByteData(2)..setUint16(0, k.length, Endian.little);
            final sc = ByteData(4)..setFloat32(0, _scales[i], Endian.little);
            b
              ..add(l.buffer.asUint8List())
              ..add(k)
              ..add(sc.buffer.asUint8List())
              ..add(Uint8List.view(_vectors[i].buffer));
          }
          final tmp = File('${_file.path}.tmp');
          await tmp.writeAsBytes(b.takeBytes(), flush: true);
          await tmp.rename(_file.path);
        } catch (e) {
          _dirty = true;
          DiagLog.log('search', 'picture index not saved: $e');
        }
      });

  /// Items that look like [q] (the text's numbers), best first: those close
  /// to the best one and not far off (at most [max]).
  List<(String, double)> search(Float32List q, {int max = 200}) {
    if (_keys.isEmpty) return const [];
    final scores = <(String, double)>[];
    for (var i = 0; i < _keys.length; i++) {
      final v = _vectors[i];
      var s = 0.0;
      for (var j = 0; j < dim; j++) {
        s += v[j] * q[j];
      }
      scores.add((_keys[i], s * _scales[i]));
    }
    scores.sort((a, b) => b.$2.compareTo(a.$2));
    final best = scores.first.$2;
    final floor = math.max(0.12, best - 0.06);
    return [for (final s in scores.take(max)) if (s.$2 >= floor) s];
  }

  @override
  void dispose() {
    _saveSoon?.cancel();
    super.dispose();
  }
}

/// Reads what photos and videos look like, in the background, after the
/// person turned picture search on and the model is here. Same manners as
/// the text reading: one at a time, only while the PC is quiet.
class PictureIndexer {
  PictureIndexer({
    required this.library,
    required this.files,
    required this.index,
    required this.model,
    required this.enabled,
    required this.busy,
    required this.rgb,
  }) : encoder = PictureEncoder(model);

  final LibraryIndex library;
  final ReceivedFiles files;
  final PictureIndex index;
  final PictureModel model;
  final PictureEncoder encoder;
  final bool Function() enabled;
  final bool Function() busy;

  /// 224×224 RGB of a picture / a video's middle frame (ffmpeg).
  final Future<Uint8List?> Function(String path, {bool video}) rgb;

  final ValueNotifier<IndexProgress> progress = ValueNotifier(const IndexProgress(IndexState.off));
  bool _running = false;
  bool _stopped = false;
  int _failures = 0;
  bool _warm = false;
  Completer<void>? _wake;
  Timer? _wakeSoon;

  bool get ready => enabled() && model.ready;

  void start() {
    if (_running) return;
    _running = true;
    library.addListener(_nudge);
    files.changes.addListener(_nudge);
    unawaited(_loop());
  }

  void _nudge() {
    _wakeSoon?.cancel();
    _wakeSoon = Timer(const Duration(seconds: 8), wake);
  }

  void wake() {
    final w = _wake;
    _wake = null;
    if (w != null && !w.isCompleted) w.complete();
  }

  Future<void> _sleep(Duration d) {
    final w = _wake = Completer<void>();
    return Future.any([w.future, Future<void>.delayed(d)]);
  }

  /// Items that look like [query] (keys, best first).
  Future<List<(String, double)>> find(String query) async {
    if (!ready || query.trim().isEmpty) return const [];
    await index.load();
    final q = await encoder.text(query);
    if (q == null) return const [];
    return index.search(q);
  }

  Future<void> _loop() async {
    await _sleep(const Duration(seconds: 40)); // after the text reading starts
    while (!_stopped) {
      try {
        if (!ready) {
          progress.value = const IndexProgress(IndexState.off);
          encoder.close();
          _warm = false;
          await _sleep(const Duration(minutes: 5));
          continue;
        }
        if (library.offline) {
          progress.value = const IndexProgress(IndexState.paused);
          await _sleep(const Duration(minutes: 1));
          continue;
        }
        await index.load();
        // The text side loaded now, so the first search is quick.
        if (!_warm) {
          _warm = true;
          unawaited(encoder.text('photo'));
        }
        final todo = await _todo();
        if (todo.isEmpty) {
          await index.save();
          progress.value = IndexProgress(IndexState.done, done: index.count, total: index.count);
          await _sleep(const Duration(minutes: 10));
          continue;
        }
        var done = 0;
        for (final (key, path, video) in todo) {
          if (_stopped || !ready) break;
          while (busy() || library.offline) {
            progress.value = IndexProgress(IndexState.paused, done: done, total: todo.length);
            await _sleep(const Duration(seconds: 10));
            if (_stopped || !ready) break;
          }
          if (_stopped || !ready) break;
          progress.value = IndexProgress(IndexState.working, done: done, total: todo.length);
          final px = await rgb(path, video: video);
          final e = px == null ? Float32List(PictureIndex.dim) : await encoder.picture(px);
          if (e == null) {
            // The model gave no answer: not marked (tried again later);
            // after a few in a row, stop and say so.
            if (++_failures >= 3) break;
            continue;
          }
          _failures = 0;
          // Not readable as a picture: an empty mark, so it isn't tried
          // again and again.
          index.put(key, e);
          done++;
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        await index.save();
        if (_failures >= 3) {
          _failures = 0;
          progress.value = const IndexProgress(IndexState.failed);
          DiagLog.log('search', 'picture reading paused for 30 min: ${encoder.lastError}');
          encoder.close();
          _warm = false;
          await _sleep(const Duration(minutes: 30));
        }
      } catch (e, st) {
        DiagLog.log('search', 'picture reading stopped: $e\n$st');
        await _sleep(const Duration(minutes: 2));
      }
    }
  }

  /// Photos and videos not read yet (newest first), received pictures too.
  Future<List<(String, String, bool)>> _todo() async {
    final out = <(String, String, bool)>[];
    final keep = <String>{};
    final items = List.of(library.items)..sort((a, b) => b.receivedMs.compareTo(a.receivedMs));
    for (final i in items) {
      if (i.kind != MediaKind.image && i.kind != MediaKind.video) continue;
      final key = TextIndex.mediaKey(i);
      keep.add(key);
      if (!index.has(key)) out.add((key, library.absPath(i), i.kind == MediaKind.video));
    }
    for (final f in await files.list()) {
      final kind = MediaKind.fromName(f.name);
      if (kind != MediaKind.image && kind != MediaKind.video) continue;
      final rel = files.relOf(f.path);
      if (rel == null) continue;
      final key = TextIndex.fileKey(rel, f.size);
      keep.add(key);
      if (!index.has(key)) out.add((key, f.path, kind == MediaKind.video));
    }
    index.prune(keep);
    return out;
  }

  void stop() {
    _stopped = true;
    _running = false;
    library.removeListener(_nudge);
    files.changes.removeListener(_nudge);
    _wakeSoon?.cancel();
    wake();
    encoder.close();
  }
}
