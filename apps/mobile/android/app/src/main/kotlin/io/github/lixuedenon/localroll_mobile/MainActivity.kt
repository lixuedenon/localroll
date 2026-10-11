// apps/mobile/android/app/src/main/kotlin/io/github/lixuedenon/localroll_mobile/MainActivity.kt
package io.github.lixuedenon.localroll_mobile

import android.Manifest
import android.content.pm.PackageManager
import android.os.BatteryManager
import android.os.Build
import android.provider.MediaStore
import android.os.StatFs
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
                    // Android reads originals in place (no temporary copy), but
                    // report free space anyway so the app can warn early.
                    "freeSpace" -> result.success(StatFs(filesDir.path).availableBytes)
                    "assetSize" -> result.success(-1L)
                    "assetSizes" -> {
                        val ids = call.argument<List<String>>("ids") ?: emptyList()
                        Thread {
                            val sizes = assetSizes(ids)
                            runOnUiThread { result.success(sizes) }
                        }.start()
                    }
                    "battery" -> {
                        val bm = getSystemService(BATTERY_SERVICE) as BatteryManager
                        result.success(
                            mapOf(
                                "level" to bm.getIntProperty(BatteryManager.BATTERY_PROPERTY_CAPACITY),
                                "charging" to (Build.VERSION.SDK_INT >= 23 && bm.isCharging),
                            )
                        )
                    }
                    else -> result.notImplemented()
                }
            }
    }

    /** Byte sizes from MediaStore, 500 ids per query. */
    private fun assetSizes(ids: List<String>): Map<String, Long> {
        val out = HashMap<String, Long>()
        val uri = MediaStore.Files.getContentUri("external")
        for (chunk in ids.chunked(500)) {
            val sel = "${MediaStore.MediaColumns._ID} IN (${chunk.joinToString(",") { "?" }})"
            try {
                contentResolver.query(
                    uri,
                    arrayOf(MediaStore.MediaColumns._ID, MediaStore.MediaColumns.SIZE),
                    sel,
                    chunk.toTypedArray(),
                    null,
                )?.use { c ->
                    while (c.moveToNext()) out[c.getLong(0).toString()] = c.getLong(1)
                }
            } catch (e: Exception) {
            }
        }
        return out
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
