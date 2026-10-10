// packages/core/lib/src/device_names.dart
import 'dart:math';

import 'i18n.dart';
import 'languages.g.dart';

/// Random, friendly device names in the user's language: 24 × 24 = 576 per
/// language, about 9 800 across the 17 languages. The words are data, not
/// code: packages/core/l10n/names/<language>.json.
///
/// Theme "light + place" (Amber Lighthouse, 琥珀灯塔): fits a photo app, is
/// easy to say aloud ("send it to Amber Lighthouse"), and stays neutral across
/// cultures — no animals, food, religion or numbers, nothing with an unlucky
/// meaning or homophone. Each language composes the two parts its own way so
/// the result is grammatical (no gender/case agreement needed).
class DeviceNames {
  DeviceNames._();

  static final Random _rng = Random();

  /// A new name in [language] (falls back to English) that is not in
  /// [avoid] — pass the names of known devices and the names already shown,
  /// so rolling again always gives something new and no two devices clash.
  static String random(String language, {Random? rng, Set<String> avoid = const {}}) {
    final r = rng ?? _rng;
    final set = deviceNameWords[language] ?? deviceNameWords[fallbackLanguage]!;
    var name = '';
    for (var i = 0; i < 60; i++) {
      name = set.compose(set.first[r.nextInt(set.first.length)], set.second[r.nextInt(set.second.length)]);
      if (!avoid.contains(name)) break;
    }
    return name;
  }

  /// How many different names [language] can produce (24 × 24 = 576).
  static int countFor(String language) {
    final set = deviceNameWords[language] ?? deviceNameWords[fallbackLanguage]!;
    return set.first.length * set.second.length;
  }
}

/// One language's word lists and how to join them. The data lives in
/// packages/core/l10n/names/<language>.json (edit there, then run
/// `python scripts/gen_l10n.py`).
class NameWords {
  const NameWords({
    required this.first,
    required this.second,
    required this.pattern,
    this.vowelPattern,
    this.vowels = '',
  });

  final List<String> first;
  final List<String> second;

  /// `{a}` and `{b}` stand for the two words, e.g. `{a} de {b}`.
  final String pattern;

  /// Used instead of [pattern] when the second word starts with one of
  /// [vowels] (Italian / French elision: `{a} d’{b}`).
  final String? vowelPattern;
  final String vowels;

  String compose(String a, String b) {
    final vp = vowelPattern;
    final usesVowel = vp != null && b.isNotEmpty && vowels.contains(b[0]);
    return (usesVowel ? vp : pattern).replaceAll('{a}', a).replaceAll('{b}', b);
  }
}

/// Icons a device can show (keys shared by both apps; each app maps them to
/// its own icon set) and the colour palette for the badge.
class DeviceLook {
  DeviceLook._();

  static const List<String> icons = [
    'desktop', 'laptop', 'home', 'work', 'sofa', 'study', 'bed', 'tv',
    'star', 'camera', 'mountain', 'sun', 'palette', 'music', 'plant', 'rocket',
  ];

  /// ARGB values that read well on the dark Darkroom background.
  static const List<int> colors = [
    0xFFFFB547, 0xFF5FD4C4, 0xFF7AA7FF, 0xFFFF8A80,
    0xFFB39DFF, 0xFF9CCC65, 0xFFFFD54F, 0xFFF48FB1,
  ];

  static String randomIcon([Random? rng]) => icons[(rng ?? Random()).nextInt(icons.length)];

  static int randomColor([Random? rng]) => colors[(rng ?? Random()).nextInt(colors.length)];
}
