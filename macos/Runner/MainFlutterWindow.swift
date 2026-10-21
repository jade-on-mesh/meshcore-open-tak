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

    // Push-to-talk audio (lib/vox/walkie_audio.dart).
    MeshPcmStream.shared.attach(messenger: flutterViewController.engine.binaryMessenger)

    super.awakeFromNib()
  }

  private static let synth = AVSpeechSynthesizer()
}

/// Push-to-talk audio (lib/vox/walkie_audio.dart): 8 kHz mono PCM16 played as
/// it arrives through AVAudioEngine. "open" {sampleRate} -> true once running;
/// "write" {pcm} schedules audio; "close" {drain} lets it finish or stops now.
final class MeshPcmStream {
  static let shared = MeshPcmStream()
  private var engine: AVAudioEngine?
  private var node: AVAudioPlayerNode?
  private var format: AVAudioFormat?
  private var pending = 0

  func attach(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "meshcore_open/pcm_stream", binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { return }
      let args = call.arguments as? [String: Any]
      switch call.method {
      case "open":
        let rate = (args?["sampleRate"] as? Int) ?? 8000
        result(self.open(rate: Double(rate)))
      case "write":
        if let data = args?["pcm"] as? FlutterStandardTypedData {
          self.write(data.data)
        }
        result(nil)
      case "close":
        let drain = (args?["drain"] as? Bool) ?? true
        self.close(drain: drain)
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private func open(rate: Double) -> Bool {
    if engine != nil, format?.sampleRate == rate { return true }
    stopNow()
    guard let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate,
                                  channels: 1, interleaved: false) else { return false }
    let e = AVAudioEngine()
    let n = AVAudioPlayerNode()
    e.attach(n)
    e.connect(n, to: e.mainMixerNode, format: fmt)
    do {
      try e.start()
    } catch {
      return false
    }
    n.play()
    engine = e
    node = n
    format = fmt
    pending = 0
    return true
  }

  private func write(_ data: Data) {
    guard let n = node, let fmt = format else { return }
    let count = data.count / 2
    if count == 0 { return }
    guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(count)),
          let out = buf.floatChannelData?[0] else { return }
    buf.frameLength = AVAudioFrameCount(count)
    data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
      for i in 0..<count {
        let lo = UInt16(raw[i * 2])
        let hi = UInt16(raw[i * 2 + 1])
        out[i] = Float(Int16(bitPattern: lo | (hi << 8))) / 32768.0
      }
    }
    pending += 1
    n.scheduleBuffer(buf) { [weak self] in
      DispatchQueue.main.async {
        guard let self = self else { return }
        self.pending = max(0, self.pending - 1)
        if self.pending == 0 && self.closing { self.stopNow() }
      }
    }
  }

  private var closing = false

  private func close(drain: Bool) {
    if drain && pending > 0 {
      closing = true
      return
    }
    stopNow()
  }

  private func stopNow() {
    closing = false
    node?.stop()
    engine?.stop()
    node = nil
    engine = nil
    format = nil
    pending = 0
  }
}
