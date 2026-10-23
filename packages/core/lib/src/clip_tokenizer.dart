// packages/core/lib/src/clip_tokenizer.dart
import 'dart:convert';
import 'dart:math';

/// The text side of picture search: turns a search like "海边的日落" into the
/// numbers the text model reads. XLM-RoBERTa's SentencePiece (unigram)
/// tokenizer, in pure Dart: words are split at spaces, each starts with
/// "▁", and the most likely split into known pieces is found (Viterbi).
class ClipTokenizer {
  ClipTokenizer._(this._pieces, this._maxLen, {required this.unk, required this.bos, required this.eos, required this.pad, required this.ctx});

  /// Piece → (id, score).
  final Map<String, (int, double)> _pieces;
  final int _maxLen;
  final int unk;
  final int bos;
  final int eos;
  final int pad;

  /// Tokens per text (padded to this length).
  final int ctx;

  /// From the vocabulary file made with the model (clip-vocab.json).
  factory ClipTokenizer.fromJson(String json) {
    final j = jsonDecode(json) as Map<String, dynamic>;
    final vocab = j['vocab'] as List;
    final pieces = <String, (int, double)>{};
    var maxLen = 1;
    for (var id = 0; id < vocab.length; id++) {
      final e = vocab[id] as List;
      final p = e[0] as String;
      pieces[p] = (id, (e[1] as num).toDouble());
      if (p.length > maxLen) maxLen = p.length;
    }
    return ClipTokenizer._(
      pieces,
      min(maxLen, 24),
      unk: (j['unk'] as num?)?.toInt() ?? 3,
      bos: (j['bos'] as num?)?.toInt() ?? 0,
      eos: (j['eos'] as num?)?.toInt() ?? 2,
      pad: (j['pad'] as num?)?.toInt() ?? 1,
      ctx: (j['ctx'] as num?)?.toInt() ?? 77,
    );
  }

  static const String _space = '▁'; // ▁

  /// Full-width letters / digits made plain, odd spaces made ordinary, runs
  /// of spaces made one (what the model's own normalizer mostly does).
  static String normalize(String s) {
    final b = StringBuffer();
    for (final r in s.runes) {
      var c = r;
      if (c >= 0xFF01 && c <= 0xFF5E) c -= 0xFEE0;
      if (c == 0x3000 || c == 0x00A0 || c == 0x09 || c == 0x0A || c == 0x0D) c = 0x20;
      if (c < 0x20) continue;
      b.writeCharCode(c);
    }
    return b.toString().replaceAll(RegExp(' {2,}'), ' ');
  }

  /// The ids of [text]: <s> pieces </s>, without padding.
  List<int> encode(String text) {
    final t = normalize(text);
    if (t.trim().isEmpty) return [bos, eos];
    // "▁" before the text and in place of every space; split before each ▁.
    final marked = '$_space${t.replaceAll(' ', _space)}';
    final words = <String>[];
    var start = 0;
    for (var i = 1; i < marked.length; i++) {
      if (marked[i] == _space) {
        words.add(marked.substring(start, i));
        start = i;
      }
    }
    words.add(marked.substring(start));
    final out = <int>[bos];
    for (final w in words) {
      out.addAll(_viterbi(w));
    }
    out.add(eos);
    return out;
  }

  /// [encode], cut to [ctx] (keeping </s>) and padded.
  List<int> encodePadded(String text) {
    var ids = encode(text);
    if (ids.length > ctx) ids = [...ids.sublist(0, ctx - 1), eos];
    return [...ids, for (var i = ids.length; i < ctx; i++) pad];
  }

  /// Best split of one word into known pieces (unknown characters: <unk>,
  /// one per run, as SentencePiece does).
  List<int> _viterbi(String w) {
    final chars = w.runes.map(String.fromCharCode).toList();
    final n = chars.length;
    final best = List<double>.filled(n + 1, double.negativeInfinity);
    final from = List<int>.filled(n + 1, -1);
    final piece = List<int>.filled(n + 1, -1);
    best[0] = 0;
    const unkScore = -100.0;
    for (var i = 0; i < n; i++) {
      if (best[i] == double.negativeInfinity) continue;
      var s = '';
      var found = false;
      for (var j = i; j < n && j - i < _maxLen; j++) {
        s += chars[j];
        final p = _pieces[s];
        if (p == null) continue;
        found = true;
        final score = best[i] + p.$2;
        if (score > best[j + 1]) {
          best[j + 1] = score;
          from[j + 1] = i;
          piece[j + 1] = p.$1;
        }
      }
      if (!found || best[i + 1] == double.negativeInfinity) {
        final score = best[i] + unkScore;
        if (score > best[i + 1]) {
          best[i + 1] = score;
          from[i + 1] = i;
          piece[i + 1] = unk;
        }
      }
    }
    final ids = <int>[];
    for (var at = n; at > 0; at = from[at]) {
      ids.add(piece[at]);
    }
    final rev = ids.reversed.toList();
    // Runs of unknown characters are one <unk>.
    final out = <int>[];
    for (final id in rev) {
      if (id == unk && out.isNotEmpty && out.last == unk) continue;
      out.add(id);
    }
    return out;
  }
}
