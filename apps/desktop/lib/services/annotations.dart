// apps/desktop/lib/services/annotations.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' show Offset, Rect;

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/foundation.dart';
import 'package:localroll_core/localroll_core.dart';

import 'library_index.dart';
import 'text_index.dart';

/// What one mark on a picture is.
enum InkTool { pen, marker, line, arrow, rect, ellipse, text, check, cross, number }

/// One mark: a stroke, a shape, a word, a tick… Stored as lines and
/// points, 0–1 of the picture's width / height, so it fits the picture at
/// any size. The original file is never touched.
class InkMark {
  InkMark({
    required this.id,
    required this.tool,
    required this.color,
    required this.width,
    required this.points,
    this.size = 0.05,
    this.text,
    this.number,
    this.atMs,
    this.dx = 0,
    this.dy = 0,
    this.scale = 1,
    this.rotation = 0,
    List<int>? times,
    this.live = false,
    this.wallMs,
  }) : times = times ?? [];

  final String id;
  final InkTool tool;
  int color;

  /// Line width, part of the picture's height.
  double width;

  /// Text / tick / number size, part of the picture's height.
  double size;
  List<Offset> points;
  String? text;
  int? number;

  /// Videos: when it was drawn (it appears then).
  int? atMs;

  /// Moved (0–1 of the picture), resized, turned (radians) afterwards.
  double dx, dy, scale, rotation;

  /// When each point was drawn, ms after the first one (replaying shows
  /// it being drawn). Drawn while the video played ([live]): video time;
  /// drawn while paused: real time.
  List<int> times;

  /// Drawn while the video played (it grows with the video).
  bool live;

  /// Drawn while paused: when, in real time since drawing began (the
  /// order and pace of the replay).
  int? wallMs;

  /// How long drawing it took (ms).
  int get drawMs => times.isEmpty ? 0 : times.last;

  bool get isStamp => tool == InkTool.text || tool == InkTool.check || tool == InkTool.cross || tool == InkTool.number;

  InkMark copy() => InkMark.fromJson(toJson());

  Map<String, dynamic> toJson() => {
        'id': id,
        't': tool.name,
        'c': color,
        'w': _r(width),
        's': _r(size),
        'p': [for (final p in points) ...[_r(p.dx), _r(p.dy)]],
        'text': ?text,
        'n': ?number,
        'at': ?atMs,
        if (dx != 0) 'dx': _r(dx),
        if (dy != 0) 'dy': _r(dy),
        if (scale != 1) 'k': _r(scale),
        if (rotation != 0) 'r': _r(rotation),
        if (times.isNotEmpty) 'pt': times,
        if (live) 'lv': true,
        'wall': ?wallMs,
      };

  static double _r(double v) => (v * 100000).roundToDouble() / 100000;

  static InkMark fromJson(Map<String, dynamic> j) {
    final p = (j['p'] as List?) ?? const [];
    return InkMark(
      id: j['id'] as String? ?? newId(),
      tool: InkTool.values.firstWhere((t) => t.name == j['t'], orElse: () => InkTool.pen),
      color: (j['c'] as num?)?.toInt() ?? 0xFFFF3B30,
      width: (j['w'] as num?)?.toDouble() ?? 0.006,
      size: (j['s'] as num?)?.toDouble() ?? 0.05,
      points: [for (var i = 0; i + 1 < p.length; i += 2) Offset((p[i] as num).toDouble(), (p[i + 1] as num).toDouble())],
      text: j['text'] as String?,
      number: (j['n'] as num?)?.toInt(),
      atMs: (j['at'] as num?)?.toInt(),
      dx: (j['dx'] as num?)?.toDouble() ?? 0,
      dy: (j['dy'] as num?)?.toDouble() ?? 0,
      scale: (j['k'] as num?)?.toDouble() ?? 1,
      rotation: (j['r'] as num?)?.toDouble() ?? 0,
      times: [for (final t in (j['pt'] as List?) ?? const []) (t as num).toInt()],
      live: j['lv'] == true,
      wallMs: (j['wall'] as num?)?.toInt(),
    );
  }

  /// Where it is before moving / turning (0–1).
  Rect get bounds {
    if (points.isEmpty) return Rect.zero;
    var l = points.first.dx, r = l, t = points.first.dy, b = t;
    for (final p in points) {
      l = math.min(l, p.dx);
      r = math.max(r, p.dx);
      t = math.min(t, p.dy);
      b = math.max(b, p.dy);
    }
    return Rect.fromLTRB(l, t, r, b);
  }

