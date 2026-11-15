// apps/desktop/lib/services/bg_tasks.dart
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:localroll_core/localroll_core.dart';

/// What a background task is doing.
enum BgState { queued, running, done, failed, cancelled }

/// One long job (making a recording, a clip, a PDF…). It runs on whatever
/// page is open; its card can be put aside and the app used meanwhile.
class BgTask {
  BgTask._(this.id, this.title, {required this.heavy, this.open});

  final int id;
  final String title;

  /// Video work (encoding): one at a time, the others wait their turn.
  final bool heavy;

  /// "Show it": where the result can be seen (null: no button).
  final VoidCallback? open;

  BgState state = BgState.queued;

  /// 0..1; 0 or less: not known (a moving bar).
  double progress = 0;

  /// Stops the work (set by the job; null: it can't be stopped).
  VoidCallback? onCancel;

  bool get over => state == BgState.done || state == BgState.failed || state == BgState.cancelled;

  Completer<void>? _turn;
  bool _cancelled = false;

  void setProgress(double p) {
    // Not more often than every percent: every listener repaints.
    if ((p - progress).abs() < 0.01 && p < 1) return;
    progress = p;
    BgTasks.instance._changed();
  }

  void cancel() {
    if (over) return;
    _cancelled = true;
    if (state == BgState.queued) {
      final turn = _turn;
      if (turn != null && !turn.isCompleted) turn.complete();
    } else {
      onCancel?.call();
    }
    BgTasks.instance._changed();
  }
}

/// The background jobs: never one that holds the whole app. Each starts
/// with its card in the middle; a click anywhere else (or another page /
/// dialog opening) puts it aside to the corner card, where it goes on and
/// says when it is done.
class BgTasks extends ChangeNotifier {
  BgTasks._();

  static final BgTasks instance = BgTasks._();

  final List<BgTask> tasks = [];

  /// The one shown in the middle (null: all aside), and since when.
  BgTask? focused;
  DateTime? focusedAt;

  int _next = 1;

  /// Running or waiting.
  int get busy => tasks.where((t) => !t.over).length;

  /// Shown in the corner card: going, waiting, or done while put aside.
  List<BgTask> get listed => [for (final t in tasks) if (t != focused) t];

  void _changed() => notifyListeners();

  /// The middle card goes to the corner.
  void putAside() {
    if (focused == null) return;
    focused = null;
    notifyListeners();
  }

  /// A done one's line in the corner card goes.
  void dismiss(BgTask t) {
    if (!t.over) return;
    tasks.remove(t);
    notifyListeners();
  }

  /// Runs [job] as a background task. Null when it was cancelled while
  /// waiting its turn. Errors are passed on (after the task shows failed).
  /// [ok]: whether the result counts as done (else "failed").
  Future<T?> run<T>({
    required String title,
    required Future<T> Function(BgTask t) job,
    bool heavy = false,
    VoidCallback? open,
    bool Function(T result)? ok,
  }) async {
    final t = BgTask._(_next++, title, heavy: heavy, open: open);
    tasks.add(t);
    // Old finished lines: only the last few stay.
    final old = [for (final x in tasks) if (x.over) x];
    if (old.length > 4) tasks.removeWhere((x) => old.take(old.length - 4).contains(x));
    focused = t;
    focusedAt = DateTime.now();
    notifyListeners();
    DiagLog.log('task', 'start: ${heavy ? 'video' : 'light'}');
    try {
      if (heavy) {
        // One video job at a time.
        while (tasks.any((x) => x != t && x.heavy && x.state == BgState.running)) {
          final turn = t._turn = Completer<void>();
          await turn.future;
          if (t._cancelled) break;
        }
      }
      if (t._cancelled) {
        _finish(t, BgState.cancelled);
        return null;
      }
      t.state = BgState.running;
      notifyListeners();
      final r = await job(t);
      _finish(t, t._cancelled ? BgState.cancelled : ((ok?.call(r) ?? true) ? BgState.done : BgState.failed));
      return r;
    } catch (e) {
      DiagLog.log('task', 'failed: $e');
      _finish(t, t._cancelled ? BgState.cancelled : BgState.failed);
      rethrow;
    }
  }

  void _finish(BgTask t, BgState s) {
    t.state = s;
    t.progress = 1;
    DiagLog.log('task', 'end: ${s.name}${focused == t ? '' : ' (aside)'}');
    // Still in the middle: the page shows the result as before; the task
    // just goes. Put aside: its line stays in the corner card ("done").
    if (focused == t) {
      focused = null;
      tasks.remove(t);
    } else if (s == BgState.cancelled) {
      tasks.remove(t);
    }
    // The next video job's turn.
    for (final x in tasks) {
      final turn = x._turn;
      if (x.heavy && x.state == BgState.queued && turn != null && !turn.isCompleted) {
        turn.complete();
        break;
      }
    }
    notifyListeners();
  }
}
