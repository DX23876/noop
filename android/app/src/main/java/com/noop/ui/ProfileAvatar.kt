package com.noop.ui

import android.content.Context
import android.content.SharedPreferences
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Matrix
import android.media.ExifInterface
import android.net.Uri
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.Image
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import java.io.File

// MARK: - Profile picture (optional, on-device avatar)
//
// An OPTIONAL profile photo, kept entirely on this phone — never uploaded (NOOP is offline). The
// picked image's bytes are downscaled to ~256px, re-encoded as a small JPEG, and written to a single
// file in the app-private filesDir; only the file path + an "is set" flag live in SharedPreferences.
//
// macOS/iOS parity note: the iOS side keeps the avatar in its ProfileStore as Data on disk. Compose
// has no OS-reactive store, so — exactly like `AppearancePrefs` / `ChartStylePrefs` in PaletteTokens.kt
// — the decoded [ImageBitmap] is held in SNAPSHOT state. Every `ProfileAvatarStore.bitmap` read (the
// Today header avatar, the Settings avatar) recomposes the moment the photo is set or cleared.

/**
 * The on-device profile avatar. Snapshot-backed so the header + Settings avatars update live, with the
 * actual bytes persisted to `filesDir/avatar.jpg` and the path/flag in the same `noop_profile`
 * SharedPreferences file the [ProfileStore] uses. [load] is called once from MainActivity before first
 * composition; [setAvatarFromUri] / [clearAvatar] write through and flip the live state.
 */
object ProfileAvatarStore {
    private const val PREFS = "noop_profile"
    private const val KEY_HAS_AVATAR = "avatar_present"
    private const val FILE_NAME = "avatar.jpg"

    /** Longest edge (px) the stored avatar is downscaled to — small enough to stay tiny on disk while
     *  still crisp at the largest on-screen size (the Settings avatar). */
    private const val MAX_DIMEN = 256

    /** JPEG quality for the re-encoded avatar — high enough to look clean at avatar sizes, small on disk. */
    private const val JPEG_QUALITY = 85

    private fun prefs(ctx: Context): SharedPreferences =
        ctx.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    private fun avatarFile(ctx: Context): File =
        File(ctx.applicationContext.filesDir, FILE_NAME)

    /** The decoded avatar for composition; null = no photo set (fall back to the person icon). */
    var bitmap by mutableStateOf<ImageBitmap?>(null)
        private set

    /** True when a photo is set — drives the "Remove photo" affordance in Settings. */
    val hasAvatar: Boolean get() = bitmap != null

    /** Decode the persisted avatar (if any) into [bitmap]. Safe to call before first composition. */
    fun load(ctx: Context) {
        val file = avatarFile(ctx)
        bitmap = if (prefs(ctx).getBoolean(KEY_HAS_AVATAR, false) && file.exists()) {
            runCatching { BitmapFactory.decodeFile(file.absolutePath)?.asImageBitmap() }.getOrNull()
        } else {
            null
        }
    }

    /**
     * Read the picked image's bytes, downscale to [MAX_DIMEN] on the longest edge, re-encode as a small
     * JPEG into `filesDir/avatar.jpg`, persist the flag, and update the live [bitmap]. Returns true on
     * success. All decode/IO is wrapped — a bad pick just returns false and leaves the current avatar.
     * Call off the main thread for a large source image (it does bitmap decode + file IO).
     */
    fun setAvatarFromUri(ctx: Context, uri: Uri): Boolean {
        val app = ctx.applicationContext
        val scaled = runCatching { decodeDownscaled(app, uri) }.getOrNull() ?: return false
        val file = avatarFile(app)
        val wrote = runCatching {
            file.outputStream().use { out ->
                scaled.compress(Bitmap.CompressFormat.JPEG, JPEG_QUALITY, out)
            }
        }.isSuccess
        if (!wrote) {
            scaled.recycle()
            return false
        }
        prefs(app).edit().putBoolean(KEY_HAS_AVATAR, true).apply()
        bitmap = scaled.asImageBitmap()
        return true
    }

