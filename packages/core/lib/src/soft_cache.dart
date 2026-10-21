// packages/core/lib/src/soft_cache.dart
import 'dart:async';
import 'dart:collection';

/// Waits between tries in [retryWhileNull]: a file that has just arrived can
/// be busy for a moment (a virus scanner reading it, the sender still
/// closing it).
const List<Duration> defaultRetryWaits = [Duration(seconds: 2), Duration(seconds: 5), Duration(seconds: 15)];

/// Runs [attempt]; while it gives null (or fails), waits and tries again.
Future<T?> retryWhileNull<T extends Object>(Future<T?> Function() attempt, {List<Duration> waits = defaultRetryWaits}) async {
  Future<T?> once() async {
    try {
      return await attempt();
    } catch (_) {
      return null;
    }
  }

  var r = await once();
  for (final w in waits) {
    if (r != null) return r;
    await Future<void>.delayed(w);
    r = await once();
  }
  return r;
}

class _Slot<T> {
  late Future<T?> future;
  DateTime? failedAt;
}

/// Remembers slow results (thumbnails, first pages) by key — but not a
/// failure for good: a null result is made again when asked after
/// [retryAfter]. Keeps the [max] most recently used.
class SoftCache<T extends Object> {
  SoftCache({this.retryAfter = const Duration(minutes: 1), this.max = 500});

  final Duration retryAfter;
  final int max;
  final LinkedHashMap<String, _Slot<T>> _slots = LinkedHashMap();

  Future<T?> get(String key, Future<T?> Function() make) {
    final now = DateTime.now();
    final s = _slots.remove(key);
    if (s != null && (s.failedAt == null || now.difference(s.failedAt!) < retryAfter)) {
      _slots[key] = s; // most recent last
      return s.future;
    }
    final slot = _Slot<T>();
    slot.future = make().then((v) {
      if (v == null) slot.failedAt = DateTime.now();
      return v;
    }, onError: (Object _) {
      slot.failedAt = DateTime.now();
      return null;
    });
    _slots[key] = slot;
    while (_slots.length > max) {
      _slots.remove(_slots.keys.first);
    }
    return slot.future;
  }

  void remove(String key) => _slots.remove(key);
}
