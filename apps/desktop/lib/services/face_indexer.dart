// apps/desktop/lib/services/face_indexer.dart
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:localroll_core/localroll_core.dart';

import 'face_engine.dart';
import 'library_index.dart';
import 'people.dart';
import 'received_files.dart';
import 'text_index.dart';
import 'text_indexer.dart' show IndexProgress, IndexState;

/// Finds the faces in photos, in the background, once the person turned
/// "People" on. Same manners as the other reading: one photo at a time,
/// only while the PC is quiet. Photos only (videos later).
class FaceIndexer {
  FaceIndexer({
    required this.library,
    required this.files,
    required this.people,
    required this.engine,
    required this.enabled,
    required this.busy,
    required this.picture,
  });

  final LibraryIndex library;
  final ReceivedFiles files;
  final PeopleIndex people;
  final FaceEngine engine;
  final bool Function() enabled;
  final bool Function() busy;

  /// A photo as RGB bytes and its size (ffmpeg; at most 1280 on its long side).
  final Future<(int, int, Uint8List)?> Function(String path) picture;

  final ValueNotifier<IndexProgress> progress = ValueNotifier(const IndexProgress(IndexState.off));
  bool _running = false;
  bool _stopped = false;
  int _failures = 0;
  Completer<void>? _wake;
  Timer? _wakeSoon;

  bool get ready => enabled() && engine.available;

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

  Future<void> _loop() async {
    await _sleep(const Duration(seconds: 50)); // after the other reading starts
    while (!_stopped) {
      try {
        if (!ready) {
          progress.value = const IndexProgress(IndexState.off);
          engine.close();
          await _sleep(const Duration(minutes: 5));
          continue;
        }
        if (library.offline) {
          progress.value = const IndexProgress(IndexState.paused);
          await _sleep(const Duration(minutes: 1));
          continue;
        }
        await people.load();
        final todo = await _todo();
        if (todo.isEmpty) {
          await people.save();
          progress.value = IndexProgress(IndexState.done, done: people.photosRead, total: people.photosRead);
          await _sleep(const Duration(minutes: 10));
          continue;
        }
        var done = 0;
        for (final (key, path) in todo) {
          if (_stopped || !ready) break;
          while (busy() || library.offline) {
            progress.value = IndexProgress(IndexState.paused, done: done, total: todo.length);
            await _sleep(const Duration(seconds: 10));
            if (_stopped || !ready) break;
          }
          if (_stopped || !ready) break;
          progress.value = IndexProgress(IndexState.working, done: done, total: todo.length);
          final px = await picture(path);
          final faces = px == null ? const <FaceRead>[] : await engine.read(px.$3, px.$1, px.$2);
          if (faces == null) {
            // The models gave no answer: not marked as read (tried again
            // later); after a few in a row, stop and say so.
            if (++_failures >= 3) break;
            continue;
          }
          _failures = 0;
          // Not readable as a picture: marked as read with nobody, so it
          // isn't tried again and again.
          people.put(key, faces);
          done++;
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        await people.save();
        if (_failures >= 3) {
          _failures = 0;
          progress.value = const IndexProgress(IndexState.failed);
          DiagLog.log('people', 'face reading paused for 30 min: ${engine.lastError}');
          engine.close();
          await _sleep(const Duration(minutes: 30));
        }
      } catch (e, st) {
        DiagLog.log('people', 'face reading stopped: $e\n$st');
        await _sleep(const Duration(minutes: 2));
      }
    }
  }

  /// Photos not read yet (newest first), received pictures too.
  Future<List<(String, String)>> _todo() async {
    final out = <(String, String)>[];
    final keep = <String>{};
    final items = List.of(library.items)..sort((a, b) => b.receivedMs.compareTo(a.receivedMs));
    for (final i in items) {
      if (i.kind != MediaKind.image) continue;
      final key = TextIndex.mediaKey(i);
      keep.add(key);
      if (!people.has(key)) out.add((key, library.absPath(i)));
    }
    for (final f in await files.list()) {
      if (MediaKind.fromName(f.name) != MediaKind.image) continue;
      final rel = files.relOf(f.path);
      if (rel == null) continue;
      final key = TextIndex.fileKey(rel, f.size);
      keep.add(key);
      if (!people.has(key)) out.add((key, f.path));
    }
    // Never on an empty list (library not there yet): names would go.
    if (keep.isNotEmpty) people.prune(keep);
    return out;
  }

  void stop() {
    _stopped = true;
    _running = false;
    library.removeListener(_nudge);
    files.changes.removeListener(_nudge);
    _wakeSoon?.cancel();
    wake();
    engine.close();
  }
}
