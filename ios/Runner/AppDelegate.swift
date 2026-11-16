import Flutter
import UIKit
import AVFoundation

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
    let messenger = engineBridge.applicationRegistrar.messenger()
    let channel = FlutterMethodChannel(name: "innerwave/audio", binaryMessenger: messenger)
    let decoder = DispatchQueue(label: "studio.innerwave.decoder", qos: .userInitiated)
    channel.setMethodCallHandler { call, result in
      guard call.method == "decode" else { result(FlutterMethodNotImplemented); return }
      guard let args = call.arguments as? [String: String],
            let input = args["input"], let output = args["output"] else {
        result(FlutterError(code: "arguments", message: "Missing audio file path.", details: nil))
        return
      }
      decoder.async {
        do {
          let frames = try Self.decode(input: input, output: output)
          DispatchQueue.main.async { result(frames) }
        } catch {
          DispatchQueue.main.async {
            result(FlutterError(code: "decode", message: error.localizedDescription, details: nil))
          }
        }
      }
    }
  }

  static func decode(input: String, output: String) throws -> Int64 {
    let asset = AVURLAsset(url: URL(fileURLWithPath: input))
    guard let track = asset.tracks(withMediaType: .audio).first else {
      throw audioError("This file has no readable audio track.")
    }
    let reader = try AVAssetReader(asset: asset)
    let settings: [String: Any] = [
      AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 44_100,
      AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 16,
      AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
      AVLinearPCMIsNonInterleaved: false,
    ]
    let stream = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
    stream.alwaysCopiesSampleData = false
    guard reader.canAdd(stream) else { throw audioError("Unsupported audio format.") }
    reader.add(stream)
    guard reader.startReading() else { throw reader.error ?? audioError("Unable to read audio.") }
    defer { if reader.status == .reading { reader.cancelReading() } }
    let destination = URL(fileURLWithPath: output)
    let temporary = destination.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
    guard FileManager.default.createFile(atPath: temporary.path, contents: nil) else {
      throw audioError("Unable to create the imported audio file.")
    }
    defer { try? FileManager.default.removeItem(at: temporary) }
    let file = try FileHandle(forWritingTo: temporary)
    defer { try? file.close() }
    var size: Int64 = 0
    while try autoreleasepool(invoking: { () throws -> Bool in
      guard let sample = stream.copyNextSampleBuffer() else { return false }
      guard let block = CMSampleBufferGetDataBuffer(sample) else { throw audioError("Missing PCM data.") }
      let count = CMBlockBufferGetDataLength(block)
      guard count > 0 else { return true }
      var bytes = Data(count: count)
      let status = bytes.withUnsafeMutableBytes { (p: UnsafeMutableRawBufferPointer) in
        CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: count, destination: p.baseAddress!)
      }
      guard status == kCMBlockBufferNoErr else { throw audioError("Unable to copy decoded audio.") }
      try file.write(contentsOf: bytes)
      size += Int64(count)
      return true
    }) {}
    guard reader.status == .completed, size > 0, size % 4 == 0 else {
      throw reader.error ?? audioError("Incomplete or empty audio.")
    }
    try file.synchronize()
    try FileManager.default.moveItem(at: temporary, to: destination)
    return size / 4
  }

  private static func audioError(_ message: String) -> NSError {
    NSError(domain: "studio.innerwave.audio", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
  }
}
