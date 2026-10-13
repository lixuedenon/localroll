// apps/mobile/lib/services/secure_store.dart
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Secrets in the system keychain (iPhone Keychain / Android Keystore)
/// instead of plain app preferences: the pairing tokens, and this phone's
/// id so that deleting and reinstalling LocalRoll on an iPhone keeps the
/// same identity (no "new phone" on the PC).
class SecureStore {
  SecureStore._();

  static const FlutterSecureStorage _s = FlutterSecureStorage(
    // Readable after the first unlock since start-up, so background
    // transfers still work while the phone is locked. Not synced to iCloud.
    iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock_this_device),
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  /// All stored values, or null when the keychain cannot be read now.
  static Future<Map<String, String>?> readAll() async {
    try {
      return await _s.readAll();
    } catch (_) {
      return null;
    }
  }

  /// False when it could not be written.
  static Future<bool> write(String key, String value) async {
    try {
      await _s.write(key: key, value: value);
      return true;
    } catch (_) {
      return false;
    }
  }

  static Future<void> delete(String key) async {
    try {
      await _s.delete(key: key);
    } catch (_) {}
  }
}
