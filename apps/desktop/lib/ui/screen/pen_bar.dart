// apps/desktop/lib/ui/screen/pen_bar.dart
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:localroll_core/localroll_core.dart' show DiagLog;
import 'package:window_manager/window_manager.dart';

import '../../app_services.dart';
import '../../l10n/l10n.dart';
import '../../services/annotations.dart' show CandleKind;
import '../../services/pen_controls.dart';
import '../../services/pen_overlay.dart';
import '../../services/stamp_library.dart';
import '../../services/win_screen.dart';
import '../app_nav.dart';
import '../player/ink_editor.dart';
import '../stamps/candle_panel.dart';
import '../stamps/stamp_picker.dart';
import '../theme.dart';
import 'float_panel.dart';
import 'screen_record.dart';

/// The screen pen's tools (LocalRoll's window, kept out of recordings):
/// the mouse button lets the mouse through to the apps; any drawing tool
/// draws. Undo / redo, pages, board, light around the mouse, options.
class PenToolbar extends StatefulWidget {
  const PenToolbar({super.key, this.extra = const [], this.controls, this.vertical = false, this.flat = false});

  /// More buttons at the end (end the pen…).
  final List<Widget> extra;

  /// What it works (null: the pen itself; the floating panel passes its
  /// stand-in).
  final PenControls? controls;

  /// Buttons in columns (the panel standing upright).
  final bool vertical;

  /// Inside a bar of its own (the floating panel): no card, no grip.
  final bool flat;

  @override
  State<PenToolbar> createState() => _PenToolbarState();
}

class _PenToolbarState extends State<PenToolbar> {
  final TextEditingController _words = TextEditingController();
  final FocusNode _wordsFocus = FocusNode();

  PenControls get o => widget.controls ?? PenOverlay.instance;

  @override
  void dispose() {
    _words.dispose();
    _wordsFocus.dispose();
    super.dispose();
  }

  /// A panel (stamps / candles): the bar grows for it a moment, then back.
  Future<T?> _big<T>(Future<T?> Function() show) async {
    final was = WinScreen.ownPlaceRect();
    final k = MediaQuery.devicePixelRatioOf(context);
    if (was != null) {
      WinScreen.place(Rect.fromLTWH(was.left, was.top, math.max(was.width, 820 * k), math.max(was.height, 680 * k)), onTop: true);
    }
    final r = await show();
    if (was != null) WinScreen.place(was, onTop: true, activate: false);
    return r;
  }

  Future<void> _pickStamp() async {
    final r = await _big(() => showStampPicker(context));
    if (r == null) return;
    if (r.id == StampLibrary.candleDraw) return _pickCandle();
    await o.setStamp(r.shape);
  }

  Future<void> _pickCandle() async {
    final r = await _big(() => showCandlePanel(context));
    if (r == null) return;
    final lib = StampLibrary.instance;
    if (r.stamp != null) {
      await o.setStamp(r.stamp!.shape);
    } else {
      o.setCandle(lib.upColor, lib.downColor, r.kind ?? CandleKind.normal);
    }
  }

  // The light look: white, round, the tool in use blue.
  static const _ink = Color(0xFF33415C);
  static const _blue = Color(0xFF2F6BFF);

  Widget _btn(IconData icon, String tip, VoidCallback? onTap, {bool on = false, Widget? child}) => Tooltip(
        message: tip,
        child: Material(
          color: on ? _blue : Colors.transparent,
          borderRadius: BorderRadius.circular(11),
          child: InkWell(
            borderRadius: BorderRadius.circular(11),
            onTap: onTap,
            child: SizedBox(
              width: 36,
              height: 36,
              child: Center(child: child ?? Icon(icon, size: 19, color: onTap == null ? const Color(0x5533415C) : (on ? Colors.white : _ink))),
            ),
          ),
        ),
      );

