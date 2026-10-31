// apps/desktop/lib/ui/screen/pen_bar.dart
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:localroll_core/localroll_core.dart' show DiagLog;
import 'package:window_manager/window_manager.dart';

import '../../app_services.dart';
import '../../l10n/l10n.dart';
import '../../services/pen_overlay.dart';
import '../../services/win_screen.dart';
import '../app_nav.dart';
import '../player/ink_editor.dart';
import '../theme.dart';
import 'screen_record.dart';

/// The screen pen's tools (LocalRoll's window, kept out of recordings):
/// the mouse button lets the mouse through to the apps; any drawing tool
/// draws. Undo / redo, pages, board, light around the mouse, options.
class PenToolbar extends StatefulWidget {
  const PenToolbar({super.key, this.extra = const []});

  /// More buttons at the end (end the pen…).
  final List<Widget> extra;

  @override
  State<PenToolbar> createState() => _PenToolbarState();
}

class _PenToolbarState extends State<PenToolbar> {
  final TextEditingController _words = TextEditingController();
  final FocusNode _wordsFocus = FocusNode();

  PenOverlay get o => PenOverlay.instance;

  @override
  void dispose() {
    _words.dispose();
    _wordsFocus.dispose();
    super.dispose();
  }

  Widget _btn(IconData icon, String tip, VoidCallback? onTap, {bool on = false}) => IconButton(
        tooltip: tip,
        onPressed: onTap,
        style: IconButton.styleFrom(backgroundColor: on ? LrColors.safelight.withValues(alpha: 0.25) : null),
        icon: Icon(icon, size: 20, color: onTap == null ? Colors.white38 : (on ? LrColors.safelight : Colors.white)),
      );

