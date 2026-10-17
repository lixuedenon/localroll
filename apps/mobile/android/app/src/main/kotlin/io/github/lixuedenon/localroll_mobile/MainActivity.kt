// apps/mobile/android/app/src/main/kotlin/io/github/lixuedenon/localroll_mobile/MainActivity.kt
package io.github.lixuedenon.localroll_mobile

import android.Manifest
import android.graphics.Bitmap
import android.graphics.Color
import android.graphics.pdf.PdfRenderer
import android.os.ParcelFileDescriptor
import java.io.ByteArrayOutputStream
import java.io.File
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
        // PDF pages as pictures (see lib/services/pdf_pages.dart).
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "localroll/pdf")
            .setMethodCallHandler { call, result ->
                val path = call.argument<String>("path")
                if (path == null) {
                    result.error("arg", "path missing", null)
                    return@setMethodCallHandler
                }
                Thread {
                    try {
                        val out: Any? = when (call.method) {
                            "count" -> pdfPageCount(path)
                            "render" -> pdfRender(path, call.argument<Int>("page") ?: 0, call.argument<Int>("width") ?: 1080)
                            else -> null
                        }
                        runOnUiThread { if (out == null) result.notImplemented() else result.success(out) }
                    } catch (e: Throwable) {
                        runOnUiThread { result.error("pdf", e.toString(), null) }
                    }
                }.start()
            }
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

    private val pdfLock = Any()

    private fun <T> withPdf(path: String, f: (PdfRenderer) -> T): T = synchronized(pdfLock) {
        val fd = ParcelFileDescriptor.open(File(path), ParcelFileDescriptor.MODE_READ_ONLY)
        try {
            val r = PdfRenderer(fd)
            try {
                f(r)
            } finally {
                r.close()
            }
        } finally {
            fd.close()
        }
    }

    private fun pdfPageCount(path: String): Int = withPdf(path) { it.pageCount }

    /** One page as a JPEG [width] pixels wide (white paper behind it). */
    private fun pdfRender(path: String, index: Int, width: Int): ByteArray = withPdf(path) { r ->
        val page = r.openPage(index.coerceIn(0, r.pageCount - 1))
        try {
            val w = width.coerceIn(64, 2400)
            val h = (w.toLong() * page.height / maxOf(page.width, 1)).toInt().coerceIn(1, 6000)
            val bmp = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
            bmp.eraseColor(Color.WHITE)
            page.render(bmp, null, null, PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY)
            val bos = ByteArrayOutputStream()
            bmp.compress(Bitmap.CompressFormat.JPEG, 88, bos)
            bmp.recycle()
            bos.toByteArray()
        } finally {
            page.close()
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
