// apps/desktop/lib/services/people.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:localroll_core/localroll_core.dart';

import 'face_engine.dart';
import 'library_index.dart';
import 'text_index.dart';

/// One face in one photo, and whose it is.
class Face {
  Face(this.item, this.n, this.score, this.x, this.y, this.w, this.h, this.v, this.scale, this.person);

  /// The photo (TextIndex keys) and which face in it.
  final String item;
  final int n;
  final double score;

  /// Where in the photo (0–1 of its width / height).
  final double x, y, w, h;

  /// The face reader's 128 numbers as small whole numbers, and what one
  /// step is worth.
  final Int8List v;
  final double scale;
  int person;

  String get id => '$item#$n';

  double dot(Float64List c) {
    var s = 0.0;
    for (var i = 0; i < PeopleIndex.dim; i++) {
      s += v[i] * c[i];
    }
    return s * scale;
  }
}

/// A person: the faces grouped as one, maybe named by the user.
class Person {
  Person(this.id, {this.name, this.hidden = false});

  final int id;
  String? name;
  bool hidden;
}

/// What the People page shows of a person.
class PersonView {
  const PersonView(this.person, this.items, this.cover);

  final Person person;

  /// Photos the person is in (keys).
  final Set<String> items;

  /// The clearest, biggest face (for the picture on the card).
  final Face cover;
}

/// Who is in which photo: faces grouped into people, kept in the library's
/// own .localroll/people folder (it goes wherever the library goes).
/// Nothing leaves this PC.
class PeopleIndex extends ChangeNotifier {
  PeopleIndex(this.library);

  final LibraryIndex library;

  static const int dim = 128;

  /// A face joins a person when it is at least this alike to the person's
  /// average face (the reader's own "same person" line is 0.363; a bit
  /// stricter, so one person may come in two groups — merged with one
  /// click — rather than two people in one).
  static const double sameAs = 0.42;

  static final List<int> _magic = utf8.encode('LRF1');

  /// Photo → its faces (empty: read, nobody there).
  final Map<String, List<Face>> _items = {};
  final Map<int, Person> _people = {};

  /// Per person: the sum of its faces' numbers, and how many.
  final Map<int, Float64List> _sum = {};
  final Map<int, int> _count = {};

  /// Face → people it was said not to be ("not this person").
  final Map<String, Set<int>> _not = {};
  int _nextId = 1;

  String? _loadedFor;
  Future<void>? _loading;
  Future<void> _saving = Future.value();
  bool _dirty = false;
  Timer? _saveSoon;

  String get _sep => Platform.pathSeparator;
  String get _dir => '${library.metaDir}${_sep}people';
  File get _facesFile => File('$_dir${_sep}faces-v1.bin');
  File get _peopleFile => File('$_dir${_sep}people.json');

  bool has(String item) => _items.containsKey(item);
  int get photosRead => _items.length;

  Future<void> load() {
    if (_loadedFor != library.rootPath) _loading = null;
    return _loading ??= _load();
  }