  Widget _typing() {
    if (!_wordsFocus.hasFocus) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _wordsFocus.requestFocus();
      });
    }
    return Row(mainAxisSize: MainAxisSize.min, children: [
      const Icon(Icons.text_fields_rounded, color: Colors.white, size: 20),
      const SizedBox(width: 8),
      SizedBox(
        width: 360,
        child: TextField(
          controller: _words,
          focusNode: _wordsFocus,
          style: const TextStyle(color: Colors.white),
          decoration: InputDecoration(isDense: true, hintText: tr('ink.type_here'), hintStyle: const TextStyle(color: Colors.white54)),
          onSubmitted: (v) {
            o.putText(v);
            _words.clear();
          },
        ),
      ),
      const SizedBox(width: 8),
      FilledButton(
        onPressed: () {
          o.putText(_words.text);
          _words.clear();
        },
        child: Text(tr('common.ok')),
      ),
      TextButton(
        onPressed: () {
          o.putText('');
          _words.clear();
        },
        child: Text(tr('common.cancel')),
      ),
    ]);
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: o,
        builder: (context, _) => Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(
            color: const Color(0xF0202020),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: const Color(0x33FFFFFF)),
          ),
          child: o.textAt != null
              ? _typing()
              : Wrap(crossAxisAlignment: WrapCrossAlignment.center, alignment: WrapAlignment.center, children: [
                  const BarGrip(),
                  // On / off: operate the computer, or back to the pen in use.
                  Tooltip(
                    message: tr(o.draw ? 'pen.operate_tip' : 'pen.back_tip', {'key': _keyName(o.toggleKey)}),
                    child: TextButton.icon(
                      style: TextButton.styleFrom(
                        foregroundColor: o.draw ? Colors.white : LrColors.safelight,
                        backgroundColor: o.draw ? null : LrColors.safelight.withValues(alpha: 0.25),
                        visualDensity: VisualDensity.compact,
                      ),
                      onPressed: () => o.setDraw(!o.draw),
                      icon: Icon(o.draw ? Icons.mouse_rounded : Icons.edit_rounded, size: 18),
                      label: Text(tr(o.draw ? 'pen.to_operate' : 'pen.back_draw')),
                    ),
                  ),
                  const SizedBox(width: 4),
                  for (final t in EditTool.values)
                    _btn(InkToolbar.icon(t), InkToolbar.label(t), () => o.setTool(t.name), on: o.draw && o.tool == t.name),
                  PopupMenuButton<Color>(
                    tooltip: tr('ink.color'),
                    onSelected: o.setColor,
                    itemBuilder: (_) => [
                      for (final c in inkColors)
                        PopupMenuItem<Color>(
                          value: c,
                          height: 36,
                          child: Row(children: [
                            Container(width: 22, height: 22, decoration: BoxDecoration(color: c, shape: BoxShape.circle, border: Border.all(color: Colors.white54))),
                            if (c == o.color) ...[const SizedBox(width: 10), const Icon(Icons.check_rounded, size: 18)],
                          ]),
                        ),
                    ],
                    child: Padding(
                      padding: const EdgeInsets.all(8),
                      child: Container(
                        width: 22,
                        height: 22,
                        decoration: BoxDecoration(color: o.color, shape: BoxShape.circle, border: Border.all(color: Colors.white70, width: 2)),
                      ),
                    ),
                  ),
                  for (var l = 0; l < 3; l++)
                    IconButton(
                      tooltip: tr('ink.size_${['small', 'medium', 'large'][l]}'),
                      onPressed: () => o.setLevel(l),
                      icon: Container(
                        width: 6.0 + l * 5,
                        height: 6.0 + l * 5,
                        decoration: BoxDecoration(color: o.level == l ? LrColors.safelight : Colors.white70, shape: BoxShape.circle),
                      ),
                    ),
                  const SizedBox(width: 4),
                  _btn(Icons.undo_rounded, tr('ink.undo'), o.canUndo ? o.undo : null),
                  _btn(Icons.redo_rounded, tr('ink.redo'), o.canRedo ? o.redo : null),
                  if (o.selected) _btn(Icons.delete_outline_rounded, tr('ink.delete'), o.deleteSelected),
                  _btn(Icons.delete_sweep_rounded, tr('pen.clear_page'), o.clearPage),
                  _btn(Icons.note_add_outlined, tr('pen.new_page'), o.newPage),
                  if (o.sheets > 1) ...[
                    _btn(Icons.chevron_left_rounded, tr('pen.prev_page'), o.sheet > 1 ? o.prevPage : null),
                    Text('${o.sheet}/${o.sheets}', style: const TextStyle(color: Colors.white70, fontSize: 12)),
                    _btn(Icons.chevron_right_rounded, tr('pen.next_page'), o.sheet < o.sheets ? o.nextPage : null),
                  ],
                  const SizedBox(width: 4),
                  PopupMenuButton<int>(
                    tooltip: tr('pen.board'),
                    onSelected: o.setBoard,
                    itemBuilder: (_) => [
                      for (var b = 0; b < 3; b++)
                        CheckedPopupMenuItem(value: b, checked: o.board == b, child: Text(tr(['pen.board_none', 'pen.board_white', 'pen.board_black'][b]))),
                    ],
                    icon: Icon(Icons.dashboard_outlined, size: 20, color: o.board == 0 ? Colors.white : LrColors.safelight),
                  ),
                  _btn(Icons.highlight_rounded, tr('pen.highlight'), () => o.setHighlight(!o.highlight), on: o.highlight),
                  PopupMenuButton<String>(
                    tooltip: tr('ink.more'),
                    icon: const Icon(Icons.tune_rounded, size: 20, color: Colors.white),
                    onSelected: (v) {
                      if (v == 'fade') o.setFade(!o.fade);
                      if (v == 'return') o.setAutoReturn(!o.autoReturn);
                      if (v == 'stylus') o.setPenDraws(!o.penDraws);
                      if (v.startsWith('key')) {
                        final vk = int.parse(v.substring(3));
                        o.setToggleKey(vk);
                        PenSession.instance.services?.player.setPenKey(vk);
                      }
                    },
                    itemBuilder: (_) => [
                      CheckedPopupMenuItem(value: 'fade', checked: o.fade, child: Text(tr('screen.fade'))),
                      CheckedPopupMenuItem(value: 'return', checked: o.autoReturn, child: Text(tr('pen.auto_return'))),
                      CheckedPopupMenuItem(value: 'stylus', checked: o.penDraws, child: Text(tr('pen.stylus'))),
                      const PopupMenuDivider(),
                      PopupMenuItem(enabled: false, child: Text(tr('pen.key_title'), style: const TextStyle(fontSize: 12, color: LrColors.muted))),
                      for (final vk in const [0x75, 0x76, 0x77, 0x78, 0x79, 0])
                        CheckedPopupMenuItem(value: 'key$vk', checked: o.toggleKey == vk, child: Text(_keyName(vk))),
                      const PopupMenuDivider(),
                      PopupMenuItem(enabled: false, child: Text(tr('pen.tips_v2'), style: const TextStyle(fontSize: 12, color: LrColors.muted))),
                    ],
                  ),
                  ...widget.extra,
                ]),
        ),
      );
}

