// apps/desktop/lib/ui/player/narration_dialogs.dart
import 'dart:async';
import 'dart:ui' show FontFeature;

import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../services/mic.dart';
import '../theme.dart';
import 'narration.dart';

String _len(int ms) {
  final d = Duration(milliseconds: ms);
  final s = (d.inSeconds % 60).toString().padLeft(2, '0');
  return d.inHours > 0 ? '${d.inHours}:${(d.inMinutes % 60).toString().padLeft(2, '0')}:$s' : '${d.inMinutes}:$s';
}

/// Choose the microphone (with a level to try it). Null: cancelled.
Future<String?> pickMicrophone(BuildContext context, MicRecorder mic, {String? current}) async {
  final names = await mic.devices();
  if (!context.mounted) return null;
  if (names.isEmpty) {
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('rec.no_mic')),
        content: SizedBox(width: 420, child: Text(tr('rec.no_mic_tip'))),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: Text(tr('common.close')))],
      ),
    );
    return null;
  }
  var chosen = names.contains(current) ? current! : names.first;
  return showDialog<String>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, set) => AlertDialog(
        title: Text(tr('rec.pick_mic')),
        content: SizedBox(
          width: 420,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            for (final n in names)
              RadioListTile<String>(
                value: n,
                // ignore: deprecated_member_use
                groupValue: chosen,
                // ignore: deprecated_member_use
                onChanged: (v) => set(() => chosen = v ?? chosen),
                title: Text(n, maxLines: 2, overflow: TextOverflow.ellipsis),
                contentPadding: EdgeInsets.zero,
              ),
            const SizedBox(height: 6),
            Text(tr('rec.pick_mic_tip'), style: const TextStyle(color: LrColors.muted, fontSize: 12.5)),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(tr('common.cancel'))),
          FilledButton(onPressed: () => Navigator.pop(ctx, chosen), child: Text(tr('common.ok'))),
        ],
      ),
    ),
  );
}

/// What to do with a finished recording.
enum RecordedChoice { save, saveSend, discard }

/// "The explanation is recorded (2:35)": save, save and send, or throw
/// away; and how the original's sound goes in.
Future<(RecordedChoice, OriginalSound)?> recordedDialog(BuildContext context, int lengthMs, OriginalSound sound, {bool again = false}) =>
    showDialog<(RecordedChoice, OriginalSound)>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        var s = sound;
        return StatefulBuilder(
          builder: (ctx, set) => AlertDialog(
            title: Text(tr(again ? 'rec.remake_title' : 'rec.done_title', {'time': _len(lengthMs)})),
            content: SizedBox(
              width: 440,
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(tr('rec.sound'), style: const TextStyle(color: LrColors.muted)),
                const SizedBox(height: 6),
                SegmentedButton<OriginalSound>(
                  showSelectedIcon: false,
                  segments: [
                    ButtonSegment(value: OriginalSound.quiet, label: Text(tr('rec.sound_quiet'))),
                    ButtonSegment(value: OriginalSound.none, label: Text(tr('rec.sound_none'))),
                    ButtonSegment(value: OriginalSound.full, label: Text(tr('rec.sound_full'))),
                  ],
                  selected: {s},
                  onSelectionChanged: (v) => set(() => s = v.first),
                ),
                const SizedBox(height: 10),
                Text(tr('rec.done_tip'), style: const TextStyle(color: LrColors.muted, fontSize: 12.5, height: 1.5)),
              ]),
            ),
            actions: [
              if (!again)
                TextButton(
                  onPressed: () => Navigator.pop(ctx, (RecordedChoice.discard, s)),
                  style: TextButton.styleFrom(foregroundColor: LrColors.danger),
                  child: Text(tr('rec.discard')),
                )
              else
                TextButton(onPressed: () => Navigator.pop(ctx), child: Text(tr('common.cancel'))),
              OutlinedButton(onPressed: () => Navigator.pop(ctx, (RecordedChoice.save, s)), child: Text(tr('clip.save'))),
              FilledButton.icon(
                onPressed: () => Navigator.pop(ctx, (RecordedChoice.saveSend, s)),
                icon: const Icon(Icons.send_rounded, size: 18),
                label: Text(tr('clip.save_send')),
              ),
            ],
          ),
        );
      },
    );

