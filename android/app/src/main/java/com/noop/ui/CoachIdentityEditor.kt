package com.noop.ui

import android.graphics.BitmapFactory
import android.net.Uri
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
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.AccountCircle
import androidx.compose.material.icons.filled.AutoAwesome
import androidx.compose.material.icons.filled.DirectionsRun
import androidx.compose.material.icons.filled.Eco
import androidx.compose.material.icons.filled.FitnessCenter
import androidx.compose.material.icons.filled.LocalFireDepartment
import androidx.compose.material.icons.filled.MonitorHeart
import androidx.compose.material.icons.filled.PhotoLibrary
import androidx.compose.material.icons.filled.SelfImprovement
import androidx.compose.material.icons.filled.SportsGymnastics
import androidx.compose.material3.Icon
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.compositionLocalOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.noop.R
import com.noop.core.CoreCoach
import java.io.File
import java.util.UUID

/** The identity the coach screens draw their avatar from; null until the shared coach has answered. */
internal val LocalCoachIdentity = compositionLocalOf<CoreCoach.Identity?> { null }

/** Where a coach photo lives: app files, never the backup or the provider (`CoachIdentityStore.photoDirectory`). */
private fun photoFile(context: android.content.Context, name: String) = File(File(context.filesDir, "coach-avatar"), name)

/** The Material twin of each `CoachAvatar.presetSymbols` SF Symbol, in the same order. */
private val symbolIcons: Map<String, ImageVector> = mapOf(
    "figure.mind.and.body" to Icons.Filled.SelfImprovement,
    "figure.strengthtraining.traditional" to Icons.Filled.FitnessCenter,
    "figure.run" to Icons.Filled.DirectionsRun,
    "figure.cooldown" to Icons.Filled.SportsGymnastics,
    "sparkles" to Icons.Filled.AutoAwesome,
    "leaf.fill" to Icons.Filled.Eco,
    "flame.fill" to Icons.Filled.LocalFireDepartment,
    "bolt.heart.fill" to Icons.Filled.MonitorHeart,
    "person.crop.circle.fill" to Icons.Filled.AccountCircle,
)

/**
 * The coach's picture, as `CoachAvatarView`: Svea's or Marv's portrait, a chosen symbol on an accent disc, or the
 * wearer's own photo, in a thin ring. Svea until the identity is known.
 */
@Composable
internal fun CoachIdentityAvatar(identity: CoreCoach.Identity?, size: Dp) {
    val context = LocalContext.current
    val ring = Palette.textPrimary.copy(alpha = 0.22f)
    Box(
        Modifier.size(size).clip(CircleShape).border(if (size >= 60.dp) 3.dp else 1.5.dp, ring, CircleShape),
        contentAlignment = Alignment.Center,
    ) {
        when (identity?.avatarKind) {
            "preset" -> Box(Modifier.matchParentSize().background(Palette.accent), contentAlignment = Alignment.Center) {
                Icon(symbolIcons[identity.avatarValue] ?: Icons.Filled.AccountCircle, contentDescription = null,
                     tint = Palette.surfaceBase, modifier = Modifier.size(size * 0.5f))
            }
            "photo" -> {
                val bitmap = remember(identity.avatarValue) {
                    runCatching { BitmapFactory.decodeFile(photoFile(context, identity.avatarValue).path)?.asImageBitmap() }.getOrNull()
                }
                if (bitmap != null) Image(bitmap, null, contentScale = ContentScale.Crop, modifier = Modifier.matchParentSize())
                else Image(painterResource(R.drawable.coach_svea_avatar), null, contentScale = ContentScale.Crop,
                           modifier = Modifier.matchParentSize())
            }
            else -> Image(
                painterResource(if (identity?.avatarValue == "marv-avatar") R.drawable.coach_marv_avatar else R.drawable.coach_svea_avatar),
                null, contentScale = ContentScale.Crop, modifier = Modifier.matchParentSize(),
            )
        }
    }
}

/**
 * The coach's identity, as `CoachIdentityEditor`: start from Svea or Marv, then the name, the picture (a symbol or
 * a photo that stays on the phone) and the tone. Name and tone reach the coach's prompt; the picture never does.
 */
