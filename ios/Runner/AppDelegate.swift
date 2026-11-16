import Flutter
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
          case "start", "write":
            guard let pcm = call.arguments as? FlutterStandardTypedData else {
              throw StereoPreview.failure("Expected PCM audio.")
            }
            if call.method == "start" { try output.start(pcm.data) }
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
