package com.noop.ui.forge

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
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
import androidx.compose.material.icons.rounded.Restaurant
import androidx.compose.material.icons.rounded.Battery0Bar
import androidx.compose.material.icons.rounded.BatteryFull
import androidx.compose.material.icons.rounded.Bolt
import androidx.compose.material.icons.rounded.MoreHoriz
import androidx.compose.material.icons.rounded.DirectionsRun
import androidx.compose.material.icons.rounded.EditNote
import androidx.compose.material.icons.rounded.MonitorHeart
import androidx.compose.material.icons.rounded.Tune
import androidx.compose.material.icons.rounded.TrackChanges
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.material.icons.automirrored.rounded.KeyboardArrowRight
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.unit.dp
import androidx.compose.material.icons.rounded.Shield
import androidx.compose.ui.platform.LocalContext
import com.noop.R
import com.noop.ui.AppViewModel
import com.noop.ui.ProfileAvatar
import com.noop.ui.batteryTone
import kotlin.math.roundToInt

/** What the Today header's "+" opens, after the iOS `QuickAction`. */
enum class QuickAction { Battery, Live, Workout, Journal, Food, Breathe, Goals, LiveSession, CustomizeToday }

/**
 * The header's trailing controls, in iOS's order (`DashboardBatteryButton`, `LiquidAddButton`,
 * `headerProfileButton`): the strap's charge, then "+", then the profile photo. Android drew the photo
 * first and no charge at all; both were put right on 2026-11-19 at the owner's word, because a wearer
 * moving between the two phones reaches for the control that sits where the other one has it.
 *
 * [viewModel] and [onBattery] are optional because only the new design's header carries the charge; a
 * caller that passes neither gets the pair it always had.
 */
@Composable
internal fun TodayHeaderButtons(onProfile: () -> Unit, onQuickActions: () -> Unit, modifier: Modifier = Modifier,
                                viewModel: AppViewModel? = null, onBattery: (() -> Unit)? = null,
                                coach: (@Composable () -> Unit)? = null,
                                menu: (@Composable ColumnScope.(close: () -> Unit) -> Unit)? = null) {
    val colors = Forge.colors
    val profileLabel = stringResource(R.string.forge_qa_profile_settings)
    val quickLabel = stringResource(if (menu != null) R.string.forge_log_add else R.string.forge_qa_quick_actions)
    var menuOpen by remember { mutableStateOf(false) }
    Row(modifier, horizontalArrangement = Arrangement.spacedBy(ForgeMetrics.space3), verticalAlignment = Alignment.CenterVertically) {
        if (viewModel != null && onBattery != null) TodayHeaderBattery(viewModel, onBattery)
        // The coach after the strap, as iOS's header orders them.
        coach?.invoke()
        Box {
            Box(Modifier.size(HEADER_BUTTON).background(colors.heroFill, CircleShape).border(1.dp, colors.heroBorder, CircleShape)
                    .clickable(role = Role.Button) { if (menu != null) menuOpen = true else onQuickActions() }
                    .semantics { contentDescription = quickLabel },
                contentAlignment = Alignment.Center) {
                Icon(Icons.Rounded.Add, contentDescription = null, tint = if (menu != null) colors.accent else colors.text,
                     modifier = Modifier.size(20.dp))
            }
            if (menu != null) {
                DropdownMenu(expanded = menuOpen, onDismissRequest = { menuOpen = false }, modifier = Modifier.background(colors.surfaceTop)) {
                    menu { menuOpen = false }
                }
            }
        }
        ProfileAvatar(size = HEADER_BUTTON, contentDescription = profileLabel,
                      modifier = Modifier.clickable(role = Role.Button, onClick = onProfile))
    }
}

/**
 * The strap's charge as a ring the width of the profile picture, with the level INSIDE it: the twin of
 * iOS's `DashboardBatteryButton(percentInside: true)`. A ring with the figure beside it says the same
 * thing twice and makes the header's widest element (owner, 2026-11-19).
 *
 * Which arm is drawn comes from [StrapRowStatus], the rule the quick-action sheet's battery row states in
 * words, so the two cannot disagree about one strap. In particular a percentage that outlived the link is
 * not shown: `Disconnected` wins over a stale number, as iOS's `offline` does.
 */
