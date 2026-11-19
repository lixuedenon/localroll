// apps/desktop/lib/services/pen_overlay.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show Color, Rect;

import 'package:flutter/foundation.dart';
import 'package:localroll_core/localroll_core.dart';
import 'package:localroll_ink/localroll_ink.dart' show CandleKind, StampShape;

import 'pen_controls.dart';
import 'win_screen.dart';

/// The screen pen: LocalRoll's small helper (lr_overlay.exe, next to
/// LocalRoll.exe) puts a transparent layer over every screen. Marks show
/// on the real screen (a recording simply records them); in "operate"
/// mode the mouse goes through to the apps while the marks stay. One page
/// per window. LocalRoll's own window is the toolbar.
class PenOverlay extends ChangeNotifier implements PenControls {
  PenOverlay._();

  static final PenOverlay instance = PenOverlay._();

  static String get exe => '${File(Platform.resolvedExecutable).parent.path}${Platform.pathSeparator}lr_overlay.exe';

  /// The helper is there (Windows only).
  static bool get available => Platform.isWindows && File(exe).existsSync();

  Process? _p;
  bool get running => _p != null;

  /// Drawing (else the mouse goes through to the apps).
  bool draw = false;
  String tool = 'pen';
  Color color = const Color(0xFFFF3B30);
  int level = 1;
  bool canUndo = false, canRedo = false, selected = false;

  /// Numbers on this sheet (offer "renumber").
  bool hasNumbers = false;
  int sheet = 1, sheets = 1;

  /// 0 none, 1 white board, 2 black board.
  int board = 0;
  bool highlight = false;

  /// Options (kept while LocalRoll runs).
  bool fade = false, autoReturn = false, penDraws = true;

  /// This key switches draw / operate while the pen is on (Windows key
  /// code; 0x77 = F8, 0 = none).
  int toggleKey = 0x77;

  /// Marks follow program windows (else one layer for the whole screen).
  bool perWindow = false;

  /// The text tool was clicked here (screen pixels): words are asked for.
  ({int x, int y})? textAt;

  @override
  String textWords = '';

  /// The text mark whose words are being changed (null: a new one).
  int? _textEdit;

  Completer<bool>? _ready;

  Future<bool> start() async {
    if (_p != null) return true;
    if (!available) return false;
    try {
      final p = _p = await Process.start(exe, const []);
      final ready = _ready = Completer<bool>();
      _pong = DateTime.now();
      p.stdout.transform(const Utf8Decoder(allowMalformed: true)).transform(const LineSplitter()).listen(_line);
      p.stderr.transform(const Utf8Decoder(allowMalformed: true)).transform(const LineSplitter()).listen((e) {
        if (e.trim().isNotEmpty) DiagLog.log('pen', e.trim());
      });
      unawaited(p.exitCode.then((code) {
        if (identical(_p, p)) {
          _p = null;
          draw = false;
          textAt = null;
          if (!ready.isCompleted) ready.complete(false);
          if (code != 0) DiagLog.log('pen', 'helper ended ($code)');
          _alive?.cancel();
          _alive = null;
          notifyListeners();
          onEnded?.call();
        }
      }));
      final ok = await ready.future.timeout(const Duration(seconds: 6), onTimeout: () => false);
      if (!ok) {
        DiagLog.log('pen', 'helper did not start');
        await stop();
        return false;
      }
      _send('own ${WinScreen.ownWindow()}');
      _send('color ${_hex(color)}');
      _send('level $level');
      _send('tool $tool');
      _send('fade ${fade ? 1 : 0}');
      _send('autoreturn ${autoReturn ? 1 : 0}');
      _send('pendraw ${penDraws ? 1 : 0}');
      _send('togglekey $toggleKey');
      _send('pages ${perWindow ? 'window' : 'screen'}');
      // The helper checks Keepnear answers (else it lets go of the mouse).
      watch([(WinScreen.ownWindow(), 5000)]);
      _beat?.cancel();
      _beat = Timer.periodic(const Duration(milliseconds: 500), (_) => WinScreen.beat(WinScreen.ownWindow()));
      WinScreen.beat(WinScreen.ownWindow());
      final nt = noteText;
      if (nt != null) _send('notetext ${nt.$1}\t${nt.$2}\t${nt.$3}');
      // Still answering? A helper that stops would keep the mouse caught
      // under its screen-wide window: closed after a few seconds of silence.
      _alive?.cancel();
      _alive = Timer.periodic(const Duration(seconds: 2), (_) {
        final q = _p;
        if (q == null) return;
        final quiet = DateTime.now().difference(_pong);
        if (quiet > const Duration(seconds: 8)) {
          DiagLog.log('pen', 'helper not answering for ${quiet.inSeconds} s: closed');
          q.kill();
          return;
        }
        _send('ping');
      });
      board = 0;
      highlight = false;
      stampsSent.clear();
      return true;
    } catch (e) {
      DiagLog.log('pen', 'helper not started: $e');
      _p = null;
      return false;
    }
  }

