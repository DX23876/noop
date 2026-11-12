package com.noop.ui.forge

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.DirectionsWalk
import androidx.compose.material.icons.automirrored.rounded.MenuBook
import androidx.compose.material.icons.rounded.Accessibility
import androidx.compose.material.icons.rounded.Air
import androidx.compose.material.icons.rounded.Bedtime
import androidx.compose.material.icons.rounded.ChatBubble
import androidx.compose.material.icons.rounded.Favorite
import androidx.compose.material.icons.rounded.MedicalServices
import androidx.compose.material.icons.rounded.Mic
import androidx.compose.material.icons.rounded.PhotoCamera
import androidx.compose.material.icons.rounded.Mood
import androidx.compose.material.icons.rounded.Restaurant
import androidx.compose.material.icons.rounded.Science
import androidx.compose.material.icons.rounded.WaterDrop
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.noop.R

/**
 * What the new design's Log sheet can open, after iOS `ForgeLogChoice`. The Today shell maps each to a screen that
 * already exists, so the sheet only gathers the entry points. The coach's Photo shows only while its provider reads
 * images, as on iOS.
 */
enum class ForgeLogChoice { CoachWrite, CoachSpeak, CoachPhoto, Workout, Weight, Journal, Drink, Food, Sleep, LabMarkers, Breathe, LiveHeartRate }

private class LogItem(val choice: ForgeLogChoice, val title: Int, val icon: ImageVector, val tint: Color)

/**
 * The new design's "Log" sheet after iOS `ForgeLogSheet`: logging through the coach first (while the coach is on),
 * then the direct forms as chips in the prototype's order. Blood pressure and health records open the lab book;
 * mood and medication open the journal, where both are logged.
 */
@OptIn(ExperimentalMaterial3Api::class, ExperimentalLayoutApi::class)
@Composable
internal fun ForgeLogSheet(coachOn: Boolean, onDismiss: () -> Unit, coachPhotos: Boolean = false, onPick: (ForgeLogChoice) -> Unit) {
    val colors = Forge.colors
    val direct = listOf(
        LogItem(ForgeLogChoice.Workout, R.string.forge_log_add_workout, Icons.AutoMirrored.Rounded.DirectionsWalk, colors.effort),
        LogItem(ForgeLogChoice.Weight, R.string.forge_log_weight, Icons.Rounded.Accessibility, ForgeTokens.Color.systemPink.resolve()),
        LogItem(ForgeLogChoice.Journal, R.string.forge_log_journal, Icons.AutoMirrored.Rounded.MenuBook, ForgeTokens.Color.systemBrown.resolve()),
        LogItem(ForgeLogChoice.Drink, R.string.forge_log_drink, Icons.Rounded.WaterDrop, ForgeTokens.Color.systemCyan.resolve()),
        LogItem(ForgeLogChoice.Food, R.string.forge_log_food, Icons.Rounded.Restaurant, ForgeTokens.Color.systemOrange.resolve()),
        LogItem(ForgeLogChoice.Sleep, R.string.forge_log_sleep, Icons.Rounded.Bedtime, colors.rest),
        LogItem(ForgeLogChoice.LabMarkers, R.string.forge_log_blood_pressure, Icons.Rounded.WaterDrop, ForgeTokens.Color.systemRed.resolve()),
        LogItem(ForgeLogChoice.Journal, R.string.forge_log_mood, Icons.Rounded.Mood, ForgeTokens.Color.systemYellow.resolve()),
        LogItem(ForgeLogChoice.LabMarkers, R.string.forge_log_health_records, Icons.Rounded.Science, ForgeTokens.Color.systemPurple.resolve()),
        LogItem(ForgeLogChoice.Journal, R.string.forge_log_medication, Icons.Rounded.MedicalServices, ForgeTokens.Color.systemMint.resolve()),
        LogItem(ForgeLogChoice.Breathe, R.string.forge_log_breathe, Icons.Rounded.Air, ForgeTokens.Color.systemTeal.resolve()),
        LogItem(ForgeLogChoice.LiveHeartRate, R.string.forge_log_live_hr, Icons.Rounded.Favorite, colors.heart),
    )
    val section = Forge.type.title2.copy(fontWeight = FontWeight.Bold)
    ModalBottomSheet(onDismissRequest = onDismiss, containerColor = colors.canvas) {
        Column(Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).navigationBarsPadding()
                   .padding(horizontal = ForgeMetrics.screenPadding).padding(bottom = ForgeMetrics.space4),
               verticalArrangement = Arrangement.spacedBy(ForgeMetrics.space4)) {
            if (coachOn) {
                Text(stringResource(R.string.forge_log_with_coach), style = section, color = colors.text)
                Row(Modifier.fillMaxWidth()) {
                    CoachButton(R.string.forge_log_write, Icons.Rounded.ChatBubble, Modifier.weight(1f)) { onPick(ForgeLogChoice.CoachWrite) }
                    CoachButton(R.string.forge_log_speak, Icons.Rounded.Mic, Modifier.weight(1f)) { onPick(ForgeLogChoice.CoachSpeak) }
                    if (coachPhotos) CoachButton(R.string.forge_log_photo, Icons.Rounded.PhotoCamera, Modifier.weight(1f)) {
                        onPick(ForgeLogChoice.CoachPhoto)
                    }
                }
                Box(Modifier.fillMaxWidth().height(0.5.dp).background(colors.divider))
            }
            Text(stringResource(R.string.forge_log_yourself), style = section, color = colors.text)
            FlowRow(horizontalArrangement = Arrangement.spacedBy(ForgeMetrics.space2),
                    verticalArrangement = Arrangement.spacedBy(ForgeMetrics.space2)) {
                direct.forEach { item ->
                    Row(Modifier.heightIn(min = 40.dp).background(colors.surfaceTop, CircleShape)
                            .clickable(role = Role.Button) { onPick(item.choice) }.padding(horizontal = 14.dp),
                        horizontalArrangement = Arrangement.spacedBy(ForgeMetrics.space2), verticalAlignment = Alignment.CenterVertically) {
                        Icon(item.icon, contentDescription = null, tint = item.tint, modifier = Modifier.size(18.dp))
                        Text(stringResource(item.title), style = Forge.type.subhead.copy(fontWeight = FontWeight.Medium), color = colors.text)
                    }
                }
            }
        }
    }
}

