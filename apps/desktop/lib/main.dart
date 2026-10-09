// apps/desktop/lib/main.dart
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:media_kit/media_kit.dart';
import 'package:window_manager/window_manager.dart';

import 'app_services.dart';
import 'l10n/l10n.dart';
import 'services/settings.dart';
import 'ui/app_nav.dart';
import 'ui/home_shell.dart';
import 'ui/theme.dart';
import 'ui/title_bar.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (!await AppSettings.acquireInstanceLock()) {
    runApp(const _AlreadyRunningApp());
    return;
  }
  MediaKit.ensureInitialized();
  // Our own title bar replaces the native one; closing asks first.
  await windowManager.ensureInitialized();
  await windowManager.waitUntilReadyToShow(
    const WindowOptions(
      title: 'LocalRoll',
      minimumSize: Size(960, 620),
      titleBarStyle: TitleBarStyle.hidden,
      backgroundColor: LrColors.ink,
    ),
    () async {
      await windowManager.show();
      await windowManager.focus();
    },
  );
  await windowManager.setPreventClose(true);
  final services = await AppServices.create();
  runApp(LocalRollApp(services: services));
}

class LocalRollApp extends StatelessWidget {
  const LocalRollApp({super.key, required this.services});

  final AppServices services;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: services.settings,
      builder: (context, _) {
        final lang = services.settings.language;
        return MaterialApp(
          title: 'LocalRoll',
          debugShowCheckedModeBanner: false,
          theme: buildLrTheme(),
          themeMode: ThemeMode.dark,
          navigatorKey: AppNav.instance.navigatorKey,
          navigatorObservers: [AppNav.instance.observer],
          // null = follow Windows display language.
          locale: lang == null ? null : localeForLanguage(lang),
          supportedLocales: appSupportedLocales,
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
          localeListResolutionCallback: (preferred, _) => resolveAppLocale(preferred),
          builder: (context, child) {
            applyLocale(Localizations.localeOf(context));
            // Rebuild every page when the language changes.
            return KeyedSubtree(
              key: ValueKey(translator.language),
              child: Column(
                children: [
                  LrTitleBar(services: services),
                  Expanded(child: child!),
                ],
              ),
            );
          },
          home: HomeShell(services: services),
        );
      },
    );
  }
}

/// Shown when another LocalRoll window is already open.
class _AlreadyRunningApp extends StatelessWidget {
  const _AlreadyRunningApp();

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'LocalRoll',
      debugShowCheckedModeBanner: false,
      theme: buildLrTheme(),
      supportedLocales: appSupportedLocales,
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      localeListResolutionCallback: (preferred, _) => resolveAppLocale(preferred),
      builder: (context, child) {
        applyLocale(Localizations.localeOf(context));
        return child!;
      },
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Text(tr('app.already_running'), textAlign: TextAlign.center, style: const TextStyle(fontSize: 16)),
            ),
          ),
        ),
      ),
    );
  }
}
