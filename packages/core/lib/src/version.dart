// packages/core/lib/src/version.dart

/// The app version, set at build time:
/// `flutter build ... --dart-define=LR_VERSION=v0.2.0-beta.4`.
/// Local builds show "dev".
const String lrVersion = String.fromEnvironment('LR_VERSION', defaultValue: 'dev');
