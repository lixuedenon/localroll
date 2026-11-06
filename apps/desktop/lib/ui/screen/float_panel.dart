// apps/desktop/lib/ui/screen/float_panel.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:localroll_core/localroll_core.dart' show DiagLog, appName;
import 'package:localroll_ink/localroll_ink.dart' show CandleKind, StampShape;
import 'package:window_manager/window_manager.dart';

import '../../l10n/l10n.dart';
import '../../services/pen_controls.dart';
import '../../services/pen_overlay.dart';
import '../../services/stamp_library.dart';
import '../../services/win_screen.dart';
import '../theme.dart';
import 'pen_bar.dart';
import 'screen_record.dart';

// The floating pen panel: the pen's tools in a small window of their own
// (LocalRoll started once more with --pen-panel), so LocalRoll itself stays
// as it is — it can be shown, used and drawn on. The panel only shows and
// asks; LocalRoll does everything. They talk over a local connection
// (127.0.0.1, a one-time key): LocalRoll sends "how things are" as JSON
// lines, the panel sends what was pressed.

const String panelFlag = '--pen-panel';

/// LocalRoll's side: starts / stops the panel, tells it how things are,
/// does what it asks.
class FloatPanel {
  FloatPanel._();

  static final FloatPanel instance = FloatPanel._();

  /// The panel is used (not switched off in Settings; the pen helper is there).
  static bool get wanted => PenOverlay.available && !(PenSession.instance.services?.settings.oldPenBar ?? true);

  Process? _p;
  ServerSocket? _server;
  Socket? _sock;

  /// "pen" (drawing only) or "record" (a recording's controls too).
  String mode = 'pen';

  /// The panel's window and where it is (screen pixels).
  int hwnd = 0;
  Rect? rect;

  bool get running => _p != null;

  /// The panel went away by itself (closed, crashed).
  void Function()? onGone;

  String? _toast;