  static int _seq = 0;
  static String newId() => '${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}${(_seq++).toRadixString(36)}';
}

/// One annotation: marks drawn together, with a name. On a video it starts
/// at [startMs] (marks drawn while it played appear at their own time) and
/// stays [holdMs] after the last one.
class Note {
  Note({
    required this.id,
    required this.name,
    required this.inks,
    this.startMs = 0,
    this.holdMs = defaultHoldMs,
    this.narration = false,
    int? createdMs,
    int? modifiedMs,
  })  : createdMs = createdMs ?? DateTime.now().millisecondsSinceEpoch,
        modifiedMs = modifiedMs ?? DateTime.now().millisecondsSinceEpoch;

  static const int defaultHoldMs = 3000;

  final String id;
  String name;

  /// Drawn while recording an explanation.
  final bool narration;
  List<InkMark> inks;
  int startMs;
  int holdMs;
  final int createdMs;
  int modifiedMs;

  int get lastMs => inks.fold(startMs, (m, i) => math.max(m, (i.atMs ?? startMs) + (i.live ? i.drawMs : 0)));

  /// Moments where it was drawn while paused: playing stops there and the
  /// drawing is shown again, as it was drawn.
  List<FreezePlan> get freezes {
    final groups = <int, List<InkMark>>{};
    for (final i in inks) {
      if (i.live || i.atMs == null) continue;
      final at = groups.keys.firstWhere((k) => (k - i.atMs!).abs() <= 150, orElse: () => i.atMs!);
      (groups[at] ??= []).add(i);
    }
    return [for (final e in groups.entries) FreezePlan(noteId: id, atMs: e.key, inks: e.value, holdMs: holdMs)]
      ..sort((a, b) => a.atMs.compareTo(b.atMs));
  }
  int get endMs => lastMs + holdMs;

  /// Shown at [ms] (videos).
  bool shownAt(int ms) => ms >= startMs && ms <= endMs;

  /// [ink] shown at [ms] (it appears when it was drawn).
  bool inkShownAt(InkMark ink, int ms) => ms >= (ink.atMs ?? startMs) && ms <= endMs;

  /// Typed words, for search.
  String get words => [name, for (final i in inks) ?i.text].join(' ');

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'start': startMs,
        'hold': holdMs,
        if (narration) 'narration': true,
        'created': createdMs,
        'modified': modifiedMs,
        'inks': [for (final i in inks) i.toJson()],
      };

  static Note fromJson(Map<String, dynamic> j) => Note(
        id: j['id'] as String? ?? InkMark.newId(),
        name: j['name'] as String? ?? '',
        startMs: (j['start'] as num?)?.toInt() ?? 0,
        holdMs: (j['hold'] as num?)?.toInt() ?? defaultHoldMs,
        narration: j['narration'] == true,
        createdMs: (j['created'] as num?)?.toInt(),
        modifiedMs: (j['modified'] as num?)?.toInt(),
        inks: [for (final i in (j['inks'] as List?) ?? const []) if (i is Map<String, dynamic>) InkMark.fromJson(i)],
      );
}

/// Replaying what was drawn while the video was paused: the video stops
/// at [atMs], the marks are drawn again at their own pace (long thinking
/// gaps shortened), then it stays [holdMs] and plays on.
class FreezePlan {
  FreezePlan({required this.noteId, required this.atMs, required List<InkMark> inks, required this.holdMs}) {
    final sorted = List.of(inks)..sort((a, b) => (a.wallMs ?? 0).compareTo(b.wallMs ?? 0));
    var t = 0;
    int? lastEnd;
    for (final i in sorted) {
      final w = i.wallMs;
      if (w == null) {
        // Drawn before replays were recorded: all at once.
        start[i.id] = 0;
        continue;
      }
      if (lastEnd != null) t += math.min(math.max(0, w - lastEnd), maxGapMs);
      start[i.id] = t;
      t += i.drawMs;
      lastEnd = w + i.drawMs;
    }
    drawMs = t;
  }

  /// Pauses between marks longer than this are cut to it.
  static const int maxGapMs = 600;

  final String noteId;
  final int atMs;
  final int holdMs;

