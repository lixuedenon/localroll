// apps/desktop/lib/ui/boot_screen.dart
import 'dart:async';
import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/material.dart';
import 'package:localroll_core/localroll_core.dart' show appName;
import 'package:window_manager/window_manager.dart';

import '../l10n/l10n.dart';
import '../services/boot.dart';
import 'theme.dart';

/// Shown at once while LocalRoll gets ready: its mark, what it is doing
/// now, and one thing it can do (changing every few seconds).
class BootApp extends StatelessWidget {
  const BootApp({super.key});

  @override
  Widget build(BuildContext context) {
    // The person's language (their own choice is read a moment later).
    applyLocale(resolveAppLocale(PlatformDispatcher.instance.locales));
    return MaterialApp(
      title: appName,
      debugShowCheckedModeBanner: false,
      theme: buildLrTheme(),
      themeMode: ThemeMode.dark,
      home: const _BootPage(),
    );
  }
}

class _BootPage extends StatefulWidget {
  const _BootPage();

  @override
  State<_BootPage> createState() => _BootPageState();
}

class _BootPageState extends State<_BootPage> {
  static const int _tips = 8;
  int _tip = DateTime.now().second % _tips;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(milliseconds: 3500), (_) {
      if (mounted) setState(() => _tip = (_tip + 1) % _tips);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: LrColors.ink,
        body: Column(children: [
          // The window can be moved while it starts.
          const SizedBox(height: 40, child: DragToMoveArea(child: SizedBox.expand())),
          Expanded(
            child: Center(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Container(
                  width: 64,
                  height: 64,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(color: LrColors.safelight, width: 6),
                    boxShadow: const [BoxShadow(color: Color(0x55FFB547), blurRadius: 28)],
                  ),
                  alignment: Alignment.center,
                  child: Container(width: 20, height: 20, decoration: const BoxDecoration(shape: BoxShape.circle, color: LrColors.verified)),
                ),
                const SizedBox(height: 18),
                Text(appName, style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700)),
                const SizedBox(height: 22),
                const SizedBox(width: 220, child: LinearProgressIndicator()),
                const SizedBox(height: 10),
                ValueListenableBuilder<String>(
                  valueListenable: Boot.step,
                  builder: (context, step, _) => Text(
                    tr('boot.$step'),
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: LrColors.muted, fontSize: 13),
                  ),
                ),
                const SizedBox(height: 40),
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 400),
                  child: SizedBox(
                    key: ValueKey(_tip),
                    width: 460,
                    child: Text(
                      tr('boot.tip${_tip + 1}'),
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: LrColors.text, fontSize: 14, height: 1.5),
                    ),
                  ),
                ),
              ]),
            ),
          ),
        ]),
      );
}