  Future<void> stop() async {
    _alive?.cancel();
    _alive = null;
    _beat?.cancel();
    _beat = null;
    final p = _p;
    _p = null;
    draw = false;
    textAt = null;
    if (p == null) return;
    try {
      p.stdin.writeln('quit');
      await p.stdin.flush();
      await p.stdin.close();
    } catch (_) {}
    try {
      await p.exitCode.timeout(const Duration(seconds: 3));
    } catch (_) {
      p.kill();
    }
    notifyListeners();
  }

  Timer? _alive, _beat;
  DateTime _pong = DateTime.now();

  /// The helper went away (quit, crashed, or closed for not answering).
  void Function()? onEnded;

  /// From the helper: "reopen" (the toolbar, after it stopped answering) or
  /// "end" (end the pen: its button, or Esc twice).
  void Function(String what)? onHung;

  /// What the helper says when Keepnear stops answering: the line, and its
  /// two buttons (set before [start]).
  (String, String, String)? noteText;

  /// Keepnear's windows the helper checks, each with how long it may take
  /// to answer (ms).
  void watch(List<(int, int)> windows) =>
      _send('watch ${[for (final (h, ms) in windows) if (h != 0) '$h $ms'].join(' ')}');

  void _line(String line) {
    final parts = line.trim().split(' ');
    _pong = DateTime.now();
    switch (parts.first) {
      case 'ready':
        DiagLog.log('pen', line.trim());
        if (!(_ready?.isCompleted ?? true)) _ready!.complete(true);
      case 'state':
        if (parts.length >= 7) {
          draw = parts[1] == 'draw';
          canUndo = parts[2] == '1';
          canRedo = parts[3] == '1';
          selected = parts[4] == '1';
          sheet = int.tryParse(parts[5]) ?? 1;
          sheets = int.tryParse(parts[6]) ?? 1;
          hasNumbers = parts.length > 7 && parts[7] == '1';
          notifyListeners();
        }
      case 'text':
        if (parts.length >= 3) {
          textAt = (x: int.tryParse(parts[1]) ?? 0, y: int.tryParse(parts[2]) ?? 0);
          textWords = '';
          _textEdit = null;
          notifyListeners();
        }
      case 'textedit':
        // textedit <id> <x> <y> <words>: a click on a chosen text.
        final m = RegExp(r'^textedit (\d+) (-?\d+) (-?\d+) ?(.*)$').firstMatch(line.trim());
        if (m != null) {
          _textEdit = int.parse(m.group(1)!);
          textAt = (x: int.parse(m.group(2)!), y: int.parse(m.group(3)!));
          textWords = (m.group(4) ?? '').replaceAll('\u2028', '\n');
          notifyListeners();
        }
      case 'error':
        DiagLog.log('pen', line.trim());
      case 'hung':
        if (parts.length > 1) {
          DiagLog.log('pen', 'helper: ${parts[1]}');
          onHung?.call(parts[1]);
        }
      case 'mark':
      case 'gone':
      case 'board':
      case 'capture':
        onReport?.call(line.trim());
    }
  }

  /// A recording keeping the marks apart: hears "mark <json>", "gone <id>",
  /// "board <0|1|2> l t r b" and "capture ok|fail".
  void Function(String line)? onReport;

  /// The stamps handed over, in order (a reported mark names its stamp by
  /// number, from 1): the shape and the colour it was drawn in.
  final List<(StampShape, int)> stampsSent = [];

  /// Write out every change of the marks (see [onReport]).
  void report(bool on) => _send('report ${on ? 1 : 0}');

