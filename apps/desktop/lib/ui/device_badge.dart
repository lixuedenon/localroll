// apps/desktop/lib/ui/device_badge.dart
import 'package:flutter/material.dart';

import 'theme.dart';

/// Icon for a DeviceLook.icons key.
IconData deviceIcon(String? key) => switch (key) {
      'laptop' => Icons.laptop_rounded,
      'home' => Icons.home_rounded,
      'work' => Icons.work_rounded,
      'sofa' => Icons.weekend_rounded,
      'study' => Icons.menu_book_rounded,
      'bed' => Icons.bed_rounded,
      'tv' => Icons.tv_rounded,
      'star' => Icons.star_rounded,
      'camera' => Icons.photo_camera_rounded,
      'mountain' => Icons.landscape_rounded,
      'sun' => Icons.wb_sunny_rounded,
      'palette' => Icons.palette_rounded,
      'music' => Icons.music_note_rounded,
      'plant' => Icons.local_florist_rounded,
      'rocket' => Icons.rocket_launch_rounded,
      'phone' => Icons.phone_iphone_rounded,
      _ => Icons.desktop_windows_rounded,
    };

/// Round badge: the custom picture if there is one, else a coloured icon.
class DeviceBadge extends StatelessWidget {
  const DeviceBadge({super.key, this.icon, this.color, this.image, this.size = 48});

  final String? icon;
  final int? color;
  final ImageProvider? image;
  final double size;

  @override
  Widget build(BuildContext context) {
    final c = Color(color ?? LrColors.safelight.toARGB32());
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: c.withValues(alpha: 0.16),
        border: Border.all(color: c, width: size > 40 ? 2 : 1.5),
        boxShadow: [BoxShadow(color: c.withValues(alpha: 0.28), blurRadius: size / 3)],
        image: image == null ? null : DecorationImage(image: image!, fit: BoxFit.cover),
      ),
      alignment: Alignment.center,
      child: image == null ? Icon(deviceIcon(icon), color: c, size: size * 0.5) : null,
    );
  }
}