/// Drawing on the screen without recording: LocalRoll shrinks to the
/// toolbar at the top (kept out of recordings and screenshots).
class PenSession {
  PenSession._();

  static final PenSession instance = PenSession._();

  bool active = false;
  Rect? _saved;

  /// Set when LocalRoll starts (for saving screenshots).
  AppServices? services;

  /// Where LocalRoll's window was before (a recording started from here
  /// takes it over).
  Rect? get savedWindow => _saved;

  Future<void> toggle() => active ? stop() : start();

  Future<bool> start() async {
    if (active) return true;
    final ctx = AppNav.instance.navigatorKey.currentContext;
    if (!PenOverlay.available) {
      if (ctx != null) ScaffoldMessenger.maybeOf(ctx)?.showSnackBar(SnackBar(content: Text(tr('pen.missing'))));
      return false;
    }
    _saved = WinScreen.ownRect();
    AppNav.instance.fullscreen.value = true;
    await windowManager.setMinimumSize(const Size(200, 40));
    WinScreen.excludeFromCapture(true);
    final o = PenOverlay.instance;
    if (!await o.start()) {
      await _restore();
      return false;
    }
    active = true;
    o.setDraw(true);
    placeBar(tall: false);
    AppNav.instance.navigatorKey.currentState?.push(MaterialPageRoute(settings: const RouteSettings(name: 'pen-bar'), builder: (_) => const _PenBarPage()));
    DiagLog.log('pen', 'drawing on the screen');
    return true;
  }

  Future<void> stop() async {
    if (!active) return;
    active = false;
    await PenOverlay.instance.stop();
    await _restore();
  }

  /// A recording takes over (the marks and the pen stay).
  void handOver() {
    active = false;
    AppNav.instance.navigatorKey.currentState?.popUntil((r) => r.settings.name != 'pen-bar');
  }

  Future<void> _restore() async {
    WinScreen.excludeFromCapture(false);
    final r = _saved;
    if (r != null) WinScreen.place(r, onTop: false);
    _saved = null;
    await windowManager.setMinimumSize(const Size(960, 620));
    AppNav.instance.fullscreen.value = false;
    AppNav.instance.navigatorKey.currentState?.popUntil((r) => r.settings.name != 'pen-bar');
    try {
      await windowManager.focus();
    } catch (_) {}
  }

  /// The toolbar at the top of the screen in use (or where it was moved
  /// to), over the pen's layer.
  static void placeBar({required bool tall}) {
    final screens = WinScreen.screens();
    if (screens.isEmpty) return;
    final c = WinScreen.cursor();
    final scr = screens.firstWhere((s) => s.rect.contains(c), orElse: () => screens.first);
    final k = scr.scale;
    final w = 1180 * k, h = (tall ? 140 : 76) * k;
    WinScreen.place(BarPlace.rect(Rect.fromLTWH(scr.rect.center.dx - w / 2, scr.rect.top + 8 * k, w, h)), onTop: true, activate: false);
  }
}

class _PenBarPage extends StatelessWidget {
  const _PenBarPage();

