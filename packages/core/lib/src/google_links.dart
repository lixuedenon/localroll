// packages/core/lib/src/google_links.dart
import 'dart:convert';

/// Google Drive shortcut files (Docs, Sheets, Slides…) → the address part
/// on docs.google.com. The document itself lives online.
const googleShortcutKinds = {
  'gdoc': 'document',
  'gsheet': 'spreadsheets',
  'gslides': 'presentation',
  'gdraw': 'drawings',
  'gform': 'forms',
};

/// The web address in a Google Drive shortcut file ([ext] without the dot).
/// Only Google's own https addresses come out; anything else gives null.
String? googleShortcutUrl(String json, String ext) {
  try {
    final j = jsonDecode(json);
    if (j is! Map) return null;
    final u = j['url'];
    if (u is String) {
      final uri = Uri.tryParse(u);
      if (uri != null && uri.scheme == 'https' && (uri.host == 'docs.google.com' || uri.host == 'drive.google.com')) {
        return u;
      }
    }
    final id = j['doc_id'];
    final kind = googleShortcutKinds[ext.toLowerCase()];
    if (id is String && kind != null && RegExp(r'^[A-Za-z0-9_-]{10,200}$').hasMatch(id)) {
      return 'https://docs.google.com/$kind/d/$id';
    }
  } catch (_) {}
  return null;
}