  /// When each mark starts in the replay (ms).
  final Map<String, int> start = {};
  late final int drawMs;

  /// The whole stop: drawing, then the hold.
  int get totalMs => drawMs + holdMs;
}

/// The annotations of one photo or video.
class NoteSet {
  NoteSet({required this.key, required this.name, required this.path, required this.size, this.rel, this.sha, this.video = false, List<Note>? notes})
      : notes = notes ?? [];

  final String key;
  String name;
  String path;
  final int size;

  /// Library item: where it is in the library, and its content hash.
  String? rel;
  final String? sha;
  final bool video;
  final List<Note> notes;

  List<Note> get sorted => List.of(notes)..sort((a, b) => a.startMs.compareTo(b.startMs));

  Map<String, dynamic> toJson() => {
        'version': 1,
        'key': key,
        'name': name,
        'path': path,
        'size': size,
        'rel': ?rel,
        'sha': ?sha,
        'video': video,
        'notes': [for (final n in notes) n.toJson()],
      };

  static NoteSet? fromJson(Object? j) {
    if (j is! Map<String, dynamic>) return null;
    final key = j['key'];
    if (key is! String) return null;
    return NoteSet(
      key: key,
      name: j['name'] as String? ?? '',
      path: j['path'] as String? ?? '',
      size: (j['size'] as num?)?.toInt() ?? 0,
      rel: j['rel'] as String?,
      sha: j['sha'] as String?,
      video: j['video'] == true,
      notes: [for (final n in (j['notes'] as List?) ?? const []) if (n is Map<String, dynamic>) Note.fromJson(n)],
    );
  }
}

/// A search result: an annotation, on which file.
class NoteHit {
  const NoteHit({required this.set, required this.note});

  final NoteSet set;
  final Note note;
}

/// Where annotations are kept. Library items: in the library
/// (".localroll\annotations", they travel with it). Other files on this
/// PC: in LocalRoll's own folder, found by their contents (renamed or moved
/// files keep them).
class NoteStore extends ChangeNotifier {
  NoteStore({required this.library, required this.dataDir, required this.textIndex});

  final LibraryIndex library;
  final Directory dataDir;
  final TextIndex textIndex;

  /// Names of the tools in the person's language, for search ("arrow").
  String Function(InkTool t)? toolName;

  Directory get _libDir => Directory('${library.metaDir}${Platform.pathSeparator}annotations');
  Directory get _localDir => Directory('${dataDir.path}${Platform.pathSeparator}annotations');

  /// Every set read so far, by key (for search and counts).
  final Map<String, NoteSet> _sets = {};

  /// Annotation count per library item ([TextIndex.mediaKey]).
  final Map<String, int> _counts = {};
  String? _scannedRoot;

  int countFor(MediaItem i) => _counts[TextIndex.mediaKey(i)] ?? 0;

  /// Key of a library item: its content hash when known.
  static String libraryKey(MediaItem i) =>
      i.sha256 != null && i.sha256!.length >= 32 ? 'h${i.sha256!.substring(0, 32)}' : 'r${shortKey('${i.relPath.toLowerCase()}|${i.size}')}';

  /// Key of any other file: from its size and its first and last MB.
  static Future<String> contentKey(String path) async {
    final f = await File(path).open();
    try {
      final len = await f.length();
      const part = 1 << 20;
      final head = await f.read(math.min(part, len));
      var tail = const <int>[];
      if (len > part) {
        await f.setPosition(math.max(part, len - part));
        tail = await f.read(part);
      }
      final d = crypto.sha256.convert([...utf8.encode('$len|'), ...head, ...tail]);
      return 'c${d.toString().substring(0, 32)}';
    } finally {
      await f.close();
    }
  }

  File _fileFor(String key, bool inLibrary) =>
      File('${(inLibrary ? _libDir : _localDir).path}${Platform.pathSeparator}$key.json');