/// "Throw this explanation away?" — really (and the drawings too?).
/// Null: back.
Future<bool?> confirmDiscard(BuildContext context, {required bool drew}) => showDialog<bool>(
      context: context,
      builder: (ctx) {
        var ink = false;
        return StatefulBuilder(
          builder: (ctx, set) => AlertDialog(
            title: Text(tr('rec.discard_title')),
            content: SizedBox(
              width: 440,
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(tr('rec.discard_text'), style: const TextStyle(height: 1.5)),
                if (drew) ...[
                  const SizedBox(height: 10),
                  CheckboxListTile(
                    value: ink,
                    onChanged: (v) => set(() => ink = v ?? false),
                    contentPadding: EdgeInsets.zero,
                    controlAffinity: ListTileControlAffinity.leading,
                    title: Text(tr('rec.discard_ink')),
                    subtitle: Text(tr('rec.discard_ink_tip')),
                  ),
                ],
              ]),
            ),
            actions: [
              FilledButton(autofocus: true, onPressed: () => Navigator.pop(ctx), child: Text(tr('rec.back'))),
              TextButton(
                onPressed: () => Navigator.pop(ctx, ink),
                style: TextButton.styleFrom(foregroundColor: LrColors.danger),
                child: Text(tr('rec.discard_yes')),
              ),
            ],
          ),
        );
      },
    );

/// The bar on top while recording: time, how loud, pause / go on, stop.
class RecordingBar extends StatefulWidget {
  const RecordingBar({
    super.key,
    required this.elapsed,
    required this.paused,
    required this.level,
    required this.onPause,
    required this.onStop,
  });

  final int Function() elapsed;
  final bool paused;
  final double Function() level;
  final VoidCallback onPause;
  final VoidCallback onStop;

  @override
  State<RecordingBar> createState() => _RecordingBarState();
}

class _RecordingBarState extends State<RecordingBar> {
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(milliseconds: 100), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final lv = widget.paused ? 0.0 : widget.level();
    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      decoration: BoxDecoration(
        color: const Color(0xE6202020),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: widget.paused ? LrColors.muted : LrColors.danger),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(widget.paused ? Icons.pause_circle_filled_rounded : Icons.fiber_manual_record_rounded,
            color: widget.paused ? LrColors.muted : LrColors.danger, size: 18),
        const SizedBox(width: 8),
        Text(
          '${tr(widget.paused ? 'rec.paused' : 'rec.recording')}  ${_len(widget.elapsed())}',
          style: const TextStyle(color: Colors.white, fontFeatures: [FontFeature.tabularFigures()]),
        ),
        const SizedBox(width: 12),
        Tooltip(
          message: tr('rec.level'),
          child: Container(
            width: 80,
            height: 6,
            decoration: BoxDecoration(color: const Color(0x33FFFFFF), borderRadius: BorderRadius.circular(3)),
            alignment: Alignment.centerLeft,
            child: FractionallySizedBox(
              widthFactor: lv,
              child: Container(decoration: BoxDecoration(color: lv > 0.9 ? LrColors.danger : LrColors.verified, borderRadius: BorderRadius.circular(3))),
            ),
          ),
        ),
        const SizedBox(width: 8),
        IconButton(
          tooltip: tr(widget.paused ? 'rec.resume' : 'rec.pause'),
          onPressed: widget.onPause,
          icon: Icon(widget.paused ? Icons.play_arrow_rounded : Icons.pause_rounded, color: Colors.white, size: 20),
        ),
        FilledButton.icon(
          style: FilledButton.styleFrom(backgroundColor: LrColors.danger, foregroundColor: Colors.white, visualDensity: VisualDensity.compact),
          onPressed: widget.onStop,
          icon: const Icon(Icons.stop_rounded, size: 18),
          label: Text(tr('rec.stop')),
        ),
      ]),
    );
  }
}
