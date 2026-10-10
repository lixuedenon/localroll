// packages/core/lib/src/exif.dart
import 'dart:typed_data';

/// Minimal EXIF plumbing for conversions: lift the EXIF block (capture
/// time, GPS, camera, lens…) out of an original HEIC/HEIF/AVIF or JPEG and
/// put it into the converted JPEG. ffmpeg drops EXIF when it re-encodes.
///
/// Works on the raw TIFF structure ("II*\0" / "MM\0*"); nothing is decoded
/// or rewritten except the Orientation value.
class Exif {
  Exif._();

  /// The EXIF TIFF block of a JPEG or ISOBMFF (HEIC/HEIF/AVIF) file, or null.
  static Uint8List? extractTiff(Uint8List file) {
    if (file.length > 4 && file[0] == 0xFF && file[1] == 0xD8) return _fromJpeg(file);
    if (file.length > 12 && _type(file, 4) == 'ftyp') return _fromIsoBmff(file);
    return null;
  }

  /// EXIF Orientation (1–8), or null if absent.
  static int? orientation(Uint8List tiff) {
    final pos = _orientationValuePos(tiff);
    if (pos == null) return null;
    final v = _u16(tiff, pos, _littleEndian(tiff));
    return v >= 1 && v <= 8 ? v : null;
  }

  /// A copy of [tiff] with Orientation set to [value] (unchanged if absent).
  static Uint8List withOrientation(Uint8List tiff, int value) {
    final out = Uint8List.fromList(tiff);
    final pos = _orientationValuePos(out);
    if (pos != null) {
      if (_littleEndian(out)) {
        out[pos] = value & 0xFF;
        out[pos + 1] = value >> 8;
      } else {
        out[pos] = value >> 8;
        out[pos + 1] = value & 0xFF;
      }
    }
    return out;
  }

  /// [jpeg] with its EXIF replaced by [tiff] (as APP1 right after SOI).
  /// Returns [jpeg] unchanged if it isn't a JPEG or the block is too big
  /// for one APP1 segment (64 KB).
  static Uint8List insertIntoJpeg(Uint8List jpeg, Uint8List tiff) {
    if (jpeg.length < 4 || jpeg[0] != 0xFF || jpeg[1] != 0xD8) return jpeg;
    final segLen = 2 + 6 + tiff.length;
    if (segLen > 0xFFFF) return jpeg;
    final b = BytesBuilder(copy: false)
      ..add(const [0xFF, 0xD8, 0xFF, 0xE1])
      ..add([segLen >> 8, segLen & 0xFF])
      ..add(const [0x45, 0x78, 0x69, 0x66, 0x00, 0x00]) // "Exif\0\0"
      ..add(tiff);
    // Copy the remaining segments, minus any existing EXIF APP1.
    var i = 2;
    while (i + 4 <= jpeg.length && jpeg[i] == 0xFF) {
      final marker = jpeg[i + 1];
      if (marker == 0xDA || marker == 0xD9) break; // start of scan / end
      final len = (jpeg[i + 2] << 8) | jpeg[i + 3];
      final end = i + 2 + len;
      if (end > jpeg.length) break;
      final isExif = marker == 0xE1 && len >= 8 && _isExifHeader(jpeg, i + 4);
      if (!isExif) b.add(Uint8List.sublistView(jpeg, i, end));
      i = end;
    }
    b.add(Uint8List.sublistView(jpeg, i));
    return b.takeBytes();
  }

  /// ffmpeg filter that turns pixels stored with EXIF [orientation] upright
  /// (null for 1 / unknown).
  static String? uprightFilter(int? orientation) => switch (orientation) {
        2 => 'hflip',
        3 => 'hflip,vflip',
        4 => 'vflip',
        5 => 'transpose=0',
        6 => 'transpose=1',
        7 => 'transpose=3',
        8 => 'transpose=2',
        _ => null,
      };

  // ------------------------------------------------------------- JPEG

  static Uint8List? _fromJpeg(Uint8List f) {
    var i = 2;
    while (i + 4 <= f.length && f[i] == 0xFF) {
      final marker = f[i + 1];
      if (marker == 0xDA || marker == 0xD9) return null;
      final len = (f[i + 2] << 8) | f[i + 3];
      if (marker == 0xE1 && len >= 8 && _isExifHeader(f, i + 4)) {
        final start = i + 4 + 6;
        final end = i + 2 + len;
        if (end > f.length || start >= end) return null;
        return _validTiff(Uint8List.fromList(f.sublist(start, end)));
      }
      i += 2 + len;
    }
    return null;
  }

  static bool _isExifHeader(Uint8List f, int p) =>
      p + 6 <= f.length &&
      f[p] == 0x45 && f[p + 1] == 0x78 && f[p + 2] == 0x69 && f[p + 3] == 0x66 && f[p + 4] == 0 && f[p + 5] == 0;

  // ------------------------------------------------------------- HEIF

  static Uint8List? _fromIsoBmff(Uint8List f) {
    final meta = _findBox(f, 0, f.length, 'meta');
    if (meta == null) return null;
    // meta is a FullBox: 4 bytes version/flags before its children.
    final cStart = meta.$1 + 4;
    final cEnd = meta.$2;
    final iinf = _findBox(f, cStart, cEnd, 'iinf');
    final iloc = _findBox(f, cStart, cEnd, 'iloc');
    if (iinf == null || iloc == null) return null;
    final exifId = _exifItemId(f, iinf.$1, iinf.$2);
    if (exifId == null) return null;
    final data = _itemData(f, iloc.$1, iloc.$2, exifId);
    if (data == null || data.length < 8) return null;
    // Item payload: 4-byte offset to the TIFF header, then (usually) "Exif\0\0".
    final off = _u32(data, 0, false);
    final start = 4 + off;
    if (start < data.length) {
      final t = _validTiff(Uint8List.fromList(data.sublist(start)));
      if (t != null) return t;
    }
    // Some writers get the offset wrong: look for the TIFF header nearby.
    for (var p = 4; p < data.length - 4 && p < 64; p++) {
      final t = _validTiff(Uint8List.fromList(data.sublist(p)));
      if (t != null) return t;
    }
    return null;
  }

