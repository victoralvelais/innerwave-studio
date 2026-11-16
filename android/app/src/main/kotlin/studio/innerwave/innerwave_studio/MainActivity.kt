package studio.innerwave.innerwave_studio

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger
        val worker = messenger.makeBackgroundTaskQueue()
        MethodChannel(messenger, "innerwave/audio", io.flutter.plugin.common.StandardMethodCodec.INSTANCE, worker)
            .setMethodCallHandler { call, result ->
                if (call.method != "decode") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                try {
                    val input = requireNotNull(call.argument<String>("input"))
                    val output = requireNotNull(call.argument<String>("output"))
                    result.success(AudioImport.decode(input, output))
                } catch (error: Exception) {
                    result.error("decode", error.localizedMessage ?: "Unable to decode audio.", null)
                }
            }
    }
}