    /** Remove the photo: delete the file, clear the flag, and drop the live [bitmap] back to null. */
    fun clearAvatar(ctx: Context) {
        val app = ctx.applicationContext
        runCatching { avatarFile(app).delete() }
        prefs(app).edit().putBoolean(KEY_HAS_AVATAR, false).apply()
        bitmap = null
    }

    /**
     * Decode [uri] into a Bitmap whose longest edge is at most [MAX_DIMEN]. Uses a two-pass decode: a
     * bounds-only pass to pick an `inSampleSize`, then the real decode, then an exact down-fit so a
     * non-power-of-two source still lands at the cap, then an EXIF-orientation correction so a photo
     * taken sideways lands upright. Returns null if the stream can't be read/decoded.
     */
    private fun decodeDownscaled(ctx: Context, uri: Uri): Bitmap? {
        val resolver = ctx.contentResolver

        // Pass 1: bounds only — read the source dimensions without allocating the full bitmap.
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        resolver.openInputStream(uri)?.use { BitmapFactory.decodeStream(it, null, bounds) }
        val srcW = bounds.outWidth
        val srcH = bounds.outHeight
        if (srcW <= 0 || srcH <= 0) return null

        // EXIF orientation — read BEFORE the bitmap decode (BitmapFactory drops EXIF). The pixels come
        // off the sensor un-rotated; the orientation tag says how to spin them upright. We read it from a
        // fresh stream now and apply the rotation AFTER the down-fit below. iOS already lands upright.
        val orientation = runCatching {
            resolver.openInputStream(uri)?.use {
                ExifInterface(it).getAttributeInt(ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_NORMAL)
            }
        }.getOrNull() ?: ExifInterface.ORIENTATION_NORMAL

        // Pass 2: sub-sampled decode (power-of-two) to get under ~2× the cap cheaply.
        var sample = 1
        while (srcW / (sample * 2) >= MAX_DIMEN && srcH / (sample * 2) >= MAX_DIMEN) {
            sample *= 2
        }
        val decodeOpts = BitmapFactory.Options().apply { inSampleSize = sample }
        val decoded = resolver.openInputStream(uri)?.use {
            BitmapFactory.decodeStream(it, null, decodeOpts)
        } ?: return null

        // Exact down-fit: scale the longest edge to MAX_DIMEN (never upscale a small source), folding
        // the EXIF rotate/flip into the SAME matrix so it's one createBitmap. A small source that skips
        // scaling (factor 1) still gets oriented if the EXIF tag is non-trivial.
        val longest = maxOf(decoded.width, decoded.height)
        val factor = if (longest > MAX_DIMEN) MAX_DIMEN.toFloat() / longest.toFloat() else 1f
        val matrix = Matrix().apply {
            if (factor != 1f) postScale(factor, factor)
            applyExifOrientation(this, orientation)
        }
        if (matrix.isIdentity) return decoded
        val out = Bitmap.createBitmap(decoded, 0, 0, decoded.width, decoded.height, matrix, true)
        if (out !== decoded) decoded.recycle()
        return out
    }

    /** One post-concatenated step of an EXIF correction: either a clockwise rotate or an axis scale. */
    internal sealed interface ExifOp {
        data class Rotate(val degrees: Float) : ExifOp
        data class Scale(val sx: Float, val sy: Float) : ExifOp
    }

    /**
     * The ordered list of post-concatenations that brings an EXIF [orientation] upright (empty = no-op).
     * Pure + Android-free (only int tag constants, which are compile-time literals) so the tag→ops table
     * is unit-testable without a real [Matrix], which is stubbed in JVM unit tests. The op sequences are
     * the literal operations [applyExifOrientation] used to call inline, so behaviour is unchanged.
     */
    internal fun exifOps(orientation: Int): List<ExifOp> = when (orientation) {
        ExifInterface.ORIENTATION_FLIP_HORIZONTAL -> listOf(ExifOp.Scale(-1f, 1f))
        ExifInterface.ORIENTATION_ROTATE_180 -> listOf(ExifOp.Rotate(180f))
        ExifInterface.ORIENTATION_FLIP_VERTICAL -> listOf(ExifOp.Scale(1f, -1f))
        ExifInterface.ORIENTATION_TRANSPOSE -> listOf(ExifOp.Rotate(90f), ExifOp.Scale(-1f, 1f))
        ExifInterface.ORIENTATION_ROTATE_90 -> listOf(ExifOp.Rotate(90f))
        ExifInterface.ORIENTATION_TRANSVERSE -> listOf(ExifOp.Rotate(270f), ExifOp.Scale(-1f, 1f))
        ExifInterface.ORIENTATION_ROTATE_270 -> listOf(ExifOp.Rotate(270f))
        else -> emptyList() // ORIENTATION_NORMAL / UNDEFINED — no transform
    }

