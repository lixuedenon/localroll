// packages/core/test/clip_tokenizer_test.dart
//
// The app's own tokenizer must give exactly the ids the model was made with
// (samples made by scripts/models/export_clip.py, from the "deps" release).
import 'dart:convert';
import 'dart:io';

import 'package:localroll_core/localroll_core.dart';
import 'package:test/test.dart';

const _base = 'https://github.com/lixuedenon/localroll/releases/download/deps';

Future<String?> _get(String name) async {
  final http = HttpClient()..connectionTimeout = const Duration(seconds: 20);
  try {
    final res = await (await http.getUrl(Uri.parse('$_base/$name'))).close();
    if (res.statusCode != 200) return null;
    return await utf8.decodeStream(res);
  } catch (_) {
    return null;
  } finally {
    http.close(force: true);
  }
}

void main() {
  test('same ids as the model\'s own tokenizer', () async {
    final vocab = await _get('clip-vocab.json');
    final samples = await _get('clip-token-samples.json');
    if (vocab == null || samples == null) {
      markTestSkipped('model files not reachable');
      return;
    }
    final tok = ClipTokenizer.fromJson(vocab);
    for (final s in (jsonDecode(samples) as List).cast<Map<String, dynamic>>()) {
      expect(tok.encode(s['text'] as String), (s['ids'] as List).cast<int>(), reason: s['text'] as String);
    }
    final padded = tok.encodePadded('a dog');
    expect(padded.length, tok.ctx);
  }, timeout: const Timeout(Duration(minutes: 2)));
}