  Future<bool> start(String mode) async {
    this.mode = mode;
    if (_p != null) {
      _push();
      return true;
    }
    final s = PenSession.instance.services;
    if (s == null) return false;
    try {
      final server = _server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final key = List.generate(16, (_) => math.Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0')).join();
      server.listen((sock) {
        // Only the panel we started, once.
        if (_sock != null) {
          sock.destroy();
          return;
        }
        var first = true;
        sock.cast<List<int>>().transform(const Utf8Decoder(allowMalformed: true)).transform(const LineSplitter()).listen((line) {
          if (first) {
            first = false;
            if (line != 'hello $key') {
              sock.destroy();
              return;
            }
            _sock = sock;
            _push();
            return;
          }
          if (identical(_sock, sock)) _onLine(line);
        }, onDone: () {
          if (identical(_sock, sock)) _gone();
        }, onError: (_) {});
      });
      final at = s.player.barAt;
      final p = _p = await Process.start(Platform.resolvedExecutable, [
        panelFlag,
        '--port=${server.port}',
        '--key=$key',
        '--lang=${translator.language}',
        '--data=${s.settings.dataDir.path}',
        if (at != null) '--at=${at.dx.round()},${at.dy.round()}',
        if (s.player.barVertical) '--vertical',
      ]);
      unawaited(p.exitCode.then((code) {
        if (identical(_p, p)) {
          DiagLog.log('pen', 'panel ended ($code)');
          _gone();
        }
      }));
      PenOverlay.instance.addListener(_push);
      ScreenRecorder.instance.addListener(_push);
      DiagLog.log('pen', 'floating panel started');
      return true;
    } catch (e) {
      DiagLog.log('pen', 'floating panel not started: $e');
      await stop();
      return false;
    }
  }

  Future<void> stop() async {
    PenOverlay.instance.removeListener(_push);
    ScreenRecorder.instance.removeListener(_push);
    final p = _p, sock = _sock;
    _p = null;
    _sock = null;
    hwnd = 0;
    rect = null;
    try {
      sock?.writeln(jsonEncode({'quit': true}));
      await sock?.flush();
      sock?.destroy();
    } catch (_) {}
    await _server?.close();
    _server = null;
    if (p != null) {
      unawaited(Future<void>.delayed(const Duration(seconds: 2), () => p.kill()));
    }
    // The panel may have changed the stamps (recent, favourites…): read them again.
    final s = PenSession.instance.services;
    if (p != null && s != null) {
      unawaited(Future<void>.delayed(const Duration(milliseconds: 800), () => StampLibrary.instance.load(s.settings.dataDir)));
    }
  }

  void _gone() {
    if (_p == null && _sock == null) return;
    unawaited(stop());
    onGone?.call();
  }

  /// A short message shown on the panel ("Saved").
  void toast(String text) {
    _toast = text;
    _push();
  }

  void _push() {
    final sock = _sock;
    if (sock == null) return;
    final o = PenOverlay.instance;
    final r = ScreenRecorder.instance;
    final m = <String, Object?>{
      'mode': mode,
      'draw': o.draw,
      'tool': o.tool,
      'color': o.color.toARGB32(),
      'level': o.level,
      'canUndo': o.canUndo,
      'canRedo': o.canRedo,
      'selected': o.selected,
      'hasNumbers': o.hasNumbers,
      'sheet': o.sheet,
      'sheets': o.sheets,
      'board': o.board,
      'highlight': o.highlight,
      'fade': o.fade,
      'autoReturn': o.autoReturn,
      'penDraws': o.penDraws,
      'toggleKey': o.toggleKey,
      'perWindow': o.perWindow,
      if (o.textAt != null) 'textAt': [o.textAt!.x, o.textAt!.y],
      if (mode == 'record') ...{
        'armed': r.armed,
        'countdown': r.countdown,
        'recording': r.recording,
        'paused': r.paused,
        'elapsed': r.elapsedMs,
        'pen': r.pen,
        'what': r.recordingWhat,
      },
      if (_toast != null) 'toast': _toast,
    };
    _toast = null;
    try {
      sock.writeln(jsonEncode(m));
    } catch (_) {}
  }

  void _onLine(String line) {
    Map<String, dynamic> m;
    try {
      m = (jsonDecode(line) as Map).cast<String, dynamic>();
    } catch (_) {
      return;
    }
    final o = PenOverlay.instance;
    final r = ScreenRecorder.instance;
    final s = PenSession.instance.services;
    final v = m['v'];
    switch (m['a']) {
      case 'hwnd':
        hwnd = (v as num?)?.toInt() ?? 0;
        if (hwnd != 0) o.own(hwnd);
      case 'at':
        final l = (m['l'] as num?)?.toDouble(), t = (m['t'] as num?)?.toDouble();
        final w = (m['w'] as num?)?.toDouble(), h = (m['h'] as num?)?.toDouble();
        if (l != null && t != null && w != null && h != null) {
          rect = Rect.fromLTWH(l, t, w, h);
          if (m['save'] == true) s?.player.setBarAt(Offset(l, t));
        }
      case 'vertical':
        s?.player.setBarVertical(v == true);
      case 'draw':
        o.setDraw(v == true);
      case 'tool':
        o.setTool('$v');
      case 'color':
        o.setColor(Color((v as num).toInt()));
      case 'level':
        o.setLevel((v as num).toInt());
      case 'undo':
        o.undo();
      case 'redo':
        o.redo();
      case 'clear':
        o.clearPage();
      case 'delete':
        o.deleteSelected();
      case 'renumber':
        o.renumber();
      case 'newpage':
        o.newPage();
      case 'prev':
        o.prevPage();
      case 'next':
        o.nextPage();
      case 'board':
        o.setBoard((v as num).toInt());
      case 'highlight':
        o.setHighlight(v == true);
      case 'fade':
        o.setFade(v == true);
      case 'autoreturn':
        o.setAutoReturn(v == true);
      case 'pendraws':
        o.setPenDraws(v == true);
      case 'perwindow':
        o.setPerWindow(v == true);
      case 'togglekey':
        final vk = (v as num).toInt();
        o.setToggleKey(vk);
        s?.player.setPenKey(vk);
      case 'text':
        o.putText('$v');
      case 'stamp':
        if (v is Map) unawaited(o.setStamp(StampShape.fromJson(v.cast<String, dynamic>())));
      case 'candle':
        o.setCandle((m['up'] as num).toInt(), (m['down'] as num).toInt(), CandleKind.values[((m['kind'] as num?)?.toInt() ?? 0).clamp(0, CandleKind.values.length - 1)]);
      case 'shot':
        if (s != null) {
          unawaited(savePenShot(s).then((f) => toast(f == null ? tr('ink.shot_failed') : tr('recs.pen_saved'))));
        }
      case 'end':
        if (mode == 'pen') unawaited(PenSession.instance.stop());
      case 'go':
        unawaited(r.go());
      case 'cancel':
        unawaited(r.cancel());
      case 'pause':
        unawaited(r.togglePause());
      case 'stop':
        unawaited(r.stop());
      case 'pen':
        unawaited(r.togglePen());
    }
  }
}

// ---------------------------------------------------------------------------
// The panel's side (its own little program).

/// LocalRoll started with [panelFlag]: show only the pen panel.
Future<void> runPenPanel(List<String> args) async {
  String? arg(String name) {
    for (final a in args) {
      if (a.startsWith('--$name=')) return a.substring(name.length + 3);
    }
    return null;
  }

  final port = int.tryParse(arg('port') ?? '');
  final key = arg('key');
  if (port == null || key == null) exit(2);
  WidgetsFlutterBinding.ensureInitialized();
  final lang = arg('lang');
  if (lang != null) translator.language = lang;
  WinScreen.title = '$appName ✎';
  final data = arg('data');
  if (data != null) {
    try {
      await StampLibrary.instance.load(Directory(data));
    } catch (_) {}
  }
  final Socket sock;
  try {
    sock = await Socket.connect(InternetAddress.loopbackIPv4, port, timeout: const Duration(seconds: 5));
  } catch (_) {
    exit(3);
  }
  sock.writeln('hello $key');
  final remote = RemotePen(sock);
  Offset? at;
  final a = arg('at')?.split(',');
  if (a != null && a.length == 2) {
    final x = double.tryParse(a[0]), y = double.tryParse(a[1]);
    if (x != null && y != null) at = Offset(x, y);
  }
  final panel = _PanelPlace(at: at, vertical: args.contains('--vertical'));
  await windowManager.ensureInitialized();
  await windowManager.waitUntilReadyToShow(
    WindowOptions(
      title: WinScreen.title,
      titleBarStyle: TitleBarStyle.hidden,
      skipTaskbar: true,
      alwaysOnTop: true,
      backgroundColor: LrColors.ink,
      size: const Size(640, 120),
    ),
    () async {
      await windowManager.setResizable(false);
      // Its size and place first (no flash of a big window), then shown.
      panel.place();
      await windowManager.show();
    },
  );
  WinScreen.excludeFromCapture(true);
  remote.send({'a': 'hwnd', 'v': WinScreen.ownWindow()});
  panel.report(remote, save: false);
  runApp(_PanelApp(remote: remote, place: panel));
}

/// Where the panel stands and how big it is.
class _PanelPlace {
  _PanelPlace({this.at, required this.vertical});

