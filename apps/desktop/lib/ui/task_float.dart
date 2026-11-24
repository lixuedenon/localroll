// apps/desktop/lib/ui/task_float.dart
import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import '../services/bg_tasks.dart';
import 'app_nav.dart';
import 'light_look.dart';

/// A long job just started: its card in the middle, like a dialog, but the
/// rest of the app is not blocked. A click anywhere else (that click still
/// does what it does), another section, page or dialog: the card goes to
/// the corner and the job goes on there.
class TaskFloat extends StatefulWidget {
  const TaskFloat({super.key});

  @override
  State<TaskFloat> createState() => _TaskFloatState();
}

class _TaskFloatState extends State<TaskFloat> {
  BgTasks get b => BgTasks.instance;

  @override
  void initState() {
    super.initState();
    AppNav.instance.wentElsewhere.addListener(_elsewhere);
  }

  @override
  void dispose() {
    AppNav.instance.wentElsewhere.removeListener(_elsewhere);
    super.dispose();
  }

  void _elsewhere() {
    final at = AppNav.instance.wentElsewhere.value, since = b.focusedAt;
    if (at != null && since != null && at.isAfter(since)) b.putAside();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: Listenable.merge([b, AppNav.instance.fullscreen]),
        builder: (context, _) {
          final t = b.focused;
          if (t == null || AppNav.instance.fullscreen.value) return const SizedBox.shrink();
          return Positioned.fill(
            child: Stack(children: [
              // Everywhere but the card: put aside, and the click goes on
              // to whatever is there (translucent: not swallowed).
              Positioned.fill(
                child: Listener(behavior: HitTestBehavior.translucent, onPointerDown: (_) => b.putAside()),
              ),
              Center(
                child: Material(
                  type: MaterialType.transparency,
                  child: Theme(data: LightLook.theme(Theme.of(context)), child: _card(t)),
                ),
              ),
            ]),
          );
        },
      );

  Widget _card(BgTask t) {
    final queued = t.state == BgState.queued;
    final p = t.progress;
    return Container(
      width: 420,
      padding: const EdgeInsets.fromLTRB(24, 20, 16, 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: const Color(0xFFE3E8F2)),
        boxShadow: const [BoxShadow(color: Color(0x401F3B70), blurRadius: 30, offset: Offset(0, 12))],
      ),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(t.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: LightLook.text)),
        const SizedBox(height: 16),
        if (!t.still) Padding(
          padding: const EdgeInsets.only(right: 8),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(5),
            child: LinearProgressIndicator(
              value: queued || p <= 0 ? null : p,
              minHeight: 7,
              backgroundColor: const Color(0xFFE8EEF8),
              color: LightLook.blue,
            ),
          ),
        ),
        const SizedBox(height: 8),
        Text(t.still ? (t.note ?? '') : (queued ? tr('task.queued') : (p > 0 ? '${(p * 100).round()}%' : tr('task.working'))),
            style: const TextStyle(color: LightLook.muted, fontSize: 13)),
        const SizedBox(height: 10),
        Row(children: [
          Expanded(child: Text(tr('task.hint'), style: const TextStyle(color: LightLook.muted, fontSize: 12))),
          if (t.onCancel != null || queued) TextButton(onPressed: t.cancel, child: Text(tr('common.cancel'))),
        ]),
      ]),
    );
  }
}
