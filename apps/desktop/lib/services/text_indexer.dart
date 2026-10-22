// apps/desktop/lib/services/text_indexer.dart
import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:localroll_core/localroll_core.dart';

import 'library_index.dart';
import 'received_files.dart';
import 'text_index.dart';
import 'windows_ocr.dart';

/// Where the text search stands (for the library and Settings).
enum IndexState {
  /// Switched off in Settings.
  off,

  /// Windows on this PC has no text recognition at all.
  noOcr,

  /// Not started yet / looking for what is new.
  starting,

  /// Reading.
  working,

  /// Waiting: files are being sent or received, or the library is offline.
  paused,

  /// Everything read.
  done,
}

class IndexProgress {
  const IndexProgress(this.state, {this.done = 0, this.total = 0});

  final IndexState state;

  /// Items read in this round / items to read in this round.
  final int done;
  final int total;
}

/// Reads the text in photos and received files in the background, one at a
/// time, only while the PC is otherwise quiet: photos and screenshots with
/// Windows' text recognition, PDFs by their own text (scans: each page
/// recognized, after the photos), Office and text files by their text.
/// New arrivals are read as they come.
class TextIndexer {
  TextIndexer({
    required this.library,
    required this.files,
    required this.index,
    required this.enabled,
    required this.busy,
    this.convert,
    WindowsOcr? ocr,
    this.readPdf,
  }) : ocr = ocr ?? WindowsOcr();

  final LibraryIndex library;
  final ReceivedFiles files;
  final TextIndex index;
  final WindowsOcr ocr;

  /// Switched on in Settings.
  final bool Function() enabled;

  /// Sending, receiving or converting: wait.
  final bool Function() busy;

  /// Makes a JPEG of a picture Windows can't open itself (HEIC, RAW…).
  final Future<bool> Function(String src, String out)? convert;

  /// Reads a PDF (its own text; scanned pages through [ocrPage]).
  final Future<(String, bool)?> Function(
    String path, {
    required String tmpDir,
    required Future<String?> Function(String png) ocrPage,
    Future<bool> Function()? keepGoing,
  })? readPdf;

  final ValueNotifier<IndexProgress> progress = ValueNotifier(const IndexProgress(IndexState.starting));
  final ValueNotifier<OcrLanguages?> languages = ValueNotifier(null);

  bool _running = false;
  bool _stopped = false;
  Completer<void>? _wake;
  Timer? _wakeSoon;

  /// Picture kinds Windows opens directly.
  static const _direct = {'jpg', 'jpeg', 'png', 'bmp', 'gif', 'tif', 'tiff'};

  /// Text files read as they are (start only).
  static const _textKinds = {'txt', 'md', 'csv', 'tsv', 'log', 'json', 'xml', 'html', 'htm', 'srt', 'vtt', 'ini'};

  void start() {
    if (_running) return;
    _running = true;
    _stopped = false;
    library.addListener(_nudge);
    files.changes.addListener(_nudge);
    unawaited(_loop());
  }

  /// Something changed (new photos, files): look again soon.
  void _nudge() {
    _wakeSoon?.cancel();
    _wakeSoon = Timer(const Duration(seconds: 5), wake);
  }

  /// Look again now (switched on, a language installed…).
  void wake() {
    final w = _wake;
    _wake = null;
    if (w != null && !w.isCompleted) w.complete();
  }

  Future<void> _sleep(Duration d) {
    final w = _wake = Completer<void>();
    return Future.any([w.future, Future<void>.delayed(d)]);
  }

  /// Languages Windows can read now (asked again after an install).
  Future<OcrLanguages> checkLanguages() async {
    final l = await ocr.languages(refresh: true);
    languages.value = l;
    return l;
  }

  Future<void> _loop() async {
    await _sleep(const Duration(seconds: 20)); // let the app start first
    if (WindowsOcr.supported) {
      final l = await ocr.languages();
      languages.value = l;
    }
    while (!_stopped) {
      try {
        if (!enabled()) {
          progress.value = const IndexProgress(IndexState.off);
          await _sleep(const Duration(minutes: 5));
          continue;
        }
        if (library.offline) {
          progress.value = const IndexProgress(IndexState.paused);
          await _sleep(const Duration(minutes: 1));
          continue;
        }
        await index.load();
        final todo = await _todo();
        if (todo.isEmpty) {
          await index.save();
          final noOcr = WindowsOcr.supported && !(languages.value?.any ?? false);
          progress.value = IndexProgress(noOcr ? IndexState.noOcr : IndexState.done, done: index.count, total: index.count);
          await _sleep(const Duration(minutes: 10));
          continue;
        }
        var done = 0;
        for (final job in todo) {
          if (_stopped || !enabled()) break;
          while (busy() || library.offline) {
            progress.value = IndexProgress(IndexState.paused, done: done, total: todo.length);
            await _sleep(const Duration(seconds: 10));
            if (_stopped || !enabled()) break;
          }
          if (_stopped || !enabled()) break;
          progress.value = IndexProgress(IndexState.working, done: done, total: todo.length);
          await job();
          done++;
          // Quiet: a little rest between items.
          await Future<void>.delayed(const Duration(milliseconds: 150));
        }
        await index.save();
      } catch (e, st) {
        DiagLog.log('search', 'indexing stopped: $e\n$st');
        await _sleep(const Duration(minutes: 2));
      }
    }
  }

  String get _tmp => '${library.cacheDir}${Platform.pathSeparator}ocr_tmp';

