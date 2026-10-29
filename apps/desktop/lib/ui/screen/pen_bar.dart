// apps/desktop/lib/ui/screen/pen_bar.dart
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:localroll_core/localroll_core.dart' show DiagLog;
import 'package:window_manager/window_manager.dart';

import '../../l10n/l10n.dart';
import '../../services/pen_overlay.dart';
import '../../services/win_screen.dart';
import '../app_nav.dart';
import '../player/ink_editor.dart';
import '../theme.dart';

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
                  _btn(Icons.mouse_rounded, tr('pen.operate'), () => o.setDraw(false), on: !o.draw),
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
                    },
                    itemBuilder: (_) => [
                      CheckedPopupMenuItem(value: 'fade', checked: o.fade, child: Text(tr('screen.fade'))),
                      CheckedPopupMenuItem(value: 'return', checked: o.autoReturn, child: Text(tr('pen.auto_return'))),
                      CheckedPopupMenuItem(value: 'stylus', checked: o.penDraws, child: Text(tr('pen.stylus'))),
                      PopupMenuItem(enabled: false, child: Text(tr('pen.tips'), style: const TextStyle(fontSize: 12, color: LrColors.muted))),
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

  /// The toolbar at the top of the screen in use, over the pen's layer.
  static void placeBar({required bool tall}) {
    final screens = WinScreen.screens();
    if (screens.isEmpty) return;
    final c = WinScreen.cursor();
    final scr = screens.firstWhere((s) => s.rect.contains(c), orElse: () => screens.first);
    final k = scr.scale;
    final w = 1180 * k, h = (tall ? 140 : 76) * k;
    WinScreen.place(Rect.fromLTWH(scr.rect.center.dx - w / 2, scr.rect.top + 8 * k, w, h), onTop: true, activate: false);
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
