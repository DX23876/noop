package com.noop.ui.forge

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.Uri
import java.io.ByteArrayOutputStream

/**
 * A picture chosen for a bug report, cut down to something a report can carry. The Apple twin is
 * `ReportProblemView.scaled`, and the numbers are the same on both: long edge 1600, JPEG at 70.
 *
 * It matters because the whole bundle has to stay under the service's 4 MiB ceiling and the strap log
 * already fills most of it. A twelve-megapixel screenshot sent as it comes would be the one attachment
 * that pushes a report over and gets it refused.
 *
 * Decoded in two passes so a huge image never has to fit in memory whole: the first pass reads only
 * the dimensions, the second decodes already shrunk.
 */
object ReportPicture {
    const val LONG_EDGE = 1600
    const val QUALITY = 70

    fun scaled(context: Context, uri: Uri): ByteArray? = runCatching {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        context.contentResolver.openInputStream(uri)?.use {
            BitmapFactory.decodeStream(it, null, bounds)
        }
        val side = maxOf(bounds.outWidth, bounds.outHeight)
        if (side <= 0) return null

        var sample = 1
        while (side / sample > LONG_EDGE * 2) sample *= 2
        val options = BitmapFactory.Options().apply { inSampleSize = sample }
        val decoded = context.contentResolver.openInputStream(uri)?.use {
            BitmapFactory.decodeStream(it, null, options)
        } ?: return null

        val longest = maxOf(decoded.width, decoded.height)
        val bitmap = if (longest <= LONG_EDGE) decoded else {
            val scale = LONG_EDGE.toFloat() / longest
            Bitmap.createScaledBitmap(decoded, (decoded.width * scale).toInt(),
                                      (decoded.height * scale).toInt(), true)
        }
        ByteArrayOutputStream().use { out ->
            bitmap.compress(Bitmap.CompressFormat.JPEG, QUALITY, out)
            out.toByteArray()
        }
    }.getOrNull()
}
