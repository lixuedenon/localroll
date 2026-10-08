// apps/mobile/ios/Runner/AppDelegate.swift
import AVFoundation
import Flutter
import Photos
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
    if let reg = engineBridge.pluginRegistry.registrar(forPlugin: "LocalRollDiag") {
      PermissionDiag.register(messenger: reg.messenger())
    }
  }
}

/// Calls Apple's permission APIs directly (no plugins) so we can tell an app
/// problem from a system one. Channel: localroll/diag.
enum PermissionDiag {
  static var channel: FlutterMethodChannel?

  static func register(messenger: FlutterBinaryMessenger) {
    let ch = FlutterMethodChannel(name: "localroll/diag", binaryMessenger: messenger)
    ch.setMethodCallHandler { call, result in
      switch call.method {
      case "info":
        result(info())
      case "photos":
        let t = Date()
        PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
          let ms = Int(Date().timeIntervalSince(t) * 1000)
          DispatchQueue.main.async { result("photos=\(status.rawValue) \(ms)ms") }
        }
      case "camera":
        let t = Date()
        AVCaptureDevice.requestAccess(for: .video) { ok in
          let ms = Int(Date().timeIntervalSince(t) * 1000)
          DispatchQueue.main.async { result("camera=\(ok) \(ms)ms") }
        }
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    channel = ch
  }

  static func info() -> String {
    let app = UIApplication.shared
    let states = ["active", "inactive", "background"]
    let appState = app.applicationState.rawValue < states.count ? states[app.applicationState.rawValue] : "?"
    let scenes = app.connectedScenes.map { s -> String in
      let names = [-1: "unattached", 0: "fgActive", 1: "fgInactive", 2: "background"]
      return names[s.activationState.rawValue] ?? "\(s.activationState.rawValue)"
    }.joined(separator: ",")
    let keyWindow = app.connectedScenes.compactMap { $0 as? UIWindowScene }
      .flatMap { $0.windows }.contains { $0.isKeyWindow }
    let profile = Bundle.main.path(forResource: "embedded", ofType: "mobileprovision") != nil
    return [
      "iOS \(UIDevice.current.systemVersion)",
      "bundle=\(Bundle.main.bundleIdentifier ?? "?")",
      "app=\(appState) scenes=[\(scenes)] keyWindow=\(keyWindow)",
      "photosStatus=\(PHPhotoLibrary.authorizationStatus(for: .readWrite).rawValue)",
      "cameraStatus=\(AVCaptureDevice.authorizationStatus(for: .video).rawValue)",
      "profile=\(profile)",
    ].joined(separator: "\n")
  }
}