  Offset? at;
  bool vertical;
  bool small = false;

  void place() {
    final screens = WinScreen.screens();
    if (screens.isEmpty) return;
    final c = at ?? WinScreen.cursor();
    final scr = screens.firstWhere((s) => s.rect.contains(c), orElse: () => screens.first);
    final k = scr.scale;
    final Size size;
    if (small) {
      size = Size(64 * k, 64 * k);
    } else if (vertical) {
      size = Size(150 * k, math.min(900 * k, scr.rect.height - 60 * k));
    } else {
      final w = math.min(1480 * k, scr.rect.width - 40 * k);
      size = Size(w, (76 * (w < 1480 * k ? 1.75 : 1) + BarTips.line + 34) * k);
    }
    final want = at ?? Offset(scr.rect.center.dx - size.width / 2, scr.rect.top + 8 * k);
    final x = want.dx.clamp(scr.rect.left, math.max(scr.rect.left, scr.rect.right - size.width));
    final y = want.dy.clamp(scr.rect.top, math.max(scr.rect.top, scr.rect.bottom - size.height));
    WinScreen.place(Rect.fromLTWH(x, y, size.width, size.height), onTop: true, activate: false);
  }

  /// Tells LocalRoll where the panel is (and to remember it, after a move).
  void report(RemotePen remote, {required bool save}) {
    final r = WinScreen.ownPlaceRect();
    if (r == null) return;
    if (save) at = r.topLeft;
    remote.send({'a': 'at', 'l': r.left, 't': r.top, 'w': r.width, 'h': r.height, 'save': save});
  }
}

/// The pen as the panel sees it: how LocalRoll says things are; whatever
/// is pressed goes to LocalRoll.
class RemotePen extends ChangeNotifier implements PenControls {
  RemotePen(this._sock) {
    _sock.cast<List<int>>().transform(const Utf8Decoder(allowMalformed: true)).transform(const LineSplitter()).listen(_onLine,
        onDone: () => exit(0), onError: (_) => exit(0));
  }

