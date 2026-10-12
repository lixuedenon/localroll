// packages/core/lib/src/media_kind.dart

enum MediaKind {
  image,
  video,
  other;

  static MediaKind fromName(String? name) {
    if (name == null) return MediaKind.other;
    final ext = extensionOf(name);
    if (imageExtensions.contains(ext)) return MediaKind.image;
    if (videoExtensions.contains(ext)) return MediaKind.video;
    return MediaKind.other;
  }

  static MediaKind parse(String? value) => MediaKind.values.firstWhere(
        (k) => k.name == value,
        orElse: () => MediaKind.other,
      );
}

const Set<String> imageExtensions = {
  'jpg', 'jpeg', 'png', 'gif', 'webp', 'bmp', 'heic', 'heif', 'avif', 'dng', 'tif', 'tiff',
};

const Set<String> videoExtensions = {
  'mov', 'mp4', 'm4v', '3gp', 'mkv', 'avi', 'webm', 'mts', 'm2ts',
};

/// Images Flutter's built-in decoder can show directly on Windows.
const Set<String> nativelyDecodableImages = {'jpg', 'jpeg', 'png', 'gif', 'webp', 'bmp'};

/// Lower-case extension without the dot, or '' when there is none.
String extensionOf(String name) {
  final dot = name.lastIndexOf('.');
  if (dot < 0 || dot == name.length - 1) return '';
  return name.substring(dot + 1).toLowerCase();
}

/// Strips path separators and characters Windows does not allow in file names.
String sanitizeFileName(String name) {
  var base = name.split(RegExp(r'[\\/]')).last.trim();
  base = base.replaceAll(RegExp(r'[<>:"|?*\x00-\x1F]'), '_');
  // Windows also rejects trailing dots and spaces.
  base = base.replaceAll(RegExp(r'[. ]+$'), '');
  if (base.isEmpty) base = 'file';
  return base;
}

/// PDF and office documents (they get a folder of their own on the PC).
const Set<String> documentExtensions = {
  'pdf', 'doc', 'docx', 'xls', 'xlsx', 'ppt', 'pptx', 'odt', 'ods', 'odp', 'rtf', 'txt', 'md', 'csv',
  'pages', 'numbers', 'key', 'wps', 'et', 'dps', 'epub', 'xps', 'ofd',
};

bool isDocumentName(String name) => documentExtensions.contains(extensionOf(name));

/// What a file really is, from its first bytes — for files whose name has
/// no (or a wrong) extension. Returns the kind and the usual extension, or
/// null when it is neither a photo, a video nor a PDF.
({MediaKind kind, String ext})? sniffFileType(List<int> h) {
  bool at(int o, List<int> sig) {
    if (h.length < o + sig.length) return false;
    for (var i = 0; i < sig.length; i++) {
      if (h[o + i] != sig[i]) return false;
    }
    return true;
  }

  List<int> a(String s) => s.codeUnits;
  if (at(0, [0xFF, 0xD8, 0xFF])) return (kind: MediaKind.image, ext: 'jpg');
  if (at(0, [0x89, 0x50, 0x4E, 0x47])) return (kind: MediaKind.image, ext: 'png');
  if (at(0, a('GIF8'))) return (kind: MediaKind.image, ext: 'gif');
  if (at(0, a('RIFF')) && at(8, a('WEBP'))) return (kind: MediaKind.image, ext: 'webp');
  if (at(0, a('BM'))) return (kind: MediaKind.image, ext: 'bmp');
  if (at(0, a('%PDF'))) return (kind: MediaKind.other, ext: 'pdf');
  if (at(4, a('ftyp'))) {
    final brand = h.length >= 12 ? String.fromCharCodes(h.sublist(8, 12)) : '';
    if (const {'heic', 'heix', 'hevc', 'heim', 'heis', 'mif1', 'msf1'}.contains(brand)) {
      return (kind: MediaKind.image, ext: 'heic');
    }
    if (brand == 'avif') return (kind: MediaKind.image, ext: 'avif');
    if (brand == 'qt  ') return (kind: MediaKind.video, ext: 'mov');
    return (kind: MediaKind.video, ext: 'mp4');
  }
  return null;
}
