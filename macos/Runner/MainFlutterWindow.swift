import AVFoundation
import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    let badgeChannel = FlutterMethodChannel(
      name: "meshcore_open/app_badge",
      binaryMessenger: flutterViewController.engine.binaryMessenger
    )
    badgeChannel.setMethodCallHandler { call, result in
      guard call.method == "setBadgeCount" else {
        result(FlutterMethodNotImplemented)
        return
      }
      let count = (call.arguments as? Int) ?? 0
      NSApp.dockTile.badgeLabel = count > 0 ? String(count) : nil
      result(nil)
    }

    // Spoken turn prompts for Bloodhound directions (lib/services/speech_service.dart).
    let speechChannel = FlutterMethodChannel(
      name: "meshcore_open/speech",
      binaryMessenger: flutterViewController.engine.binaryMessenger
    )
    speechChannel.setMethodCallHandler { call, result in
      switch call.method {
      case "speak":
        let args = call.arguments as? [String: Any]
        let text = (args?["text"] as? String) ?? ""
        if text.isEmpty { result(false); return }
        let u = AVSpeechUtterance(string: text)
        if let lang = args?["language"] as? String, let v = AVSpeechSynthesisVoice(language: lang) {
          u.voice = v
        }
        if MainFlutterWindow.synth.isSpeaking { MainFlutterWindow.synth.stopSpeaking(at: .immediate) }
        MainFlutterWindow.synth.speak(u)
        result(true)
      case "stop":
        MainFlutterWindow.synth.stopSpeaking(at: .immediate)
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    super.awakeFromNib()
  }

  private static let synth = AVSpeechSynthesizer()
}