@Composable
internal fun TodayHeaderBattery(viewModel: AppViewModel, onBattery: () -> Unit) {
    val colors = Forge.colors
    val live by viewModel.live.collectAsState()
    val name by viewModel.activeDeviceName.collectAsState()
    val row = StrapRowStatus.of(named = name != null, onAir = live.connected || live.bonded,
                                syncing = live.backfilling, charging = live.charging, batteryPct = live.batteryPct)
    if (row == StrapRow.None) return
    val charging = live.charging == true
    val pct = if (row == StrapRow.Disconnected) null else live.batteryPct
    // Spoken with the words the sheet's own battery row uses, so nothing new has to be translated for a
    // control that says what that row says. A charging strap with a reading is announced by its reading:
    // the number is the thing a wearer wants, and the bolt beside it is on screen for everyone else.
    val label = when {
        pct != null -> stringResource(R.string.forge_qa_connected_battery, pct.roundToInt())
        row == StrapRow.Disconnected -> stringResource(R.string.forge_qa_not_connected)
        charging -> stringResource(R.string.forge_qa_charging)
        else -> stringResource(R.string.forge_qa_connected)
    }
    Box(Modifier.size(HEADER_BUTTON).background(colors.heroFill, CircleShape).border(1.dp, colors.heroBorder, CircleShape)
            .clickable(role = Role.Button, onClick = onBattery)
            .semantics { contentDescription = label },
        contentAlignment = Alignment.Center) {
        if (pct != null) {
            val tint = batteryTone(pct).color
            // The arc from the top, clockwise, and never a hairline: a strap at 1 % must still draw
            // something, or the ring reads as "no reading" (iOS's `max(0.015, pct / 100)`).
            Canvas(Modifier.fillMaxSize().padding(3.dp)) {
                val stroke = 3.dp.toPx()
                drawArc(color = tint, startAngle = -90f, sweepAngle = maxOf(5.4f, (pct / 100 * 360).toFloat()),
                        useCenter = false, topLeft = androidx.compose.ui.geometry.Offset(stroke / 2, stroke / 2),
                        size = androidx.compose.ui.geometry.Size(size.width - stroke, size.height - stroke),
                        style = Stroke(width = stroke, cap = StrokeCap.Round))
            }
            Row(verticalAlignment = Alignment.CenterVertically) {
                if (charging) Icon(Icons.Rounded.Bolt, contentDescription = null, tint = tint, modifier = Modifier.size(10.dp))
                // The number alone, without the per-cent sign: at this size the sign costs a third of the
                // room and says nothing the ring has not already said.
                Text(pct.roundToInt().toString(), style = Forge.type.captionNumber.copy(fontWeight = FontWeight.SemiBold),
                     color = tint, maxLines = 1)
            }
        } else {
            Icon(if (charging) Icons.Rounded.Bolt else if (row == StrapRow.Disconnected) Icons.Rounded.Battery0Bar else Icons.Rounded.MoreHoriz,
                 contentDescription = null, modifier = Modifier.size(16.dp),
                 tint = if (charging) ForgeTokens.Color.systemGreen.resolve() else colors.textSecondary)
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
    // The device row's line as iOS resolves it (`StrapBatteryDisplayState`); no row without a strap. The
    // rule is [StrapRowStatus], shared with the device row behind the profile: this sheet counts a bonded
    // strap as present and names charging, which the rule carries, so only the wording differs here.
    val status: String? = when (StrapRowStatus.of(named = name != null, onAir = live.connected || live.bonded,
                                                  syncing = live.backfilling, charging = live.charging,
                                                  batteryPct = live.batteryPct)) {
        StrapRow.None -> null
        StrapRow.Disconnected -> stringResource(R.string.forge_qa_not_connected)
        StrapRow.Syncing -> stringResource(R.string.forge_qa_syncing)
        StrapRow.Charging -> stringResource(R.string.forge_qa_charging)
        StrapRow.Battery -> stringResource(R.string.forge_qa_connected_battery, live.batteryPct!!.roundToInt())
        StrapRow.Connected -> stringResource(R.string.forge_qa_connected)
    }
    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
                     containerColor = colors.surface) {
        Column(Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).navigationBarsPadding()
                   .padding(horizontal = ForgeMetrics.screenPadding).padding(bottom = ForgeMetrics.space4),
               verticalArrangement = Arrangement.spacedBy(ForgeMetrics.space2)) {
            if (status != null) {
                ActionRow(stringResource(R.string.forge_qa_battery), Icons.Rounded.BatteryFull,
                          ForgeTokens.Color.systemGreen.resolve(), status) { onPick(QuickAction.Battery) }
                Spacer(Modifier.size(ForgeMetrics.space1))
            }
            Text(stringResource(R.string.forge_qa_header), style = Forge.type.overline, color = colors.textSecondary,
                 modifier = Modifier.padding(bottom = ForgeMetrics.space1))
            ActionRow(stringResource(R.string.forge_qa_live_hr), Icons.Rounded.MonitorHeart, colors.heart) { onPick(QuickAction.Live) }
            ActionRow(stringResource(R.string.forge_qa_start_workout), Icons.Rounded.DirectionsRun, colors.effort) { onPick(QuickAction.Workout) }
            ActionRow(stringResource(R.string.forge_qa_log_journal), Icons.Rounded.EditNote,
                      ForgeTokens.Color.systemOrange.resolve()) { onPick(QuickAction.Journal) }
            ActionRow(stringResource(R.string.food_log_food), Icons.Rounded.Restaurant, colors.food) { onPick(QuickAction.Food) }
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

/**
 * One action row as iOS draws it (`QuickActionSheet.row`): a soft raised card without an outline, a large hued icon
 * tile, the title in a heavier weight and a trailing chevron.
 */
@Composable
private fun ActionRow(title: String, icon: ImageVector, tint: Color, subtitle: String? = null, onClick: () -> Unit) {
    val colors = Forge.colors
    val shape = RoundedCornerShape(18.dp)
    Row(Modifier.fillMaxWidth().heightIn(min = 64.dp)
            .shadow(3.dp, shape, ambientColor = Color.Black.copy(alpha = 0.06f), spotColor = Color.Black.copy(alpha = 0.10f))
            .background(colors.surfaceTop, shape).clickable(role = Role.Button, onClick = onClick)
            .padding(horizontal = 14.dp, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically) {
        Box(Modifier.size(46.dp).background(tint, RoundedCornerShape(14.dp)), contentAlignment = Alignment.Center) {
            Icon(icon, contentDescription = null, tint = Color.White, modifier = Modifier.size(24.dp))
        }
        Spacer(Modifier.width(16.dp))
        Column(Modifier.weight(1f)) {
            Text(title, style = Forge.type.headline.copy(fontWeight = FontWeight.SemiBold), color = colors.text)
            if (subtitle != null) Text(subtitle, style = Forge.type.footnote, color = colors.textSecondary)
        }
        Icon(Icons.AutoMirrored.Rounded.KeyboardArrowRight, contentDescription = null, tint = colors.textTertiary,
             modifier = Modifier.size(22.dp))
    }
}
