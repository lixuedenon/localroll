// apps/desktop/lib/services/stamp_library.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:localroll_core/localroll_core.dart';
import 'package:localroll_ink/localroll_ink.dart';

/// One stamp the user made (from drawn marks or a picture).
class MyStamp {
  MyStamp({required this.id, required this.name, required this.shape});

  final String id;
  String name;
  final StampShape shape;

  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'shape': shape.toJson()};

  static MyStamp? fromJson(Object? j) {
    if (j is! Map) return null;
    final m = j.cast<String, dynamic>();
    final sh = m['shape'];
    if (m['id'] is! String || sh is! Map) return null;
    return MyStamp(id: m['id'] as String, name: m['name'] as String? ?? '', shape: StampShape.fromJson(sh.cast<String, dynamic>()));
  }
}

/// The stamps on this PC: the user's own, recently used, favourites, and
/// candle colours (stamps.json beside the settings; never sent anywhere).
class StampLibrary extends ChangeNotifier {
  StampLibrary._();

  static final StampLibrary instance = StampLibrary._();

  File? _file;
  final List<MyStamp> mine = [];
  final List<String> recent = [];
  final Set<String> favorites = {};

  /// Packs not shown in the stamp panel (turned off there).
  final Set<String> hiddenPacks = {};

  /// Candles: rising / falling colours (rising green, as in US markets,
  /// unless changed).
  int upColor = Candles.green, downColor = Candles.red;

  bool get redUp => upColor == Candles.red && downColor == Candles.green;

  (int, int) get colors => (upColor, downColor);

  /// The candle kind drawn by hand.
  CandleKind kind = CandleKind.normal;

  Future<void> load(Directory dataDir) async {
    final f = _file = File('${dataDir.path}${Platform.pathSeparator}stamps.json');
    try {
      if (!await f.exists()) return;
      final j = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      mine
        ..clear()
        ..addAll([for (final x in (j['mine'] as List?) ?? const []) ?MyStamp.fromJson(x)]);
      recent
        ..clear()
        ..addAll([for (final x in (j['recent'] as List?) ?? const []) '$x']);
      favorites
        ..clear()
        ..addAll([for (final x in (j['fav'] as List?) ?? const []) '$x']);
      hiddenPacks
        ..clear()
        ..addAll([for (final x in (j['hide'] as List?) ?? const []) '$x']);
      upColor = (j['up'] as num?)?.toInt() ?? Candles.green;
      downColor = (j['down'] as num?)?.toInt() ?? Candles.red;
      kind = CandleKind.values.firstWhere((k) => k.name == j['kind'], orElse: () => CandleKind.normal);
    } catch (e) {
      DiagLog.log('stamps', 'not read: $e');
    }
  }

  Timer? _save;

  void _changed() {
    notifyListeners();
    _save?.cancel();
    _save = Timer(const Duration(milliseconds: 400), () async {
      final f = _file;
      if (f == null) return;
      try {
        final tmp = File('${f.path}.tmp');
        await tmp.writeAsString(jsonEncode({
          'mine': [for (final m in mine) m.toJson()],
          'recent': recent,
          'fav': [...favorites],
          'hide': [...hiddenPacks],
          'up': upColor,
          'down': downColor,
          'kind': kind.name,
        }));
        await tmp.rename(f.path);
      } catch (e) {
        DiagLog.log('stamps', 'not saved: $e');
      }
    });
  }

  void setRedUp(bool v) {
    final c = Candles.colors(v);
    upColor = c.$1;
    downColor = c.$2;
    _changed();
  }

  void setColors({int? up, int? down}) {
    if (up != null) upColor = up;
    if (down != null) downColor = down;
    _changed();
  }

  void setKind(CandleKind k) {
    kind = k;
    _changed();
  }

  /// Used now: first in "Recent" (at most 24).
  void used(String id) {
    recent
      ..remove(id)
      ..insert(0, id);
    if (recent.length > 24) recent.removeRange(24, recent.length);
    _changed();
  }

  void setPackShown(String pack, bool shown) {
    shown ? hiddenPacks.remove(pack) : hiddenPacks.add(pack);
    _changed();
  }

  /// The user's own stamps as a file's contents (to keep or send).
  String exportMine([List<MyStamp>? only]) => jsonEncode({
        'localrollStamps': 1,
        'stamps': [for (final m in only ?? mine) m.toJson()],
      });

  /// Adds the stamps in [text] (an exported file); how many were added.
  /// Ones already here (same name and picture) are skipped.
  int importMine(String text) {
    final j = jsonDecode(text);
    if (j is! Map || j['localrollStamps'] == null) throw const FormatException('not a stamp file');
    var n = 0;
    for (final x in (j['stamps'] as List?) ?? const []) {
      final m = MyStamp.fromJson(x);
      if (m == null) continue;
      final pic = jsonEncode(m.shape.toJson());
      if (mine.any((o) => o.name == m.name && jsonEncode(o.shape.toJson()) == pic)) continue;
      mine.add(MyStamp(id: 'my_${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}$n', name: m.name, shape: m.shape));
      n++;
    }
    if (n > 0) _changed();
    return n;
  }

  void toggleFavorite(String id) {
    if (!favorites.remove(id)) favorites.add(id);
    _changed();
  }

  MyStamp add(String name, StampShape shape) {
    final m = MyStamp(id: 'my_${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}', name: name, shape: shape);
    mine.insert(0, m);
    _changed();
    return m;
  }

  void remove(String id) {
    mine.removeWhere((m) => m.id == id);
    recent.remove(id);
    favorites.remove(id);
    _changed();
  }

  void rename(String id, String name) {
    for (final m in mine) {
      if (m.id == id) m.name = name;
    }
    _changed();
  }
}
