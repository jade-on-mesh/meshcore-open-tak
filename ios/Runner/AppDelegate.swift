import AVFoundation
import Flutter
import UIKit
import UserNotifications

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
    // Spoken turn prompts for Bloodhound directions (lib/services/speech_service.dart).
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "MeshSpeech") {
      MeshSpeech.shared.attach(messenger: registrar.messenger())
    }
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "MeshAppBadge") {
      let channel = FlutterMethodChannel(
        name: "meshcore_open/app_badge",
        binaryMessenger: registrar.messenger()
      )
      channel.setMethodCallHandler { call, result in
        guard call.method == "setBadgeCount" else {
          result(FlutterMethodNotImplemented)
          return
        }
        let count = (call.arguments as? Int) ?? 0
        UNUserNotificationCenter.current().setBadgeCount(max(0, count)) { error in
          if let error = error {
            result(FlutterError(code: "badge", message: error.localizedDescription, details: nil))
          } else {
            result(nil)
          }
        }
      }
    }
  }
}

/// Speaks turn prompts with the system voice, ducking other audio meanwhile.
final class MeshSpeech: NSObject, AVSpeechSynthesizerDelegate {
  static let shared = MeshSpeech()
  private let synth = AVSpeechSynthesizer()

  func attach(messenger: FlutterBinaryMessenger) {
    synth.delegate = self
    let channel = FlutterMethodChannel(name: "meshcore_open/speech", binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { return }
      switch call.method {
      case "speak":
        let args = call.arguments as? [String: Any]
        let text = (args?["text"] as? String) ?? ""
        if text.isEmpty { result(false); return }
        let u = AVSpeechUtterance(string: text)
        if let lang = args?["language"] as? String, let v = AVSpeechSynthesisVoice(language: lang) {
          u.voice = v
        }
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .voicePrompt,
                                 options: [.duckOthers, .interruptSpokenAudioAndMixWithOthers])
        try? session.setActive(true)
        if self.synth.isSpeaking { self.synth.stopSpeaking(at: .immediate) }
        self.synth.speak(u)
        result(true)
      case "stop":
        self.synth.stopSpeaking(at: .immediate)
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish u: AVSpeechUtterance) {
    if !s.isSpeaking { try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
  }
}
