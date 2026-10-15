// packages/core/lib/src/diag_log.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Local diagnostics log, for "what went wrong" after the fact.
///
/// * Stays on the device; never sent anywhere. The user exports it on
///   purpose (Settings) and decides whom to give it to.
/// * Holds events and error codes — never photo contents, tokens or PINs.
/// * At most about 2 MB: one current file and one older one.
///
/// Lines logged before [init] (very early start-up) are kept and written
/// once it is called.
final class DiagLog {
  DiagLog._();

  static Directory? _dir;
  static final List<String> _queue = [];
  static Future<void>? _writing;

  /// A file grows to this size, then becomes the older one.
  static int maxBytes = 1024 * 1024;

  static String _path(String name) => '${_dir!.path}${Platform.pathSeparator}$name';
  static String get _current => _path('localroll.log');
  static String get _older => _path('localroll.1.log');

  static bool get ready => _dir != null;

  /// Start writing into [dir]; [about] goes first (app version, system).
  static Future<void> init(Directory dir, {String about = ''}) async {
    await dir.create(recursive: true);
    _dir = dir;
    log('start', about);
    await flush();
  }

  /// One line: time, [tag], message (kept on one line).
  static void log(String tag, String message) {
    final now = DateTime.now();
    final line = '${now.toIso8601String()} [$tag] ${message.replaceAll(RegExp(r'[\r\n]+'), ' | ')}';
    if (_queue.length >= 2000) _queue.removeAt(0); // never grow without end
    _queue.add(line);
    if (_dir != null) _writing ??= _drain();
  }

  /// An error with its stack (shortened).
  static void error(String tag, Object e, [StackTrace? st]) {
    final stack = st == null ? '' : ' @ ${st.toString().split('\n').take(8).join(' < ')}';
    log(tag, 'ERROR $e$stack');
  }

  static Future<void> _drain() async {
    try {
      while (_queue.isNotEmpty) {
        final text = '${_queue.join('\n')}\n';
        _queue.clear();
        final f = File(_current);
        try {
          if (await f.exists() && await f.length() > maxBytes) await f.rename(_older);
        } catch (_) {}
        try {
          await f.writeAsString(text, mode: FileMode.append);
        } catch (_) {}
      }
    } finally {
      _writing = null;
    }
  }

  /// Everything queued is on disk.
  static Future<void> flush() async {
    while (_writing != null || (_dir != null && _queue.isNotEmpty)) {
      await (_writing ??= _drain());
    }
  }

  /// The whole log (older part first), for exporting.
  static Future<String> read() async {
    await flush();
    if (_dir == null) return _queue.join('\n');
    final out = StringBuffer();
    for (final p in [_older, _current]) {
      try {
        final f = File(p);
        if (await f.exists()) out.write(utf8.decode(await f.readAsBytes(), allowMalformed: true));
      } catch (_) {}
    }
    return out.toString();
  }

  /// For tests: forget the folder and anything queued.
  static void reset() {
    _dir = null;
    _queue.clear();
    _writing = null;
  }
}