    /** Post-concatenate the EXIF correction for [orientation] onto [matrix] (after any down-scale). */
    private fun applyExifOrientation(matrix: Matrix, orientation: Int) {
        for (op in exifOps(orientation)) when (op) {
            is ExifOp.Rotate -> matrix.postRotate(op.degrees)
            is ExifOp.Scale -> matrix.postScale(op.sx, op.sy)
        }
    }
}

// MARK: - ProfileAvatar composable
//
// The one reusable avatar: the saved photo Circle-cropped if set, else the person fallback icon.
// A single [size] drives both the small header avatar (~28dp) and the large Settings avatar.

/**
 * Renders the on-device profile photo, circle-cropped, or the NOOP loop-mark ([LoopMark]) fallback when
 * none is set. Reads [ProfileAvatarStore.bitmap] (snapshot state), so it updates live the instant
 * the photo is set/cleared. Token-only: a hairline rim ties it to the rest of the chrome. Decorative by
 * default — pass a [contentDescription] (e.g. on the tappable header avatar) when it needs a spoken label.
 *
 * @param size diameter of the avatar.
 * @param modifier applied to the avatar box (e.g. the header's clickable/semantics wrapper).
 * @param contentDescription spoken label for the image; null keeps it decorative.
 */
@Composable
fun ProfileAvatar(
    size: Dp,
    modifier: Modifier = Modifier,
    contentDescription: String? = null,
) {
    val bitmap = ProfileAvatarStore.bitmap
    Box(
        modifier = modifier
            .size(size)
            .clip(CircleShape)
            .border(1.dp, Palette.hairline, CircleShape),
        contentAlignment = Alignment.Center,
    ) {
        if (bitmap != null) {
            Image(
                bitmap = bitmap,
                contentDescription = contentDescription,
                contentScale = ContentScale.Crop,
                modifier = Modifier.size(size).clip(CircleShape),
            )
        } else {
            // No photo: the NOOP loop mark (open green ring + white core) — the brand glyph, matching the
            // iOS default avatar. The user's chosen photo path is untouched; this is only the fallback.
            LoopMark(modifier = Modifier.fillMaxSize())
        }
    }
}

/**
 * The NOOP loop mark drawn as a fallback avatar: an OPEN ~80% recovery ring (round caps, starting at 12
 * o'clock, clockwise) in the recovery green with a solid WHITE centre core dot. Matches the iOS BrandMark
 * shape but in the Apple-Fitness green + white core. CLEAN/flat — no glow, no halo. Decorative.
 */
@Composable
private fun LoopMark(modifier: Modifier = Modifier) {
    val ring = Palette.statusPositive   // recovery / "on" green, a design token (no hardcoded hex)
    val core = if (Palette.isLight) Palette.textPrimary else Color.White
    Canvas(modifier = modifier) {
        val stroke = size.minDimension * 0.13f
        val radius = (size.minDimension - stroke) / 2f
        val topLeft = Offset(center.x - radius, center.y - radius)
        val arcSize = Size(radius * 2f, radius * 2f)
        val capStroke = Stroke(width = stroke, cap = StrokeCap.Round)
        // Open recovery-ring arc: ~80% (288°), −90° start (12 o'clock), clockwise.
        drawArc(
            color = ring,
            startAngle = -90f,
            sweepAngle = 288f,
            useCenter = false,
            topLeft = topLeft,
            size = arcSize,
            style = capStroke,
        )
        // Solid white "core" dot at the centre.
        drawCircle(color = core, radius = stroke * 0.7f, center = center)
    }
}
