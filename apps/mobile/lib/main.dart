// apps/mobile/lib/main.dart
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'l10n/l10n.dart';
import 'services/discovery.dart';
import 'services/mobile_settings.dart';
import 'ui/home_page.dart';
import 'ui/theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final settings = await MobileSettings.load();
  // Discovery starts after the photo permission prompt (see HomePage).
  final discovery = DesktopDiscovery();
  runApp(LocalRollMobileApp(settings: settings, discovery: discovery));
}

class LocalRollMobileApp extends StatelessWidget {
  const LocalRollMobileApp({super.key, required this.settings, required this.discovery});

  final MobileSettings settings;
  final DesktopDiscovery discovery;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: settings,
      builder: (context, _) {
        final lang = settings.language;
        return MaterialApp(
          title: 'LocalRoll',
          debugShowCheckedModeBanner: false,
          theme: buildLrTheme(),
          themeMode: ThemeMode.dark,
          // null = follow the phone's language.
          locale: lang == null ? null : localeForLanguage(lang),
          supportedLocales: appSupportedLocales,
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
          localeListResolutionCallback: (preferred, _) => resolveAppLocale(preferred),
          builder: (context, child) {
            applyLocale(Localizations.localeOf(context));
            // Rebuild every page when the language changes.
            return KeyedSubtree(key: ValueKey(translator.language), child: child!);
          },
          home: HomePage(settings: settings, discovery: discovery),
        );
      },
    );
  }
}
