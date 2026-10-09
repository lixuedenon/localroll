// apps/mobile/ios/Runner/AppDelegate.swift
import AVFoundation
import BackgroundTasks
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
    // BGTaskScheduler handlers must be registered during launch.
    if #available(iOS 26.0, *) {
      ContinuedTransfer.registerIfPermitted()
    }
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let reg = engineBridge.pluginRegistry.registrar(forPlugin: "LocalRollDiag") {
      PermissionDiag.register(messenger: reg.messenger())
    }
    if let reg = engineBridge.pluginRegistry.registrar(forPlugin: "LocalRollBackground") {
      BackgroundTransfer.register(messenger: reg.messenger())
    }
  }
}

/// Keeps uploads running when the app leaves the foreground.
/// iOS 26+: a user-initiated BGContinuedProcessingTask (system progress UI,
/// no time limit while progress is reported). Older iOS: the usual ~30 s
/// grace period only. Channel: localroll/background.
enum BackgroundTransfer {
  static var channel: FlutterMethodChannel?
  static var shortTask: UIBackgroundTaskIdentifier = .invalid

  static func register(messenger: FlutterBinaryMessenger) {
    let ch = FlutterMethodChannel(name: "localroll/background", binaryMessenger: messenger)
    ch.setMethodCallHandler { call, result in
      let args = call.arguments as? [String: Any] ?? [:]
      let title = args["title"] as? String ?? "LocalRoll"
      let text = args["text"] as? String ?? ""
      switch call.method {
      case "start":
        beginShortTask()
        var mode = "short"
        if #available(iOS 26.0, *) {
          if ContinuedTransfer.submit(title: title, text: text) { mode = "continued" }
        }
        result(mode)
      case "update":
        if #available(iOS 26.0, *) {
          ContinuedTransfer.update(title: title, text: text, fraction: args["progress"] as? Double ?? -1)
        }
        result(nil)
      case "stop":
        if #available(iOS 26.0, *) {
          ContinuedTransfer.finish(success: args["success"] as? Bool ?? true)
        }
        endShortTask()
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    channel = ch
  }

  static func expired() {
    DispatchQueue.main.async { channel?.invokeMethod("expired", arguments: nil) }
  }

  private static func beginShortTask() {
    endShortTask()
    shortTask = UIApplication.shared.beginBackgroundTask(withName: "LocalRoll transfer") {
      endShortTask()
    }
  }

  private static func endShortTask() {
    if shortTask != .invalid {
      UIApplication.shared.endBackgroundTask(shortTask)
      shortTask = .invalid
    }
  }
}

@available(iOS 26.0, *)
enum ContinuedTransfer {
  static var identifier: String { (Bundle.main.bundleIdentifier ?? "localroll") + ".transfer" }
  static var registered = false
  static var task: BGContinuedProcessingTask?
  /// Set when Flutter already finished before iOS handed us the task.
  static var finished = false
  static var lastTitle = "LocalRoll"

  static func registerIfPermitted() {
    // Registering an identifier missing from Info.plist crashes; a re-signed
    // build with a changed bundle id simply falls back to the short task.
    let permitted = Bundle.main.object(forInfoDictionaryKey: "BGTaskSchedulerPermittedIdentifiers") as? [String] ?? []
    guard permitted.contains(identifier) else { return }
    registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { t in
      guard let t = t as? BGContinuedProcessingTask else {
        t.setTaskCompleted(success: false)
        return
      }
      if finished {
        t.setTaskCompleted(success: true)
        return
      }
      t.progress.totalUnitCount = 1000
      t.expirationHandler = {
        task = nil
        BackgroundTransfer.expired()
      }
      task = t
    }
  }

  static func submit(title: String, text: String) -> Bool {
    guard registered else { return false }
    finished = false
    lastTitle = title
    BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
    let request = BGContinuedProcessingTaskRequest(identifier: identifier, title: title, subtitle: text)
    do {
      try BGTaskScheduler.shared.submit(request)
      return true
    } catch {
      return false
    }
  }

  static func update(title: String, text: String, fraction: Double) {
    guard let t = task else { return }
    if fraction >= 0 {
      t.progress.completedUnitCount = Int64(min(max(fraction, 0), 1) * 1000)
    }
    lastTitle = title
    t.updateTitle(title, subtitle: text)
  }

  static func finish(success: Bool) {
    finished = true
    if let t = task {
      t.progress.completedUnitCount = t.progress.totalUnitCount
      t.setTaskCompleted(success: success)
    }
    task = nil
    BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
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
