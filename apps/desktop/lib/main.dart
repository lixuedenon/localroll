// apps/desktop/lib/main.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/foundation.dart' show LicenseEntryWithLineBreaks, LicenseRegistry;
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:localroll_core/localroll_core.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path_provider/path_provider.dart';
import 'package:window_manager/window_manager.dart';

import 'app_services.dart';
import 'l10n/l10n.dart';
import 'services/autostart.dart';
import 'services/boot.dart';
import 'services/face_engine.dart';
import 'services/open_with.dart';
import 'services/settings.dart';
import 'services/single_instance.dart';
import 'services/watchdog.dart';
import 'ui/app_nav.dart';
import 'ui/boot_screen.dart';
import 'ui/home_shell.dart';
import 'ui/player/player_home.dart';
import 'ui/player/player_page.dart';
import 'ui/screen/float_panel.dart';
import 'ui/screen/screen_record.dart';
import 'services/run_flag.dart';
import 'ui/media_thumb.dart';
import 'ui/send_paths.dart';
import 'ui/theme.dart';
import 'ui/title_bar.dart';
import 'ui/transfer_float.dart';
import 'services/window_memory.dart';

Future<void> main(List<String> args) async {
  // Build check (CI): the bundled face models load and answer here, the
  // way the app runs them; the result goes to the file given, then exit.
  if (args.length == 2 && args.first == '--check-models') {
    exit(await checkModels(args[1]));
  }
  // The screen pen's floating panel: a second, small copy of LocalRoll
  // that only shows the pen's tools (LocalRoll started it).
  if (args.contains(panelFlag)) return runPenPanel(args);
  WidgetsFlutterBinding.ensureInitialized();
  _addLicenses();
  // Photos / videos handed over by Explorer ("Open with").
  final files = existingFiles(args);
  // Explorer's "Send to → Keepnear": files and folders, to send.
  final sending = args.contains(OpenWith.sendFlag);
  final toSend = [
    for (final p in args)
      if (!p.startsWith('--') && FileSystemEntity.typeSync(p) != FileSystemEntityType.notFound) p,
  ];
  // Only ever one LocalRoll, decided before anything shows: a copy already
  // running (it answers on this PC) gets the files and comes to the front;
  // this one quits at once. Checked three ways: it answers, the Windows
  // mutex, the lock file.
  if (sending ? await _openInRunningCopy(toSend, rounds: 1, send: true) : await _handOver(files, rounds: 1)) exit(0);
  if (!SingleInstance.claim() || !await AppSettings.acquireInstanceLock()) {
    // It may still be starting (Explorer opens one copy per file): keep trying
    // a few seconds. Only if it can't be reached, say so in a small window.
    if (sending ? await _openInRunningCopy(toSend, send: true) : await _handOver(files, rounds: 16)) exit(0);
    runApp(const _AlreadyRunningApp());
    return;
  }
  Boot.mark('one copy');
  await _startLog();
  await RunFlag.start();
  Boot.logReady();
  Boot.mark('log');
  MediaKit.ensureInitialized();
  // Our own title bar replaces the native one; closing asks first.
  await windowManager.ensureInitialized();
  await windowManager.waitUntilReadyToShow(
    const WindowOptions(
      title: appName,
      minimumSize: Size(960, 620),
      titleBarStyle: TitleBarStyle.hidden,
      backgroundColor: LrColors.ink,
    ),
    () async {
      // As it was left (the first time: maximized).
      final max = await WindowMemory.apply();
      await windowManager.show();
      if (max) await windowManager.maximize();
      unawaited(Future<void>.delayed(const Duration(seconds: 1), WindowMemory.report));
      // Started with Windows: stay out of the way, just receive.
      if (args.contains(AutoStart.minimizedFlag)) {
        await windowManager.minimize();
      } else {
        await windowManager.focus();
      }
    },
  );
  await windowManager.setPreventClose(true);
  Boot.mark('window');
  // Something to look at at once, while the rest gets ready.
  runApp(const BootApp());
  final services = await AppServices.create();
  MediaThumb.hoverPreview = services.settings.hoverPreview;
  services.server.onShowRequested = _bringToFront;
  services.server.onOpenRequested = (paths) {
    unawaited(_bringToFront());
    PlayerLauncher.request(services, existingFiles(paths));
  };
  // After the first screens: written in the language LocalRoll shows.
  unawaited(Future<void>.delayed(const Duration(seconds: 5), OpenWith.register));
  unawaited(Future<void>.delayed(const Duration(seconds: 8), OpenWith.registerSendTo));
  services.server.onSendRequested = (paths) {
    unawaited(_bringToFront());
    sendFromExplorer(services, paths);
  };
  if (sending && toSend.isNotEmpty) {
    WidgetsBinding.instance.addPostFrameCallback((_) => sendFromExplorer(services, toSend));
  }
  runApp(LocalRollApp(services: services));
  WidgetsBinding.instance.addPostFrameCallback((_) => Boot.mark('first screen'));
  // Ctrl+Shift+R / P / D for recording the screen, from anywhere.
  ScreenRecorder.instance.watchKeys(services);
  if (files.isNotEmpty && !sending) PlayerLauncher.request(services, files);
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

/// Hands [files] (none: just "come to the front") to the copy already
/// running (on this PC only); [rounds] tries, half a second apart.
Future<bool> _handOver(List<String> files, {required int rounds}) =>
    files.isNotEmpty ? _openInRunningCopy(files, rounds: rounds) : _activateRunningCopy(rounds: rounds);

/// Hands [files] to the copy that is already running (on this PC only).
/// Explorer starts one copy per file when several are opened at once, and
/// the first may still be starting: tried for a few seconds.
Future<bool> _openInRunningCopy(List<String> files, {int rounds = 16, bool send = false}) async {
  final body = utf8.encode(jsonEncode({'paths': files, if (send) 'send': true}));
  for (var round = 0; round < rounds; round++) {
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
    if (round + 1 < rounds) await Future<void>.delayed(const Duration(milliseconds: 500));
  }
  return false;
}

/// Asks the copy that is already running (on this PC only) to show itself.
Future<bool> _activateRunningCopy({int rounds = 1}) async {
  for (var round = 0; round < rounds; round++) {
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
    } finally {
      client.close(force: true);
    }
    if (round + 1 < rounds) await Future<void>.delayed(const Duration(milliseconds: 500));
  }
  return false;
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
          title: appName,
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
                  Expanded(
                    child: Stack(fit: StackFit.expand, children: [
                      Positioned.fill(child: PlayerDropTarget(services: services, child: child!)),
                      // Sending / receiving: how far, on top of any page.
                      TransferFloat(services: services),
                    ]),
                  ),
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
      title: appName,
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

/// Parts that ship with the app but aren't Dart packages (those list
/// themselves): shown on the licenses page too.
void _addLicenses() {
  LicenseRegistry.addLicense(() async* {
    yield const LicenseEntryWithLineBreaks(['Material Symbols'], '''Material Symbols, Copyright Google LLC.
Licensed under the Apache License, Version 2.0 (the "License"); you may not use these files except in compliance with the License. You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software distributed under the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the License for the specific language governing permissions and limitations under the License.

Used here: the icon shapes of some stamps, turned into outlines.''');
    yield const LicenseEntryWithLineBreaks(['FFmpeg'], '''FFmpeg is free software licensed under the GNU Lesser General Public License (LGPL) version 2.1 or later. This app ships an unmodified LGPL build of FFmpeg as a separate program (ffmpeg.exe), from https://github.com/BtbN/FFmpeg-Builds. Its source code is available at https://ffmpeg.org/download.html. You may replace the bundled ffmpeg.exe with your own build.''');
    yield const LicenseEntryWithLineBreaks(['libmpv'], '''mpv / libmpv is licensed under the GNU Lesser General Public License (LGPL) version 2.1 or later. This app uses it as an unmodified shared library (bundled by media_kit); its source code is available at https://github.com/mpv-player/mpv. You may replace the bundled library with your own build.''');
  });
}
