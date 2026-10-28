package com.noop.ui.forge

import android.graphics.ImageDecoder
import android.graphics.drawable.AnimatedImageDrawable
import android.graphics.drawable.BitmapDrawable
import android.graphics.drawable.Drawable
import android.widget.ImageView
import android.widget.VideoView
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.viewinterop.AndroidView
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.noop.R
import com.noop.core.CoreExerciseMedia
import com.noop.ui.NoopPrefs
import com.noop.ui.rememberPoseStill
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File

/** Optional files are separate from the catalogue and require a rights/source disclosure before download. */
@Composable
fun ForgeExerciseMediaSettings(onClose: () -> Unit) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var info by remember { mutableStateOf<CoreExerciseMedia.Info?>(null) }
    var revision by remember { mutableIntStateOf(0) }
    var disclosure by remember { mutableStateOf(false) }
    var failed by remember { mutableStateOf(false) }
    var busy by remember { mutableStateOf(false) }
    var presentation by remember { mutableStateOf(NoopPrefs.of(context).getString("training.mediaPresentation", "large") ?: "large") }
    LaunchedEffect(revision) {
        do {
            info = withContext(Dispatchers.IO) { CoreExerciseMedia.info(context) }
            val running = info?.state in listOf("downloading", "installing")
            if (running) delay(1_000)
        } while (running)
    }
    fun change(block: () -> Boolean) = scope.launch {
        busy = true; failed = false
        val ok = withContext(Dispatchers.IO) { runCatching(block).getOrDefault(false) }
        failed = !ok; busy = false; revision++
    }
    BackHandler { if (disclosure) disclosure = false else onClose() }
    SettingsColumn {
        PageTitle(stringResource(R.string.forge_media_title), onClose)
        ForgeCard(Modifier.fillMaxWidth()) {
            ReportNote(stringResource(R.string.forge_media_optional))
            val ids = listOf("large", "small", "hidden")
            val labels = listOf(stringResource(R.string.forge_media_large), stringResource(R.string.forge_media_small), stringResource(R.string.forge_media_hidden))
            ReportPicker(labels[ids.indexOf(presentation).coerceAtLeast(0)], labels) { index ->
                presentation = ids[index]
                NoopPrefs.of(context).edit().putString("training.mediaPresentation", presentation).apply()
            }
        }
        val current = info
        if (current == null) {
            ReportNote(stringResource(R.string.forge_library_unavailable))
            TextButton(onClick = { revision++ }) { Text(stringResource(R.string.forge_report_retry)) }
            return@SettingsColumn
        }
        ForgeCard(Modifier.fillMaxWidth()) {
            ReportHeading(stringResource(when (current.state) {
                "ready" -> R.string.forge_media_downloaded
                "downloading" -> R.string.forge_media_downloading
                "installing" -> R.string.forge_media_installing
                "disabled" -> R.string.forge_media_disabled
                "failed" -> R.string.forge_media_title
                else -> R.string.forge_media_missing
            }))
            if (current.state == "ready") {
                ReportFact(stringResource(R.string.forge_media_size), android.text.format.Formatter.formatFileSize(context, current.bytes))
                ReportFact(stringResource(R.string.forge_media_files), current.files.toString())
                current.checksum?.let { ReportFact(stringResource(R.string.forge_media_checksum), it.take(16)) }
            }
            if (current.state == "downloading") current.progress?.let {
                LinearProgressIndicator(progress = { it }, modifier = Modifier.fillMaxWidth())
            } ?: LinearProgressIndicator(Modifier.fillMaxWidth())
            if (current.state == "installing" || busy) LinearProgressIndicator(Modifier.fillMaxWidth())
            if (current.error != null && current.state !in listOf("downloading", "installing")) ReportNote(stringResource(mediaErrorResource(current.error)))
            if (failed) ReportNote(stringResource(R.string.forge_media_action_failed))
            if (current.withdrawn) ReportNote(stringResource(R.string.forge_media_withdrawn))
            if (!current.withdrawn) Row(Modifier.fillMaxWidth()) {
                Text(stringResource(R.string.forge_media_disable), style = Forge.type.subhead,
                    color = Forge.colors.text, modifier = Modifier.weight(1f))
                Switch(current.disabled, enabled = !busy, onCheckedChange = { value -> change { CoreExerciseMedia.setDisabled(context, value); true } })
            }
            if (!current.disabled && !current.withdrawn && current.state !in listOf("downloading", "installing")) {
                TextButton(enabled = !busy, onClick = { disclosure = true }) { Text(stringResource(R.string.forge_media_download)) }
            }
            if (current.state == "downloading" || current.state == "installing") TextButton(enabled = !busy,
                onClick = { change { CoreExerciseMedia.cancel(context); true } }) { Text(stringResource(R.string.forge_media_cancel_download)) }
            TextButton(enabled = !busy, onClick = { change { CoreExerciseMedia.delete(context) } }) { Text(stringResource(R.string.forge_media_delete)) }
        }
        ForgeCard(Modifier.fillMaxWidth()) {
            ReportHeading(stringResource(R.string.forge_media_source_rights))
            ReportNote(current.provider.source)
            ReportFact(stringResource(R.string.forge_media_holder), current.provider.rightsHolder)
            ReportNote(current.provider.attribution)
            ReportNote(stringResource(R.string.forge_media_rights))
        }
    }
    if (disclosure && info != null) AlertDialog(onDismissRequest = { disclosure = false },
        title = { Text(stringResource(R.string.forge_media_confirm_title)) },
        text = { Column(Modifier.verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(ForgeMetrics.gap)) {
            val provider = info!!.provider
            ReportNote(provider.source)
            ReportNote(provider.attribution)
            ReportNote(stringResource(R.string.forge_media_rights))
            ReportFact(stringResource(R.string.forge_media_size), android.text.format.Formatter.formatFileSize(context, provider.approximateBytes))
            ReportNote(stringResource(R.string.forge_media_external))
        } },
        confirmButton = { TextButton(onClick = { disclosure = false; change { CoreExerciseMedia.begin(context) } }) {
            Text(stringResource(R.string.forge_media_confirm))
        } }, dismissButton = { TextButton(onClick = { disclosure = false }) { Text(stringResource(R.string.forge_report_cancel)) } })
}

