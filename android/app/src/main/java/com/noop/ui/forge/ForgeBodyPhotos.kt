package com.noop.ui.forge

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.ImageDecoder
import android.graphics.Matrix
import android.media.ExifInterface
import android.net.Uri
import android.os.Build
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Delete
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.FilterChip
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import com.noop.R
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File
import java.time.LocalDate
import java.util.Locale

/**
 * Fork (DX23876), Android parity plan 2.3: progress photos after `ProgressPhotoStore` and `BodyPhotosView`. Three
 * poses, one photo per pose per day (a new one replaces that day's), compared oldest against newest. Photos are
 * picked with the Android photo picker and re-encoded into the app's private files: the copy carries no camera
 * metadata, is never written back to the gallery, and stays out of NOOP and Android backups (`allowBackup` is off).
 */
internal object BodyPhotoStore {
    enum class Pose(val raw: String) { Front("front"), Side("side"), Back("back") }
    data class Photo(val day: String, val pose: Pose, val file: File)

    private const val MAX_EDGE = 1600

    private fun dir(context: Context) = File(context.filesDir, "BodyPhotos").apply { mkdirs() }

    fun all(context: Context): List<Photo> = dir(context).listFiles().orEmpty().mapNotNull { f ->
        val name = f.name.removeSuffix(".jpg")
        if (name == f.name || name.length < 12) return@mapNotNull null
        val pose = Pose.entries.firstOrNull { it.raw == name.substring(11) } ?: return@mapNotNull null
        Photo(name.substring(0, 10), pose, f)
    }.sortedBy { it.day }

    /** Copies the picked image as a fresh JPEG for today and this pose; false when it could not be read. */
    fun save(context: Context, uri: Uri, pose: Pose, day: String = LocalDate.now().toString()): Boolean {
        val bitmap = decode(context, uri) ?: return false
        val target = File(dir(context), "$day-${pose.raw}.jpg")
        val temp = File(target.path + ".tmp")
        val ok = runCatching { temp.outputStream().use { bitmap.compress(Bitmap.CompressFormat.JPEG, 88, it) } }.getOrDefault(false)
        bitmap.recycle()
        return ok && temp.renameTo(target)
    }

    fun delete(photo: Photo) { photo.file.delete() }

    fun load(photo: Photo): Bitmap? = BitmapFactory.decodeFile(photo.file.path)

    /** Decodes upright and no larger than [MAX_EDGE]; re-encoding drops every metadata field. */
    private fun decode(context: Context, uri: Uri): Bitmap? = runCatching {
        if (Build.VERSION.SDK_INT >= 28) {
            ImageDecoder.decodeBitmap(ImageDecoder.createSource(context.contentResolver, uri)) { decoder, info, _ ->
                val edge = maxOf(info.size.width, info.size.height)
                if (edge > MAX_EDGE) {
                    val scale = MAX_EDGE.toFloat() / edge
                    decoder.setTargetSize((info.size.width * scale).toInt(), (info.size.height * scale).toInt())
                }
                decoder.allocator = ImageDecoder.ALLOCATOR_SOFTWARE
            }
        } else {
            val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            context.contentResolver.openInputStream(uri)?.use { BitmapFactory.decodeStream(it, null, bounds) }
            var sample = 1
            while (maxOf(bounds.outWidth, bounds.outHeight) / (sample * 2) >= MAX_EDGE) sample *= 2
            val raw = context.contentResolver.openInputStream(uri)?.use {
                BitmapFactory.decodeStream(it, null, BitmapFactory.Options().apply { inSampleSize = sample })
            } ?: return null
            val rotation = context.contentResolver.openInputStream(uri)?.use {
                when (ExifInterface(it).getAttributeInt(ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_NORMAL)) {
                    ExifInterface.ORIENTATION_ROTATE_90 -> 90f
                    ExifInterface.ORIENTATION_ROTATE_180 -> 180f
                    ExifInterface.ORIENTATION_ROTATE_270 -> 270f
                    else -> 0f
                }
            } ?: 0f
            if (rotation == 0f) raw
            else Bitmap.createBitmap(raw, 0, 0, raw.width, raw.height, Matrix().apply { postRotate(rotation) }, true)
        }
    }.getOrNull()
}

