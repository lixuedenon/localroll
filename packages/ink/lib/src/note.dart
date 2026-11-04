// packages/ink/lib/src/note.dart
import 'dart:math' as math;

import 'ink_mark.dart';

/// One annotation: marks drawn together, with a name. On a video it starts
/// at [startMs] (marks drawn while it played appear at their own time) and
/// stays [holdMs] after the last one.
class Note {
  Note({
    required this.id,
    required this.name,
    required this.inks,
    this.startMs = 0,
    this.holdMs = defaultHoldMs,
    this.narration = false,
    int? createdMs,
    int? modifiedMs,
  })  : createdMs = createdMs ?? DateTime.now().millisecondsSinceEpoch,
        modifiedMs = modifiedMs ?? DateTime.now().millisecondsSinceEpoch;

  static const int defaultHoldMs = 3000;

  final String id;
  String name;

  /// Drawn while recording an explanation.
  final bool narration;
  List<InkMark> inks;
  int startMs;
  int holdMs;
  final int createdMs;
  int modifiedMs;

  int get lastMs => inks.fold(startMs, (m, i) => math.max(m, (i.atMs ?? startMs) + (i.live ? i.drawMs : 0)));

  /// Moments where it was drawn while paused: playing stops there and the
  /// drawing is shown again, as it was drawn.
  List<FreezePlan> get freezes {
    final groups = <int, List<InkMark>>{};
    for (final i in inks) {
      if (i.live || i.atMs == null) continue;
      final at = groups.keys.firstWhere((k) => (k - i.atMs!).abs() <= 150, orElse: () => i.atMs!);
      (groups[at] ??= []).add(i);
    }
    return [for (final e in groups.entries) FreezePlan(noteId: id, atMs: e.key, inks: e.value, holdMs: holdMs)]
      ..sort((a, b) => a.atMs.compareTo(b.atMs));
  }
  int get endMs => lastMs + holdMs;

  /// Shown at [ms] (videos).
  bool shownAt(int ms) => ms >= startMs && ms <= endMs;

  /// [ink] shown at [ms] (it appears when it was drawn).
  bool inkShownAt(InkMark ink, int ms) => ms >= (ink.atMs ?? startMs) && ms <= endMs;

  /// Typed words, for search.
  String get words => [name, for (final i in inks) ?i.text].join(' ');

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'start': startMs,
        'hold': holdMs,
        if (narration) 'narration': true,
        'created': createdMs,
        'modified': modifiedMs,
        'inks': [for (final i in inks) i.toJson()],
      };

  static Note fromJson(Map<String, dynamic> j) => Note(
        id: j['id'] as String? ?? InkMark.newId(),
        name: j['name'] as String? ?? '',
        startMs: (j['start'] as num?)?.toInt() ?? 0,
        holdMs: (j['hold'] as num?)?.toInt() ?? defaultHoldMs,
        narration: j['narration'] == true,
        createdMs: (j['created'] as num?)?.toInt(),
        modifiedMs: (j['modified'] as num?)?.toInt(),
        inks: [for (final i in (j['inks'] as List?) ?? const []) if (i is Map<String, dynamic>) InkMark.fromJson(i)],
      );
}

/// Replaying what was drawn while the video was paused: the video stops
/// at [atMs], the marks are drawn again at their own pace (long thinking
/// gaps shortened), then it stays [holdMs] and plays on.
class FreezePlan {
  FreezePlan({required this.noteId, required this.atMs, required List<InkMark> inks, required this.holdMs}) {
    final sorted = List.of(inks)..sort((a, b) => (a.wallMs ?? 0).compareTo(b.wallMs ?? 0));
    var t = 0;
    int? lastEnd;
    for (final i in sorted) {
      final w = i.wallMs;
      if (w == null) {
        // Drawn before replays were recorded: all at once.
        start[i.id] = 0;
        continue;
      }
      if (lastEnd != null) t += math.min(math.max(0, w - lastEnd), maxGapMs);
      start[i.id] = t;
      t += i.drawMs;
      lastEnd = w + i.drawMs;
    }
    drawMs = t;
  }

  /// Pauses between marks longer than this are cut to it.
  static const int maxGapMs = 600;

  final String noteId;
  final int atMs;
  final int holdMs;

  /// When each mark starts in the replay (ms).
  final Map<String, int> start = {};
  late final int drawMs;

  /// The whole stop: drawing, then the hold.
  int get totalMs => drawMs + holdMs;
}
