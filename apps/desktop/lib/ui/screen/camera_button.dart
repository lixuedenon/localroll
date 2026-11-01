// apps/desktop/lib/ui/screen/camera_button.dart
import 'dart:async';

import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../services/camera_bubble.dart';
import '../../services/player_memory.dart';
import '../theme.dart';

/// The camera on / off (the bubble), on the recording bars. With [menu]:
/// which camera, its size, round / square, mirrored.
class CameraButton extends StatefulWidget {
  const CameraButton({super.key, required this.memory, this.menu = true});

  final PlayerMemory memory;
  final bool menu;

  @override
  State<CameraButton> createState() => _CameraButtonState();
}

class _CameraButtonState extends State<CameraButton> {
  final CameraBubble _b = CameraBubble.instance;

  @override
  void initState() {
    super.initState();
    _b.addListener(_changed);
    widget.memory.addListener(_changed);
  }

  @override
  void dispose() {
    _b.removeListener(_changed);
    widget.memory.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> _toggle() async {
    final m = widget.memory;
    m.setCamera(on: !m.cameraOn);
    await _b.sync();
    if (!mounted) return;
    final p = _b.problem;
    if (m.cameraOn || p == null) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(tr(p == 'nocamera' ? 'cam.none' : 'cam.failed'))));
  }

  Future<void> _menu(BuildContext context) async {
    final m = widget.memory;
    final names = await _b.cameras();
    if (!context.mounted) return;
    final box = context.findRenderObject() as RenderBox?;
    if (box == null) return;
    final at = box.localToGlobal(Offset.zero);
    final v = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(at.dx, at.dy + box.size.height, at.dx + box.size.width, at.dy),
      items: [
        if (names.isEmpty) PopupMenuItem(enabled: false, child: Text(tr('cam.none'))),
        for (final n in names)
          CheckedPopupMenuItem(value: 'cam:$n', checked: n == m.camera || (m.camera == null && n == names.first), child: Text(n)),
        const PopupMenuDivider(),
        for (var k = 0; k < 3; k++)
          CheckedPopupMenuItem(value: 'size:$k', checked: m.cameraSize == k, child: Text(tr(['cam.small', 'cam.medium', 'cam.large'][k]))),
        const PopupMenuDivider(),
        CheckedPopupMenuItem(value: 'round', checked: m.cameraRound, child: Text(tr('cam.round'))),
        CheckedPopupMenuItem(value: 'square', checked: !m.cameraRound, child: Text(tr('cam.square'))),
        CheckedPopupMenuItem(value: 'mirror', checked: m.cameraMirror, child: Text(tr('cam.mirror'))),
      ],
    );
    if (v == null) return;
    if (v.startsWith('cam:')) {
      final n = v.substring(4);
      if (n == m.camera) return;
      m.setCamera(name: n);
      // Another camera: shown again with it.
      if (_b.showing) {
        await _b.quit();
        await _b.sync();
      }
    } else if (v.startsWith('size:')) {
      m.setCamera(size: int.parse(v.substring(5)));
      await _b.sync();
    } else if (v == 'round' || v == 'square') {
      m.setCamera(round: v == 'round');
      if (_b.showing) _b.setRound(v == 'round');
    } else if (v == 'mirror') {
      m.setCamera(mirror: !m.cameraMirror);
      await _b.sync();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!CameraBubble.available) return const SizedBox.shrink();
    final on = widget.memory.cameraOn;
    return Padding(
      padding: const EdgeInsets.only(left: 6),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Tooltip(
          message: tr(on ? 'cam.off' : 'cam.on'),
          child: IconButton(
            visualDensity: VisualDensity.compact,
            isSelected: on,
            color: Colors.white,
            selectedIcon: const Icon(Icons.videocam_rounded, color: LrColors.safelight),
            icon: const Icon(Icons.videocam_off_rounded, color: Colors.white70),
            onPressed: () => unawaited(_toggle()),
          ),
        ),
        if (widget.menu)
          Builder(
            builder: (context) => IconButton(
              visualDensity: VisualDensity.compact,
              tooltip: tr('cam.options'),
              icon: const Icon(Icons.arrow_drop_down_rounded, color: Colors.white70),
              onPressed: () => unawaited(_menu(context)),
            ),
          ),
      ]),
    );
  }
}

/// The camera in the "record the screen" dialog: on, which one, size, mirrored.
class CameraOptions extends StatefulWidget {
  const CameraOptions({super.key, required this.memory});

  final PlayerMemory memory;

  @override
  State<CameraOptions> createState() => _CameraOptionsState();
}

class _CameraOptionsState extends State<CameraOptions> {
  List<String>? _names;

  @override
  void initState() {
    super.initState();
    if (widget.memory.cameraOn) unawaited(_load());
  }

  Future<void> _load() async {
    final n = await CameraBubble.instance.cameras();
    // Only listing: the helper is not kept running.
    if (!CameraBubble.instance.showing) await CameraBubble.instance.quit();
    if (mounted) setState(() => _names = n);
  }

  @override
  Widget build(BuildContext context) {
    if (!CameraBubble.available) return const SizedBox.shrink();
    final m = widget.memory;
    final names = _names;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        dense: true,
        value: m.cameraOn,
        onChanged: (v) {
          setState(() => m.setCamera(on: v));
          if (v && _names == null) unawaited(_load());
        },
        title: Text(tr('cam.title')),
        subtitle: Text(tr('cam.tip'), style: const TextStyle(fontSize: 12)),
      ),
      if (m.cameraOn)
        Wrap(spacing: 12, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
          if (names == null)
            const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
          else if (names.isEmpty)
            Text(tr('cam.none'), style: const TextStyle(color: LrColors.danger))
          else
            DropdownButton<String>(
              value: names.contains(m.camera) ? m.camera : names.first,
              items: [for (final n in names) DropdownMenuItem(value: n, child: Text(n))],
              onChanged: (v) => setState(() => m.setCamera(name: v)),
            ),
          SegmentedButton<int>(
            showSelectedIcon: false,
            segments: [for (var k = 0; k < 3; k++) ButtonSegment(value: k, label: Text(tr(['cam.small', 'cam.medium', 'cam.large'][k])))],
            selected: {m.cameraSize},
            onSelectionChanged: (v) => setState(() => m.setCamera(size: v.first)),
          ),
          SegmentedButton<bool>(
            showSelectedIcon: false,
            segments: [
              ButtonSegment(value: true, label: Text(tr('cam.round'))),
              ButtonSegment(value: false, label: Text(tr('cam.square'))),
            ],
            selected: {m.cameraRound},
            onSelectionChanged: (v) => setState(() => m.setCamera(round: v.first)),
          ),
          FilterChip(
            label: Text(tr('cam.mirror')),
            selected: m.cameraMirror,
            onSelected: (v) => setState(() => m.setCamera(mirror: v)),
          ),
        ]),
    ]);
  }
}
