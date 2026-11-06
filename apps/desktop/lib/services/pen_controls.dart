// apps/desktop/lib/services/pen_controls.dart
import 'dart:ui' show Color;

import 'package:flutter/foundation.dart';
import 'package:localroll_ink/localroll_ink.dart' show CandleKind, StampShape;

/// What the pen's toolbar shows and does. The pen itself
/// ([PenOverlay]) in LocalRoll; in the floating panel (its own small
/// window) a stand-in that passes everything on to LocalRoll.
abstract class PenControls implements Listenable {
  bool get draw;
  String get tool;
  Color get color;
  int get level;
  bool get canUndo;
  bool get canRedo;
  bool get selected;
  bool get hasNumbers;
  int get sheet;
  int get sheets;
  int get board;
  bool get highlight;
  bool get fade;
  bool get autoReturn;
  bool get penDraws;
  int get toggleKey;
  bool get perWindow;
  ({int x, int y})? get textAt;

  void setDraw(bool on);
  void setTool(String t);
  Future<void> setStamp(StampShape shape);
  void setCandle(int up, int down, CandleKind kind);
  void setColor(Color c);
  void setLevel(int l);
  void undo();
  void redo();
  void clearPage();
  void deleteSelected();
  void renumber();
  void newPage();
  void prevPage();
  void nextPage();
  void setBoard(int b);
  void setHighlight(bool on);
  void setFade(bool on);
  void setAutoReturn(bool on);
  void setPenDraws(bool on);
  void setPerWindow(bool on);
  void setToggleKey(int vk);
  void putText(String words);
}