  /// A button with more inside (shapes, marks, stamps, colour): a small
  /// arrow under it; the window grows a moment while the list is open.
  Widget _group(IconData icon, String tip, bool on, Future<void> Function(Rect at) open, {Widget? child}) => Builder(
        builder: (ctx) => Stack(clipBehavior: Clip.none, children: [
          _btn(icon, tip, () {
            final box = ctx.findRenderObject() as RenderBox?;
            if (box == null) return;
            unawaited(open(box.localToGlobal(Offset.zero) & box.size));
          }, on: on, child: child),
          Positioned(
            right: 1,
            bottom: 1,
            child: IgnorePointer(child: Icon(Icons.arrow_drop_down_rounded, size: 13, color: on ? Colors.white70 : const Color(0xFF8A97B0))),
          ),
        ]),
      );

  /// A list under [at] (above it when there is no room below).
  Future<T?> _menu<T>(Rect at, List<PopupMenuEntry<T>> items) => _big(() {
        final size = MediaQuery.sizeOf(context);
        final down = at.bottom + 260 < size.height || at.top < 260;
        return showMenu<T>(
          context: context,
          color: Colors.white,
          surfaceTintColor: Colors.white,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          position: down
              ? RelativeRect.fromLTRB(at.left, at.bottom + 6, size.width - at.right, 0)
              : RelativeRect.fromLTRB(at.left, 0, size.width - at.right, size.height - at.top + 6),
          items: items,
        );
      });

  /// A row of tools in one list entry (tapped: chosen, the list closes).
  PopupMenuEntry<T> _tiles<T>(List<(Widget, String, VoidCallback, bool)> tiles) => _Tiles<T>(tiles: tiles);

  static const _shapes = [EditTool.line, EditTool.arrow, EditTool.rect, EditTool.ellipse];
  static const _marks = [EditTool.check, EditTool.cross, EditTool.number];

  /// The tool shown for a group: the one in use if it is in it, else the
  /// group's first.
  EditTool _shown(List<EditTool> g) => g.firstWhere((t) => o.tool == t.name, orElse: () => g.first);

  Future<void> _pickFrom(Rect at, List<EditTool> g) => _menu<void>(at, [
        _tiles([
          for (final t in g)
            (Icon(InkToolbar.icon(t), size: 20, color: o.tool == t.name ? Colors.white : _ink), InkToolbar.label(t), () => o.setTool(t.name), o.draw && o.tool == t.name),
        ]),
      ]);

  Future<void> _stamps(Rect at) async {
    final lib = StampLibrary.instance;
    String? pick;
    await _menu<void>(at, [
      if (lib.quick.isNotEmpty)
        _tiles([
          for (final id in lib.quick) (StampThumb(id: id, size: 22), stampName(id), () => pick = id, false),
        ]),
      PopupMenuItem<void>(
        onTap: () => pick = '',
        child: Row(children: [
          const Icon(Icons.apps_rounded, size: 18, color: _ink),
          const SizedBox(width: 10),
          Text(tr('ink.tool_stamp'), style: const TextStyle(color: _ink)),
        ]),
      ),
    ]);
    final id = pick;
    if (id == null) return;
    if (id.isEmpty) return _pickStamp();
    final q = quickStamp(id);
    if (q == null) return _pickCandle();
    await o.setStamp(q.shape);
  }

  Future<void> _colour(Rect at) => _menu<void>(at, [
        _tiles([
          for (final c in inkColors)
            (
              Container(width: 22, height: 22, decoration: BoxDecoration(color: c, shape: BoxShape.circle, border: Border.all(color: const Color(0xFFD7DDEA), width: 2))),
              '',
              () => o.setColor(c),
              c == o.color,
            ),
        ]),
        _tiles([
          for (var l = 0; l < 3; l++)
            (
              Container(width: 6.0 + l * 5, height: 6.0 + l * 5, decoration: BoxDecoration(color: o.level == l ? Colors.white : _ink, shape: BoxShape.circle)),
              tr('ink.size_${['small', 'medium', 'large'][l]}'),
              () => o.setLevel(l),
              o.level == l,
            ),
        ]),
      ]);

