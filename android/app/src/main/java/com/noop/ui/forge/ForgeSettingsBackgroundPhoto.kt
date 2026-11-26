package com.noop.ui.forge

import android.net.Uri
import android.widget.Toast
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.noop.R
import com.noop.ui.BackgroundFillMode
import com.noop.ui.BackgroundImageStore
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** The name of a scaling choice, iOS's `BackgroundFillMode.label`. */
@Composable
private fun BackgroundFillMode.label(): String = stringResource(when (this) {
    BackgroundFillMode.FILL -> R.string.fsp4_bg_fill
    BackgroundFillMode.FIT -> R.string.fsp4_bg_fit
    BackgroundFillMode.STRETCH -> R.string.fsp4_bg_stretch
    BackgroundFillMode.TILE -> R.string.fsp4_bg_tile
})

/**
 * The custom photo controls at the foot of Settings › Appearance › Background, as iOS's `backgroundImageControls`:
 * choose (or replace) from the photo picker, browse the files, the recent pictures to bring back, the "Custom photo"
 * switch, the fit menu, Remove, and the note that it stays on the phone. The picture and its choices live in
 * [BackgroundImageStore], which every screen's backdrop already reads, so a change shows at once.
 */
@Composable
internal fun ColumnScope.BackgroundPhotoControls() {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val problem = stringResource(R.string.fsp4_bg_problem)
    // Both sources hand a uri to the store, which reads it once, scales it down and keeps a private copy; nothing is
    // uploaded and no storage permission is asked for.
    val use: (Uri) -> Unit = { uri ->
        scope.launch {
            val ok = withContext(Dispatchers.IO) { BackgroundImageStore.setImageFromUri(context, uri) }
            if (!ok) Toast.makeText(context, problem, Toast.LENGTH_LONG).show()
        }
    }
    val photos = rememberLauncherForActivityResult(ActivityResultContracts.PickVisualMedia()) { uri -> if (uri != null) use(uri) }
    val files = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri -> if (uri != null) use(uri) }
    val hasImage = BackgroundImageStore.hasImage
    Row(Modifier.fillMaxWidth().padding(vertical = ForgeMetrics.space2), horizontalArrangement = Arrangement.spacedBy(ForgeMetrics.space2)) {
        PhotoButton(stringResource(if (hasImage) R.string.cx_replace_from_photos else R.string.cx_choose_from_photos),
                    Modifier.weight(1f)) {
            photos.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly))
        }
        PhotoButton(stringResource(R.string.cx_browse_files), Modifier.weight(1f)) { files.launch(arrayOf("image/*")) }
    }
    if (hasImage) {
        // The first picture is the one in use; tapping another brings it back with the fit it last had.
        val recents = BackgroundImageStore.recents
        if (recents.isNotEmpty()) {
            Column(Modifier.padding(bottom = ForgeMetrics.space2), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                Text(stringResource(R.string.cx_recent), style = Forge.type.footnote, color = Forge.colors.textSecondary)
                Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    recents.forEachIndexed { i, recent ->
                        RecentPhoto(BackgroundImageStore.thumbnails.getOrNull(i), recent.fillMode, active = i == 0) {
                            scope.launch { withContext(Dispatchers.IO) { BackgroundImageStore.applyRecent(context, i) } }
                        }
                    }
                }
            }
        }
        ToggleRow(stringResource(R.string.fsp4_bg_custom_photo), null, BackgroundImageStore.enabled) {
            BackgroundImageStore.setEnabled(context, it)
        }
        RowDivider()
        SettingRow(stringResource(R.string.fsp4_bg_fit_label)) {
            MenuPicker(BackgroundImageStore.fillMode.label(), BackgroundFillMode.entries.toList(), label = { it.label() },
                       onSelect = { BackgroundImageStore.setFillMode(context, it) })
        }
        TextButton(onClick = { scope.launch { withContext(Dispatchers.IO) { BackgroundImageStore.clearImage(context) } } }) {
            Text(stringResource(R.string.cx_remove_image), color = Forge.colors.textSecondary)
        }
    }
    Text(stringResource(R.string.fsp4_bg_photo_note), style = Forge.type.caption, color = Forge.colors.textTertiary)
}

/** A choice that opens the picker: the inset block the Profile photo row uses. */
@Composable
private fun PhotoButton(text: String, modifier: Modifier, onClick: () -> Unit) {
    Box(modifier.heightIn(min = 48.dp).background(Forge.colors.inset, RoundedCornerShape(14.dp))
            .clickable(role = Role.Button, onClick = onClick), contentAlignment = Alignment.Center) {
        Text(text, style = Forge.type.body.copy(fontWeight = FontWeight.SemiBold), color = Forge.colors.accent)
    }
}

/** One recent picture: a small cropped thumbnail, ringed in the accent while it is the one in use, over its fit. */
@Composable
private fun RecentPhoto(thumb: ImageBitmap?, mode: BackgroundFillMode, active: Boolean, onClick: () -> Unit) {
    val shape = RoundedCornerShape(10.dp)
    val colors = Forge.colors
    Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(3.dp)) {
        Box(Modifier.size(64.dp).clip(shape)
                .border(if (active) 2.dp else ForgeMetrics.hairline, if (active) colors.accent else colors.border, shape)
                .clickable(role = Role.Button, onClick = onClick)) {
            if (thumb != null) Image(thumb, contentDescription = null, modifier = Modifier.fillMaxSize(), contentScale = ContentScale.Crop)
            else Box(Modifier.fillMaxSize().background(colors.inset))
        }
        Text(mode.label(), style = Forge.type.caption, color = if (active) colors.accent else colors.textTertiary)
    }
}