/** Decode and play local media only. Missing or corrupt media leaves the existing muscle/text fallback. */
@Composable
internal fun ForgeLocalExerciseMedia(exerciseId: String, title: String, thumbnail: Boolean = false) {
    val context = LocalContext.current
    val poseStill = rememberPoseStill()
    val mediaRevision by CoreExerciseMedia.changes.collectAsStateWithLifecycle()
    val presentation = NoopPrefs.of(context).getString("training.mediaPresentation", "large")
    if (presentation == "hidden") return
    var path by remember(exerciseId) { mutableStateOf<String?>(null) }
    var drawable by remember(exerciseId, poseStill) { mutableStateOf<Drawable?>(null) }
    LaunchedEffect(exerciseId, poseStill, mediaRevision) {
        path = null; drawable = null
        path = withContext(Dispatchers.IO) { CoreExerciseMedia.resolve(context, exerciseId, thumbnail || poseStill) }
        val file = path?.let(::File) ?: return@LaunchedEffect
        if (file.extension.lowercase() !in listOf("mp4", "mov", "m4v")) {
            drawable = withContext(Dispatchers.IO) { runCatching {
                val source = ImageDecoder.createSource(file)
                val limit = if (thumbnail) 256 else 960
                if (poseStill || thumbnail) BitmapDrawable(context.resources, ImageDecoder.decodeBitmap(source) { decoder, info, _ ->
                    decoder.setTargetSampleSize((maxOf(info.size.width, info.size.height) / limit).coerceAtLeast(1))
                }) else ImageDecoder.decodeDrawable(source) { decoder, info, _ ->
                    decoder.setTargetSampleSize((maxOf(info.size.width, info.size.height) / limit).coerceAtLeast(1))
                }
            }.getOrNull() }
        }
    }
    val local = path ?: return
    var videoFailed by remember(local) { mutableStateOf(false) }
    val height = if (thumbnail || presentation == "small") ForgeMetrics.chartHeight / 2 else ForgeMetrics.chartHeight
    Column(Modifier.fillMaxWidth()) {
        if (!videoFailed && File(local).extension.lowercase() in listOf("mp4", "mov", "m4v")) {
            AndroidView(factory = { VideoView(it).apply {
                contentDescription = title
                setVideoPath(local)
                setOnErrorListener { _, _, _ -> videoFailed = true; true }
                setOnPreparedListener { player -> player.isLooping = true; player.setVolume(0f, 0f); if (!poseStill) start() else seekTo(1) }
            } }, modifier = Modifier.fillMaxWidth().height(height),
                update = { if (poseStill) it.pause() else it.start() }, onRelease = { it.stopPlayback() })
        } else drawable?.let { image ->
            AndroidView(factory = { ImageView(it).apply { scaleType = ImageView.ScaleType.FIT_CENTER; contentDescription = title } },
                modifier = Modifier.fillMaxWidth().height(height),
                update = { view -> view.setImageDrawable(image); (image as? AnimatedImageDrawable)?.let { if (poseStill || thumbnail) it.stop() else it.start() } },
                onRelease = { (it.drawable as? AnimatedImageDrawable)?.stop(); it.setImageDrawable(null) })
        }
        if (drawable != null || !videoFailed && File(local).extension.lowercase() in listOf("mp4", "mov", "m4v")) ReportNote(stringResource(R.string.forge_media_credit))
    }
}

private fun mediaErrorResource(code: String): Int = when (code) {
    "unsafeArchive" -> R.string.forge_media_unsafe
    "packTooLarge" -> R.string.forge_media_too_large
    "checksumMismatch" -> R.string.forge_media_checksum_failed
    "notEnoughSpace" -> R.string.forge_media_no_space
    "downloadFailed" -> R.string.forge_media_network_failed
    else -> R.string.forge_media_failed
}
