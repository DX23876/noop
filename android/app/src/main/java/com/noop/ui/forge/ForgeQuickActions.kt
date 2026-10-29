package com.noop.ui.forge

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Add
import androidx.compose.material.icons.rounded.Air
import androidx.compose.material.icons.rounded.BatteryFull
import androidx.compose.material.icons.rounded.DirectionsRun
import androidx.compose.material.icons.rounded.EditNote
import androidx.compose.material.icons.rounded.MonitorHeart
import androidx.compose.material.icons.rounded.Tune
import androidx.compose.material.icons.rounded.TrackChanges
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import androidx.compose.material.icons.rounded.Shield
import androidx.compose.ui.platform.LocalContext
import com.noop.R
import com.noop.ui.AppViewModel
import com.noop.ui.ProfileAvatar
import kotlin.math.roundToInt

/** What the Today header's "+" opens, after the iOS `QuickAction`. */
enum class QuickAction { Battery, Live, Workout, Journal, Breathe, Goals, LiveSession, CustomizeToday }

/** The header's trailing pair after iOS (`headerProfileButton`, `LiquidAddButton`): the profile photo, then "+". */
@Composable
internal fun TodayHeaderButtons(onProfile: () -> Unit, onQuickActions: () -> Unit, modifier: Modifier = Modifier) {
    val colors = Forge.colors
    val profileLabel = stringResource(R.string.forge_qa_profile_settings)
    val quickLabel = stringResource(R.string.forge_qa_quick_actions)
    Row(modifier, horizontalArrangement = Arrangement.spacedBy(ForgeMetrics.space3), verticalAlignment = Alignment.CenterVertically) {
        ProfileAvatar(size = HEADER_BUTTON, contentDescription = profileLabel,
                      modifier = Modifier.clickable(role = Role.Button, onClick = onProfile))
        Box(Modifier.size(HEADER_BUTTON).background(colors.heroFill, CircleShape).border(1.dp, colors.heroBorder, CircleShape)
                .clickable(role = Role.Button, onClick = onQuickActions).semantics { contentDescription = quickLabel },
            contentAlignment = Alignment.Center) {
            Icon(Icons.Rounded.Add, contentDescription = null, tint = colors.text, modifier = Modifier.size(20.dp))
        }
    }
}

/** `NoopMetrics.compactControlSize`. */
private val HEADER_BUTTON = 36.dp

/**
 * The quick-action sheet after the iOS `QuickActionSheet`: the strap's charge and link on top, then the quick
 * actions, then "Customize home". Android has no Silent Guardian screen yet, so that row is left out.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun ForgeQuickActionSheet(viewModel: AppViewModel, onDismiss: () -> Unit, onPick: (QuickAction) -> Unit) {
    val colors = Forge.colors
    val live by viewModel.live.collectAsState()
    val name by viewModel.activeDeviceName.collectAsState()
    // The device row's line as iOS resolves it (`StrapBatteryDisplayState`); no row without a strap.
    val status: String? = when {
        name == null -> null
        !(live.connected || live.bonded) -> stringResource(R.string.forge_qa_not_connected)
        live.backfilling -> stringResource(R.string.forge_qa_syncing)
        live.charging == true -> stringResource(R.string.forge_qa_charging)
        live.batteryPct != null -> stringResource(R.string.forge_qa_connected_battery, live.batteryPct!!.roundToInt())
        else -> stringResource(R.string.forge_qa_connected)
    }
    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
                     containerColor = colors.surface) {
        Column(Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).navigationBarsPadding()
                   .padding(horizontal = ForgeMetrics.screenPadding).padding(bottom = ForgeMetrics.space4),
               verticalArrangement = Arrangement.spacedBy(ForgeMetrics.space2)) {
            if (status != null) {
                ActionRow(stringResource(R.string.forge_qa_battery), Icons.Rounded.BatteryFull,
                          ForgeTokens.Color.systemGreen.resolve(), status) { onPick(QuickAction.Battery) }
                Spacer(Modifier.size(ForgeMetrics.space2))
            }
            Text(stringResource(R.string.forge_qa_header), style = Forge.type.overline, color = colors.textSecondary,
                 modifier = Modifier.padding(bottom = ForgeMetrics.space1))
            ActionRow(stringResource(R.string.forge_qa_live_hr), Icons.Rounded.MonitorHeart, colors.heart) { onPick(QuickAction.Live) }
            ActionRow(stringResource(R.string.forge_qa_start_workout), Icons.Rounded.DirectionsRun, colors.effort) { onPick(QuickAction.Workout) }
            ActionRow(stringResource(R.string.forge_qa_log_journal), Icons.Rounded.EditNote,
                      ForgeTokens.Color.systemOrange.resolve()) { onPick(QuickAction.Journal) }
            ActionRow(stringResource(R.string.forge_qa_breathe), Icons.Rounded.Air, colors.rest) { onPick(QuickAction.Breathe) }
            ActionRow(stringResource(R.string.forge_lay_section_goals), Icons.Rounded.TrackChanges, colors.charge) { onPick(QuickAction.Goals) }
            // The guided session (iOS "Silent Guardian"), while its beta switch is on (Settings › Training).
            if (com.noop.ui.LiveSessionPrefs.enabled(LocalContext.current)) {
                ActionRow(stringResource(R.string.forge_qa_guardian), Icons.Rounded.Shield, ForgeTokens.Color.systemCyan.resolve(),
                          stringResource(R.string.forge_qa_guardian_sub)) { onPick(QuickAction.LiveSession) }
            }
            HorizontalDivider(color = colors.divider, modifier = Modifier.padding(vertical = ForgeMetrics.space3))
            ActionRow(stringResource(R.string.forge_qa_customize_home), Icons.Rounded.Tune, colors.textSecondary) {
                onPick(QuickAction.CustomizeToday)
            }
        }
    }
}

/** One flat action row: the hued icon tile and its title, on an inset surface with a hairline. */
@Composable
private fun ActionRow(title: String, icon: ImageVector, tint: Color, subtitle: String? = null, onClick: () -> Unit) {
    val colors = Forge.colors
    Row(Modifier.fillMaxWidth().heightIn(min = 56.dp).background(colors.inset, RoundedCornerShape(14.dp))
            .border(1.dp, colors.border, RoundedCornerShape(14.dp)).clickable(role = Role.Button, onClick = onClick)
            .padding(horizontal = 12.dp, vertical = 9.dp),
        verticalAlignment = Alignment.CenterVertically) {
        Box(Modifier.size(38.dp).background(tint, RoundedCornerShape(10.dp)), contentAlignment = Alignment.Center) {
            Icon(icon, contentDescription = null, tint = Color.White, modifier = Modifier.size(20.dp))
        }
        Spacer(Modifier.width(13.dp))
        Column(Modifier.weight(1f)) {
            Text(title, style = Forge.type.body, color = colors.text)
            if (subtitle != null) Text(subtitle, style = Forge.type.caption, color = colors.textSecondary)
        }
    }
}
