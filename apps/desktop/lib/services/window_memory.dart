// apps/desktop/lib/services/window_memory.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:localroll_core/localroll_core.dart';
import 'package:path_provider/path_provider.dart';
import 'package:window_manager/window_manager.dart';

import '../ui/app_nav.dart';

/// The window opens the way it was left: maximized, or at its last size
/// (centred, so it is never off a screen that is gone). The very first
/// time it opens maximized, so every tool along the top is in view.
class WindowMemory with WindowListener {
  WindowMemory._(this._file);

  final File _file;
  Timer? _save;
  DateTime _quietUntil = DateTime(2000);

  static WindowMemory? _instance;

  /// Before the window is shown.
  static Future<void> apply() async {
    try {
      final dir = await getApplicationSupportDirectory();
      final m = WindowMemory._(File('${dir.path}${Platform.pathSeparator}window.json'));
      _instance = m;
      Map<String, dynamic>? j;
      if (await m._file.exists()) {
        try {
          j = jsonDecode(await m._file.readAsString()) as Map<String, dynamic>;
        } catch (_) {}
      }
      if (j == null || j['max'] == true) {
        await windowManager.maximize();
      } else {
        final w = (j['w'] as num?)?.toDouble() ?? 1280, h = (j['h'] as num?)?.toDouble() ?? 760;
        await windowManager.setSize(Size(w < 960 ? 960 : w, h < 620 ? 620 : h));
        await windowManager.center();
      }
      windowManager.addListener(m);
      // Back from recording / snipping: the window is put back where it
      // was, which is not a new size to keep.
      AppNav.instance.fullscreen.addListener(() => m._quietUntil = DateTime.now().add(const Duration(seconds: 3)));
    } catch (e) {
      DiagLog.log('ui', 'window size not restored: $e');
    }
  }

  void _later() {
    _save?.cancel();
    _save = Timer(const Duration(seconds: 1), () => unawaited(_write()));
  }

  Future<void> _write() async {
    try {
      // Recording / snipping spreads the window over a screen: not a size to keep.
      if (AppNav.instance.fullscreen.value || DateTime.now().isBefore(_quietUntil)) return;
      final max = await windowManager.isMaximized();
      if (await windowManager.isMinimized()) return;
      final size = await windowManager.getSize();
      await _file.writeAsString(jsonEncode({'max': max, if (!max) 'w': size.width, if (!max) 'h': size.height}));
    } catch (_) {}
  }

  @override
  void onWindowMaximize() => _later();

  @override
  void onWindowUnmaximize() => _later();

  @override
  void onWindowResized() => _later();

  /// Keeps the instance reachable (listeners hold it too).
  static WindowMemory? get current => _instance;
}