@Composable
@OptIn(ExperimentalLayoutApi::class)
fun CoachIdentityEditor(vm: CoachViewModel) {
    val context = LocalContext.current
    val identity by vm.identity.collectAsStateWithLifecycle()
    LaunchedEffect(Unit) { vm.loadCoachName() }
    val current = identity
    var nameDraft by remember(current?.name) { mutableStateOf(current?.name.orEmpty()) }

    val picker = rememberLauncherForActivityResult(ActivityResultContracts.PickVisualMedia()) { uri: Uri? ->
        if (uri == null) return@rememberLauncherForActivityResult
        val name = "coach-avatar-${UUID.randomUUID()}.img"
        val stored = runCatching {
            val dir = File(context.filesDir, "coach-avatar").apply { mkdirs() }
            context.contentResolver.openInputStream(uri)?.use { input -> File(dir, name).outputStream().use { input.copyTo(it) } }
        }.isSuccess
        if (stored) {
            val previous = current?.takeIf { it.avatarKind == "photo" }?.avatarValue
            vm.updateIdentity(avatarKind = "photo", avatarValue = name)
            previous?.let { photoFile(context, it).delete() }
        }
    }
    fun dropPhoto() {
        current?.takeIf { it.avatarKind == "photo" }?.let { photoFile(context, it.avatarValue).delete() }
    }

    ScreenScaffold(title = stringResource(R.string.coach_identity)) {
        Column(verticalArrangement = Arrangement.spacedBy(16.dp)) {
            NoopCard(padding = 14.dp, tint = Palette.chargeColor) {
                Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    Overline(stringResource(R.string.coach_identity_start))
                    Text(stringResource(R.string.coach_identity_start_body), style = NoopType.footnote, color = Palette.textSecondary)
                    Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                        listOf("svea" to "Svea", "marv" to "Marv").forEach { (id, label) ->
                            val selected = current?.avatarKind == "bundled" && current.avatarValue == "$id-avatar"
                            Row(
                                Modifier.weight(1f).clip(RoundedCornerShape(16.dp))
                                    .background(if (selected) Palette.accent.copy(alpha = 0.18f) else Palette.surfaceInset)
                                    .border(1.dp, if (selected) Palette.accent else Palette.hairline, RoundedCornerShape(16.dp))
                                    .clickable { dropPhoto(); vm.updateIdentity(preset = id) }
                                    .padding(10.dp)
                                    .semantics { contentDescription = context.getString(R.string.coach_identity_use_preset, label) },
                                verticalAlignment = Alignment.CenterVertically,
                                horizontalArrangement = Arrangement.spacedBy(10.dp),
                            ) {
                                CoachIdentityAvatar(CoreCoach.Identity(label, "bundled", "$id-avatar", "", emptyList()), 40.dp)
                                Text(label, style = NoopType.headline, color = Palette.textPrimary)
                            }
                        }
                    }
                }
            }
            NoopCard(padding = 14.dp, tint = Palette.chargeColor) {
                Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                    Overline(stringResource(R.string.coach_identity_name))
                    OutlinedTextField(
                        value = nameDraft,
                        onValueChange = { nameDraft = it; if (it.isNotBlank()) vm.updateIdentity(name = it) },
                        placeholder = { Text(stringResource(R.string.coach_identity_name_placeholder)) },
                        singleLine = true, colors = coachFieldColors(), shape = RoundedCornerShape(14.dp),
                        modifier = Modifier.fillMaxWidth(),
                    )
                }
            }
            NoopCard(padding = 14.dp, tint = Palette.chargeColor) {
                Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    Overline(stringResource(R.string.coach_identity_picture))
                    FlowRow(horizontalArrangement = Arrangement.spacedBy(12.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                        (current?.symbols ?: symbolIcons.keys.toList()).forEach { symbol ->
                            val selected = current?.avatarKind == "preset" && current.avatarValue == symbol
                            Box(
                                Modifier.size(52.dp).clip(CircleShape)
                                    .background(if (selected) Palette.accent else Palette.accent.copy(alpha = 0.12f))
                                    .border(1.dp, if (selected) Palette.accent else Palette.hairline, CircleShape)
                                    .clickable { dropPhoto(); vm.updateIdentity(avatarKind = "preset", avatarValue = symbol) }
                                    .semantics {
                                        contentDescription = context.getString(R.string.coach_identity_avatar_option)
                                        this.selected = selected
                                    },
                                contentAlignment = Alignment.Center,
                            ) {
                                Icon(symbolIcons[symbol] ?: Icons.Filled.AccountCircle, contentDescription = null,
                                     tint = if (selected) Palette.surfaceBase else Palette.accent, modifier = Modifier.size(24.dp))
                            }
                        }
                    }
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Row(
                            Modifier.clip(RoundedCornerShape(50)).clickable {
                                picker.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly))
                            }.padding(vertical = 6.dp),
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(6.dp),
                        ) {
                            Icon(Icons.Filled.PhotoLibrary, contentDescription = null, tint = Palette.accent, modifier = Modifier.size(18.dp))
                            Text(stringResource(R.string.coach_identity_upload_photo), style = NoopType.footnote, color = Palette.accent)
                        }
                        Spacer(Modifier.weight(1f))
                        if (current?.avatarKind == "photo") {
                            Text(
                                stringResource(R.string.coach_identity_remove_photo), style = NoopType.footnote,
                                color = Palette.textSecondary,
                                modifier = Modifier.clip(RoundedCornerShape(50)).clickable {
                                    // A plain, neutral symbol, as on iOS: not Svea's or Marv's portrait.
                                    dropPhoto(); vm.updateIdentity(avatarKind = "preset", avatarValue = "person.crop.circle.fill")
                                }.padding(vertical = 6.dp),
                            )
                        }
                    }
                    Text(stringResource(R.string.coach_identity_photo_note), style = NoopType.caption, color = Palette.textTertiary)
                }
            }
            NoopCard(padding = 14.dp, tint = Palette.chargeColor) {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Overline(stringResource(R.string.coach_identity_tone))
                    Row(
                        Modifier.fillMaxWidth().clip(RoundedCornerShape(12.dp)).background(Palette.surfaceInset).padding(3.dp),
                    ) {
                        listOf("warm" to R.string.coach_voice_warm, "grounded" to R.string.coach_voice_grounded,
                               "neutral" to R.string.coach_voice_neutral).forEach { (id, label) ->
                            val selected = current?.voice == id
                            Box(
                                Modifier.weight(1f).clip(RoundedCornerShape(10.dp))
                                    .background(if (selected) Palette.surfaceRaised else androidx.compose.ui.graphics.Color.Transparent)
                                    .clickable { vm.updateIdentity(voice = id) }
                                    .padding(vertical = 8.dp)
                                    .semantics { this.selected = selected },
                                contentAlignment = Alignment.Center,
                            ) {
                                Text(stringResource(label), style = NoopType.subhead,
                                     color = if (selected) Palette.textPrimary else Palette.textSecondary)
                            }
                        }
                    }
                    Text(stringResource(R.string.coach_identity_tone_note), style = NoopType.caption, color = Palette.textTertiary)
                }
            }
        }
    }
}
