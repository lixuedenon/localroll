// apps/desktop/lib/services/global_keys.dart
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:localroll_core/localroll_core.dart';

/// A key that works everywhere in Windows, even while Keepnear is hidden
/// (RegisterHotKey in the runner, flutter_window.cpp).
enum SnipKey {
  off(0, 0, ''),
  ctrlAltX(_ctrl | _alt, 0x58, 'Ctrl + Alt + X'),
  ctrlShiftX(_ctrl | _shift, 0x58, 'Ctrl + Shift + X'),
  altShiftX(_alt | _shift, 0x58, 'Alt + Shift + X'),
  ctrlAltZ(_ctrl | _alt, 0x5A, 'Ctrl + Alt + Z');

  const SnipKey(this.mods, this.vk, this.label);

  final int mods, vk;
  final String label;

  static SnipKey of(String? name) => values.firstWhere((v) => v.name == name, orElse: () => ctrlAltX);
}

const int _alt = 1, _ctrl = 2, _shift = 4;

class GlobalKeys {
  GlobalKeys._();

  static const MethodChannel _ch = MethodChannel('keepnear/hotkeys');

  /// The snip key's id.
  static const int snip = 1;

  static final Map<int, VoidCallback> _actions = {};
  static bool _listening = false;

  /// Whether the snip key could be had (false: another program has it).
  static final ValueNotifier<bool?> snipOk = ValueNotifier(null);

  /// [key] runs [action] (off: nothing). Returns false when another
  /// program already uses the key.
  static Future<bool> setSnip(SnipKey key, VoidCallback action, {bool retry = true}) async {
    if (!_listening) {
      _listening = true;
      _ch.setMethodCallHandler((call) async {
        if (call.method == 'pressed') _actions[call.arguments as int]?.call();
        return null;
      });
    }
    try {
      if (key == SnipKey.off) {
        _actions.remove(snip);
        await _ch.invokeMethod<bool>('unregister', [snip]);
        snipOk.value = null;
        return true;
      }
      _actions[snip] = action;
      final ok = await _ch.invokeMethod<bool>('register', [snip, key.mods, key.vk]) ?? false;
      snipOk.value = ok;
      DiagLog.log('keys', '${key.label}: ${ok ? 'ready' : 'taken by another program'}');
      return ok;
    } on MissingPluginException {
      // Very early at start: the runner's side may not be listening yet.
      if (!retry) return false;
      await Future<void>.delayed(const Duration(seconds: 2));
      return setSnip(key, action, retry: false);
    } catch (e) {
      DiagLog.log('keys', 'global key unavailable: $e');
      snipOk.value = false;
      return false;
    }
  }
}
