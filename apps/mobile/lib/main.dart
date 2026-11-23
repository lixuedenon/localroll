// apps/mobile/lib/main.dart
import 'dart:io';
import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/foundation.dart' show LicenseEntryWithLineBreaks, LicenseRegistry;
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:localroll_core/localroll_core.dart';
import 'package:path_provider/path_provider.dart';

import 'l10n/l10n.dart';
import 'services/clip_maker.dart';
import 'services/discovery.dart';
import 'services/media_saver.dart';
import 'services/mobile_settings.dart';
import 'services/my_library.dart';
import 'ui/home_look.dart';
import 'ui/home_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await _startLog();
  MyLibrary.rootDir = MediaSaver.filesFolder;
  final settings = await MobileSettings.load();
  // Discovery starts after the photo permission prompt (see HomePage).
  final discovery = DesktopDiscovery();
  ClipEnv.settings = settings;
  ClipEnv.discovery = discovery;
  if (Platform.isAndroid) {
    // Android edits PDFs with pdfium (bundled libpdfium.so).
    LicenseRegistry.addLicense(() => Stream.value(const LicenseEntryWithLineBreaks(['pdfium'], _pdfiumLicense)));
  }
  runApp(LocalRollMobileApp(settings: settings, discovery: discovery));
}

/// Diagnostics log (stays on this phone; exported from Settings on
/// purpose): app messages and errors, never photo contents.
Future<void> _startLog() async {
  try {
    final dir = await getApplicationSupportDirectory();
    await DiagLog.init(Directory('${dir.path}/logs'),
        about: 'LocalRoll $lrVersion · ${Platform.operatingSystem} ${Platform.operatingSystemVersion} · ${Platform.localeName}');
  } catch (_) {}
  final prior = debugPrint;
  debugPrint = (String? message, {int? wrapWidth}) {
    if (message != null) DiagLog.log('app', message);
    prior(message, wrapWidth: wrapWidth);
  };
  final flutterError = FlutterError.onError;
  FlutterError.onError = (d) {
    DiagLog.error('ui', d.exception, d.stack);
    flutterError?.call(d);
  };
  PlatformDispatcher.instance.onError = (e, st) {
    DiagLog.error('uncaught', e, st);
    return false;
  };
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
          title: appName,
          debugShowCheckedModeBanner: false,
          theme: buildLightTheme(),
          themeMode: ThemeMode.light,
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

/// pdfium (Android build by bblanchon/pdfium-binaries): BSD-3-Clause and
/// Apache-2.0 (its parts).
const String _pdfiumLicense = '''PDFium — Copyright 2014 The PDFium Authors.
Redistribution and use in source and binary forms, with or without modification, are permitted provided that the following conditions are met:
1. Redistributions of source code must retain the above copyright notice, this list of conditions and the following disclaimer.
2. Redistributions in binary form must reproduce the above copyright notice, this list of conditions and the following disclaimer in the documentation and/or other materials provided with the distribution.
3. Neither the name of Google Inc. nor the names of its contributors may be used to endorse or promote products derived from this software without specific prior written permission.
THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
Parts of PDFium are under the Apache License 2.0 (https://www.apache.org/licenses/LICENSE-2.0).''';
