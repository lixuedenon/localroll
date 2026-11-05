// packages/ink/lib/src/stamp_packs.dart
import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui';

import 'candle.dart';
import 'stamp.dart';
import 'stamp_icons.g.dart';

part 'packs/art.dart';
part 'packs/draw.dart';
part 'packs/school.dart';
part 'packs/sports.dart';
part 'packs/work.dart';

/// A ready-made stamp. Its name: the app's text 'stamp.<id>'.
class Stamp {
  const Stamp({required this.id, required this.pack, required this.shape});

  final String id;

  /// 'basic', 'finance', 'mine'…
  final String pack;
  final StampShape shape;
}

/// The packs that come with LocalRoll.
class StampPacks {
  static const List<String> packs = ['basic', 'finance', 'kids', 'math', 'physics', 'chem', 'bio', 'geo', 'history', 'lang', 'code', 'callig', 'music', 'art', 'photo', 'dance', 'tactics', 'fields', 'fitness', 'golf', 'tutorial', 'business', 'shop', 'interior', 'engineering', 'auto', 'legal', 'medical', 'traffic', 'cooking', 'gaming', 'astro'];

  /// The packs by kind (the panel shows a kind, then its packs).
  static const Map<String, List<String>> kinds = {
    'general': ['basic', 'finance', 'kids'],
    'school': ['math', 'physics', 'chem', 'bio', 'geo', 'history', 'lang', 'code', 'callig'],
    'art': ['music', 'art', 'photo', 'dance'],
    'sports': ['tactics', 'fields', 'fitness', 'golf'],
    'work': ['tutorial', 'business', 'shop', 'interior', 'engineering', 'auto', 'legal', 'medical', 'traffic', 'cooking', 'gaming', 'astro'],
  };

  static Map<String, List<List<Offset>>>? _icons;

  static List<List<Offset>> _icon(String name) {
    final all = _icons ??= {
      for (final e in (jsonDecode(stampIconsJson) as Map<String, dynamic>).entries)
        e.key: [
          for (final p in e.value as List)
            [for (var i = 0; i + 1 < (p as List).length; i += 2) Offset((p[i] as num).toDouble(), (p[i + 1] as num).toDouble())],
        ],
    };
    return all[name] ?? const [];
  }

  static StampShape _ic(String name, {int? color, String? role}) =>
      StampShape(aspect: 1, parts: [StampPart(polys: _icon(name), color: color, role: role)]);

  /// A round badge with a word (buy / sell).
  static StampShape _badge(String word, String role) {
    final ring = [for (var k = 0; k < 40; k++) Offset(0.5 + 0.48 * math.cos(k * math.pi / 20), 0.5 + 0.48 * math.sin(k * math.pi / 20))];
    return StampShape(aspect: 1, parts: [
      StampPart(polys: [ring], role: role),
      StampPart(text: word, size: 0.55, color: 0xFFFFFFFF),
    ]);
  }

  /// A price tag with a word.
  static StampShape _tag(String word, String role) => StampShape(aspect: 2.2, parts: [
        StampPart(polys: [
          [const Offset(0.0, 0.5), const Offset(0.16, 0.05), const Offset(1, 0.05), const Offset(1, 0.95), const Offset(0.16, 0.95)],
        ], role: role),
        StampPart(text: word, at: const Offset(0.58, 0.5), size: 0.55, color: 0xFFFFFFFF),
      ]);

  /// The candle stamps (shown in the candle panel too).
  static const List<String> singles = ['doji', 'hammer', 'inv_hammer', 'upper_shadow', 'lower_shadow', 'marubozu'];
  static const List<String> patterns = ['bull_engulf', 'bear_engulf', 'morning_star', 'evening_star', 'three_soldiers', 'three_crows', 'gap'];

  static Stamp? byId(String id) {
    for (final s in all) {
      if (s.id == id) return s;
    }
    return null;
  }

  static List<Stamp>? _all;

