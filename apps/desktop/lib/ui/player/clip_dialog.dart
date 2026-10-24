// apps/desktop/lib/ui/player/clip_dialog.dart
import 'dart:math' as math;
import 'dart:ui' show FontFeature;

import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../theme.dart';

/// What was chosen for a clip.
typedef ClipChoice = ({int startMs, int endMs, bool withInk, bool send});

String _t(int ms) {
  final d = Duration(milliseconds: ms);
  final s = (d.inSeconds % 60).toString().padLeft(2, '0');
  return d.inHours > 0 ? '${d.inHours}:${(d.inMinutes % 60).toString().padLeft(2, '0')}:$s' : '${d.inMinutes}:$s';
}

/// Choose the start and end of a clip (a second at a time), and how:
/// with the drawings (re-encoded at the original's size) or as it is.
Future<ClipChoice?> showClipDialog(
  BuildContext context, {
  required int startMs,
  required int endMs,
  required int durationMs,
  bool hasInk = true,
  bool send = false,
}) =>
    showDialog<ClipChoice>(
      context: context,
      builder: (_) => _ClipDialog(startMs: startMs, endMs: endMs, durationMs: durationMs, hasInk: hasInk, send: send),
    );

class _ClipDialog extends StatefulWidget {
  const _ClipDialog({required this.startMs, required this.endMs, required this.durationMs, required this.hasInk, required this.send});

  final int startMs, endMs, durationMs;
  final bool hasInk, send;

  @override
  State<_ClipDialog> createState() => _ClipDialogState();
}

class _ClipDialogState extends State<_ClipDialog> {
  late int _a = widget.startMs.clamp(0, _max);
  late int _b = widget.endMs.clamp(_a + 1000, math.max(_a + 1000, _max));
  late bool _ink = widget.hasInk;

  int get _max => widget.durationMs > 0 ? widget.durationMs : 1 << 40;

  void _moveA(int d) => setState(() => _a = (_a + d).clamp(0, math.max(0, _b - 1000)));
  void _moveB(int d) => setState(() => _b = (_b + d).clamp(_a + 1000, _max));

  Widget _edge(String label, int ms, void Function(int) move) => Row(children: [
        SizedBox(width: 64, child: Text(label, style: const TextStyle(color: LrColors.muted))),
        for (final d in const [-5000, -1000])
          TextButton(onPressed: () => move(d), child: Text('${d ~/ 1000}s')),
        Container(
          width: 76,
          alignment: Alignment.center,
          child: Text(_t(ms), style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600, fontFeatures: [FontFeature.tabularFigures()])),
        ),
        for (final d in const [1000, 5000])
          TextButton(onPressed: () => move(d), child: Text('+${d ~/ 1000}s')),
      ]);

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text(tr('clip.title')),
        content: SizedBox(
          width: 440,
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            _edge(tr('clip.from'), _a, _moveA),
            _edge(tr('clip.to'), _b, _moveB),
            Padding(
              padding: const EdgeInsets.only(left: 64, top: 4, bottom: 12),
              child: Text(tr('clip.length', {'time': _t(_b - _a)}), style: const TextStyle(color: LrColors.muted)),
            ),
            RadioListTile<bool>(
              value: true,
              // ignore: deprecated_member_use
              groupValue: _ink,
              // ignore: deprecated_member_use
              onChanged: (v) => setState(() => _ink = v ?? true),
              contentPadding: EdgeInsets.zero,
              title: Text(tr('clip.with_ink')),
              subtitle: Text(tr('clip.with_ink_tip')),
            ),
            RadioListTile<bool>(
              value: false,
              // ignore: deprecated_member_use
              groupValue: _ink,
              // ignore: deprecated_member_use
              onChanged: (v) => setState(() => _ink = v ?? true),
              contentPadding: EdgeInsets.zero,
              title: Text(tr('clip.as_is')),
              subtitle: Text(tr('clip.as_is_tip')),
            ),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: Text(tr('common.cancel'))),
          if (widget.send)
            OutlinedButton(
              onPressed: () => Navigator.pop(context, (startMs: _a, endMs: _b, withInk: _ink, send: false)),
              child: Text(tr('clip.save')),
            ),
          FilledButton.icon(
            onPressed: () => Navigator.pop(context, (startMs: _a, endMs: _b, withInk: _ink, send: widget.send)),
            icon: Icon(widget.send ? Icons.send_rounded : Icons.movie_creation_rounded, size: 18),
            label: Text(tr(widget.send ? 'clip.save_send' : 'clip.save')),
          ),
          if (!widget.send)
            TextButton(
              onPressed: () => Navigator.pop(context, (startMs: _a, endMs: _b, withInk: _ink, send: true)),
              child: Text(tr('clip.save_send')),
            ),
        ],
      );
}

/// The seconds before / after an annotation that its clip takes (0–60).
Future<(int, int)?> showClipAroundDialog(BuildContext context, int before, int after) => showDialog<(int, int)>(
      context: context,
      builder: (ctx) {
        var b = before.toDouble(), a = after.toDouble();
        return StatefulBuilder(
          builder: (ctx, set) => AlertDialog(
            title: Text(tr('clip.around')),
            content: SizedBox(
              width: 400,
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Row(children: [
                  SizedBox(width: 110, child: Text(tr('clip.before'))),
                  Expanded(child: Slider(value: b, max: 60, divisions: 60, label: '${b.round()}s', onChanged: (v) => set(() => b = v))),
                  SizedBox(width: 44, child: Text('${b.round()}s')),
                ]),
                Row(children: [
                  SizedBox(width: 110, child: Text(tr('clip.after'))),
                  Expanded(child: Slider(value: a, max: 60, divisions: 60, label: '${a.round()}s', onChanged: (v) => set(() => a = v))),
                  SizedBox(width: 44, child: Text('${a.round()}s')),
                ]),
              ]),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx), child: Text(tr('common.cancel'))),
              FilledButton(onPressed: () => Navigator.pop(ctx, (b.round(), a.round())), child: Text(tr('common.ok'))),
            ],
          ),
        );
      },
    );
