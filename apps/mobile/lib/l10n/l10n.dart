// apps/mobile/lib/l10n/l10n.dart
import 'package:flutter/widgets.dart';
import 'package:intl/intl.dart';
import 'package:localroll_core/localroll_core.dart';

import 'translations.g.dart';

/// App-wide translator. The language is set from the resolved locale in
/// MaterialApp.builder (see main.dart), so services can call [tr] too.
final Translator translator = Translator(translations);

/// Translated text for [key]; `{name}` placeholders are filled from [args].
String tr(String key, [Map<String, Object?> args = const {}]) => translator.tr(key, args);

Locale localeForLanguage(String code) => code == 'zh_Hant'
    ? const Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hant')
    : Locale(code);

final List<Locale> appSupportedLocales = [
  for (final l in supportedLanguages) localeForLanguage(l.code),
];

/// Picks the first of the user's preferred system locales we support.
Locale resolveAppLocale(List<Locale>? preferred) {
  for (final l in preferred ?? const <Locale>[]) {
    final code = matchLanguage(l.languageCode, scriptCode: l.scriptCode, countryCode: l.countryCode);
    if (code != null) return localeForLanguage(code);
  }
  return localeForLanguage(fallbackLanguage);
}

/// Called with the locale MaterialApp actually uses.
void applyLocale(Locale locale) {
  translator.language =
      matchLanguage(locale.languageCode, scriptCode: locale.scriptCode, countryCode: locale.countryCode) ??
          fallbackLanguage;
}

/// "October 2026" / "2026年10月" / "octobre 2026"…
String formatMonthYear(DateTime t) {
  final tag = translator.language == 'zh_Hant' ? 'zh_TW' : translator.language;
  try {
    return DateFormat.yMMMM(tag).format(t);
  } catch (_) {
    return '${t.year}-${t.month.toString().padLeft(2, '0')}';
  }
}
