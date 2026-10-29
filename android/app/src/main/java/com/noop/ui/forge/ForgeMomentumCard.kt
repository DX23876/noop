package com.noop.ui.forge

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.size
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Close
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.foundation.layout.width
import androidx.compose.ui.unit.dp
import androidx.compose.material.icons.rounded.ChevronRight
import androidx.compose.material.icons.rounded.PauseCircle
import androidx.compose.material.icons.rounded.Speed
import androidx.compose.material.icons.rounded.Event
import androidx.compose.material.icons.rounded.Flag
import androidx.compose.material.icons.rounded.MonitorWeight
import androidx.compose.material.icons.rounded.Warning
import androidx.compose.material.icons.rounded.DirectionsRun
import androidx.compose.material.icons.rounded.DirectionsWalk
import androidx.compose.material.icons.rounded.Bedtime
import androidx.compose.material.icons.rounded.LocalFireDepartment
import androidx.compose.material.icons.rounded.ShowChart
import androidx.compose.material.icons.rounded.Battery2Bar
import androidx.compose.material.icons.rounded.WaterDrop
import androidx.compose.material.icons.rounded.TrackChanges
import androidx.compose.material.icons.rounded.FavoriteBorder
import com.noop.R
import com.noop.core.CoreMomentum

/** The Momentum destinations Android has a page for: the goals, the coach's plan book and Live. */
internal val MOMENTUM_DESTINATIONS = setOf("goalJourney", "plan", "liveSession")

/** Presentation only. Readings, priority, progress and wording are already resolved by the Swift core. */
@Composable
internal fun MomentumMessageCard(message: CoreMomentum.Message, compact: Boolean = false,
                                 onOpen: (() -> Unit)? = null, onHide: (() -> Unit)? = null,
                                 onDestination: ((String) -> Unit)? = null) {
    val colors = Forge.colors
    val tint = when (message.tone) {
        "positive" -> colors.charge
        "warning" -> colors.effort
        "critical" -> colors.heart
        "accent" -> colors.accent
        else -> colors.textSecondary
    }
    if (compact) {
        CompactMomentumCard(message, tint, onOpen, onHide)
        return
    }
    ForgeCard(Modifier.fillMaxWidth().then(if (onOpen != null) Modifier.clickable(role = Role.Button, onClick = onOpen) else Modifier)) {
        Column(verticalArrangement = Arrangement.spacedBy(ForgeMetrics.space2)) {
            Row(verticalAlignment = Alignment.Top) {
                Text(message.headline, style = Forge.type.headline, color = colors.text,
                     modifier = Modifier.weight(1f).semantics { heading() })
                if (onHide != null) IconButton(onClick = onHide, modifier = Modifier.size(ForgeMetrics.minHitTarget)) {
                    Icon(Icons.Rounded.Close, contentDescription = stringResource(R.string.forge_momentum_hide), tint = colors.textTertiary)
                }
            }
            val detail = if (compact) message.actionLine ?: message.detail else message.detail
            if (detail.isNotBlank()) Text(detail, style = Forge.type.subhead, color = colors.textSecondary)
            if (!compact) {
                if (message.actionLine != null && message.actionLine != detail) {
                    Text(message.actionLine, style = Forge.type.body, color = colors.text)
                }
                message.progress?.let { progress ->
                    LinearProgressIndicator(progress = progress.toFloat(), color = tint,
                        trackColor = colors.inset, modifier = Modifier.fillMaxWidth())
                }
                val labels = listOfNotNull(message.progressLabel, message.progressChip, message.deltaText).distinct()
                labels.forEach { Text(it, style = Forge.type.caption, color = colors.textSecondary) }
                // A destination shows only where this host has its real page, as on Apple; the Charge breakdown
                // sheet is not on Android yet.
                val destination = message.destination
                if (destination in MOMENTUM_DESTINATIONS && message.actionTitle != null && onDestination != null) {
                    TextButton(onClick = { onDestination(destination!!) }, modifier = Modifier.heightIn(min = ForgeMetrics.minHitTarget)) {
                        Text(message.actionTitle, style = Forge.type.headline, color = tint)
                    }
                }
            }
        }
    }
}

/** The kind's symbol, after iOS `MomentumSymbol`, with the nearest Material icon. */
private fun momentumIcon(kind: String): androidx.compose.ui.graphics.vector.ImageVector = when (kind) {
    "statusOverride" -> Icons.Rounded.PauseCircle
    "calibrating" -> Icons.Rounded.Speed
    "planDeviation", "weeklyTrainingGoal" -> Icons.Rounded.Event
    "milestone" -> Icons.Rounded.Flag
    "weightMilestone" -> Icons.Rounded.MonitorWeight
    "restDayNeeded", "healthAlert" -> Icons.Rounded.Warning
    "trainingSuggestion" -> Icons.Rounded.DirectionsRun
    "stepGoal", "stepsBelowUsual" -> Icons.Rounded.DirectionsWalk
    "sleepCatchUp", "bedtimeTarget" -> Icons.Rounded.Bedtime
    "streak" -> Icons.Rounded.LocalFireDepartment
    "hrvTrend" -> Icons.Rounded.ShowChart
    "strapBattery" -> Icons.Rounded.Battery2Bar
    "cyclePhase" -> Icons.Rounded.WaterDrop
    "goalCheckIn" -> Icons.Rounded.TrackChanges
    else -> Icons.Rounded.FavoriteBorder
}

/**
 * Today's compact Momentum card as iOS draws it (`MomentumCard.compactBody`): the kind's symbol, MOMENTUM, "All" with
 * its chevron and the close button on one line, then the headline and one line of what to do.
 */
@Composable
private fun CompactMomentumCard(message: CoreMomentum.Message, tint: androidx.compose.ui.graphics.Color,
                                onOpen: (() -> Unit)?, onHide: (() -> Unit)?) {
    val colors = Forge.colors
    ForgeCard(Modifier.fillMaxWidth().then(if (onOpen != null) Modifier.clickable(role = Role.Button, onClick = onOpen) else Modifier),
              contentPadding = ForgeMetrics.space4) {
        Column(verticalArrangement = Arrangement.spacedBy(ForgeMetrics.space1)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(momentumIcon(message.kind), contentDescription = null, tint = tint, modifier = Modifier.size(16.dp))
                androidx.compose.foundation.layout.Spacer(Modifier.width(6.dp))
                Text(stringResource(R.string.forge_momentum_title).uppercase(), style = Forge.type.overline,
                     color = colors.textSecondary, modifier = Modifier.weight(1f).semantics { heading() })
                Text(stringResource(R.string.forge_momentum_all), style = Forge.type.footnote, color = colors.accent)
                Icon(Icons.Rounded.ChevronRight, contentDescription = null, tint = colors.textTertiary, modifier = Modifier.size(16.dp))
                if (onHide != null) IconButton(onClick = onHide, modifier = Modifier.size(36.dp)) {
                    Icon(Icons.Rounded.Close, contentDescription = stringResource(R.string.forge_momentum_hide),
                         tint = colors.textTertiary, modifier = Modifier.size(16.dp))
                }
            }
            Text(message.headline, style = Forge.type.subhead.copy(fontWeight = androidx.compose.ui.text.font.FontWeight.SemiBold),
                 color = colors.text)
            val line = message.actionLine ?: message.detail
            if (line.isNotBlank()) Text(line, style = Forge.type.footnote, color = colors.textSecondary, maxLines = 2,
                                        overflow = androidx.compose.ui.text.style.TextOverflow.Ellipsis)
        }
    }
}
