package com.noop.ui.forge

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.BeachAccess
import androidx.compose.material.icons.rounded.Bedtime
import androidx.compose.material.icons.rounded.Bolt
import androidx.compose.material.icons.rounded.Check
import androidx.compose.material.icons.rounded.Edit
import androidx.compose.material.icons.rounded.Healing
import androidx.compose.material3.Button
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.unit.dp
import com.noop.R
import com.noop.core.CoreRead
import com.noop.core.CoreTodayStatus
import com.noop.ui.ProfileStore
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

private data class ActivityChoice(val raw: String, val title: Int, val subtitle: Int, val icon: ImageVector,
                                  val color: ForgeColor)

/** `ActivityStatus.State` with its words, symbol and `ActivityStatusColors` colour. */
private val ACTIVITY_CHOICES = listOf(
    ActivityChoice("active", R.string.forge_as_active, R.string.forge_as_active_sub, Icons.Rounded.Bolt, ForgeTokens.Color.systemGreen),
    ActivityChoice("sick", R.string.forge_as_sick, R.string.forge_as_sick_sub, Icons.Rounded.Bedtime, ForgeTokens.Color.systemRed),
    ActivityChoice("injured", R.string.forge_as_injured, R.string.forge_as_injured_sub, Icons.Rounded.Healing, ForgeTokens.Color.systemOrange),
    ActivityChoice("onBreak", R.string.forge_as_break, R.string.forge_as_break_sub, Icons.Rounded.BeachAccess, ForgeTokens.Color.systemYellow),
)

/** The sheet's durations (`SharedActivityStatusSheet.DurationChoice`), without iOS's custom date. */
private val DURATIONS = listOf("untilChanged" to R.string.forge_as_until_changed, "today" to R.string.forge_as_today,
                               "threeDays" to R.string.forge_as_3days, "thisWeek" to R.string.forge_as_week)

/**
 * Fork (DX23876), Android parity plan 2.3: the pill row above Today's Momentum card, as `LiquidTodayView.synthesisSection`
 * draws it: the readiness word (Push, Maintain, Rest) in its level's colour, and the wearer's activity status with a
 * pencil, which opens the status sheet. Both come from the shared core.
 */
@Composable
internal fun TodayStatusPills() {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var revision by remember { mutableIntStateOf(0) }
    var status by remember { mutableStateOf<CoreTodayStatus.Status?>(null) }
    var editing by remember { mutableStateOf(false) }
    LaunchedEffect(revision) {
        status = withContext(Dispatchers.IO) {
            CoreRead.open(context)
            val profile = ProfileStore.from(context)
            CoreTodayStatus.read(profile.hrMax.toDouble(), profile.sex, dismissedTrainingWorkouts(context))
        }
    }
    val s = status ?: return
    val word = when (s.level) {
        "primed" -> R.string.today_readiness_push
        "balanced" -> R.string.today_readiness_maintain
        "strained", "rundown" -> R.string.today_readiness_rest
        else -> null
    }
    val levelColor = when (s.level) {
        "primed" -> Forge.colors.accent
        "balanced" -> ForgeTokens.Color.systemGreen.resolve()
        "strained" -> ForgeTokens.Color.systemOrange.resolve()
        else -> ForgeTokens.Color.systemRed.resolve()
    }
    val activity = ACTIVITY_CHOICES.firstOrNull { it.raw == s.activity } ?: ACTIVITY_CHOICES.first()
    val activityColor = activity.color.resolve()
    Row(horizontalArrangement = Arrangement.spacedBy(ForgeMetrics.space2), verticalAlignment = Alignment.CenterVertically) {
        if (word != null) {
            Text(stringResource(word).uppercase(), style = Forge.type.overline, color = levelColor,
                 modifier = Modifier.background(levelColor.copy(alpha = 0.12f), CircleShape)
                     .padding(horizontal = ForgeMetrics.space3, vertical = ForgeMetrics.space1))
        }
        Row(Modifier.background(activityColor.copy(alpha = 0.14f), CircleShape)
                .clickable(role = Role.Button) { editing = true }
                .padding(horizontal = 10.dp, vertical = 5.dp),
            verticalAlignment = Alignment.CenterVertically) {
            Icon(activity.icon, null, tint = activityColor, modifier = Modifier.size(14.dp))
            Spacer(Modifier.width(5.dp))
            Text(stringResource(activity.title).uppercase(), style = Forge.type.overline, color = activityColor, maxLines = 1)
            Spacer(Modifier.width(5.dp))
            Icon(Icons.Rounded.Edit, null, tint = activityColor, modifier = Modifier.size(12.dp))
        }
    }
    if (editing) {
        ActivityStatusSheet(s.activity, onDismiss = { editing = false }) { state, duration ->
            scope.launch {
                withContext(Dispatchers.IO) { CoreTodayStatus.setActivity(state, duration) }
                editing = false
                revision++
            }
        }
    }
}

