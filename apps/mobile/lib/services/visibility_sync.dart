// apps/mobile/lib/services/visibility_sync.dart
import 'dart:async';

import 'package:localroll_core/localroll_core.dart';

import 'discovery.dart';
import 'mobile_settings.dart';

/// "Who can see what I send" changed for everything already sent: each
/// paired PC is told at once; a PC that is off is told when it is linked
/// again (MobileSettings.visibilityPending).
class VisibilitySync {
  VisibilitySync._();

  static final Map<String, Future<bool>> _running = {};

  /// Tells every PC still waiting; returns how many could not be reached.
  static Future<int> pushAll(MobileSettings settings, DesktopDiscovery discovery) async {
    final ids = settings.visibilityPending.toList();
    var left = 0;
    for (final id in ids) {
      if (!await push(settings, discovery, id)) left++;
    }
    return left;
  }

  /// Tells PC [pcId] if it is waiting; true when done (or nothing to do).
  static Future<bool> push(MobileSettings settings, DesktopDiscovery discovery, String pcId) {
    if (!settings.visibilityPending.contains(pcId)) return Future.value(true);
    return _running[pcId] ??= _push(settings, discovery, pcId).whenComplete(() => _running.remove(pcId));
  }

  static Future<bool> _push(MobileSettings settings, DesktopDiscovery discovery, String pcId) async {
    final d = settings.byId(pcId);
    if (d == null) {
      await settings.visibilityDone(pcId);
      return true;
    }
    try {
      final c = await connectToDesktop(settings, d, discovered: discovery.found);
      try {
        final private = !settings.shareWithFamily;
        final n = await c.setVisibilityAll(private: private);
        DiagLog.log('family', '${d.name}: everything ${private ? 'only me' : 'shared'} ($n)');
      } finally {
        c.close();
      }
      await settings.visibilityDone(pcId);
      return true;
    } catch (e) {
      DiagLog.log('family', '${d.name}: visibility not told yet: $e');
      return false;
    }
  }
}