  final Socket _sock;

  void send(Map<String, Object?> m) {
    try {
      _sock.writeln(jsonEncode(m));
    } catch (_) {}
  }

  void _do(String a, [Object? v]) => send({'a': a, 'v': v});

  String mode = 'pen';
  bool armed = false, recording = false, paused = false, pen = false;
  int countdown = 0, elapsed = 0;
  String what = '';
  final Stopwatch _since = Stopwatch();

  /// Recording time now (counted on between LocalRoll's messages).
  int get elapsedNow => paused || !recording ? elapsed : elapsed + _since.elapsedMilliseconds;

  /// A message to show a moment ("Saved").
  final ValueNotifier<String?> toast = ValueNotifier(null);

  @override
  bool draw = false;
  @override
  String tool = 'pen';
  @override
  Color color = const Color(0xFFFF3B30);
  @override
  int level = 1;
  @override
  bool canUndo = false;
  @override
  bool canRedo = false;
  @override
  bool selected = false;
  @override
  bool hasNumbers = false;
  @override
  int sheet = 1;
  @override
  int sheets = 1;
  @override
  int board = 0;
  @override
  bool highlight = false;
  @override
  bool fade = false;
  @override
  bool autoReturn = false;
  @override
  bool penDraws = true;
  @override
  int toggleKey = 0x77;
  @override
  bool perWindow = false;
  @override
  ({int x, int y})? textAt;

  void _onLine(String line) {
    Map<String, dynamic> m;
    try {
      m = (jsonDecode(line) as Map).cast<String, dynamic>();
    } catch (_) {
      return;
    }
    if (m['quit'] == true) exit(0);
    bool b(String k) => m[k] == true;
    int i(String k, int d) => (m[k] as num?)?.toInt() ?? d;
    final typingBefore = textAt;
    mode = m['mode'] as String? ?? 'pen';
    draw = b('draw');
    tool = m['tool'] as String? ?? tool;
    color = Color(i('color', color.toARGB32()));
    level = i('level', 1);
    canUndo = b('canUndo');
    canRedo = b('canRedo');
    selected = b('selected');
    hasNumbers = b('hasNumbers');
    sheet = i('sheet', 1);
    sheets = i('sheets', 1);
    board = i('board', 0);
    highlight = b('highlight');
    fade = b('fade');
    autoReturn = b('autoReturn');
    penDraws = b('penDraws');
    toggleKey = i('toggleKey', 0x77);
    perWindow = b('perWindow');
    final t = m['textAt'];
    textAt = t is List && t.length == 2 ? (x: (t[0] as num).toInt(), y: (t[1] as num).toInt()) : null;
    armed = b('armed');
    countdown = i('countdown', 0);
    recording = b('recording');
    paused = b('paused');
    elapsed = i('elapsed', 0);
    _since
      ..reset()
      ..start();
    pen = b('pen');
    what = m['what'] as String? ?? '';
    final msg = m['toast'] as String?;
    if (msg != null) {
      toast.value = msg;
      Future<void>.delayed(const Duration(seconds: 3), () {
        if (toast.value == msg) toast.value = null;
      });
    }
    // Words to type: the panel takes the keyboard.
    if (typingBefore == null && textAt != null) unawaited(windowManager.focus());
    notifyListeners();
  }