  Future<void> _load() async {
    _loadedFor = library.rootPath;
    _items.clear();
    _people.clear();
    _sum.clear();
    _count.clear();
    _not.clear();
    _nextId = 1;
    try {
      if (await _peopleFile.exists()) {
        final j = jsonDecode(await _peopleFile.readAsString()) as Map<String, dynamic>;
        _nextId = (j['next'] as num?)?.toInt() ?? 1;
        for (final p in (j['people'] as List? ?? const [])) {
          final m = p as Map<String, dynamic>;
          final id = (m['id'] as num).toInt();
          _people[id] = Person(id, name: m['name'] as String?, hidden: m['hidden'] == true);
        }
        for (final e in ((j['not'] as Map?) ?? const {}).entries) {
          _not[e.key as String] = {for (final x in e.value as List) (x as num).toInt()};
        }
      }
      if (await _facesFile.exists()) {
        final b = await _facesFile.readAsBytes();
        final d = ByteData.sublistView(b);
        if (b.length >= 8 && listEquals(b.sublist(0, 4), _magic)) {
          final n = d.getUint32(4, Endian.little);
          var at = 8;
          for (var i = 0; i < n && at + 3 <= b.length; i++) {
            final len = d.getUint16(at, Endian.little);
            at += 2;
            if (at + len + 1 > b.length) break;
            final item = utf8.decode(b.sublist(at, at + len));
            at += len;
            final count = b[at++];
            final faces = <Face>[];
            const per = 4 * 6 + dim + 4;
            for (var k = 0; k < count && at + per <= b.length; k++) {
              double f32() {
                final v = d.getFloat32(at, Endian.little);
                at += 4;
                return v;
              }

              final score = f32(), x = f32(), y = f32(), w = f32(), h = f32(), scale = f32();
              final v = Int8List.fromList(b.sublist(at, at + dim));
              at += dim;
              final person = d.getUint32(at, Endian.little);
              at += 4;
              faces.add(Face(item, k, score, x, y, w, h, v, scale, person));
            }
            _items[item] = faces;
            for (final f in faces) {
              _people.putIfAbsent(f.person, () => Person(f.person));
              _addTo(f.person, f);
              _nextId = math.max(_nextId, f.person + 1);
            }
          }
        }
      }
      // People left with no face (their photos went) go.
      _people.removeWhere((id, _) => (_count[id] ?? 0) == 0);
    } catch (e) {
      DiagLog.log('people', 'people unreadable, starting again: $e');
    }
    notifyListeners();
  }

  void _addTo(int person, Face f, [int sign = 1]) {
    final s = _sum.putIfAbsent(person, () => Float64List(dim));
    for (var i = 0; i < dim; i++) {
      s[i] += sign * f.v[i] * f.scale;
    }
    _count[person] = (_count[person] ?? 0) + sign;
    if ((_count[person] ?? 0) <= 0) {
      _sum.remove(person);
      _count.remove(person);
    }
  }

  /// How alike [f] is to [person]'s average face.
  double _alike(Face f, int person) {
    final s = _sum[person];
    if (s == null) return -1;
    var n = 0.0;
    for (final x in s) {
      n += x * x;
    }
    return n == 0 ? -1 : f.dot(s) / math.sqrt(n);
  }

  /// The person [f] belongs to (an existing one alike enough, not one it
  /// was said not to be, not someone already in the same photo), or a new one.
  int _place(Face f, Set<int> taken) {
    final no = _not[f.id] ?? const <int>{};
    var best = -1, bestScore = sameAs;
    for (final p in _sum.keys) {
      if (no.contains(p) || taken.contains(p)) continue;
      final a = _alike(f, p);
      if (a >= bestScore) {
        best = p;
        bestScore = a;
      }
    }
    if (best >= 0) return best;
    final id = _nextId++;
    _people[id] = Person(id);
    return id;
  }

  /// The faces read in a photo ([faces] empty: nobody there).
  void put(String item, List<FaceRead> faces) {
    _removeItem(item);
    final list = <Face>[];
    final taken = <int>{};
    for (var k = 0; k < faces.length; k++) {
      final r = faces[k];
      var top = 0.0;
      for (final x in r.vector) {
        top = math.max(top, x.abs());
      }
      final scale = top == 0 ? 0.0 : top / 127;
      final v = Int8List(dim);
      for (var i = 0; i < dim && i < r.vector.length && scale > 0; i++) {
        v[i] = (r.vector[i] / scale).round().clamp(-127, 127);
      }
      final f = Face(item, k, r.score, r.x, r.y, r.w, r.h, v, scale, 0);
      if (scale == 0) continue;
      f.person = _place(f, taken);
      taken.add(f.person);
      _addTo(f.person, f);
      list.add(f);
    }
    _items[item] = list;
    _changed();
  }

  void _removeItem(String item) {
    final old = _items.remove(item);
    if (old == null) return;
    for (final f in old) {
      _addTo(f.person, f, -1);
      if (!_count.containsKey(f.person)) _people.remove(f.person);
    }
  }

