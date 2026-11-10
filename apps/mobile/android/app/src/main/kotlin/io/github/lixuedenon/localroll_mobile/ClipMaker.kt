// apps/mobile/android/app/src/main/kotlin/io/github/lixuedenon/localroll_mobile/ClipMaker.kt
package io.github.lixuedenon.localroll_mobile

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.media.MediaMetadataRetriever
import android.net.Uri
import android.os.Handler
import android.os.Looper
import androidx.annotation.OptIn
import androidx.media3.common.MediaItem
import androidx.media3.common.MimeTypes
import androidx.media3.common.util.UnstableApi
import androidx.media3.effect.BitmapOverlay
import androidx.media3.effect.OverlayEffect
import androidx.media3.effect.TextureOverlay
import androidx.media3.transformer.Composition
import androidx.media3.transformer.EditedMediaItem
import androidx.media3.transformer.Effects
import androidx.media3.transformer.ExportException
import androidx.media3.transformer.ExportResult
import androidx.media3.transformer.Transformer
import com.google.common.collect.ImmutableList
import java.io.File

/**
 * A part of a video with still pictures (the drawings) laid over it for
 * stretches of time, made with Media3 (see lib/services/clip_maker.dart).
 * Channel: localroll/clip, method "make".
 */
@OptIn(UnstableApi::class)
object ClipMaker {
    private class Piece(val picture: Bitmap, val startUs: Long, val endUs: Long)

    fun make(
        ctx: Context,
        input: String,
        output: String,
        startMs: Long,
        endMs: Long,
        overlays: List<Map<String, Any?>>,
        maxSide: Int,
        done: (String?) -> Unit,
    ) {
        // The picture as shown (upright): drawings are laid over it at that size.
        val (w, h) = try {
            val r = MediaMetadataRetriever()
            r.setDataSource(input)
            val vw = r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH)?.toIntOrNull() ?: 0
            val vh = r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT)?.toIntOrNull() ?: 0
            val rot = r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION)?.toIntOrNull() ?: 0
            r.release()
            if (rot % 180 != 0) Pair(vh, vw) else Pair(vw, vh)
        } catch (e: Exception) {
            Pair(0, 0)
        }
        val pieces = overlays.mapNotNull { o ->
            val path = o["path"] as? String ?: return@mapNotNull null
            var bmp = BitmapFactory.decodeFile(path) ?: return@mapNotNull null
            if (w > 0 && h > 0 && (bmp.width != w || bmp.height != h)) {
                bmp = Bitmap.createScaledBitmap(bmp, w, h, true)
            }
            Piece(bmp, (o["startMs"] as Number).toLong() * 1000, (o["endMs"] as Number).toLong() * 1000)
        }
        val clear = Bitmap.createBitmap(
            if (w > 0) w else (pieces.firstOrNull()?.picture?.width ?: 2),
            if (h > 0) h else (pieces.firstOrNull()?.picture?.height ?: 2),
            Bitmap.Config.ARGB_8888,
        )
        val overlay = object : BitmapOverlay() {
            // The first frame's time: frames of a cut part may count from
            // the start of the file or from the cut.
            private var base = -1L

            override fun getBitmap(presentationTimeUs: Long): Bitmap {
                if (base < 0) base = presentationTimeUs
                val t = presentationTimeUs - base
                return pieces.firstOrNull { t >= it.startUs && t < it.endUs }?.picture ?: clear
            }
        }
        Handler(Looper.getMainLooper()).post {
            try {
                File(output).delete()
                val item = MediaItem.Builder()
                    .setUri(Uri.fromFile(File(input)))
                    .setClippingConfiguration(
                        MediaItem.ClippingConfiguration.Builder()
                            .setStartPositionMs(startMs)
                            .setEndPositionMs(endMs)
                            .build()
                    )
                    .build()
                // Smaller ("compress"): the longer side at most maxSide.
                val video = mutableListOf<androidx.media3.common.Effect>()
                val long = maxOf(w, h)
                if (maxSide in 1 until long && w > 0 && h > 0) {
                    val k = maxSide.toDouble() / long
                    video.add(
                        androidx.media3.effect.Presentation.createForWidthAndHeight(
                            ((w * k).toInt() / 2) * 2, ((h * k).toInt() / 2) * 2,
                            androidx.media3.effect.Presentation.LAYOUT_SCALE_TO_FIT,
                        )
                    )
                }
                if (pieces.isNotEmpty()) video.add(OverlayEffect(ImmutableList.of<TextureOverlay>(overlay)))
                val effects = Effects(listOf(), video)
                val edited = EditedMediaItem.Builder(item).setEffects(effects).build()
                val transformer = Transformer.Builder(ctx)
                    .setVideoMimeType(MimeTypes.VIDEO_H264)
                    .addListener(object : Transformer.Listener {
                        override fun onCompleted(composition: Composition, exportResult: ExportResult) = done(null)
                        override fun onError(composition: Composition, exportResult: ExportResult, exportException: ExportException) =
                            done(exportException.message ?: "export failed")
                    })
                    .build()
                transformer.start(edited, output)
            } catch (e: Exception) {
                done(e.message ?: e.toString())
            }
        }
    }
}
