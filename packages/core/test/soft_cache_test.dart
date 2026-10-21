// packages/core/test/soft_cache_test.dart
import 'package:localroll_core/localroll_core.dart';
import 'package:test/test.dart';

void main() {
  test('retryWhileNull: tries again until something comes back', () async {
    var n = 0;
    final r = await retryWhileNull(() async => ++n < 3 ? null : 'ok', waits: const [Duration.zero, Duration.zero, Duration.zero]);
    expect(r, 'ok');
    expect(n, 3);
  });

  test('retryWhileNull: a failure counts as null; gives up after the waits', () async {
    var n = 0;
    final r = await retryWhileNull<String>(() async {
      n++;
      throw StateError('busy');
    }, waits: const [Duration.zero]);
    expect(r, isNull);
    expect(n, 2);
  });

  test('SoftCache: keeps a result; makes a failed one again after retryAfter', () async {
    final c = SoftCache<String>(retryAfter: const Duration(milliseconds: 50));
    var made = 0;
    Future<String?> fail() async {
      made++;
      return null;
    }

    expect(await c.get('a', fail), isNull);
    expect(await c.get('a', fail), isNull);
    expect(made, 1); // remembered for a moment
    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(await c.get('a', () async => 'now'), 'now');
    expect(await c.get('a', () async => 'other'), 'now'); // a result is kept
  });

  test('SoftCache: keeps at most max entries', () async {
    final c = SoftCache<int>(max: 2);
    await c.get('1', () async => 1);
    await c.get('2', () async => 2);
    await c.get('3', () async => 3);
    expect(await c.get('1', () async => 9), 9); // dropped, made again
  });
}