  /// Keeps only [keep] (deleted / changed photos go).
  void prune(Set<String> keep) {
    final gone = [for (final k in _items.keys) if (!keep.contains(k)) k];
    if (gone.isEmpty) return;
    for (final k in gone) {
      _removeItem(k);
    }
    _not.removeWhere((id, _) => !keep.contains(id.substring(0, id.lastIndexOf('#'))));
    _changed();
  }

  void _changed({bool now = false}) {
    _dirty = true;
    notifyListeners();
    if (now) {
      _saveSoon?.cancel();
      _saveSoon = null;
      unawaited(save());
      return;
    }
    _saveSoon ??= Timer(const Duration(seconds: 20), () {
      _saveSoon = null;
      unawaited(save());
    });
  }

  Future<void> save() => _saving = _saving.then((_) async {
        if (!_dirty || library.offline) return;
        _dirty = false;
        try {
          await Directory(_dir).create(recursive: true);
          final b = BytesBuilder(copy: false)..add(_magic);
          b.add((ByteData(4)..setUint32(0, _items.length, Endian.little)).buffer.asUint8List());
          for (final e in _items.entries) {
            final k = utf8.encode(e.key);
            b
              ..add((ByteData(2)..setUint16(0, k.length, Endian.little)).buffer.asUint8List())
              ..add(k)
              ..addByte(e.value.length);
            for (final f in e.value) {
              final d = ByteData(24)
                ..setFloat32(0, f.score, Endian.little)
                ..setFloat32(4, f.x, Endian.little)
                ..setFloat32(8, f.y, Endian.little)
                ..setFloat32(12, f.w, Endian.little)
                ..setFloat32(16, f.h, Endian.little)
                ..setFloat32(20, f.scale, Endian.little);
              b
                ..add(d.buffer.asUint8List())
                ..add(Uint8List.view(f.v.buffer))
                ..add((ByteData(4)..setUint32(0, f.person, Endian.little)).buffer.asUint8List());
            }
          }
          await _write(_facesFile, b.takeBytes());
          await _write(
              _peopleFile,
              utf8.encode(jsonEncode({
                'next': _nextId,
                'people': [
                  for (final p in _people.values)
                    if (p.name != null || p.hidden) {'id': p.id, if (p.name != null) 'name': p.name, if (p.hidden) 'hidden': true},
                ],
                'not': {for (final e in _not.entries) e.key: e.value.toList()},
              })));
        } catch (e) {
          _dirty = true;
          DiagLog.log('people', 'people not saved: $e');
        }
      });

  static Future<void> _write(File f, List<int> bytes) async {
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsBytes(bytes, flush: true);
    await tmp.rename(f.path);
  }

  // ------------------------------------------------------------ what's shown

  /// Everyone found, most photos first (named ones first).
  List<PersonView> people() {
    final items = <int, Set<String>>{};
    final cover = <int, Face>{};
    double clear(Face f) => f.score * f.w * f.h;
    for (final faces in _items.values) {
      for (final f in faces) {
        (items[f.person] ??= {}).add(f.item);
        final c = cover[f.person];
        // Library photos before received files for the card.
        if (c == null || (c.item.startsWith('f:') && f.item.startsWith('m:')) ||
            (c.item.startsWith('m:') == f.item.startsWith('m:') && clear(f) > clear(c))) {
          cover[f.person] = f;
        }
      }
    }
    final out = [
      for (final e in items.entries)
        if (_people[e.key] != null) PersonView(_people[e.key]!, e.value, cover[e.key]!),
    ];
    out.sort((a, b) {
      final an = a.person.name != null, bn = b.person.name != null;
      if (an != bn) return an ? -1 : 1;
      return b.items.length.compareTo(a.items.length);
    });
    return out;
  }

  Person? person(int id) => _people[id];

  /// The photos [id] is in.
  Set<String> itemsOf(int id) => {
        for (final faces in _items.values)
          for (final f in faces)
            if (f.person == id) f.item,
      };

  /// The person's face in [item] (for its picture), if any.
  Face? faceIn(int id, String item) {
    for (final f in _items[item] ?? const <Face>[]) {
      if (f.person == id) return f;
    }
    return null;
  }