  @override
  void setDraw(bool on) => _do('draw', on);
  @override
  void setTool(String t) => _do('tool', t);
  @override
  Future<void> setStamp(StampShape shape) async => _do('stamp', shape.toJson());
  @override
  void setCandle(int up, int down, CandleKind kind) => send({'a': 'candle', 'up': up, 'down': down, 'kind': kind.index});
  @override
  void setColor(Color c) => _do('color', c.toARGB32());
  @override
  void setLevel(int l) => _do('level', l);
  @override
  void undo() => _do('undo');
  @override
  void redo() => _do('redo');
  @override
  void clearPage() => _do('clear');
  @override
  void deleteSelected() => _do('delete');
  @override
  void renumber() => _do('renumber');
  @override
  void newPage() => _do('newpage');
  @override
  void prevPage() => _do('prev');
  @override
  void nextPage() => _do('next');
  @override
  void setBoard(int b) => _do('board', b);
  @override
  void setHighlight(bool on) => _do('highlight', on);
  @override
  void setFade(bool on) => _do('fade', on);
  @override
  void setAutoReturn(bool on) => _do('autoreturn', on);
  @override
  void setPenDraws(bool on) => _do('pendraws', on);
  @override
  void setPerWindow(bool on) => _do('perwindow', on);
  @override
  void setToggleKey(int vk) => _do('togglekey', vk);
  @override
  void putText(String words) => _do('text', words);
}

class _PanelApp extends StatelessWidget {
  const _PanelApp({required this.remote, required this.place});

  final RemotePen remote;
  final _PanelPlace place;

  @override
  Widget build(BuildContext context) => MaterialApp(
        debugShowCheckedModeBanner: false,
        title: WinScreen.title,
        theme: buildLrTheme(),
        home: _PanelPage(remote: remote, place: place),
      );
}

class _PanelPage extends StatefulWidget {
  const _PanelPage({required this.remote, required this.place});

  final RemotePen remote;
  final _PanelPlace place;

  @override
  State<_PanelPage> createState() => _PanelPageState();
}

class _PanelPageState extends State<_PanelPage> with WindowListener {
  Timer? _tick;
  Timer? _moved;

  RemotePen get r => widget.remote;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    // The recording time counts on by itself.
    _tick = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (r.recording && !r.paused && mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    _tick?.cancel();
    _moved?.cancel();
    super.dispose();
  }

  @override
  void onWindowMoved() {
    _moved?.cancel();
    _moved = Timer(const Duration(milliseconds: 300), () => widget.place.report(r, save: true));
  }

  @override
  void onWindowMove() {
    _moved?.cancel();
    _moved = Timer(const Duration(milliseconds: 600), () => widget.place.report(r, save: true));
  }

  void _relayout(void Function() change) {
    setState(change);
    widget.place.place();
    widget.place.report(r, save: false);
  }

  Widget _tool(IconData icon, String tip, VoidCallback onTap, {Color color = Colors.white}) => IconButton(
        tooltip: tip,
        onPressed: onTap,
        icon: Icon(icon, size: 20, color: color),
      );

  /// Upright / flat, small, close: the panel's own buttons.
  List<Widget> _own() => [
        _tool(widget.place.vertical ? Icons.view_stream_rounded : Icons.view_column_rounded, tr(widget.place.vertical ? 'panel.flat' : 'panel.upright'), () {
          _relayout(() => widget.place.vertical = !widget.place.vertical);
          r.send({'a': 'vertical', 'v': widget.place.vertical});
        }),
        _tool(Icons.close_fullscreen_rounded, tr('panel.small'), () => _relayout(() => widget.place.small = true)),
      ];

  String _time(int ms) {
    final s = ms ~/ 1000;
    String two(int n) => n.toString().padLeft(2, '0');
    return s >= 3600 ? '${s ~/ 3600}:${two(s ~/ 60 % 60)}:${two(s % 60)}' : '${two(s ~/ 60)}:${two(s % 60)}';
  }

