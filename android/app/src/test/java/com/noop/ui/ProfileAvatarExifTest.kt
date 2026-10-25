package com.noop.ui

import android.media.ExifInterface
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pins the EXIF-orientation → matrix-op table for Android profile-photo import (#586 / PR #586).
 * BitmapFactory drops EXIF, so a photo shot sideways decodes un-rotated; [ProfileAvatarStore.exifOps]
 * is the pure tag→correction table applied (after the down-fit scale) to land the avatar upright —
 * matching iOS, which is already correct.
 *
 * The op decision is tested as data (no real android.graphics.Matrix, which is stubbed in JVM unit
 * tests). The ExifInterface.ORIENTATION_* values are compile-time int constants, safe off-device.
 */
class ProfileAvatarExifTest {

    private fun rot(d: Float) = ProfileAvatarStore.ExifOp.Rotate(d)
    private fun scale(x: Float, y: Float) = ProfileAvatarStore.ExifOp.Scale(x, y)

    @Test
    fun normalAndUndefinedAreNoOps() {
        assertTrue(ProfileAvatarStore.exifOps(ExifInterface.ORIENTATION_NORMAL).isEmpty())
        assertTrue(ProfileAvatarStore.exifOps(ExifInterface.ORIENTATION_UNDEFINED).isEmpty())
        // An unknown/garbage tag must also be a no-op, never a crash or a stray rotate.
        assertTrue(ProfileAvatarStore.exifOps(999).isEmpty())
    }

    @Test
    fun rotateTagsMapToPlainRotations() {
        assertEquals(listOf(rot(90f)), ProfileAvatarStore.exifOps(ExifInterface.ORIENTATION_ROTATE_90))
        assertEquals(listOf(rot(180f)), ProfileAvatarStore.exifOps(ExifInterface.ORIENTATION_ROTATE_180))
        assertEquals(listOf(rot(270f)), ProfileAvatarStore.exifOps(ExifInterface.ORIENTATION_ROTATE_270))
    }

    @Test
    fun mirrorTagsMapToAxisFlips() {
        assertEquals(listOf(scale(-1f, 1f)), ProfileAvatarStore.exifOps(ExifInterface.ORIENTATION_FLIP_HORIZONTAL))
        assertEquals(listOf(scale(1f, -1f)), ProfileAvatarStore.exifOps(ExifInterface.ORIENTATION_FLIP_VERTICAL))
    }

    @Test
    fun diagonalTagsRotateThenMirror() {
        // Transpose / transverse are a rotate followed by a horizontal flip, in that order.
        assertEquals(
            listOf(rot(90f), scale(-1f, 1f)),
            ProfileAvatarStore.exifOps(ExifInterface.ORIENTATION_TRANSPOSE),
        )
        assertEquals(
            listOf(rot(270f), scale(-1f, 1f)),
            ProfileAvatarStore.exifOps(ExifInterface.ORIENTATION_TRANSVERSE),
        )
    }

    @Test
    fun everyStandardTagIsCovered() {
        val tags = listOf(
            ExifInterface.ORIENTATION_NORMAL,
            ExifInterface.ORIENTATION_FLIP_HORIZONTAL,
            ExifInterface.ORIENTATION_ROTATE_180,
            ExifInterface.ORIENTATION_FLIP_VERTICAL,
            ExifInterface.ORIENTATION_TRANSPOSE,
            ExifInterface.ORIENTATION_ROTATE_90,
            ExifInterface.ORIENTATION_TRANSVERSE,
            ExifInterface.ORIENTATION_ROTATE_270,
        )
        // No tag throws; the four upright/identity-or-rotate-only tags are the non-flip ones.
        for (t in tags) ProfileAvatarStore.exifOps(t) // must not throw
        val flipped = tags.count { tag -> ProfileAvatarStore.exifOps(tag).any { it is ProfileAvatarStore.ExifOp.Scale } }
        assertEquals(4, flipped) // FLIP_H, FLIP_V, TRANSPOSE, TRANSVERSE carry a mirror
    }
}
