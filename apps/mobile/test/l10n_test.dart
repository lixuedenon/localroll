// apps/mobile/test/l10n_test.dart
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localroll_core/localroll_core.dart';
import 'package:localroll_mobile/l10n/l10n.dart';
import 'package:localroll_mobile/l10n/translations.g.dart';

void main() {
  test('every supported language has every key', () {
    final keys = translations['en']!.keys.toSet();
    for (final lang in supportedLanguages) {
      final table = translations[lang.code];
      expect(table, isNotNull, reason: 'missing language ${lang.code}');
      expect(keys.difference(table!.keys.toSet()), isEmpty, reason: 'missing keys in ${lang.code}');
    }
  });

  test('system locales resolve to the right language', () {
    expect(resolveAppLocale(const [Locale('pl'), Locale('ja')]), const Locale('ja'));
    expect(resolveAppLocale(const [Locale('zh', 'TW')]),
        const Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hant'));
    expect(resolveAppLocale(const [Locale('pl')]), const Locale('en'));
  });

  test('tr switches language and fills placeholders', () {
    applyLocale(const Locale('fr'));
    final fr = tr('common.retry');
    applyLocale(const Locale('en'));
    expect(tr('common.retry'), 'Retry');
    expect(fr, isNot('Retry'));
  });
}
