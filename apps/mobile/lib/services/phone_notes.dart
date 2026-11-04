// apps/mobile/lib/services/phone_notes.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:localroll_ink/localroll_ink.dart';
import 'package:path_provider/path_provider.dart';

/// Drawings on photos and videos made on this phone, kept in the app's own
/// folder (one small file per photo / video; the photo itself is never
/// changed). Same format as on the PC.
///
/// Keys: "asset:<id>" (this phone's photo library), "my:<id>" (My files),
/// "pc:<PC id>:<path>" (a PC's library, seen from here).
class PhoneNotes extends ChangeNotifier {
  PhoneNotes._();

  static final PhoneNotes instance = PhoneNotes._();

  final Map<String, List<Note>> _cache = {};
  final Set<String> _loading = {};
  Directory? _dir;

  Future<Directory> _folder() async {
    final d = _dir ??= Directory('${(await getApplicationSupportDirectory()).path}/annotations');
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }

  /// A file name from the key (FNV-1a, 64 bits: the same every run).
  static String _name(String key) {
    var h = 0xcbf29ce484222325;
    for (final b in utf8.encode(key)) {
      h ^= b;
      h *= 0x100000001b3;
    }
    return '${h.toUnsigned(64).toRadixString(16)}.json';
  }

  /// The drawings of [key] (empty until loaded; listeners hear when they are).
  List<Note> of(String key) {
    final have = _cache[key];
    if (have != null) return have;
    if (_loading.add(key)) unawaited(_load(key));
    return const [];
  }

  Future<void> _load(String key) async {
    try {
      final f = File('${(await _folder()).path}/${_name(key)}');
      final notes = <Note>[];
      if (await f.exists()) {
        final j = jsonDecode(await f.readAsString());
        if (j is Map<String, dynamic> && j['key'] == key) {
          for (final n in (j['notes'] as List?) ?? const []) {
            if (n is Map<String, dynamic>) notes.add(Note.fromJson(n));
          }
        }
      }
      _cache[key] = notes;
    } catch (_) {
      _cache[key] = [];
    } finally {
      _loading.remove(key);
      notifyListeners();
    }
  }

  /// Loaded now (for opening the editor).
  Future<List<Note>> load(String key) async {
    if (!_cache.containsKey(key)) await _load(key);
    return _cache[key] ?? [];
  }

  /// Keeps [notes] for [key] (none: the file goes).
  Future<void> save(String key, List<Note> notes) async {
    final keep = [for (final n in notes) if (n.inks.isNotEmpty) n];
    _cache[key] = keep;
    notifyListeners();
    final f = File('${(await _folder()).path}/${_name(key)}');
    if (keep.isEmpty) {
      if (await f.exists()) await f.delete();
      return;
    }
    // Written beside, then moved over: a crash never leaves half a file.
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsString(jsonEncode({
      'version': 1,
      'key': key,
      'notes': [for (final n in keep) n.toJson()],
    }));
    await tmp.rename(f.path);
  }
}
