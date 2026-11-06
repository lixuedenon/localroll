// apps/mobile/lib/services/clipboard_sync.dart
import 'package:flutter/services.dart';
import 'package:localroll_core/localroll_core.dart';

import 'discovery.dart';
import 'mobile_settings.dart';

/// Clipboard sync with a paired computer (on demand, nothing in the
/// background): this phone's copied text goes there (ready to paste there
/// too), or the computer's copied text comes here.
class ClipboardSync {
  ClipboardSync._();

  static Future<LrClient> _client(MobileSettings settings, DesktopDiscovery discovery, PairedDesktop desktop) async {
    final d = await connectToDesktop(settings, desktop, discovered: discovery.found);
    try {
      return LrClient(host: d.host, port: d.port, deviceId: settings.deviceId, token: d.token, secure: d.secure, pin: d.pin);
    } finally {
      d.close();
    }
  }

  /// Sends what is copied here. False: nothing copied (or not reached).
  static Future<bool> send(MobileSettings settings, DesktopDiscovery discovery, PairedDesktop desktop) async {
    final text = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
    if (text == null || text.trim().isEmpty) return false;
    final c = await _client(settings, discovery, desktop);
    try {
      await c.sendText(text.length > LrProtocol.maxText ? text.substring(0, LrProtocol.maxText) : text);
      return true;
    } finally {
      c.close();
    }
  }

  /// Copies what is copied on the computer; returns it (null: nothing).
  static Future<String?> take(MobileSettings settings, DesktopDiscovery discovery, PairedDesktop desktop) async {
    final c = await _client(settings, discovery, desktop);
    try {
      final t = await c.clipboard();
      if (t != null) await Clipboard.setData(ClipboardData(text: t));
      return t;
    } finally {
      c.close();
    }
  }
}
