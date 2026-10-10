// apps/mobile/android/app/src/main/kotlin/io/github/lixuedenon/localroll_mobile/MainActivity.kt
package io.github.lixuedenon.localroll_mobile

import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // Background transfer (see lib/services/background_transfer.dart).
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "localroll/background")
            .setMethodCallHandler { call, result ->
                val title = call.argument<String>("title") ?: "LocalRoll"
                val text = call.argument<String>("text") ?: ""
                when (call.method) {
                    "start" -> {
                        askForNotifications()
                        TransferService.start(this, call.argument<String>("channel") ?: title, title, text)
                        result.success("service")
                    }
                    "update" -> {
                        val fraction = call.argument<Double>("progress") ?: -1.0
                        val p = if (fraction < 0) -1 else (fraction * 100).toInt()
                        TransferService.update(this, title, text, p)
                        result.success(null)
                    }
                    "stop" -> {
                        TransferService.stop(this)
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    /** Android 13+: without this the progress notification is hidden (the transfer still runs). */
    private fun askForNotifications() {
        if (Build.VERSION.SDK_INT >= 33 &&
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
        ) {
            requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 7001)
        }
    }
}