  /// Whether the marks are filmed by screen recordings (false: they are
  /// drawn in afterwards; "capture ok" / "capture fail" answers).
  void capture(bool on) => _send('capture ${on ? 1 : 0}');

  void _send(String cmd) {
    try {
      _p?.stdin.writeln(cmd);
    } catch (_) {}
  }

  static String _hex(Color c) => c.toARGB32().toRadixString(16).padLeft(8, '0').toUpperCase();

  void setDraw(bool on) {
    draw = on;
    _send('mode ${on ? 'draw' : 'operate'}');
    notifyListeners();
  }

  /// A tool: drawing starts with it.
  void setTool(String t) {
    tool = t;
    _send('tool $t');
    setDraw(true);
  }

  /// A stamp to place (as a picture in the current colour).
  Future<void> setStamp(StampShape shape) async {
    final png = await shape.toPng(color.toARGB32());
    if (png == null) return;
    stampsSent.add((shape, color.toARGB32()));
    _send('stamp ${shape.aspect.toStringAsFixed(4)} ${shape.noTurn ? 1 : 0} ${base64Encode(png)}');
    setTool('stamp');
  }

  /// Candles: rising / falling colours, then the candle tool.
  void setCandle(int up, int down, CandleKind kind) {
    _send('candle ${up.toRadixString(16).padLeft(8, '0')} ${down.toRadixString(16).padLeft(8, '0')} ${kind.index}');
    setTool('candle');
  }

  void setColor(Color c) {
    color = c;
    _send('color ${_hex(c)}');
    notifyListeners();
  }

  void setLevel(int l) {
    level = l.clamp(0, 2);
    _send('level $level');
    notifyListeners();
  }

  void undo() => _send('undo');
  void redo() => _send('redo');
  void clearPage() => _send('clear');
  void deleteSelected() => _send('delete');

  /// Numbers 1, 2, 3… again, in the order they were put down.
  void renumber() => _send('renumber');
  void newPage() => _send('newpage');
  void prevPage() => _send('prevpage');
  void nextPage() => _send('nextpage');

  void setBoard(int b) {
    board = b;
    _send('board ${['none', 'white', 'black'][b]}');
    notifyListeners();
  }

  void setHighlight(bool on) {
    highlight = on;
    _send('highlight ${on ? 1 : 0}');
    notifyListeners();
  }

  void setFade(bool on) {
    fade = on;
    _send('fade ${on ? 1 : 0}');
    notifyListeners();
  }

  void setAutoReturn(bool on) {
    autoReturn = on;
    _send('autoreturn ${on ? 1 : 0}');
    notifyListeners();
  }

  void setPenDraws(bool on) {
    penDraws = on;
    _send('pendraw ${on ? 1 : 0}');
    notifyListeners();
  }

  void setPerWindow(bool on) {
    perWindow = on;
    _send('pages ${on ? 'window' : 'screen'}');
    notifyListeners();
  }

  void setToggleKey(int vk) {
    toggleKey = vk;
    _send('togglekey $vk');
    notifyListeners();
  }

  /// The window that is LocalRoll's (clicks on it are not drawing): the
  /// floating panel's when there is one.
  void own(int hwnd) => _send('own $hwnd');

  /// Start on this window's page.
  void page(int hwnd) => _send('page $hwnd');

  /// Recording one window: its marks stay its own, whichever window is in
  /// front (LocalRoll's bar, the panel). 0: free again.
  void lockPage(int hwnd) => _send('lock $hwnd');

  /// Words for the text tool's click ([textAt]); empty: none.
  void putText(String words) {
    final at = textAt;
    final edit = _textEdit;
    textAt = null;
    _textEdit = null;
    textWords = '';
    // New lines travel as U+2028 (the layer reads one command per line).
    final w = words.trim().replaceAll('\r', '').replaceAll('\n', '\u2028');
    if (at != null && w.isNotEmpty) _send(edit != null ? 'retext $edit $w' : 'text ${at.x} ${at.y} $w');
    notifyListeners();
  }

  /// The red frame around a recorded area (null: none).
  void border(Rect? r) => _send(r == null
      ? 'border off'
      : 'border ${r.left.round()} ${r.top.round()} ${r.width.round()} ${r.height.round()}');
}
