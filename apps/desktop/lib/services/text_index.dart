// apps/desktop/lib/services/text_index.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:localroll_core/localroll_core.dart';

import 'library_index.dart';

/// The text found in one photo / file.
class TextEntry {
  const TextEntry(this.text, {this.lang = '', this.ocr = false});

  /// As found ('' = looked, nothing there).
  final String text;

  /// The recognizer language used (OCR only): read again when a better one
  /// is installed later (e.g. Chinese).
  final String lang;

  /// Read from a picture (not from the file's own text).
  final bool ocr;

  Map<String, dynamic> toJson() => {'t': text, if (lang.isNotEmpty) 'l': lang, if (ocr) 'o': 1};

  static TextEntry fromJson(Object? j) {
    if (j is! Map) return const TextEntry('');
    return TextEntry(j['t'] as String? ?? '', lang: j['l'] as String? ?? '', ocr: j['o'] == 1);
  }
}

/// What text is in which photo / file, for searching: kept in the library's
/// own .localroll/search folder (it goes wherever the library goes), by
/// path and size, so a changed file is read again.
class TextIndex extends ChangeNotifier {
  TextIndex(this.library);

  final LibraryIndex library;

  /// Bumped when the way text is read changes: everything is read again.
  static const int version = 1;

  /// Longest text kept per item.
  static const int maxChars = 20000;

  final Map<String, TextEntry> _entries = {};
  final Map<String, String> _plain = {}; // key → normalized text
  String? _loadedFor;
  Future<void>? _loading;
  Timer? _saveSoon;
  Future<void> _saving = Future.value();
  bool _dirty = false;

  String get _sep => Platform.pathSeparator;
  File get _file => File('${library.metaDir}${_sep}search${_sep}text.json');

  /// Key of a library photo / video.
  static String mediaKey(MediaItem i) => 'm:${i.relPath.toLowerCase()}|${i.size}';

  /// Key of a received file ([rel]: its path inside the library).
  static String fileKey(String rel, int size) => 'f:${rel.toLowerCase()}|$size';

  Future<void> load() {
    if (_loadedFor != library.rootPath) _loading = null;
    return _loading ??= _load();
  }

  Future<void> _load() async {
    _loadedFor = library.rootPath;
    _entries.clear();
    _plain.clear();
    try {
      if (await _file.exists()) {
        final j = jsonDecode(await _file.readAsString());
        if (j is Map<String, dynamic> && j['v'] == version && j['e'] is Map) {
          for (final e in (j['e'] as Map).entries) {
            final entry = TextEntry.fromJson(e.value);
            _entries[e.key as String] = entry;
            if (entry.text.isNotEmpty) _plain[e.key as String] = normalize(entry.text);
          }
        }
      }
    } catch (e) {
      DiagLog.log('search', 'text index unreadable, starting again: $e');
    }
    notifyListeners();
  }

  int get count => _entries.length;
  bool has(String key) => _entries.containsKey(key);
  TextEntry? operator [](String key) => _entries[key];

  void put(String key, TextEntry e) {
    final t = e.text.length > maxChars ? e.text.substring(0, maxChars) : e.text;
    final entry = TextEntry(t, lang: e.lang, ocr: e.ocr);
    _entries[key] = entry;
    if (t.isEmpty) {
      _plain.remove(key);
    } else {
      _plain[key] = normalize(t);
    }
    _dirty = true;
    _saveSoon ??= Timer(const Duration(seconds: 20), () {
      _saveSoon = null;
      unawaited(save());
    });
    // Pages showing results refresh every few seconds, not per item.
    _notifySoon ??= Timer(const Duration(seconds: 3), () {
      _notifySoon = null;
      notifyListeners();
    });
  }

  Timer? _notifySoon;

  /// Drops entries not in [keep] (deleted, changed files).
  void prune(Set<String> keep) {
    final gone = [for (final k in _entries.keys) if (!keep.contains(k)) k];
    if (gone.isEmpty) return;
    for (final k in gone) {
      _entries.remove(k);
      _plain.remove(k);
    }
    _dirty = true;
    unawaited(save());
  }

  Future<void> save() => _saving = _saving.then((_) async {
        if (!_dirty || library.offline) return;
        _dirty = false;
        try {
          await _file.parent.create(recursive: true);
          final tmp = File('${_file.path}.tmp');
          await tmp.writeAsString(jsonEncode({
            'v': version,
            'e': {for (final e in _entries.entries) e.key: e.value.toJson()},
          }));
          await tmp.rename(_file.path);
        } catch (e) {
          _dirty = true;
          DiagLog.log('search', 'text index not saved: $e');
        }
      });

  /// Does the item at [key] (named [name]) match [query]? Every word of
  /// the query must be in its text or its name.
  bool matches(String key, String name, SearchQuery query) {
    if (query.isEmpty) return true;
    final text = _plain[key] ?? '';
    final n = normalize(name);
    return query.words.every((w) => text.contains(w) || n.contains(w));
  }

  /// A little of the text around the first word of [query] (for a tooltip).
  String? snippet(String key, SearchQuery query) {
    final raw = _entries[key]?.text;
    if (raw == null || raw.isEmpty || query.isEmpty) return null;
    final flat = raw.replaceAll(RegExp(r'\s+'), ' ');
    final lower = flat.toLowerCase();
    var at = -1;
    for (final w in query.raw) {
      at = lower.indexOf(w.toLowerCase());
      if (at >= 0) break;
    }
    if (at < 0) return flat.length > 80 ? '${flat.substring(0, 80)}…' : flat;
    final from = (at - 30).clamp(0, flat.length);
    final to = (at + 50).clamp(0, flat.length);
    return '${from > 0 ? '…' : ''}${flat.substring(from, to)}${to < flat.length ? '…' : ''}';
  }

  /// Lower case, full-width letters and digits made plain, no spaces.
  static String normalize(String s) {
    final b = StringBuffer();
    for (final r in s.runes) {
      var c = r;
      if (c >= 0xFF01 && c <= 0xFF5E) c -= 0xFEE0; // full-width ASCII
      if (c == 0x3000 || c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D) continue;
      b.writeCharCode(c);
    }
    return b.toString().toLowerCase();
  }

  @override
  void dispose() {
    _saveSoon?.cancel();
    _notifySoon?.cancel();
    super.dispose();
  }
}

/// What was typed in a search box, split into words.
class SearchQuery {
  SearchQuery(String text)
      : raw = [for (final w in text.trim().split(RegExp(r'\s+'))) if (w.isNotEmpty) w],
        words = [
          for (final w in text.trim().split(RegExp(r'\s+')))
            if (TextIndex.normalize(w).isNotEmpty) TextIndex.normalize(w),
        ];

  final List<String> raw;
  final List<String> words;

  bool get isEmpty => words.isEmpty;
}
