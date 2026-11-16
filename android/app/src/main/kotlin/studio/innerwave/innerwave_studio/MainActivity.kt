package studio.innerwave.innerwave_studio

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMethodCodec

class MainActivity : FlutterActivity() {
    private val output = StereoPreview()
    private var channel: MethodChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger
        channel = MethodChannel(messenger, "innerwave/preview", StandardMethodCodec.INSTANCE, messenger.makeBackgroundTaskQueue())
        channel?.setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "start" -> { output.start(call.arguments as ByteArray); result.success(null) }
                    "write" -> { output.write(call.arguments as ByteArray); result.success(null) }
                    "position" -> result.success(output.position())
                    "stop" -> result.success(output.stop())
                    else -> result.notImplemented()
                }
            } catch (e: Exception) {
                runCatching { output.stop() }
                result.error("preview", e.localizedMessage ?: "Audio output is unavailable.", null)
            }
        }
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        channel?.setMethodCallHandler(null)
        channel = null
        output.stop()
        super.cleanUpFlutterEngine(flutterEngine)
    }
}
