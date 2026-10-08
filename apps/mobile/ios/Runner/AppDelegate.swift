import Flutter
import UIKit

// UIScene lifecycle (required by iOS 26+/Xcode 27). Plugins are registered on the
// implicit engine once it exists instead of in didFinishLaunching.
// Needs Flutter >= 3.38 — the iOS CI job builds with a newer Flutter than desktop.
@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
  }
}
