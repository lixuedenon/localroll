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