  /// (contentStart, end) of the first [type] box in [start, end).
  static (int, int)? _findBox(Uint8List f, int start, int end, String type) {
    var p = start;
    while (p + 8 <= end) {
      var size = _u32(f, p, false);
      var header = 8;
      if (size == 1) {
        if (p + 16 > end) return null;
        size = _u32(f, p + 8, false) * 0x100000000 + _u32(f, p + 12, false);
        header = 16;
      } else if (size == 0) {
        size = end - p;
      }
      if (size < header || p + size > end) return null;
      if (_type(f, p + 4) == type) return (p + header, p + size);
      p += size;
    }
    return null;
  }

  static int? _exifItemId(Uint8List f, int start, int end) {
    final version = f[start];
    var p = start + 4;
    final count = version == 0 ? _u16(f, p, false) : _u32(f, p, false);
    p += version == 0 ? 2 : 4;
    for (var n = 0; n < count && p + 8 <= end; n++) {
      final size = _u32(f, p, false);
      if (size < 8 || p + size > end) return null;
      if (_type(f, p + 4) == 'infe') {
        final v = f[p + 8];
        if (v >= 2) {
          var q = p + 12;
          final id = v == 2 ? _u16(f, q, false) : _u32(f, q, false);
          q += v == 2 ? 2 : 4;
          q += 2; // item_protection_index
          if (q + 4 <= p + size && _type(f, q) == 'Exif') return id;
        }
      }
      p += size;
    }
    return null;
  }

  static Uint8List? _itemData(Uint8List f, int start, int end, int itemId) {
    final version = f[start];
    var p = start + 4;
    final offsetSize = f[p] >> 4;
    final lengthSize = f[p] & 0xF;
    final baseOffsetSize = f[p + 1] >> 4;
    final indexSize = (version == 1 || version == 2) ? f[p + 1] & 0xF : 0;
    p += 2;
    final count = version < 2 ? _u16(f, p, false) : _u32(f, p, false);
    p += version < 2 ? 2 : 4;
    for (var n = 0; n < count && p < end; n++) {
      final id = version < 2 ? _u16(f, p, false) : _u32(f, p, false);
      p += version < 2 ? 2 : 4;
      var method = 0;
      if (version == 1 || version == 2) {
        method = _u16(f, p, false) & 0xF;
        p += 2;
      }
      p += 2; // data_reference_index
      final base = _uint(f, p, baseOffsetSize);
      p += baseOffsetSize;
      final extents = _u16(f, p, false);
      p += 2;
      final b = BytesBuilder(copy: false);
      for (var e = 0; e < extents; e++) {
        p += indexSize;
        final off = _uint(f, p, offsetSize);
        p += offsetSize;
        final len = _uint(f, p, lengthSize);
        p += lengthSize;
        if (id == itemId && method == 0) {
          final s = base + off;
          final l = len == 0 ? f.length - s : len;
          if (s < 0 || s + l > f.length) return null;
          b.add(Uint8List.sublistView(f, s, s + l));
        }
      }
      if (id == itemId) return method == 0 ? b.takeBytes() : null;
    }
    return null;
  }

  // ------------------------------------------------------------- TIFF

  static Uint8List? _validTiff(Uint8List t) {
    if (t.length < 8) return null;
    final le = t[0] == 0x49 && t[1] == 0x49 && t[2] == 0x2A && t[3] == 0;
    final be = t[0] == 0x4D && t[1] == 0x4D && t[2] == 0 && t[3] == 0x2A;
    return le || be ? t : null;
  }

  static bool _littleEndian(Uint8List t) => t[0] == 0x49;

  /// Byte offset of the Orientation value inside IFD0, or null.
  static int? _orientationValuePos(Uint8List t) {
    if (_validTiff(t) == null) return null;
    final le = _littleEndian(t);
    final ifd = _u32(t, 4, le);
    if (ifd + 2 > t.length) return null;
    final n = _u16(t, ifd, le);
    for (var i = 0; i < n; i++) {
      final e = ifd + 2 + i * 12;
      if (e + 12 > t.length) return null;
      if (_u16(t, e, le) == 0x0112) return e + 8;
    }
    return null;
  }

  // ------------------------------------------------------------- bytes

  static String _type(Uint8List f, int p) => String.fromCharCodes(f.sublist(p, p + 4));

  static int _u16(Uint8List f, int p, bool le) => le ? f[p] | (f[p + 1] << 8) : (f[p] << 8) | f[p + 1];

  static int _u32(Uint8List f, int p, bool le) => le
      ? f[p] | (f[p + 1] << 8) | (f[p + 2] << 16) | (f[p + 3] << 24)
      : (f[p] << 24) | (f[p + 1] << 16) | (f[p + 2] << 8) | f[p + 3];

  static int _uint(Uint8List f, int p, int size) {
    var v = 0;
    for (var i = 0; i < size; i++) {
      v = v * 256 + f[p + i];
    }
    return v;
  }
}
