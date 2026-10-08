// packages/core/lib/src/hashing.dart
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;

/// Incremental SHA-256: feed chunks with [add], read the hex digest with [finish].
class StreamingSha256 {
  StreamingSha256() {
    _input = crypto.sha256.startChunkedConversion(_sink);
  }

  final _DigestSink _sink = _DigestSink();
  late final ByteConversionSink _input;
  bool _closed = false;

  void add(List<int> bytes) {
    if (_closed) throw StateError('StreamingSha256 already finished');
    _input.add(bytes);
  }

  String finish() {
    if (!_closed) {
      _input.close();
      _closed = true;
    }
    return _sink.value.toString();
  }
}

class _DigestSink implements Sink<crypto.Digest> {
  crypto.Digest? _value;

  crypto.Digest get value => _value ?? (throw StateError('digest not ready'));

  @override
  void add(crypto.Digest data) => _value = data;

  @override
  void close() {}
}

/// Hex SHA-256 of a file, streamed so multi-GB videos do not load into memory.
Future<String> sha256OfFile(File file) async {
  final hasher = StreamingSha256();
  await for (final chunk in file.openRead()) {
    hasher.add(chunk);
  }
  return hasher.finish();
}

/// Short stable key for a string (first 16 hex chars of its SHA-256).
String shortKey(String input) =>
    crypto.sha256.convert(utf8.encode(input)).toString().substring(0, 16);
