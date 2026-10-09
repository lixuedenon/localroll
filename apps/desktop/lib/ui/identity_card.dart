// apps/desktop/lib/ui/identity_card.dart
import 'dart:math';
import 'dart:ui' as ui;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:localroll_core/localroll_core.dart';

import '../app_services.dart';
import '../l10n/l10n.dart';
import '../services/settings.dart';
import 'device_badge.dart';
import 'theme.dart';

/// "This PC" in Settings: how phones see this computer — name, icon, colour
/// or own picture. Name: keep the computer's name, type one, or roll a
/// random one; look: random, pick from the set, or use a picture.
class IdentityCard extends StatefulWidget {
  const IdentityCard({super.key, required this.services});

  final AppServices services;

  @override
  State<IdentityCard> createState() => _IdentityCardState();
}

class _IdentityCardState extends State<IdentityCard> {
  late final TextEditingController _name =
      TextEditingController(text: widget.services.settings.deviceName);
  bool _busy = false;

  AppSettings get _s => widget.services.settings;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _apply({String? name, String? icon, int? color, Uint8List? png, bool removePng = false}) async {
    setState(() => _busy = true);
    try {
      if (png != null || removePng) await FileImage(_s.avatarFile).evict();
      await widget.services.updateIdentity(
        name: name,
        icon: icon,
        color: color,
        avatarPng: png,
        removeAvatar: removePng,
      );
      if (name != null) _name.text = _s.deviceName;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _pickPicture() async {
    final file = await openFile(acceptedTypeGroups: const [
      XTypeGroup(label: 'Images', extensions: ['jpg', 'jpeg', 'png', 'webp', 'bmp', 'gif']),
    ]);
    if (file == null) return;
    final png = await squareAvatarPng(await file.readAsBytes());
    if (png == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('identity.picture_error'))));
      }
      return;
    }
    await _apply(png: png);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasPicture = _s.avatarVersion != 0;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Live preview, as phones will see it.
            Row(
              children: [
                DeviceBadge(
                  icon: _s.iconKey,
                  color: _s.colorValue,
                  image: hasPicture ? FileImage(_s.avatarFile) : null,
                  size: 72,
                ),
                const SizedBox(width: 18),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(_s.deviceName, style: theme.textTheme.headlineSmall),
                      const SizedBox(height: 4),
                      Text(tr('identity.preview_hint'), style: theme.textTheme.bodySmall),
                    ],
                  ),
                ),
                if (_busy) const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
              ],
            ),
            const SizedBox(height: 24),

            // Name.
            Text(tr('identity.name'), style: theme.textTheme.titleMedium),
            const SizedBox(height: 10),
            Row(children: [
              Expanded(
                child: TextField(
                  controller: _name,
                  maxLength: 40,
                  decoration: const InputDecoration(counterText: ''),
                  onSubmitted: (v) => _apply(name: v),
                ),
              ),
              const SizedBox(width: 10),
              FilledButton(onPressed: () => _apply(name: _name.text), child: Text(tr('common.save'))),
            ]),
            const SizedBox(height: 10),
            Wrap(spacing: 8, runSpacing: 8, children: [
              OutlinedButton.icon(
                onPressed: () => _apply(name: AppSettings.originalName),
                icon: const Icon(Icons.computer_rounded, size: 18),
                label: Text(tr('identity.use_pc_name', {'name': AppSettings.originalName})),
              ),
              OutlinedButton.icon(
                onPressed: () => _apply(name: DeviceNames.random(translator.language)),
                icon: const Icon(Icons.casino_rounded, size: 18),
                label: Text(tr('identity.random_name')),
              ),
            ]),
            const SizedBox(height: 28),

            // Look.
            Text(tr('identity.look'), style: theme.textTheme.titleMedium),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final k in DeviceLook.icons)
                  _Choice(
                    selected: !hasPicture && k == _s.iconKey,
                    onTap: () => _apply(icon: k, removePng: hasPicture),
                    child: Icon(deviceIcon(k), color: Color(_s.colorValue)),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 10,
              children: [
                for (final c in DeviceLook.colors)
                  _Choice(
                    selected: c == _s.colorValue,
                    round: true,
                    onTap: () => _apply(color: c),
                    child: Container(
                      width: 22,
                      height: 22,
                      decoration: BoxDecoration(color: Color(c), shape: BoxShape.circle),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 16),
            Wrap(spacing: 8, runSpacing: 8, children: [
              OutlinedButton.icon(
                onPressed: () {
                  final r = Random();
                  _apply(icon: DeviceLook.randomIcon(r), color: DeviceLook.randomColor(r), removePng: hasPicture);
                },
                icon: const Icon(Icons.shuffle_rounded, size: 18),
                label: Text(tr('identity.random_look')),
              ),
              OutlinedButton.icon(
                onPressed: _pickPicture,
                icon: const Icon(Icons.add_photo_alternate_rounded, size: 18),
                label: Text(tr('identity.use_picture')),
              ),
              if (hasPicture)
                TextButton(onPressed: () => _apply(removePng: true), child: Text(tr('identity.remove_picture'))),
            ]),
          ],
        ),
      ),
    );
  }
}

class _Choice extends StatelessWidget {
  const _Choice({required this.selected, required this.onTap, required this.child, this.round = false});

  final bool selected;
  final VoidCallback onTap;
  final Widget child;
  final bool round;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      customBorder: round ? const CircleBorder() : RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      child: Container(
        width: round ? 34 : 44,
        height: round ? 34 : 44,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          shape: round ? BoxShape.circle : BoxShape.rectangle,
          borderRadius: round ? null : BorderRadius.circular(10),
          color: selected ? LrColors.raised : Colors.transparent,
          border: Border.all(color: selected ? LrColors.safelight : LrColors.line, width: selected ? 2 : 1),
        ),
        child: child,
      ),
    );
  }
}

/// Centre-crops a picture to a square and scales it to [size] px PNG.
Future<Uint8List?> squareAvatarPng(Uint8List bytes, {int size = 256}) async {
  try {
    final codec = await ui.instantiateImageCodec(bytes);
    final img = (await codec.getNextFrame()).image;
    final side = min(img.width, img.height).toDouble();
    final src = Rect.fromLTWH((img.width - side) / 2, (img.height - side) / 2, side, side);
    final recorder = ui.PictureRecorder();
    Canvas(recorder).drawImageRect(
      img,
      src,
      Rect.fromLTWH(0, 0, size.toDouble(), size.toDouble()),
      Paint()..filterQuality = FilterQuality.high,
    );
    final out = await recorder.endRecording().toImage(size, size);
    final data = await out.toByteData(format: ui.ImageByteFormat.png);
    return data?.buffer.asUint8List();
  } catch (_) {
    return null;
  }
}