  /// A recording's controls (ready / counting down / recording).
  List<Widget> _record() {
    if (r.countdown > 0) {
      return [Text(tr('screen.starting_in', {'n': r.countdown}), style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600))];
    }
    if (r.armed) {
      return [
        if (r.what.isNotEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Text(r.what, style: const TextStyle(color: Colors.white70, fontSize: 13)),
          ),
        FilledButton.icon(
          style: FilledButton.styleFrom(backgroundColor: LrColors.danger, visualDensity: VisualDensity.compact),
          onPressed: () => r.send({'a': 'go'}),
          icon: const Icon(Icons.fiber_manual_record_rounded, size: 18),
          label: Text(tr('panel.start')),
        ),
        const SizedBox(width: 6),
        TextButton(onPressed: () => r.send({'a': 'cancel'}), child: Text(tr('common.cancel'))),
      ];
    }
    if (!r.recording) return const [];
    return [
      Icon(Icons.fiber_manual_record_rounded, size: 14, color: r.paused ? Colors.white54 : LrColors.danger),
      const SizedBox(width: 4),
      Text(_time(r.elapsedNow), style: const TextStyle(color: Colors.white, fontSize: 14, fontFeatures: [FontFeature.tabularFigures()])),
      _tool(r.paused ? Icons.play_arrow_rounded : Icons.pause_rounded, tr(r.paused ? 'panel.resume' : 'panel.pause'), () => r.send({'a': 'pause'})),
      _tool(Icons.stop_rounded, tr('panel.stop'), () => r.send({'a': 'stop'}), color: LrColors.danger),
      _tool(Icons.brush_rounded, tr(r.pen ? 'screen.pen_off' : 'screen.pen_on'), () => r.send({'a': 'pen'}), color: r.pen ? LrColors.safelight : Colors.white),
    ];
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: LrColors.ink,
        body: Focus(
          autofocus: true,
          onKeyEvent: (_, e) {
            if (e is KeyDownEvent && e.logicalKey == LogicalKeyboardKey.escape && r.mode == 'pen' && r.textAt == null) {
              r.send({'a': 'end'});
              return KeyEventResult.handled;
            }
            return KeyEventResult.ignored;
          },
          child: ListenableBuilder(
            listenable: r,
            builder: (context, _) {
              if (widget.place.small) {
                return Center(
                  child: IconButton.filled(
                    tooltip: tr('panel.big'),
                    style: IconButton.styleFrom(backgroundColor: LrColors.safelight, foregroundColor: const Color(0xFF2B1A00)),
                    onPressed: () => _relayout(() => widget.place.small = false),
                    icon: const Icon(Icons.brush_rounded),
                  ),
                );
              }
              final rec = r.mode == 'record';
              final strip = rec ? _record() : const <Widget>[];
              // Recording: the pen's tools only while the pen is on.
              final tools = !rec || r.pen;
              final vertical = widget.place.vertical;
              final top = Wrap(
                direction: vertical ? Axis.vertical : Axis.horizontal,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  const BarGrip(),
                  ...strip,
                  ..._own(),
                  if (!rec) ...[
                    _tool(Icons.add_a_photo_outlined, tr('recs.pen_shot'), () => r.send({'a': 'shot'})),
                    ValueListenableBuilder<String?>(
                      valueListenable: r.toast,
                      builder: (_, t, _) => t == null ? const SizedBox.shrink() : Text(t, style: const TextStyle(color: Colors.white70, fontSize: 12)),
                    ),
                    Padding(
                      padding: const EdgeInsets.all(4),
                      child: FilledButton.icon(
                        style: FilledButton.styleFrom(visualDensity: VisualDensity.compact),
                        onPressed: () => r.send({'a': 'end'}),
                        icon: const Icon(Icons.close_rounded, size: 18),
                        label: Text(tr('pen.end')),
                      ),
                    ),
                  ],
                ],
              );
              final body = Flex(
                direction: vertical ? Axis.horizontal : Axis.vertical,
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  top,
                  if (tools) PenToolbar(controls: r, vertical: vertical),
                ],
              );
              return LayoutBuilder(
                builder: (context, c) => BarTips(
                  child: Material(
                    color: Colors.transparent,
                    // Upright: the columns need a height to fill.
                    child: vertical ? SizedBox(height: math.max(0, c.maxHeight - BarTips.line), child: body) : body,
                  ),
                ),
              );
            },
          ),
        ),
      );
}