  static List<Stamp> get all => _all ??= [
        // Basic.
        Stamp(id: 'check', pack: 'basic', shape: _ic('check')),
        Stamp(id: 'cross', pack: 'basic', shape: _ic('close')),
        Stamp(id: 'question', pack: 'basic', shape: _ic('question_mark')),
        Stamp(id: 'exclaim', pack: 'basic', shape: _ic('priority_high')),
        Stamp(id: 'star', pack: 'basic', shape: _ic('star')),
        Stamp(id: 'heart', pack: 'basic', shape: _ic('favorite')),
        Stamp(id: 'thumb', pack: 'basic', shape: _ic('thumb_up')),
        Stamp(
          id: 'box',
          pack: 'basic',
          shape: const StampShape(aspect: 1.6, parts: [
            StampPart(fill: false, w: 0.07, polys: [
              [Offset(0.04, 0.06), Offset(0.96, 0.06), Offset(0.96, 0.94), Offset(0.04, 0.94), Offset(0.04, 0.06)],
            ]),
          ]),
        ),
        Stamp(id: 'bubble', pack: 'basic', shape: _ic('chat_bubble')),
        Stamp(id: 'point', pack: 'basic', shape: _ic('pan_tool_alt')),
        Stamp(id: 'magnifier', pack: 'basic', shape: _ic('search')),
        Stamp(id: 'bulb', pack: 'basic', shape: _ic('lightbulb')),
        Stamp(id: 'warning', pack: 'basic', shape: _ic('warning')),
        Stamp(id: 'forbid', pack: 'basic', shape: _ic('block')),
        Stamp(id: 'smile', pack: 'basic', shape: _ic('sentiment_satisfied')),
        Stamp(id: 'frown', pack: 'basic', shape: _ic('sentiment_dissatisfied')),
        // Finance.
        Stamp(id: 'buy', pack: 'finance', shape: _badge('B', 'u')),
        Stamp(id: 'sell', pack: 'finance', shape: _badge('S', 'd')),
        Stamp(id: 'stop', pack: 'finance', shape: _tag('SL', 'd')),
        Stamp(id: 'profit', pack: 'finance', shape: _tag('TP', 'u')),
        Stamp(
          id: 'tag',
          pack: 'finance',
          shape: const StampShape(aspect: 2.2, parts: [
            StampPart(fill: false, w: 0.07, polys: [
              [Offset(0.02, 0.5), Offset(0.17, 0.08), Offset(0.98, 0.08), Offset(0.98, 0.92), Offset(0.17, 0.92), Offset(0.02, 0.5)],
            ]),
          ]),
        ),
        Stamp(id: 'up', pack: 'finance', shape: _ic('arrow_upward', role: 'u')),
        Stamp(id: 'down', pack: 'finance', shape: _ic('arrow_downward', role: 'd')),
        Stamp(id: 'trend_up', pack: 'finance', shape: _ic('trending_up', role: 'u')),
        Stamp(id: 'trend_down', pack: 'finance', shape: _ic('trending_down', role: 'd')),
        Stamp(id: 'flag', pack: 'finance', shape: _ic('flag')),
        // One candle each, rising and falling.
        for (final (id, c) in const [
          ('doji', (0.5, 0.51, 0.85, 0.15)),
          ('hammer', (0.72, 0.86, 0.9, 0.1)),
          ('inv_hammer', (0.14, 0.28, 0.9, 0.1)),
          ('upper_shadow', (0.2, 0.3, 0.95, 0.15)),
          ('lower_shadow', (0.7, 0.8, 0.85, 0.05)),
          ('marubozu', (0.1, 0.9, 0.9, 0.1)),
        ]) ...[
          Stamp(id: '${id}_up', pack: 'finance', shape: Candles.pattern([c], role: 'u')),
          Stamp(id: '${id}_down', pack: 'finance', shape: Candles.pattern([(c.$2, c.$1, c.$3, c.$4)], role: 'd')),
        ],
        Stamp(id: 'bull_engulf', pack: 'finance', shape: Candles.pattern([(0.6, 0.4, 0.65, 0.35), (0.3, 0.75, 0.8, 0.25)])),
        Stamp(id: 'bear_engulf', pack: 'finance', shape: Candles.pattern([(0.4, 0.6, 0.65, 0.35), (0.75, 0.25, 0.8, 0.2)])),
        Stamp(id: 'morning_star', pack: 'finance', shape: Candles.pattern([(0.85, 0.4, 0.9, 0.35), (0.3, 0.26, 0.35, 0.18), (0.35, 0.8, 0.85, 0.3)])),
        Stamp(id: 'evening_star', pack: 'finance', shape: Candles.pattern([(0.15, 0.6, 0.65, 0.1), (0.72, 0.76, 0.82, 0.68), (0.65, 0.2, 0.7, 0.15)])),
        Stamp(id: 'three_soldiers', pack: 'finance', shape: Candles.pattern([(0.1, 0.35, 0.4, 0.05), (0.3, 0.6, 0.65, 0.25), (0.55, 0.85, 0.9, 0.5)])),
        Stamp(id: 'three_crows', pack: 'finance', shape: Candles.pattern([(0.9, 0.65, 0.95, 0.6), (0.7, 0.4, 0.75, 0.35), (0.45, 0.15, 0.5, 0.1)])),
        Stamp(id: 'gap', pack: 'finance', shape: Candles.pattern([(0.1, 0.35, 0.4, 0.05), (0.55, 0.8, 0.85, 0.5)])),
        ..._schoolStamps(),
        ..._artStamps(),
        ..._sportsStamps(),
        ..._workStamps(),
      ];
}