  /// The annotations of a library item, or of a file at [path] (empty set
  /// when there are none yet).
  Future<NoteSet> open({MediaItem? item, required String path, required String name, required int size, required bool video}) async {
    final key = item != null ? libraryKey(item) : await contentKey(path);
    final known = _sets[key];
    if (known != null) {
      known
        ..path = path
        ..name = name
        ..rel = item?.relPath ?? known.rel;
      return known;
    }
    final file = _fileFor(key, item != null);
    NoteSet? set;
    try {
      if (await file.exists()) set = NoteSet.fromJson(jsonDecode(await file.readAsString()));
    } catch (e) {
      debugPrint('annotations not read: $e');
    }
    set ??= NoteSet(key: key, name: name, path: path, size: size, rel: item?.relPath, sha: item?.sha256, video: video);
    set
      ..path = path
      ..name = name
      ..rel = item?.relPath ?? set.rel;
    _sets[key] = set;
    return set;
  }

  /// Writes [set] (deletes its file when it has no annotations left).
  Future<void> save(NoteSet set) async {
    final inLibrary = set.rel != null;
    final file = _fileFor(set.key, inLibrary);
    try {
      if (set.notes.isEmpty) {
        if (await file.exists()) await file.delete();
      } else {
        await file.parent.create(recursive: true);
        final tmp = File('${file.path}.tmp');
        await tmp.writeAsString(jsonEncode(set.toJson()), flush: true);
        await tmp.rename(file.path);
      }
    } catch (e) {
      DiagLog.log('player', 'annotations not saved: $e');
    }
    _sets[set.key] = set;
    _index(set);
    notifyListeners();
  }

  /// Search text of a set: names, typed words, tool names.
  String _words(NoteSet s) => [
        for (final n in s.notes) ...[
          n.words,
          for (final t in {for (final i in n.inks) i.tool}) ?toolName?.call(t),
        ],
      ].join(' ');

  void _index(NoteSet s) {
    final rel = s.rel;
    if (rel == null) return;
    final item = (s.sha != null ? library.findSame(s.size, s.sha!) : null) ?? library.findByRel(rel);
    if (item == null) return;
    final k = TextIndex.mediaKey(item);
    if (s.notes.isEmpty) {
      _counts.remove(k);
    } else {
      _counts[k] = s.notes.length;
    }
    textIndex.setNotes(k, s.notes.isEmpty ? null : _words(s));
  }

  /// Reads every annotation file (at start, and when the library moves):
  /// counts on the thumbnails, and the search box finds them.
  Future<void> scan() async {
    if (_scannedRoot == library.rootPath) return;
    _scannedRoot = library.rootPath;
    _sets.removeWhere((_, s) => s.rel != null);
    _counts.clear();
    for (final (dir, lib) in [(_libDir, true), (_localDir, false)]) {
      try {
        if (!await dir.exists()) continue;
        await for (final e in dir.list()) {
          if (e is! File || !e.path.endsWith('.json')) continue;
          try {
            final s = NoteSet.fromJson(jsonDecode(await e.readAsString()));
            if (s == null || s.notes.isEmpty) continue;
            if (lib && s.rel == null) s.rel = '';
            if (!lib) s.rel = null;
            _sets[s.key] = s;
            _index(s);
          } catch (_) {}
        }
      } catch (_) {}
    }
    notifyListeners();
  }

  /// Every annotation set read so far (library and other files).
  Iterable<NoteSet> get sets => _sets.values;

  /// The [count] annotations changed last.
  List<NoteHit> recent(int count) {
    final all = [
      for (final s in _sets.values)
        for (final n in s.notes) NoteHit(set: s, note: n),
    ]..sort((a, b) => b.note.modifiedMs.compareTo(a.note.modifiedMs));
    return all.take(count).toList();
  }

  /// Annotations whose name, words or tool names have all of [query]'s words.
  List<NoteHit> search(String query) {
    final q = SearchQuery(query);
    if (q.isEmpty) return const [];
    final out = <NoteHit>[];
    for (final s in _sets.values) {
      for (final n in s.notes) {
        final text = TextIndex.normalize([
          n.words,
          s.name,
          for (final t in {for (final i in n.inks) i.tool}) ?toolName?.call(t),
        ].join(' '));
        if (q.words.every(text.contains)) out.add(NoteHit(set: s, note: n));
      }
    }
    out.sort((a, b) => b.note.modifiedMs.compareTo(a.note.modifiedMs));
    return out;
  }
}

/// "Circle, arrow": the kinds of marks in [inks] (in the order first used),
/// for an annotation's name.
List<InkTool> inkKinds(List<InkMark> inks) {
  final out = <InkTool>[];
  for (final i in inks) {
    if (!out.contains(i.tool)) out.add(i.tool);
  }
  return out;
}