/** One of the coach's round buttons (iOS `coachIcon`): an accent symbol in a filled circle over its label. */
@Composable
private fun CoachButton(title: Int, icon: ImageVector, modifier: Modifier, onClick: () -> Unit) {
    val colors = Forge.colors
    Column(modifier.clickable(role = Role.Button, onClick = onClick), horizontalAlignment = Alignment.CenterHorizontally,
           verticalArrangement = Arrangement.spacedBy(ForgeMetrics.space2)) {
        Box(Modifier.size(60.dp).background(colors.surfaceTop, CircleShape), contentAlignment = Alignment.Center) {
            Icon(icon, contentDescription = null, tint = colors.accent, modifier = Modifier.size(24.dp))
        }
        Text(stringResource(title), style = Forge.type.subhead.copy(fontWeight = FontWeight.SemiBold), color = colors.text)
    }
}

/** One row of a Forge drop-down menu (the header's "+"): a leading symbol and the label, as an iOS menu draws it. */
@Composable
internal fun ForgeMenuItem(title: String, icon: ImageVector, onClick: () -> Unit) {
    val colors = Forge.colors
    androidx.compose.material3.DropdownMenuItem(
        text = { Text(title, style = Forge.type.body, color = colors.text) },
        leadingIcon = { Icon(icon, contentDescription = null, tint = colors.text, modifier = Modifier.size(20.dp)) },
        onClick = onClick,
    )
}

/** A picked photo as base64 PNG with its long side at most 1024 px, as iOS scales it before the coach reads it. */
internal fun coachPhotoPng(context: android.content.Context, uri: android.net.Uri): String? = runCatching {
    val source = context.contentResolver.openInputStream(uri)?.use { android.graphics.BitmapFactory.decodeStream(it) } ?: return null
    val scale = kotlin.math.min(1.0, 1_024.0 / kotlin.math.max(source.width, source.height).coerceAtLeast(1))
    val bitmap = android.graphics.Bitmap.createScaledBitmap(source, (source.width * scale).toInt().coerceAtLeast(1),
                                                            (source.height * scale).toInt().coerceAtLeast(1), true)
    val out = java.io.ByteArrayOutputStream()
    bitmap.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, out)
    android.util.Base64.encodeToString(out.toByteArray(), android.util.Base64.NO_WRAP)
}.getOrNull()
