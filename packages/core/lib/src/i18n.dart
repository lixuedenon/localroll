// packages/core/lib/src/i18n.dart

import 'languages.g.dart';

/// A UI language LocalRoll ships translations for.
class LrLanguage {
  const LrLanguage(this.code, this.nativeName, {this.rtl = false});

  /// Translation table key: ISO 639-1, plus `zh_Hant` for Traditional Chinese.
  final String code;

  /// Name shown in the language picker, in the language itself.
  final String nativeName;

  /// Written right to left (Arabic).
  final bool rtl;
}

/// Supported UI languages, in picker order. The list is data, not code:
/// packages/core/l10n/languages.json (run `python scripts/gen_l10n.py`
/// after editing). English is the fallback for missing keys.
const List<LrLanguage> supportedLanguages = generatedLanguages;

const String fallbackLanguage = 'en';

/// Maps a platform locale to one of [supportedLanguages], or null if unsupported.
///
/// Chinese needs special care: zh-TW / zh-HK / zh-MO and zh-Hant-* are
/// Traditional; everything else (zh-CN, zh-SG, zh-Hans, plain zh) is Simplified.
String? matchLanguage(String languageCode, {String? scriptCode, String? countryCode}) {
  final lang = languageCode.toLowerCase();
  if (lang == 'zh') {
    final script = scriptCode?.toLowerCase();
    final country = countryCode?.toUpperCase();
    if (script == 'hant' || (script == null && const {'TW', 'HK', 'MO'}.contains(country))) {
      return 'zh_Hant';
    }
    return 'zh';
  }
  // Older platforms report Indonesian as 'in'.
  final normalized = lang == 'in' ? 'id' : lang;
  for (final l in supportedLanguages) {
    if (l.code == normalized) return l.code;
  }
  return null;
}

/// Looks up translated strings with `{name}` placeholders.
class Translator {
  Translator(this.tables);

  /// language code -> key -> text
  final Map<String, Map<String, String>> tables;
  String language = fallbackLanguage;

  bool get isRtl => supportedLanguages.any((l) => l.code == language && l.rtl);

  bool has(String key) => tables[fallbackLanguage]?.containsKey(key) ?? false;

  String tr(String key, [Map<String, Object?> args = const {}]) {
    var text = tables[language]?[key] ?? tables[fallbackLanguage]?[key] ?? key;
    if (args.isNotEmpty) {
      args.forEach((name, value) => text = text.replaceAll('{$name}', '$value'));
    }
    return text;
  }
}
