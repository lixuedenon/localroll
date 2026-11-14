// apps/desktop/lib/ui/stamps/candle_panel.dart
import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../services/annotations.dart';
import '../../services/stamp_library.dart';
import '../player/ink_editor.dart';
import '../theme.dart';
import 'stamp_picker.dart';
import '../lr_dialog.dart';

/// What was chosen in the candle panel: a kind to draw by hand, or a
/// ready-made candle / pattern to place.
typedef CandlePick = ({CandleKind? kind, PickedStamp? stamp});

/// Choose, then draw on the picture being drawn on.
Future<void> pickCandleInto(BuildContext context, InkEditor editor) async {
  final r = await showCandlePanel(context);
  if (r == null) return;
  final lib = StampLibrary.instance;
  editor
    ..upColor = lib.upColor
    ..downColor = lib.downColor;
  if (r.stamp != null) {
    editor.setStamp(r.stamp!.shape, r.stamp!.name);
  } else {
    editor.candleKind = r.kind ?? CandleKind.normal;
    editor.setTool(EditTool.candle);
  }
}

/// Candles (K lines): how to draw them by hand, single candles rising and
/// falling, patterns, and the rising / falling colours.
Future<CandlePick?> showCandlePanel(BuildContext context) => showLrDialog<CandlePick>(context: context, builder: (_) => const _CandlePanel());

class _CandlePanel extends StatefulWidget {
  const _CandlePanel();

  @override
  State<_CandlePanel> createState() => _CandlePanelState();
}

class _CandlePanelState extends State<_CandlePanel> {
  final StampLibrary _lib = StampLibrary.instance;

  static const _kinds = {
    CandleKind.normal: [(0.3, 0.7, 0.8, 0.2)],
    CandleKind.longUpper: [(0.15, 0.35, 0.95, 0.1)],
    CandleKind.longLower: [(0.65, 0.85, 0.9, 0.05)],
    CandleKind.bald: [(0.2, 0.8, 0.8, 0.2)],
    CandleKind.doji: [(0.5, 0.505, 0.85, 0.15)],
  };

  void _stamp(String id) {
    final s = StampPacks.byId(id);
    if (s == null) return;
    _lib.used(id);
    Navigator.pop(context, (kind: null, stamp: (id: id, shape: s.shape.resolved(_lib.upColor, _lib.downColor), name: stampName(id))));
  }

  Widget _tile(StampShape shape, String label, VoidCallback onTap, {bool on = false}) {
    final sh = shape.resolved(_lib.upColor, _lib.downColor);
    return Tooltip(
      message: label,
      waitDuration: const Duration(milliseconds: 500),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onTap,
        child: Container(
          width: 84,
          height: 84,
          padding: const EdgeInsets.all(6),
          decoration: BoxDecoration(
            color: const Color(0x14FFFFFF),
            borderRadius: BorderRadius.circular(8),
            border: on ? Border.all(color: LrColors.safelight, width: 2) : null,
          ),
          child: Column(children: [
            Expanded(child: CustomPaint(painter: StampTile(sh), size: Size.infinite)),
            const SizedBox(height: 3),
            Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11)),
          ]),
        ),
      ),
    );
  }

  Widget _title(String t) => Padding(
        padding: const EdgeInsets.only(top: 12, bottom: 6),
        child: Text(t, style: const TextStyle(color: LrColors.muted, fontWeight: FontWeight.w600)),
      );

  Widget _colors(String label, int now, void Function(int) set) => Row(children: [
        SizedBox(width: 92, child: Text(label)),
        for (final c in inkColors)
          InkWell(
            onTap: () => setState(() => set(c.toARGB32())),
            child: Container(
              width: 24,
              height: 24,
              margin: const EdgeInsets.only(right: 6),
              decoration: BoxDecoration(
                color: c,
                shape: BoxShape.circle,
                border: Border.all(color: c.toARGB32() == now ? Colors.white : Colors.white24, width: c.toARGB32() == now ? 3 : 1),
              ),
            ),
          ),
      ]);

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(tr('candle.title')),
      content: SizedBox(
        width: 700,
        child: SingleChildScrollView(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            _title(tr('candle.draw')),
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (final e in _kinds.entries)
                _tile(Candles.pattern(e.value, role: 'u'), tr('candle.kind_${e.key.name}'), () {
                  _lib.setKind(e.key);
                  Navigator.pop(context, (kind: e.key, stamp: null));
                },
                    on: _lib.kind == e.key),
            ]),
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(tr('stamp.candle_tip'), style: const TextStyle(color: LrColors.muted, fontSize: 12)),
            ),
            _title(tr('candle.singles')),
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (final id in StampPacks.singles)
                for (final end in const ['_up', '_down'])
                  if (StampPacks.byId('$id$end') case final s?) _tile(s.shape, stampName(s.id), () => _stamp(s.id)),
            ]),
            _title(tr('candle.patterns')),
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (final id in StampPacks.patterns)
                if (StampPacks.byId(id) case final s?) _tile(s.shape, stampName(s.id), () => _stamp(s.id)),
            ]),
            _title(tr('stamp.colors')),
            _colors(tr('candle.up_color'), _lib.upColor, (c) => _lib.setColors(up: c)),
            const SizedBox(height: 8),
            _colors(tr('candle.down_color'), _lib.downColor, (c) => _lib.setColors(down: c)),
            const SizedBox(height: 8),
            Wrap(spacing: 8, children: [
              OutlinedButton(onPressed: () => setState(() => _lib.setRedUp(false)), child: Text(tr('stamp.green_up'))),
              OutlinedButton(onPressed: () => setState(() => _lib.setRedUp(true)), child: Text(tr('stamp.red_up'))),
            ]),
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(tr('candle.one_tip'), style: const TextStyle(color: LrColors.muted, fontSize: 12)),
            ),
          ]),
        ),
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: Text(tr('common.cancel')))],
    );
  }
}