  // ------------------------------------------------------------ the user's say

  void rename(int id, String? name) {
    final p = _people[id];
    if (p == null) return;
    final n = name?.trim();
    p.name = n == null || n.isEmpty ? null : n;
    _changed(now: true);
  }

  void setHidden(int id, bool hidden) {
    final p = _people[id];
    if (p == null) return;
    p.hidden = hidden;
    _changed(now: true);
  }

  /// [from] is the same person as [into]: one person from now on.
  void merge(int from, int into) {
    if (from == into || _people[from] == null || _people[into] == null) return;
    for (final faces in _items.values) {
      for (final f in faces) {
        if (f.person != from) continue;
        _addTo(from, f, -1);
        f.person = into;
        _addTo(into, f);
        _not[f.id]?.remove(into);
      }
    }
    final a = _people.remove(from)!, b = _people[into]!;
    b.name ??= a.name;
    b.hidden = b.hidden && a.hidden;
    _changed(now: true);
  }

  /// [id] is not in [items]: those faces go to someone else (or someone
  /// new), and are not put back with [id] again.
  void notThisPerson(int id, Iterable<String> items) {
    final moved = <Face>[];
    for (final item in items) {
      for (final f in _items[item] ?? const <Face>[]) {
        if (f.person != id) continue;
        _addTo(id, f, -1);
        (_not[f.id] ??= {}).add(id);
        moved.add(f);
      }
    }
    for (final f in moved) {
      final taken = {for (final o in _items[f.item]!) if (o != f) o.person};
      f.person = _place(f, taken);
      _addTo(f.person, f);
    }
    if (!_count.containsKey(id)) _people.remove(id);
    _changed(now: true);
  }

  /// Takes every face and name off this PC's library (switched off for good).
  Future<void> clear() async {
    _saveSoon?.cancel();
    _saveSoon = null;
    _items.clear();
    _people.clear();
    _sum.clear();
    _count.clear();
    _not.clear();
    _nextId = 1;
    _dirty = false;
    await _saving;
    try {
      final d = Directory(_dir);
      if (await d.exists()) await d.delete(recursive: true);
      // The faces cut out for the People page go too.
      final cache = Directory(library.cacheDir);
      if (await cache.exists()) {
        await for (final e in cache.list(followLinks: false)) {
          if (e is File && e.path.endsWith('_f.jpg')) {
            try {
              await e.delete();
            } catch (_) {}
          }
        }
      }
    } catch (e) {
      DiagLog.log('people', 'people not removed: $e');
    }
    notifyListeners();
  }

  // ------------------------------------------------------------ search

  /// A search naming people ("Mum", "Mum beach", "妈妈海边"): the people's
  /// photos (all of them in each) and the rest of the words; null when no
  /// name is in it. Hidden people are not found.
  (Set<String>, String)? split(String query) {
    final names = [
      for (final p in _people.values)
        if (p.name != null && !p.hidden) (TextIndex.normalize(p.name!), p.id),
    ]..sort((a, b) => b.$1.length.compareTo(a.$1.length));
    if (names.isEmpty) return null;
    final rest = <String>[];
    final who = <int>{};
    for (final word in query.trim().split(RegExp(r'\s+'))) {
      if (word.isEmpty) continue;
      final w = TextIndex.normalize(word);
      var hit = false;
      for (final (n, id) in names) {
        if (n.isEmpty) continue;
        if (w == n) {
          who.add(id);
          hit = true;
          break;
        }
        // Written together: "妈妈海边".
        if (w.startsWith(n) && w.length > n.length) {
          who.add(id);
          rest.add(word.substring(word.length - (w.length - n.length)));
          hit = true;
          break;
        }
      }
      if (!hit) rest.add(word);
    }
    if (who.isEmpty) return null;
    Set<String>? items;
    for (final id in who) {
      final mine = itemsOf(id);
      items = items == null ? mine : items.intersection(mine);
    }
    return (items ?? <String>{}, rest.join(' '));
  }

  @override
  void dispose() {
    _saveSoon?.cancel();
    super.dispose();
  }
}