  @override
  Widget build(BuildContext context) => PopScope(
        canPop: false,
        child: Scaffold(
          backgroundColor: LrColors.ink,
          body: Center(
            child: Material(
              color: Colors.transparent,
              child: Focus(
                autofocus: true,
                onKeyEvent: (_, e) {
                  if (e is KeyDownEvent && e.logicalKey == LogicalKeyboardKey.escape) {
                    unawaited(PenSession.instance.stop());
                    return KeyEventResult.handled;
                  }
                  return KeyEventResult.ignored;
                },
                child: PenToolbar(extra: [
                  const _ShotButton(),
                  const SizedBox(width: 6),
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: FilledButton.icon(
                      style: FilledButton.styleFrom(visualDensity: VisualDensity.compact),
                      onPressed: () => unawaited(PenSession.instance.stop()),
                      icon: const Icon(Icons.close_rounded, size: 18),
                      label: Text(tr('pen.end')),
                    ),
                  ),
                ]),
              ),
            ),
          ),
        ),
      );
}

/// "Save as screenshot" (what is on the screen now, with the marks).
class _ShotButton extends StatefulWidget {
  const _ShotButton();

  @override
  State<_ShotButton> createState() => _ShotButtonState();
}

class _ShotButtonState extends State<_ShotButton> {
  bool _busy = false;
  String? _done;

  Future<void> _take() async {
    final s = PenSession.instance.services;
    if (s == null || _busy) return;
    setState(() => _busy = true);
    final f = await savePenShot(s);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _done = f == null ? tr('ink.shot_failed') : tr('recs.pen_saved');
    });
    Future<void>.delayed(const Duration(seconds: 3), () {
      if (mounted) setState(() => _done = null);
    });
  }

  @override
  Widget build(BuildContext context) => Row(mainAxisSize: MainAxisSize.min, children: [
        IconButton(
          tooltip: tr('recs.pen_shot'),
          onPressed: _busy ? null : () => unawaited(_take()),
          icon: _busy
              ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.add_a_photo_outlined, size: 20, color: Colors.white),
        ),
        if (_done != null) Text(_done!, style: const TextStyle(color: Colors.white70, fontSize: 12)),
      ]);
}

String _keyName(int vk) => vk == 0 ? tr('pen.key_none') : 'F${vk - 0x6F}';

/// Where the toolbar goes: where it was moved to (kept on a screen), else
/// [normal].
class BarPlace {
  BarPlace._();

  static Rect rect(Rect normal) {
    final at = PenSession.instance.services?.player.barAt;
    final screens = WinScreen.screens();
    if (at == null || screens.isEmpty) return normal;
    final scr = screens.firstWhere((s) => s.rect.contains(at), orElse: () => screens.first);
    final r = scr.rect;
    final w = normal.width.clamp(0.0, r.width), h = normal.height.clamp(0.0, r.height);
    final x = at.dx.clamp(r.left, r.right - w), y = at.dy.clamp(r.top, r.bottom - h);
    return Rect.fromLTWH(x, y, w, h);
  }

  static void save() {
    final r = WinScreen.ownRect();
    if (r != null) PenSession.instance.services?.player.setBarAt(r.topLeft);
  }
}

/// Hold and drag: the toolbar (LocalRoll's window) goes anywhere, and is
/// there next time.
class BarGrip extends StatefulWidget {
  const BarGrip({super.key});

  @override
  State<BarGrip> createState() => _BarGripState();
}

class _BarGripState extends State<BarGrip> with WindowListener {
  bool _moving = false;
  Timer? _done;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    _done?.cancel();
    super.dispose();
  }

  @override
  void onWindowMove() {
    if (_moving) BarPlace.save();
  }

  @override
  void onWindowMoved() {
    if (!_moving) return;
    BarPlace.save();
    _moving = false;
  }

  @override
  Widget build(BuildContext context) => Tooltip(
        message: tr('pen.move_bar'),
        child: MouseRegion(
          cursor: SystemMouseCursors.move,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onPanStart: (_) {
              _moving = true;
              _done?.cancel();
              // Saved once more when the move is over (some systems send no "moved").
              _done = Timer(const Duration(seconds: 8), () {
                if (_moving) BarPlace.save();
                _moving = false;
              });
              unawaited(windowManager.startDragging());
            },
            child: const Padding(
              padding: EdgeInsets.symmetric(horizontal: 4, vertical: 8),
              child: Icon(Icons.drag_indicator_rounded, color: Colors.white54, size: 20),
            ),
          ),
        ),
      );
}
