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
