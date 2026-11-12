import AVFoundation
import CoreLocation
import CoreMotion
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
    // Push-to-talk audio (lib/vox/walkie_audio.dart).
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "MeshPcmStream") {
      MeshPcmStream.shared.attach(messenger: registrar.messenger())
    }
    // The AR view's sensors (lib/team/ar_view.dart).
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "MeshOrientation") {
      MeshOrientation.shared.attach(messenger: registrar.messenger())
    }
    // Video messages: a picked clip as frames and sound (lib/vox/video_source.dart).
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "MeshVideoReader") {
      MeshVideoReader.shared.attach(messenger: registrar.messenger())
    }
    // Settings > Keep screen on (lib/services/screen_awake_service.dart). iOS
    // only honours it while the app is in front.
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "MeshScreenAwake") {
      FlutterMethodChannel(name: "meshcore_open/screen_awake", binaryMessenger: registrar.messenger())
        .setMethodCallHandler { call, result in
          guard call.method == "set" else {
            result(FlutterMethodNotImplemented)
            return
          }
          let on = (call.arguments as? Bool) ?? false
          DispatchQueue.main.async {
            UIApplication.shared.isIdleTimerDisabled = on
            result(nil)
          }
        }
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
    let session = AVAudioSession.sharedInstance()
    if session.category != .playAndRecord {
      try? session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
    }
    try? session.setActive(true)
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
    try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
  }
}

/// The AR view's sensors (lib/team/ar_view.dart): gravity and the magnetic field
/// in device axes, given the same way Android does (gravity pointing up, in
/// m/s^2), plus the magnetic declination from the compass heading, about 20 times
/// a second as [gx, gy, gz, mx, my, mz, declinationDeg]. The maths is in Dart.
final class MeshOrientation: NSObject, FlutterStreamHandler, CLLocationManagerDelegate {
  static let shared = MeshOrientation()
  private let motion = CMMotionManager()
  private let location = CLLocationManager()
  private var sink: FlutterEventSink?
  private var declination = 0.0

  func attach(messenger: FlutterBinaryMessenger) {
    FlutterEventChannel(name: "meshcore_open/orientation", binaryMessenger: messenger)
      .setStreamHandler(self)
    // Android works out the declination from a position; here the compass does.
    FlutterMethodChannel(name: "meshcore_open/orientation_ctl", binaryMessenger: messenger)
      .setMethodCallHandler { _, result in result(nil) }
    location.delegate = self
  }

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    sink = events
    guard motion.isDeviceMotionAvailable,
      CMMotionManager.availableAttitudeReferenceFrames().contains(.xMagneticNorthZVertical)
    else {
      return FlutterError(code: "no_sensors", message: "This device has no compass", details: nil)
    }
    if CLLocationManager.headingAvailable() { location.startUpdatingHeading() }
    motion.deviceMotionUpdateInterval = 0.05
    motion.startDeviceMotionUpdates(using: .xMagneticNorthZVertical, to: .main) { [weak self] m, _ in
      guard let self = self, let m = m, let sink = self.sink else { return }
      let g = m.gravity
      let f = m.magneticField.field
      sink([-g.x * 9.81, -g.y * 9.81, -g.z * 9.81, f.x, f.y, f.z, self.declination])
    }
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    motion.stopDeviceMotionUpdates()
    location.stopUpdatingHeading()
    sink = nil
    return nil
  }

  func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
    guard newHeading.trueHeading >= 0, newHeading.magneticHeading >= 0 else { return }
    var d = newHeading.trueHeading - newHeading.magneticHeading
    if d > 180 { d -= 360 }
    if d < -180 { d += 360 }
    declination = d
  }
}

/// Video messages (lib/vox/video_source.dart): reads a picked clip as small
/// RGB888 frames at a fixed rate and its sound as 48 kHz mono PCM16, each into
/// a temporary file, for the AV1 encoder in Dart (video_codec.dart). The same
/// contract as Android's VoxVideoChannel.kt:
/// "meshcore_open/vox_video" "extract" {path, maxSide, fps, maxSeconds} ->
/// {frames, width, height, fps, count, durationMs, sound?, samples}
final class MeshVideoReader {
  static let shared = MeshVideoReader()
  private let queue = DispatchQueue(label: "meshcore_open.vox_video", qos: .userInitiated)

  enum ReadError: LocalizedError {
    case notVideo, noPicture, timedOut
    var errorDescription: String? {
      switch self {
      case .notVideo: return "not a video"
      case .noPicture: return "no picture in this video"
      case .timedOut: return "reading the video took too long"
      }
    }
  }