  /// Everything used less often, in one list.
  Future<void> _more(Rect at) {
    PopupMenuItem<void> item(IconData icon, String label, VoidCallback? onTap, {bool on = false}) => PopupMenuItem<void>(
          enabled: onTap != null,
          onTap: onTap,
          height: 40,
          child: Row(children: [
            Icon(icon, size: 18, color: on ? _blue : _ink),
            const SizedBox(width: 10),
            Expanded(child: Text(label, style: TextStyle(color: on ? _blue : _ink, fontWeight: on ? FontWeight.w700 : FontWeight.w400))),
            if (on) const Icon(Icons.check_rounded, size: 16, color: _blue),
          ]),
        );
    return _menu<void>(at, [
      item(Icons.redo_rounded, tr('ink.redo'), o.canRedo ? o.redo : null),
      if (o.selected) item(Icons.delete_outline_rounded, tr('ink.delete'), o.deleteSelected),
      if (o.hasNumbers) item(Icons.format_list_numbered_rounded, tr('ink.renumber'), o.renumber),
      item(Icons.delete_sweep_rounded, tr('pen.clear_page'), o.clearPage),
      item(Icons.note_add_outlined, tr('pen.new_page'), o.newPage),
      if (o.sheets > 1) ...[
        item(Icons.chevron_left_rounded, '${tr('pen.prev_sheet')}  (${o.sheet}/${o.sheets})', o.sheet > 1 ? o.prevPage : null),
        item(Icons.chevron_right_rounded, tr('pen.next_sheet'), o.sheet < o.sheets ? o.nextPage : null),
      ],
      const PopupMenuDivider(),
      for (var b = 0; b < 3; b++)
        item(b == 0 ? Icons.layers_clear_outlined : Icons.dashboard_outlined, tr(['pen.board_none', 'pen.board_white', 'pen.board_black'][b]), () => o.setBoard(b),
            on: o.board == b),
      item(Icons.highlight_rounded, tr('pen.highlight'), () => o.setHighlight(!o.highlight), on: o.highlight),
      const PopupMenuDivider(),
      item(Icons.blur_on_rounded, tr('screen.fade'), () => o.setFade(!o.fade), on: o.fade),
      item(Icons.u_turn_left_rounded, tr('pen.auto_return'), () => o.setAutoReturn(!o.autoReturn), on: o.autoReturn),
      item(Icons.draw_rounded, tr('pen.stylus'), () => o.setPenDraws(!o.penDraws), on: o.penDraws),
      item(Icons.web_asset_rounded, tr('pen.per_window'), () => o.setPerWindow(!o.perWindow), on: o.perWindow),
      PopupMenuItem<void>(enabled: false, height: 28, child: Text(tr('pen.key_title'), style: const TextStyle(fontSize: 12, color: LrColors.muted))),
      for (final vk in const [0x75, 0x76, 0x77, 0x78, 0x79, 0])
        item(Icons.keyboard_rounded, _keyName(vk), () {
          o.setToggleKey(vk);
          PenSession.instance.services?.player.setPenKey(vk);
        }, on: o.toggleKey == vk),
    ]);
  }

