// packages/core/lib/src/office/zip_reader.dart
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Reads files out of a ZIP archive (Office documents are ZIPs). Only what
/// Office needs: stored and deflated entries, no encryption, no ZIP64.
/// Sizes are checked so a damaged or hostile file can't eat the memory.
class ZipReader {
  ZipReader._(this._data, this._entries);

  final Uint8List _data;
  final Map<String, _Entry> _entries;

  /// Largest single entry we unpack.
  static const int maxEntry = 64 * 1024 * 1024;

  Iterable<String> get names => _entries.keys;

  bool has(String name) => _entries.containsKey(name);

  /// Null: not a ZIP we can read.
  static ZipReader? open(Uint8List data) {
    try {
      final bd = ByteData.sublistView(data);
      // End of central directory: last 22 bytes + up to 64 KB of comment.
      var eocd = -1;
      final stop = data.length - 22 - 0xFFFF < 0 ? 0 : data.length - 22 - 0xFFFF;
      for (var i = data.length - 22; i >= stop; i--) {
        if (bd.getUint32(i, Endian.little) == 0x06054b50) {
          eocd = i;
          break;
        }
      }
      if (eocd < 0) return null;
      final count = bd.getUint16(eocd + 10, Endian.little);
      var p = bd.getUint32(eocd + 16, Endian.little);
      final entries = <String, _Entry>{};
      for (var n = 0; n < count; n++) {
        if (p + 46 > data.length || bd.getUint32(p, Endian.little) != 0x02014b50) return null;
        final flags = bd.getUint16(p + 8, Endian.little);
        final method = bd.getUint16(p + 10, Endian.little);
        final csize = bd.getUint32(p + 20, Endian.little);
        final usize = bd.getUint32(p + 24, Endian.little);
        final nameLen = bd.getUint16(p + 28, Endian.little);
        final extraLen = bd.getUint16(p + 30, Endian.little);
        final commentLen = bd.getUint16(p + 32, Endian.little);
        final local = bd.getUint32(p + 42, Endian.little);
        final name = utf8.decode(data.sublist(p + 46, p + 46 + nameLen), allowMalformed: true);
        if ((flags & 1) == 0) entries[name] = _Entry(method, csize, usize, local);
        p += 46 + nameLen + extraLen + commentLen;
      }
      return ZipReader._(data, entries);
    } catch (_) {
      return null;
    }
  }

  /// The bytes of [name], or null (missing, too big, damaged).
  Uint8List? read(String name) {
    final e = _entries[name];
    if (e == null || e.usize > maxEntry || e.csize > _data.length) return null;
    try {
      final bd = ByteData.sublistView(_data);
      final h = e.local;
      if (bd.getUint32(h, Endian.little) != 0x04034b50) return null;
      final start = h + 30 + bd.getUint16(h + 26, Endian.little) + bd.getUint16(h + 28, Endian.little);
      if (start + e.csize > _data.length) return null;
      final raw = Uint8List.sublistView(_data, start, start + e.csize);
      if (e.method == 0) return Uint8List.fromList(raw);
      if (e.method != 8) return null;
      final out = ZLibDecoder(raw: true).convert(raw);
      if (out.length > maxEntry) return null;
      return out is Uint8List ? out : Uint8List.fromList(out);
    } catch (_) {
      return null;
    }
  }

  /// [name] as text (UTF-8).
  String? text(String name) {
    final b = read(name);
    return b == null ? null : utf8.decode(b, allowMalformed: true);
  }
}

class _Entry {
  _Entry(this.method, this.csize, this.usize, this.local);

  final int method;
  final int csize;
  final int usize;
  final int local;
}
