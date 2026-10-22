// apps/mobile/lib/services/phone_names.dart
import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:localroll_core/localroll_core.dart';

import '../l10n/l10n.dart';
import 'discovery.dart';
import 'mobile_settings.dart';

/// Names for this phone: a pleasant random one (a word from nature, in the
/// app's language, plus "iPhone" / "Android"), and telling the PCs when it
/// changes.
class PhoneNames {
  PhoneNames._();

  static String get _device => Platform.isIOS ? 'iPhone' : 'Android';

  /// A new random name, different from [not].
  static String random({String? not}) {
    if (!translator.has('phone.words')) return _device;
    final words = [
      for (final w in tr('phone.words').split(','))
        if (w.trim().isNotEmpty) w.trim(),
    ];
    if (words.isEmpty) return _device;
    final r = Random();
    for (var i = 0; i < 8; i++) {
      final n = tr('phone.name_pattern', {'word': words[r.nextInt(words.length)], 'device': _device});
      if (n != not) return n;
    }
    return tr('phone.name_pattern', {'word': words.first, 'device': _device});
  }

  /// First start of this version: a phone still called just "iPhone" /
  /// "Android" gets a pleasant name (two phones are no longer both "iPhone").
  static Future<void> nameIfPlain(MobileSettings settings, DesktopDiscovery discovery) async {
    if (!settings.hasPlainName) return;
    await rename(settings, discovery, random());
  }

  /// Renames this phone and tells every paired PC that can be reached now
  /// (the others hear it the next time they are linked).
  static Future<void> rename(MobileSettings settings, DesktopDiscovery discovery, String name) async {
    if (name.trim() == _device && !settings.hasPlainName) return;
    await settings.setDeviceName(name);
    await Future.wait([
      for (final d in settings.desktops)
        () async {
          try {
            final c = await connectToDesktop(settings, d, discovered: discovery.found);
            try {
              await c.presence(
                online: true,
                session: discovery.session,
                name: settings.deviceName,
                owner: settings.ownerName.trim(),
                timeout: const Duration(seconds: 4),
              );
            } finally {
              c.close();
            }
          } catch (e) {
            DiagLog.log('pair', '${d.name}: new name not told yet: $e');
          }
        }(),
    ]);
  }
}
