// apps/desktop/lib/main.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:localroll_core/localroll_core.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path_provider/path_provider.dart';
import 'package:window_manager/window_manager.dart';

import 'app_services.dart';
import 'l10n/l10n.dart';
import 'services/autostart.dart';
import 'services/face_engine.dart';
import 'services/open_with.dart';
import 'services/settings.dart';
import 'services/watchdog.dart';
import 'ui/app_nav.dart';
import 'ui/home_shell.dart';
import 'ui/player/player_home.dart';
import 'ui/player/player_page.dart';
import 'ui/theme.dart';
import 'ui/title_bar.dart';

Future<void> main(List<String> args) async {
  // Build check (CI): the bundled face models load and answer here, the
  // way the app runs them; the result goes to the file given, then exit.
  if (args.length == 2 && args.first == '--check-models') {
    exit(await checkModels(args[1]));
  }
  WidgetsFlutterBinding.ensureInitialized();
  // Photos / videos handed over by Explorer ("Open with").
  final files = existingFiles(args);
  if (!await AppSettings.acquireInstanceLock()) {
    // Already running: bring that window to the front (with the files) and
    // quit quietly. Only if it can't be reached, say so in a small window.
    if (files.isNotEmpty ? await _openInRunningCopy(files) : await _activateRunningCopy()) exit(0);
    runApp(const _AlreadyRunningApp());
    return;
  }
  await _startLog();
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
      // Started with Windows: stay out of the way, just receive.
      if (args.contains(AutoStart.minimizedFlag)) {
        await windowManager.minimize();
      } else {
        await windowManager.focus();
      }
    },
  );
  await windowManager.setPreventClose(true);
  final services = await AppServices.create();
  services.server.onShowRequested = _bringToFront;
  services.server.onOpenRequested = (paths) {
    unawaited(_bringToFront());
    PlayerLauncher.request(services, existingFiles(paths));
  };
  unawaited(OpenWith.register());
  runApp(LocalRollApp(services: services));
  if (files.isNotEmpty) PlayerLauncher.request(services, files);
}

/// Diagnostics log (stays on this PC; exported from Settings on purpose):
/// app messages and errors, never photo contents.
Future<void> _startLog() async {
  try {
    final dir = await getApplicationSupportDirectory();
    await DiagLog.init(Directory('${dir.path}${Platform.pathSeparator}logs'),
        about: 'LocalRoll $lrVersion · ${Platform.operatingSystemVersion} · ${Platform.localeName}');
    await Watchdog.start();
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
  // "Not responding": the app's own work blocked it for a while (a file
  // dialog open counts too). Logged when it comes back, to find the cause.
  var last = DateTime.now();
  Timer.periodic(const Duration(seconds: 1), (_) {
    final now = DateTime.now();
    final gap = now.difference(last);
    last = now;
    // Hours mean the PC slept (the watchdog tells those apart).
    if (gap > const Duration(seconds: 5) && gap < const Duration(minutes: 30)) {
      DiagLog.log('ui', 'not responding for ${gap.inSeconds} s');
    }
  });
}

Future<void> _bringToFront() async {
  try {
    if (await windowManager.isMinimized()) await windowManager.restore();
    await windowManager.show();
    await windowManager.setAlwaysOnTop(true);
    await windowManager.focus();
    Future<void>.delayed(const Duration(seconds: 1), () => windowManager.setAlwaysOnTop(false));
  } catch (_) {}
}

/// Hands [files] to the copy that is already running (on this PC only).
/// Explorer starts one copy per file when several are opened at once, and
/// the first may still be starting: tried for a few seconds.
Future<bool> _openInRunningCopy(List<String> files) async {
  final body = utf8.encode(jsonEncode({'paths': files}));
  for (var round = 0; round < 16; round++) {
    final saved = await AppSettings.savedPort();
    final ports = {?saved, LrProtocol.defaultPort, ...LrProtocol.fallbackPorts};
    final client = HttpClient()..connectionTimeout = const Duration(milliseconds: 600);
    try {
      for (final port in ports) {
        try {
          final req = await client.post(InternetAddress.loopbackIPv4.address, port, LrProtocol.pathLocalOpen);
          req.headers.contentType = ContentType.json;
          req.add(body);
          final res = await req.close().timeout(const Duration(seconds: 2));
          await res.drain<void>();
          if (res.statusCode == 200) return true;
        } catch (_) {}
      }
    } finally {
      client.close(force: true);
    }
    await Future<void>.delayed(const Duration(milliseconds: 500));
  }
  return false;
}

/// Asks the copy that is already running (on this PC only) to show itself.
Future<bool> _activateRunningCopy() async {
  final saved = await AppSettings.savedPort();
  final ports = {?saved, LrProtocol.defaultPort, ...LrProtocol.fallbackPorts};
  final client = HttpClient()..connectionTimeout = const Duration(milliseconds: 600);
  try {
    for (final port in ports) {
      try {
        final req = await client.post(InternetAddress.loopbackIPv4.address, port, LrProtocol.pathLocalShow);
        final res = await req.close().timeout(const Duration(seconds: 1));
        await res.drain<void>();
        if (res.statusCode == 200) return true;
      } catch (_) {}
    }
    return false;
  } finally {
    client.close(force: true);
  }
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
                  // The player in full screen has the whole screen.
                  ValueListenableBuilder<bool>(
                    valueListenable: AppNav.instance.fullscreen,
                    builder: (context, full, _) => full ? const SizedBox.shrink() : LrTitleBar(services: services),
                  ),
                  Expanded(child: PlayerDropTarget(services: services, child: child!)),
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

/// Loads the face models next to LocalRoll.exe and reads a plain picture;
/// writes "face models: ok …" or why not to [out]. 0 when it worked.
Future<int> checkModels(String out) async {
  final f = File(out);
  try {
    final engine = FaceEngine();
    if (!engine.available) {
      f.writeAsStringSync('face models: missing in ${engine.folder}\n');
      return 2;
    }
    final rgb = Uint8List(320 * 240 * 3)..fillRange(0, 320 * 240 * 3, 128);
    final faces = await engine.read(rgb, 320, 240);
    engine.close();
    f.writeAsStringSync(faces == null ? 'face models: no answer: ${engine.lastError}\n' : 'face models: ok, ${faces.length} faces\n');
    return faces == null ? 1 : 0;
  } catch (e) {
    f.writeAsStringSync('face models: failed: $e\n');
    return 1;
  }
}
