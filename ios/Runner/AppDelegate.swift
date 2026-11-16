import Flutter
import AVFoundation
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private let output = StereoPreview()
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    let channel = FlutterMethodChannel(name: "innerwave/preview", binaryMessenger: engineBridge.applicationRegistrar.messenger())
    channel.setMethodCallHandler { [output] call, result in
      output.queue.async {
        do {
          let value: Any?
          switch call.method {
          case "rate":
            let rate = Int(AVAudioSession.sharedInstance().sampleRate.rounded())
            value = rate > 0 ? rate : 44_100
          case "start", "write":
            let settings = call.arguments as? [String: Any]
            guard let pcm = (settings?["data"] ?? call.arguments) as? FlutterStandardTypedData else {
              throw StereoPreview.failure("Expected PCM audio.")
            }
            if call.method == "start" { try output.start(pcm.data, rate: (settings?["rate"] as? NSNumber)?.doubleValue ?? 44_100, floating: settings != nil) }
            else { try output.write(pcm.data) }
            value = nil
          case "position": value = output.position
          case "stop": value = output.stop()
          default: value = FlutterMethodNotImplemented
          }
          DispatchQueue.main.async { result(value) }
        } catch {
          _ = output.stop()
          DispatchQueue.main.async { result(FlutterError(code: "preview", message: error.localizedDescription, details: nil)) }
        }
      }
    }
  }
}