  Widget _typing() {
    if (!_wordsFocus.hasFocus) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _wordsFocus.requestFocus();
      });
    }
    return Row(mainAxisSize: MainAxisSize.min, children: [
      const Icon(Icons.text_fields_rounded, color: _ink, size: 20),
      const SizedBox(width: 8),
      SizedBox(
        width: 360,
        child: TextField(
          controller: _words,
          focusNode: _wordsFocus,
          style: const TextStyle(color: _ink),
          decoration: InputDecoration(isDense: true, hintText: tr('ink.type_here'), hintStyle: const TextStyle(color: Color(0xFF8A97B0))),
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

  /// Operate the computer, or draw: two halves of one switch.
  Widget _mode() {
    Widget half(bool draw, IconData icon, String label) {
      final on = o.draw == draw;
      return Material(
        color: on ? Colors.white : Colors.transparent,
        elevation: on ? 1 : 0,
        borderRadius: BorderRadius.circular(9),
        child: InkWell(
          borderRadius: BorderRadius.circular(9),
          onTap: () => o.setDraw(draw),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(icon, size: 16, color: on ? _blue : const Color(0xFF6B7A99)),
              const SizedBox(width: 4),
              Text(label, style: TextStyle(fontSize: 13, color: on ? _blue : const Color(0xFF4B5872), fontWeight: on ? FontWeight.w700 : FontWeight.w400)),
            ]),
          ),
        ),
      );
    }

    return Tooltip(
      message: tr(o.draw ? 'pen.operate_tip' : 'pen.back_tip', {'key': _keyName(o.toggleKey)}),
      child: Container(
        padding: const EdgeInsets.all(3),
        decoration: BoxDecoration(color: const Color(0xFFEEF2F9), borderRadius: BorderRadius.circular(12)),
        child: Flex(
          direction: widget.vertical ? Axis.vertical : Axis.horizontal,
          mainAxisSize: MainAxisSize.min,
          children: [half(false, Icons.mouse_rounded, tr('pen.mode_operate')), half(true, Icons.edit_rounded, tr('pen.mode_draw'))],
        ),
      ),
    );
  }

  Widget _sep() => widget.vertical
      ? Container(width: 26, height: 1, margin: const EdgeInsets.symmetric(vertical: 4), color: const Color(0xFFE3E8F2))
      : Container(width: 1, height: 26, margin: const EdgeInsets.symmetric(horizontal: 4), color: const Color(0xFFE3E8F2));

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: Listenable.merge([o, StampLibrary.instance]),
        builder: (context, _) {
          bool on(EditTool t) => o.draw && o.tool == t.name;
          final shape = _shown(_shapes), mark = _shown(_marks);
          final tools = <Widget>[
            _btn(InkToolbar.icon(EditTool.pen), InkToolbar.label(EditTool.pen), () => o.setTool(EditTool.pen.name), on: on(EditTool.pen)),
            _btn(InkToolbar.icon(EditTool.marker), InkToolbar.label(EditTool.marker), () => o.setTool(EditTool.marker.name), on: on(EditTool.marker)),
            _group(InkToolbar.icon(shape), tr('pen.shapes'), _shapes.any(on), (r) => _pickFrom(r, _shapes)),
            _btn(InkToolbar.icon(EditTool.text), InkToolbar.label(EditTool.text), () => o.setTool(EditTool.text.name), on: on(EditTool.text)),
            _group(InkToolbar.icon(mark), tr('pen.marks'), _marks.any(on), (r) => _pickFrom(r, _marks)),
            _group(InkToolbar.icon(EditTool.stamp), InkToolbar.label(EditTool.stamp), on(EditTool.stamp) || on(EditTool.candle), _stamps),
            _btn(InkToolbar.icon(EditTool.select), InkToolbar.label(EditTool.select), () => o.setTool(EditTool.select.name), on: on(EditTool.select)),
            _btn(InkToolbar.icon(EditTool.eraser), InkToolbar.label(EditTool.eraser), () => o.setTool(EditTool.eraser.name), on: on(EditTool.eraser)),
            _sep(),
            _group(
              Icons.circle,
              tr('ink.color'),
              false,
              _colour,
              child: Container(
                width: 20,
                height: 20,
                decoration: BoxDecoration(
                  color: o.color,
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white, width: 3),
                  boxShadow: const [BoxShadow(color: Color(0x33000000), blurRadius: 2)],
                ),
              ),
            ),
            _btn(Icons.undo_rounded, tr('ink.undo'), o.canUndo ? o.undo : null),
            _group(Icons.more_horiz_rounded, tr('ink.more'), o.highlight || o.board != 0, _more),
          ];
          return Container(
            padding: widget.flat ? EdgeInsets.zero : const EdgeInsets.symmetric(horizontal: 6, vertical: 5),
            decoration: widget.flat
                ? null
                : BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: const Color(0xFFE3E8F2)),
                    boxShadow: const [BoxShadow(color: Color(0x2A0A1432), blurRadius: 14, offset: Offset(0, 4))],
                  ),
            child: o.textAt != null
                ? _typing()
                : Flex(
                    direction: widget.vertical ? Axis.vertical : Axis.horizontal,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (!widget.flat) const BarGrip(),
                      if (widget.flat) _sep(),
                      _mode(),
                      _sep(),
                      // Operating the computer: the drawing tools stay, greyed a little.
                      Opacity(
                        opacity: o.draw ? 1 : 0.55,
                        child: Flex(direction: widget.vertical ? Axis.vertical : Axis.horizontal, mainAxisSize: MainAxisSize.min, children: tools),
                      ),
                      ...widget.extra,
                    ],
                  ),
          );
        },
      );
}