  bool _stale(String key) {
    final e = index[key];
    if (e == null) return true;
    // Read with a lesser language than Windows has now (e.g. Chinese was
    // added): read again.
    final best = languages.value?.preferred;
    return e.ocr && best != null && e.lang.isNotEmpty && e.lang != best;
  }

  /// What is not read yet: Office / text / PDFs first (quick), then photos
  /// newest first; scanned PDF pages are read as part of their PDF.
  Future<List<Future<void> Function()>> _todo() async {
    final quick = <Future<void> Function()>[];
    final photos = <Future<void> Function()>[];
    final pdfs = <Future<void> Function()>[];
    final keep = <String>{};
    final ocrOk = WindowsOcr.supported && (languages.value?.any ?? false);

    final items = List.of(library.items)..sort((a, b) => b.receivedMs.compareTo(a.receivedMs));
    for (final i in items) {
      if (i.kind != MediaKind.image) continue;
      final key = TextIndex.mediaKey(i);
      keep.add(key);
      if (!ocrOk || !_stale(key)) continue;
      photos.add(() => _readPicture(key, library.absPath(i), i.name));
    }
    for (final f in await files.list()) {
      final rel = files.relOf(f.path);
      if (rel == null) continue;
      final key = TextIndex.fileKey(rel, f.size);
      keep.add(key);
      if (!_stale(key)) continue;
      final ext = extensionOf(f.name);
      if (ext == 'pdf') {
        if (readPdf != null) pdfs.add(() => _readPdf(key, f.path));
      } else if (OfficeDoc.canRead(ext) || _textKinds.contains(ext)) {
        quick.add(() => _readDocument(key, f.path, ext));
      } else if (MediaKind.fromName(f.name) == MediaKind.image) {
        if (ocrOk) photos.add(() => _readPicture(key, f.path, f.name));
      } else {
        // Nothing to read: only the name is searched.
        index.put(key, const TextEntry(''));
      }
    }
    index.prune(keep);
    return [...quick, ...photos, ...pdfs];
  }

  Future<void> _readPicture(String key, String path, String name) async {
    final ext = extensionOf(name);
    String? text;
    if (_direct.contains(ext)) text = await ocr.read(path);
    if (text == null && convert != null) {
      // HEIC, RAW, WebP… or too big: a JPEG for reading.
      await Directory(_tmp).create(recursive: true);
      final jpg = '$_tmp${Platform.pathSeparator}page.jpg';
      try {
        if (await convert!(path, jpg)) text = await ocr.read(jpg);
      } finally {
        try {
          await File(jpg).delete();
        } catch (_) {}
      }
    }
    // Not readable: kept empty (not tried again until it changes).
    index.put(key, TextEntry(text ?? '', lang: languages.value?.preferred ?? '', ocr: true));
  }

  Future<void> _readPdf(String key, String path) async {
    await Directory(_tmp).create(recursive: true);
    final ocrOk = WindowsOcr.supported && (languages.value?.any ?? false);
    final r = await readPdf!(
      path,
      tmpDir: _tmp,
      ocrPage: (png) async => ocrOk ? await ocr.read(png) : null,
      keepGoing: () async {
        // Long scans: wait while files are being sent / received.
        while (busy() && !_stopped) {
          await _sleep(const Duration(seconds: 10));
        }
        return !_stopped && enabled();
      },
    );
    if (r == null) {
      if (!_stopped && enabled()) index.put(key, const TextEntry(''));
      return;
    }
    final (text, usedOcr) = r;
    // Scanned pages read without a recognizer: read again once there is one.
    index.put(key, TextEntry(text, lang: usedOcr ? (ocrOk ? (languages.value?.preferred ?? '') : 'none') : '', ocr: usedOcr));
  }

  Future<void> _readDocument(String key, String path, String ext) async {
    var text = '';
    try {
      final f = File(path);
      final len = await f.length();
      if (OfficeDoc.canRead(ext)) {
        if (len <= 60 * 1024 * 1024) {
          final bytes = await f.readAsBytes();
          text = await compute(_officeText, (bytes, ext));
        }
      } else {
        final raf = await f.open();
        try {
          final b = await raf.read(min(len, 1024 * 1024));
          text = FirstPage.decodeStart(b);
        } finally {
          await raf.close();
        }
      }
    } catch (e) {
      DiagLog.log('search', 'document not read: $e');
    }
    index.put(key, TextEntry(text));
  }

  void stop() {
    _stopped = true;
    _running = false;
    library.removeListener(_nudge);
    files.changes.removeListener(_nudge);
    _wakeSoon?.cancel();
    wake();
    ocr.close();
  }
}

/// All the text of an Office document (in the background).
String _officeText((Uint8List, String) a) {
  final d = OfficeDoc.read(a.$1, a.$2);
  if (d == null) return '';
  final b = StringBuffer();
  for (final block in d.blocks) {
    if (block is OfficeParagraph) {
      b.writeln(block.text);
    } else if (block is OfficeTable) {
      for (final r in block.rows) {
        b.writeln(r.join(' '));
      }
    }
  }
  for (final s in d.sheets) {
    b.writeln(s.name);
    for (final r in s.rows.take(2000)) {
      b.writeln(r.where((c) => c.trim().isNotEmpty).join(' '));
    }
  }
  for (final s in d.slides) {
    for (final p in s.paragraphs) {
      b.writeln(p);
    }
  }
  return b.toString().trim();
}