  func attach(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "meshcore_open/vox_video", binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self, call.method == "extract" else {
        result(FlutterMethodNotImplemented)
        return
      }
      guard let args = call.arguments as? [String: Any], let path = args["path"] as? String else {
        result(FlutterError(code: "extract", message: "no path", details: nil))
        return
      }
      let maxSide = args["maxSide"] as? Int ?? 256
      let fps = max(1, args["fps"] as? Int ?? 12)
      let maxSeconds = args["maxSeconds"] as? Int ?? 15
      self.queue.async {
        do {
          let out = try self.extract(path: path, maxSide: maxSide, fps: fps, maxSeconds: maxSeconds)
          DispatchQueue.main.async { result(out) }
        } catch {
          DispatchQueue.main.async {
            result(FlutterError(code: "extract", message: error.localizedDescription, details: nil))
          }
        }
      }
    }
  }

  private func even(_ v: Double) -> Int { max(2, Int((v / 2).rounded()) * 2) }

  private func tempURL(_ name: String) -> URL {
    URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(name)
  }

  private func extract(path: String, maxSide: Int, fps: Int, maxSeconds: Int) throws -> [String: Any] {
    let asset = AVURLAsset(url: URL(fileURLWithPath: path))
    guard let track = asset.tracks(withMediaType: .video).first else { throw ReadError.noPicture }
    let seconds = CMTimeGetSeconds(asset.duration)
    guard seconds.isFinite, seconds > 0 else { throw ReadError.notVideo }
    let clipMs = Int(min(seconds, Double(maxSeconds)) * 1000)
    let count = max(1, clipMs * fps / 1000)

    // The shape as shown: the track's size turned by its rotation.
    let shown = track.naturalSize.applying(track.preferredTransform)
    let aspect = Double(abs(shown.width)) / max(Double(abs(shown.height)), 1)
    let w: Int
    let h: Int
    if aspect >= 1 {
      w = even(Double(maxSide))
      h = even(Double(maxSide) / aspect)
    } else {
      w = even(Double(maxSide) * aspect)
      h = even(Double(maxSide))
    }

    // Frames upright (the rotation applied), SDR, no bigger than needed, in
    // one batch so the decoder runs through the clip once.
    let gen = AVAssetImageGenerator(asset: asset)
    gen.appliesPreferredTrackTransform = true
    gen.maximumSize = CGSize(width: w, height: h)
    let tolerance = CMTime(value: 1, timescale: CMTimeScale(fps * 2))
    gen.requestedTimeToleranceBefore = tolerance
    gen.requestedTimeToleranceAfter = tolerance
    let times = (0..<count).map {
      NSValue(time: CMTime(value: CMTimeValue($0), timescale: CMTimeScale(fps)))
    }
    var images = [CGImage?](repeating: nil, count: count)
    var left = count
    let lock = NSLock()
    let done = DispatchSemaphore(value: 0)
    gen.generateCGImagesAsynchronously(forTimes: times) { requested, image, _, _, _ in
      let i = Int((CMTimeGetSeconds(requested) * Double(fps)).rounded())
      lock.lock()
      if i >= 0 && i < count, let image = image { images[i] = image }
      left -= 1
      let finished = left == 0
      lock.unlock()
      if finished { done.signal() }
    }
    if done.wait(timeout: .now() + 120) == .timedOut {
      gen.cancelAllCGImageGeneration()
      throw ReadError.timedOut
    }
    lock.lock()
    let frames = images
    lock.unlock()
    if frames.allSatisfy({ $0 == nil }) { throw ReadError.noPicture }

    let framesURL = tempURL("vox_video_frames.rgb")
    FileManager.default.createFile(atPath: framesURL.path, contents: nil)
    let handle = try FileHandle(forWritingTo: framesURL)
    defer { try? handle.close() }
    let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    var rgba = [UInt8](repeating: 0, count: w * h * 4)
    var rgb = Data(count: w * h * 3)
    var last: Data?
    for image in frames {
      guard let image = image else {
        try handle.write(contentsOf: last ?? Data(count: w * h * 3))
        continue
      }
      rgba.withUnsafeMutableBytes { buf in
        guard let ctx = CGContext(
          data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8,
          bytesPerRow: w * 4, space: space,
          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
      }
      rgb.withUnsafeMutableBytes { out in
        let o = out.bindMemory(to: UInt8.self)
        for p in 0..<(w * h) {
          o[p * 3] = rgba[p * 4]
          o[p * 3 + 1] = rgba[p * 4 + 1]
          o[p * 3 + 2] = rgba[p * 4 + 2]
        }
      }
      try handle.write(contentsOf: rgb)
      last = rgb
    }

    var out: [String: Any] = [
      "frames": framesURL.path,
      "width": w,
      "height": h,
      "fps": fps,
      "count": count,
      "durationMs": clipMs,
      "sound": NSNull(),
      "samples": 0,
    ]
    if let (soundPath, samples) = readSound(asset: asset, clipMs: clipMs) {
      out["sound"] = soundPath
      out["samples"] = samples
    }
    return out
  }

  /// The first [clipMs] of the sound as 48 kHz mono PCM16 LE in a file
  /// (AVAssetReader resamples and mixes down); nil when there is none.
  private func readSound(asset: AVURLAsset, clipMs: Int) -> (String, Int)? {
    guard let track = asset.tracks(withMediaType: .audio).first,
      let reader = try? AVAssetReader(asset: asset)
    else { return nil }
    let settings: [String: Any] = [
      AVFormatIDKey: kAudioFormatLinearPCM,
      AVSampleRateKey: 48000,
      AVNumberOfChannelsKey: 1,
      AVLinearPCMBitDepthKey: 16,
      AVLinearPCMIsFloatKey: false,
      AVLinearPCMIsBigEndianKey: false,
      AVLinearPCMIsNonInterleaved: false,
    ]
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
    output.alwaysCopiesSampleData = false
    guard reader.canAdd(output) else { return nil }
    reader.add(output)
    reader.timeRange = CMTimeRange(
      start: .zero, duration: CMTime(value: CMTimeValue(clipMs), timescale: 1000))
    guard reader.startReading() else { return nil }
    var pcm = Data()
    while let buffer = output.copyNextSampleBuffer() {
      guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
      let n = CMBlockBufferGetDataLength(block)
      guard n > 0 else { continue }
      var chunk = Data(count: n)
      chunk.withUnsafeMutableBytes { p in
        if let base = p.baseAddress {
          _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: n, destination: base)
        }
      }
      pcm.append(chunk)
    }
    reader.cancelReading()
    let want = clipMs * 48 * 2
    if pcm.count > want { pcm = pcm.prefix(want) }
    pcm.count -= pcm.count % 2
    guard pcm.count >= 2 else { return nil }
    let url = tempURL("vox_video_sound.pcm")
    do {
      try pcm.write(to: url)
    } catch {
      return nil
    }
    return (url.path, pcm.count / 2)
  }
}