/// Tools side by side in one list entry; a tap chooses and closes the list.
class _Tiles<T> extends PopupMenuEntry<T> {
  const _Tiles({required this.tiles});

  final List<(Widget, String, VoidCallback, bool)> tiles;

  @override
  double get height => 52;

  @override
  bool represents(T? value) => false;

  @override
  State<_Tiles<T>> createState() => _TilesState<T>();
}

class _TilesState<T> extends State<_Tiles<T>> {
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          for (final (icon, label, onTap, on) in widget.tiles)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2),
              child: Tooltip(
                message: label,
                child: Material(
                  color: on ? const Color(0xFF2F6BFF) : const Color(0xFFF5F7FC),
                  borderRadius: BorderRadius.circular(10),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(10),
                    onTap: () {
                      Navigator.of(context).pop();
                      onTap();
                    },
                    child: SizedBox(width: 40, height: 40, child: Center(child: icon)),
                  ),
                ),
              ),
            ),
        ]),
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

  /// The helper's own words when Keepnear stops answering, and what its
  /// buttons (or Esc twice) do.
  static void prepareHelper({required bool recording}) {
    final o = PenOverlay.instance;
    o.noteText = (tr('pen.hung_text'), tr('pen.hung_reopen'), tr('pen.hung_end'));
    o.onHung = (what) {
      if (recording) {
        final r = ScreenRecorder.instance;
        if (what == 'end') {
          if (r.pen) unawaited(r.togglePen());
        } else if (FloatPanel.instance.running || FloatPanel.wanted) {
          unawaited(FloatPanel.instance.restart());
        }
        return;
      }
      final p = PenSession.instance;
      if (!p.active) return;
      if (what == 'end') {
        unawaited(p.stop());
      } else if (p.floating) {
        unawaited(FloatPanel.instance.restart());
      }
    };
  }

  Future<bool> start() async {
    if (active) return true;
    prepareHelper(recording: false);
    final ctx = AppNav.instance.navigatorKey.currentContext;
    if (!PenOverlay.available) {
      if (ctx != null) ScaffoldMessenger.maybeOf(ctx)?.showSnackBar(SnackBar(content: Text(tr('pen.missing'))));
      return false;
    }
    // The floating panel: LocalRoll stays as it is (and can be drawn on).
    if (FloatPanel.wanted && await _startFloating()) return true;
    _saved = WinScreen.ownPlaceRect();
    AppNav.instance.fullscreen.value = true;
    await windowManager.setMinimumSize(const Size(200, 40));
    // The toolbar is moved by its grip only; never resized.
    await windowManager.setResizable(false);
    WinScreen.excludeFromCapture(true);
    final o = PenOverlay.instance;
    // Drawing without recording: one layer over the whole screen.
    if (!o.running) o.perWindow = false;
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

  /// The tools are in the floating panel (LocalRoll's window untouched).
  bool floating = false;

  Future<bool> _startFloating() async {
    final o = PenOverlay.instance;
    if (!o.running) o.perWindow = false;
    if (!await o.start()) return false;
    final panel = FloatPanel.instance;
    panel.onGone = () {
      if (active && floating) unawaited(stop());
    };
    o.onEnded = () {
      if (active && floating) unawaited(stop());
    };
    if (!await panel.start('pen')) {
      await o.stop();
      return false;
    }
    active = true;
    floating = true;
    o.setDraw(true);
    DiagLog.log('pen', 'drawing on the screen (floating panel)');
    return true;
  }

  Future<void> stop() async {
    if (!active) return;
    active = false;
    DiagLog.log('pen', 'drawing ended');
    if (floating) {
      floating = false;
      await FloatPanel.instance.stop();
      await PenOverlay.instance.stop();
      return;
    }
    await PenOverlay.instance.stop();
    await _restore();
  }

  /// A recording takes over (the marks and the pen stay).
  void handOver() {
    active = false;
    // The floating panel stays: the recording uses it.
    floating = false;
    AppNav.instance.navigatorKey.currentState?.popUntil((r) => r.settings.name != 'pen-bar');
  }

  Future<void> _restore() async {
    WinScreen.excludeFromCapture(false);
    final r = _saved;
    if (r != null) WinScreen.place(r, onTop: false);
    _saved = null;
    await windowManager.setMinimumSize(const Size(960, 620));
    // A normal window again (resizable).
    await windowManager.setResizable(true);
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
    // Wide enough for every button; on a small screen, two rows.
    final w = math.min(1480 * k, scr.rect.width - 40 * k);
    final h = ((tall ? 140 : 76) * (w < 1480 * k ? 1.75 : 1) + BarTips.line) * k;
    WinScreen.place(BarPlace.rect(Rect.fromLTWH(scr.rect.center.dx - w / 2, scr.rect.top + 8 * k, w, h)), onTop: true, activate: false);
  }
}

