package com.noop.ui.forge

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.ChevronRight
import androidx.compose.material.icons.rounded.Info
import androidx.compose.material.icons.rounded.NorthEast
import androidx.compose.material.icons.rounded.Warning
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp

// Row shapes the iOS Settings pages use beyond the shared blocks: a row with an icon tile, an action in the
// accent colour, a note with its mark, a pill button and the head of a page that is not an index page.

/**
 * iOS `SettingsNavRow`: a 30 dp tile in [tint] with its white symbol, the title over a detail line, then a chevron, or
 * the arrow of a link that leaves the app when [external].
 */
@Composable
internal fun TileLinkRow(icon: ImageVector, tint: Color, title: String, detail: String?, external: Boolean = false,
                         busy: Boolean = false, onClick: () -> Unit) {
    val colors = Forge.colors
    Row(Modifier.fillMaxWidth().heightIn(min = ForgeMetrics.minHitTarget)
            .clickable(enabled = !busy, role = Role.Button, onClick = onClick)
            .padding(vertical = ForgeMetrics.space2),
        verticalAlignment = Alignment.CenterVertically) {
        Box(Modifier.size(30.dp).background(tint, RoundedCornerShape(8.4.dp)), contentAlignment = Alignment.Center) {
            Icon(icon, contentDescription = null, tint = Color.White, modifier = Modifier.size(15.dp))
        }
        Spacer(Modifier.width(ForgeMetrics.space3))
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(title, style = Forge.type.body, color = colors.text)
            if (detail != null) Text(detail, style = Forge.type.footnote, color = colors.textSecondary)
        }
        Spacer(Modifier.width(ForgeMetrics.space2))
        if (busy) {
            CircularProgressIndicator(Modifier.size(18.dp), color = colors.textTertiary, strokeWidth = 2.dp)
        } else {
            Icon(if (external) Icons.Rounded.NorthEast else Icons.Rounded.ChevronRight, contentDescription = null,
                 tint = colors.textTertiary, modifier = Modifier.size(if (external) 14.dp else 18.dp))
        }
    }
}

/** iOS `backupActionRow`: the symbol and the action's name in the accent colour (or the warning red when [destructive]). */
@Composable
internal fun ActionRow(icon: ImageVector?, title: String, destructive: Boolean = false, onClick: () -> Unit) {
    val colour = if (destructive) ForgeTokens.Color.systemRed.resolve() else Forge.colors.accent
    Row(Modifier.fillMaxWidth().heightIn(min = ForgeMetrics.minHitTarget)
            .clickable(role = Role.Button, onClick = onClick).padding(vertical = ForgeMetrics.space2),
        verticalAlignment = Alignment.CenterVertically) {
        if (icon != null) {
            Icon(icon, contentDescription = null, tint = colour, modifier = Modifier.size(20.dp))
            Spacer(Modifier.width(ForgeMetrics.space3))
        }
        Text(title, style = Forge.type.body, color = colour, modifier = Modifier.weight(1f))
        if (destructive) {
            Icon(Icons.Rounded.ChevronRight, contentDescription = null, tint = Forge.colors.textTertiary,
                 modifier = Modifier.size(18.dp))
        }
    }
}

/** A footnote with its mark in front, as iOS draws the import note (info) and the unencrypted-archive warning. */
@Composable
internal fun MarkedNote(text: String, warning: Boolean) {
    val colour = if (warning) ForgeTokens.StrandPalette.statusWarningForeground.resolve() else Forge.colors.textSecondary
    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(ForgeMetrics.space2)) {
        Icon(if (warning) Icons.Rounded.Warning else Icons.Rounded.Info, contentDescription = null,
             tint = if (warning) colour else Forge.colors.textTertiary, modifier = Modifier.size(16.dp).padding(top = 1.dp))
        Text(text, style = Forge.type.footnote, color = colour, modifier = Modifier.weight(1f))
    }
}

/** iOS's secondary button: a capsule on the inset with a symbol and a label, in the text colour. */
@Composable
internal fun PillButton(icon: ImageVector, text: String, enabled: Boolean = true, onClick: () -> Unit) {
    val colors = Forge.colors
    Row(Modifier.heightIn(min = ForgeMetrics.minHitTarget)
            .background(colors.inset, RoundedCornerShape(50))
            .clickable(enabled = enabled, role = Role.Button, onClick = onClick)
            .padding(horizontal = ForgeMetrics.space4, vertical = ForgeMetrics.space2),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(ForgeMetrics.space2)) {
        Icon(icon, contentDescription = null, tint = if (enabled) colors.text else colors.textTertiary, modifier = Modifier.size(18.dp))
        Text(text, style = Forge.type.body, color = if (enabled) colors.text else colors.textTertiary, maxLines = 1)
    }
}

/**
 * The head of a Settings screen that is not one of the index pages (the Test Centre): the same 60 dp tile and one
 * plain line as [SettingsPageHead], with the symbol and colour passed in.
 */
@Composable
internal fun SettingsTileHead(icon: ImageVector, tint: Color, line: String) {
    Column(Modifier.fillMaxWidth().padding(horizontal = ForgeMetrics.space4).padding(bottom = ForgeMetrics.space2)
               .semantics(mergeDescendants = true) {},
           horizontalAlignment = Alignment.CenterHorizontally,
           verticalArrangement = Arrangement.spacedBy(ForgeMetrics.space3)) {
        Box(Modifier.size(60.dp).background(tint, RoundedCornerShape(14.dp)), contentAlignment = Alignment.Center) {
            Icon(icon, contentDescription = null, tint = Color.White, modifier = Modifier.size(32.dp))
        }
        Text(line, style = Forge.type.body, color = Forge.colors.textSecondary, textAlign = TextAlign.Center)
    }
}