/** `SharedActivityStatusSheet`: the four states with their subtitles, how long, Apply. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun ActivityStatusSheet(current: String, onDismiss: () -> Unit, onApply: (String, String) -> Unit) {
    val colors = Forge.colors
    var picked by remember { mutableStateOf(current) }
    var duration by remember { mutableStateOf("untilChanged") }
    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
                     containerColor = colors.surface) {
        Column(Modifier.fillMaxWidth().navigationBarsPadding().padding(horizontal = ForgeMetrics.screenPadding)
                   .padding(bottom = ForgeMetrics.space4),
               verticalArrangement = Arrangement.spacedBy(ForgeMetrics.space2)) {
            Text(stringResource(R.string.forge_as_title), style = Forge.type.title2, color = colors.text)
            ACTIVITY_CHOICES.forEach { c ->
                val tint = c.color.resolve()
                Row(Modifier.fillMaxWidth().clickable(role = Role.RadioButton) { picked = c.raw }
                        .background(if (picked == c.raw) tint.copy(alpha = 0.10f) else Color.Transparent, RoundedCornerShape(12.dp))
                        .padding(ForgeMetrics.space3),
                    verticalAlignment = Alignment.CenterVertically) {
                    Box(Modifier.size(32.dp).background(tint.copy(alpha = 0.16f), CircleShape), contentAlignment = Alignment.Center) {
                        Icon(c.icon, null, tint = tint, modifier = Modifier.size(18.dp))
                    }
                    Spacer(Modifier.width(ForgeMetrics.space3))
                    Column(Modifier.weight(1f)) {
                        Text(stringResource(c.title), style = Forge.type.headline, color = colors.text)
                        Text(stringResource(c.subtitle), style = Forge.type.subhead, color = colors.textSecondary)
                    }
                    if (picked == c.raw) Icon(Icons.Rounded.Check, null, tint = tint)
                }
            }
            if (picked != "active") {
                Text(stringResource(R.string.forge_as_valid_for).uppercase(), style = Forge.type.overline,
                     color = colors.textSecondary)
                Row(horizontalArrangement = Arrangement.spacedBy(ForgeMetrics.space2)) {
                    DURATIONS.forEach { (raw, label) ->
                        val on = duration == raw
                        Text(stringResource(label), style = Forge.type.footnote,
                             color = if (on) Color.White else colors.text,
                             modifier = Modifier.background(if (on) colors.accent else colors.inset, CircleShape)
                                 .clickable(role = Role.RadioButton) { duration = raw }
                                 .padding(horizontal = 12.dp, vertical = 7.dp))
                    }
                }
            }
            Button(onClick = { onApply(picked, duration) }, modifier = Modifier.fillMaxWidth()) {
                Text(stringResource(R.string.forge_as_apply), style = Forge.type.headline)
            }
        }
    }
}