class _PenBarPage extends StatelessWidget {
  const _PenBarPage();

  @override
  Widget build(BuildContext context) => PopScope(
        canPop: false,
        child: Scaffold(
          backgroundColor: const Color(0xFFF3F6FC),
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
                child: BarTips(child: PenToolbar(extra: [
                  const _ShotButton(),
                  const SizedBox(width: 6),
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: FilledButton.icon(
                      style: FilledButton.styleFrom(backgroundColor: LrColors.danger, minimumSize: const Size(0, 40)),
                      onPressed: () => unawaited(PenSession.instance.stop()),
                      icon: const Icon(Icons.close_rounded, size: 18),
                      label: Text(tr('pen.end')),
                    ),
                  ),
                ])),
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
              : const Icon(Icons.add_a_photo_outlined, size: 20, color: Color(0xFF33415C)),
        ),
        if (_done != null) Text(_done!, style: const TextStyle(color: Color(0xFF6B7A99), fontSize: 12)),
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
    final r = WinScreen.ownPlaceRect();
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
              child: Icon(Icons.drag_indicator_rounded, color: Color(0xFFA9B4C8), size: 20),
            ),
          ),
        ),
      );
}

/// The bar is a small window: a tooltip can't show outside it (the name was
/// cut off). So the name of what the mouse is over shows in a line under
/// the buttons instead — taken from the buttons' own tooltips.
class BarTips extends StatefulWidget {
  const BarTips({super.key, required this.child});

  final Widget child;

  /// The line's height (the window is this much taller).
  static const double line = 18;

  @override
  State<BarTips> createState() => _BarTipsState();
}

class _BarTipsState extends State<BarTips> {
  final GlobalKey _key = GlobalKey();
  String? _tip;

  void _hover(Offset at) {
    String? found;
    void visit(Element e) {
      final w = e.widget;
      if (w is Tooltip) {
        final box = e.renderObject;
        if (box is RenderBox && box.attached && box.hasSize && (box.localToGlobal(Offset.zero) & box.size).contains(at)) {
          final m = w.message ?? w.richMessage?.toPlainText();
          // The innermost one wins (visited last).
          if (m != null && m.isNotEmpty) found = m;
        }
      }
      e.visitChildren(visit);
    }

    _key.currentContext?.visitChildElements(visit);
    if (found != _tip) setState(() => _tip = found);
  }

  @override
  Widget build(BuildContext context) => MouseRegion(
        onHover: (e) => _hover(e.position),
        onExit: (_) {
          if (_tip != null) setState(() => _tip = null);
        },
        // The line under the bar is as wide as the bar (a long tip is cut,
        // it never makes the bar wider).
        child: Stack(children: [
          Padding(
            padding: const EdgeInsets.only(bottom: BarTips.line),
            child: TooltipVisibility(visible: false, child: KeyedSubtree(key: _key, child: widget.child)),
          ),
          Positioned(
            left: 4,
            right: 4,
            bottom: 0,
            height: BarTips.line,
            child: Text(
              _tip ?? '',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Color(0xFF6B7A99), fontSize: 12, height: 1.3),
            ),
          ),
        ]),
      );
}
