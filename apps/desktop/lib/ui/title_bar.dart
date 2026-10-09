// apps/desktop/lib/ui/title_bar.dart
import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import '../app_services.dart';
import '../l10n/l10n.dart';
import '../services/receive_hub.dart';
import 'app_nav.dart';
import 'theme.dart';

/// Our own title bar (the native one is hidden): Back, app name, drag area,
/// minimise / maximise / close. Close asks first, so a stray click on the
/// little × never cuts off a transfer.
class LrTitleBar extends StatefulWidget {
  const LrTitleBar({super.key, required this.services});

  final AppServices services;

  @override
  State<LrTitleBar> createState() => _LrTitleBarState();
}

class _LrTitleBarState extends State<LrTitleBar> with WindowListener {
  bool _maximized = false;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    windowManager.isMaximized().then((v) {
      if (mounted) setState(() => _maximized = v);
    });
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    super.dispose();
  }

  @override
  void onWindowMaximize() => setState(() => _maximized = true);

  @override
  void onWindowUnmaximize() => setState(() => _maximized = false);

  /// The system close (Alt+F4, taskbar "Close window") lands here too.
  @override
  void onWindowClose() => confirmExit(widget.services);

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 44,
      decoration: const BoxDecoration(
        color: LrColors.ink,
        // The safelight: a thin amber glow along the top edge of the window.
        border: Border(top: BorderSide(color: LrColors.safelight, width: 2)),
        boxShadow: [BoxShadow(color: Color(0x33FFB547), blurRadius: 18, offset: Offset(0, -6))],
      ),
      child: Row(
        children: [
          const SizedBox(width: 6),
          ListenableBuilder(
            listenable: AppNav.instance,
            builder: (context, _) => _BarButton(
              tooltip: tr('app.back'),
              icon: Icons.arrow_back_rounded,
              label: tr('app.back'),
              onPressed: AppNav.instance.canGoBack ? AppNav.instance.back : null,
            ),
          ),
          const SizedBox(width: 8),
          const _Mark(),
          const SizedBox(width: 10),
          Text('LocalRoll', style: Theme.of(context).textTheme.titleMedium?.copyWith(letterSpacing: 0.2)),
          const Expanded(child: DragToMoveArea(child: SizedBox.expand())),
          _BarButton(tooltip: tr('app.minimize'), icon: Icons.remove_rounded, onPressed: windowManager.minimize),
          _BarButton(
            tooltip: tr(_maximized ? 'app.restore' : 'app.maximize'),
            icon: _maximized ? Icons.filter_none_rounded : Icons.crop_square_rounded,
            iconSize: _maximized ? 15 : 18,
            onPressed: () => _maximized ? windowManager.unmaximize() : windowManager.maximize(),
          ),
          _BarButton(
            tooltip: tr('app.close'),
            icon: Icons.close_rounded,
            danger: true,
            onPressed: () => confirmExit(widget.services),
          ),
        ],
      ),
    );
  }
}

/// Aperture-like mark: an amber ring with a cyan core.
class _Mark extends StatelessWidget {
  const _Mark();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 22,
      height: 22,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: LrColors.safelight, width: 2.5),
        boxShadow: const [BoxShadow(color: Color(0x55FFB547), blurRadius: 10)],
      ),
      alignment: Alignment.center,
      child: Container(
        width: 7,
        height: 7,
        decoration: const BoxDecoration(shape: BoxShape.circle, color: LrColors.verified),
      ),
    );
  }
}

class _BarButton extends StatefulWidget {
  const _BarButton({
    required this.tooltip,
    required this.icon,
    required this.onPressed,
    this.danger = false,
    this.iconSize = 18,
    this.label,
  });

  /// Shown next to the icon (used for Back, so it reads as a real button).
  final String? label;

  final String tooltip;
  final IconData icon;
  final VoidCallback? onPressed;
  final bool danger;
  final double iconSize;

  @override
  State<_BarButton> createState() => _BarButtonState();
}

class _BarButtonState extends State<_BarButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onPressed != null;
    final bg = !_hover || !enabled
        ? Colors.transparent
        : widget.danger
            ? LrColors.danger
            : LrColors.raised;
    final fg = !enabled
        ? LrColors.line
        : (_hover && widget.danger)
            ? Colors.white
            : LrColors.text;
    // No Tooltip here: the title bar lives above the Navigator's Overlay.
    return Semantics(
      button: true,
      label: widget.tooltip,
      child: MouseRegion(
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: widget.onPressed,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            constraints: const BoxConstraints(minWidth: 46),
            height: widget.label == null ? 44 : 32,
            padding: widget.label == null ? null : const EdgeInsets.symmetric(horizontal: 10),
            decoration: BoxDecoration(
              color: bg,
              borderRadius: widget.label == null ? null : BorderRadius.circular(8),
            ),
            alignment: Alignment.center,
            child: widget.label == null
                ? Icon(widget.icon, size: widget.iconSize, color: fg)
                : Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(widget.icon, size: widget.iconSize, color: fg),
                      const SizedBox(width: 6),
                      Text(widget.label!, style: TextStyle(color: fg, fontSize: 13)),
                    ],
                  ),
          ),
        ),
      ),
    );
  }
}

bool _asking = false;

/// Asks before quitting; warns when phones are still sending.
Future<void> confirmExit(AppServices services) async {
  final ctx = AppNav.instance.navigatorKey.currentContext;
  if (ctx == null || _asking) return;
  _asking = true;
  final busy = services.hub.transfers
      .where((t) => t.state == TransferState.receiving || t.state == TransferState.verifying)
      .length;
  final ok = await showDialog<bool>(
    context: ctx,
    builder: (context) => AlertDialog(
      icon: Icon(busy > 0 ? Icons.sync_problem_rounded : Icons.power_settings_new_rounded,
          color: busy > 0 ? LrColors.safelight : LrColors.muted, size: 32),
      title: Text(tr('exit.title')),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 380),
        child: Text(busy > 0 ? tr('exit.body_busy', {'count': busy}) : tr('exit.body')),
      ),
      actions: [
        OutlinedButton(onPressed: () => Navigator.of(context).pop(false), child: Text(tr('exit.stay'))),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: busy > 0 ? LrColors.danger : LrColors.safelight,
            foregroundColor: busy > 0 ? Colors.white : const Color(0xFF2B1A00),
          ),
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(tr('exit.quit')),
        ),
      ],
    ),
  );
  _asking = false;
  if (ok == true) {
    await services.shutdown();
    await windowManager.destroy();
  }
}