@Composable
internal fun ForgeBodyPhotosPage(onBack: () -> Unit) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var pose by remember { mutableStateOf(BodyPhotoStore.Pose.Front) }
    var photos by remember { mutableStateOf<List<BodyPhotoStore.Photo>>(emptyList()) }
    var revision by remember { mutableIntStateOf(0) }
    var deleting by remember { mutableStateOf<BodyPhotoStore.Photo?>(null) }
    var left by remember { mutableIntStateOf(0) }
    var right by remember { mutableIntStateOf(0) }
    LaunchedEffect(revision) { photos = withContext(Dispatchers.IO) { BodyPhotoStore.all(context) } }
    val series = photos.filter { it.pose == pose }
    // Oldest against newest, the comparison people want (`resetSelection`).
    LaunchedEffect(pose, series.size) { left = 0; right = (series.size - 1).coerceAtLeast(0) }
    val picker = rememberLauncherForActivityResult(ActivityResultContracts.PickVisualMedia()) { uri ->
        if (uri != null) scope.launch { withContext(Dispatchers.IO) { BodyPhotoStore.save(context, uri, pose) }; revision++ }
    }
    val poseLabel = poseLabel(pose)
    SettingsColumn {
        PageTitle(stringResource(R.string.forge_bp_title), onBack)
        Row(horizontalArrangement = Arrangement.spacedBy(ForgeMetrics.space2)) {
            BodyPhotoStore.Pose.entries.forEach { p ->
                FilterChip(selected = pose == p, onClick = { pose = p }, label = { Text(poseLabel(p)) })
            }
        }
        if (series.isEmpty()) {
            SettingsCard(title = stringResource(R.string.forge_bp_none, poseLabel.lowercase(Locale.getDefault())), blurb = null) {}
        } else {
            SettingsCard(title = stringResource(R.string.forge_bp_then_now), blurb = null) {
                Row(horizontalArrangement = Arrangement.spacedBy(ForgeMetrics.space2)) {
                    PhotoPane(series, left, Modifier.weight(1f)) { left = it }
                    PhotoPane(series, right, Modifier.weight(1f)) { right = it }
                }
                if (series.size < 2) {
                    Text(stringResource(R.string.forge_bp_second), style = Forge.type.caption, color = Forge.colors.textSecondary)
                }
            }
            SettingsCard(title = stringResource(R.string.forge_bp_every), blurb = series.size.toString()) {
                series.reversed().forEach { photo ->
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text(photo.day, style = Forge.type.subhead, color = Forge.colors.text, modifier = Modifier.weight(1f))
                        IconButton(onClick = { deleting = photo }) {
                            Icon(Icons.Rounded.Delete, contentDescription = stringResource(R.string.forge_bp_delete_this),
                                 tint = Forge.colors.textTertiary)
                        }
                    }
                }
            }
        }
        val hasToday = series.any { it.day == LocalDate.now().toString() }
        SettingsCard(title = null, blurb = null) {
            Text(stringResource(when (pose) {
                BodyPhotoStore.Pose.Front -> R.string.forge_bp_guide_front
                BodyPhotoStore.Pose.Side -> R.string.forge_bp_guide_side
                BodyPhotoStore.Pose.Back -> R.string.forge_bp_guide_back
            }), style = Forge.type.subhead, color = Forge.colors.textSecondary)
            TextButton(onClick = { picker.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly)) }) {
                Text(stringResource(if (hasToday) R.string.forge_bp_rechoose else R.string.forge_bp_choose))
            }
            if (hasToday) {
                Text(stringResource(R.string.forge_bp_replaces), style = Forge.type.caption, color = Forge.colors.textTertiary)
            }
        }
        SettingsCard(title = null, blurb = null) {
            Text(stringResource(R.string.forge_bp_privacy), style = Forge.type.caption, color = Forge.colors.textTertiary)
        }
    }
    deleting?.let { photo ->
        AlertDialog(
            onDismissRequest = { deleting = null },
            title = { Text(stringResource(R.string.forge_bp_delete_q, poseLabel(photo.pose).lowercase(Locale.getDefault()), photo.day)) },
            text = { Text(stringResource(R.string.forge_bp_delete_detail)) },
            confirmButton = {
                TextButton(onClick = {
                    deleting = null
                    scope.launch { withContext(Dispatchers.IO) { BodyPhotoStore.delete(photo) }; revision++ }
                }) { Text(stringResource(R.string.forge_bp_delete), color = ForgeTokens.Color.systemRed.resolve()) }
            },
            dismissButton = { TextButton(onClick = { deleting = null }) { Text(stringResource(R.string.forge_bp_cancel)) } },
        )
    }
}

@Composable
private fun poseLabel(pose: BodyPhotoStore.Pose) = stringResource(when (pose) {
    BodyPhotoStore.Pose.Front -> R.string.forge_bp_front
    BodyPhotoStore.Pose.Side -> R.string.forge_bp_side
    BodyPhotoStore.Pose.Back -> R.string.forge_bp_back
})

/** One side of the comparison; tapping the date steps to the next shot of this pose. */
@Composable
private fun PhotoPane(series: List<BodyPhotoStore.Photo>, index: Int, modifier: Modifier, onIndex: (Int) -> Unit) {
    val photo = series.getOrNull(index)
    val bitmap by produceState<Bitmap?>(null, photo?.file?.path, photo?.file?.lastModified()) {
        value = photo?.let { withContext(Dispatchers.IO) { BodyPhotoStore.load(it) } }
    }
    Column(modifier, horizontalAlignment = Alignment.CenterHorizontally) {
        val shape = RoundedCornerShape(ForgeMetrics.groupedRadius)
        val image = bitmap
        if (image != null) {
            Image(image.asImageBitmap(), contentDescription = photo?.day, contentScale = ContentScale.Fit,
                  modifier = Modifier.fillMaxWidth().clip(shape))
        } else {
            Box(Modifier.fillMaxWidth().aspectRatio(3f / 4f).clip(shape).background(Forge.colors.border))
        }
        Spacer(Modifier.fillMaxWidth())
        if (photo != null) {
            TextButton(enabled = series.size > 1, onClick = { onIndex((index + 1) % series.size) }) {
                Text(photo.day, style = Forge.type.caption)
            }
        }
    }
}
