package com.noop.ui.forge

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.systemBars
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Bedtime
import androidx.compose.material.icons.rounded.GridView
import androidx.compose.material.icons.rounded.MoreHoriz
import androidx.compose.material.icons.rounded.ShowChart
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.noop.R

/**
 * The Forge app's top-level destinations, in bar order (the iOS tab bar without Training, which is not in E), with
 * the backdrop each one draws on iOS.
 */
enum class ForgeTab(val labelRes: Int, val icon: ImageVector, val backdrop: ForgeBackdrop) {
    Today(R.string.nav_today, Icons.Rounded.GridView, ForgeBackdrop.Scene),
    Trends(R.string.nav_trends, Icons.Rounded.ShowChart, ForgeBackdrop.Sky),
    Sleep(R.string.nav_sleep, Icons.Rounded.Bedtime, ForgeBackdrop.Night),
    More(R.string.nav_more, Icons.Rounded.MoreHoriz, ForgeBackdrop.Sky),
}

/** How wide the window is, by the Compose window size class breakpoints (600 and 840 dp). */
enum class ForgeWidth { Compact, Medium, Expanded;
    companion object {
        fun of(width: Dp): ForgeWidth = when {
            width < 600.dp -> Compact
            width < 840.dp -> Medium
            else -> Expanded
        }
    }
}

/**
 * Fork (DX23876), Android plan E-3: the Forge app shell. A floating glass bar at the bottom on a compact window
 * (a phone), a navigation rail at the side from medium width on (an unfolded foldable, a tablet), each tab's
 * backdrop behind it and the content centred at [ForgeMetrics.maxContentWidth]. A screen gets the padding
 * that keeps its scrolling content clear of the bar and the system bars, and the window's width class.
 */
@Composable
fun ForgeShell(screen: @Composable (tab: ForgeTab, padding: PaddingValues, width: ForgeWidth) -> Unit) {
    var tab by rememberSaveable { mutableStateOf(ForgeTab.Today) }
    ForgeSceneBackdrop(tab.backdrop) {
        BoxWithConstraints(Modifier.fillMaxSize()) {
            val width = ForgeWidth.of(maxWidth)
            if (width == ForgeWidth.Compact) {
                Box(Modifier.fillMaxSize()) {
                    Content(tab, width, PaddingValues(bottom = ForgeMetrics.tabBarClearance + 16.dp), screen)
                    ForgeTabBar(tab, onSelect = { tab = it },
                                modifier = Modifier.align(Alignment.BottomCenter).navigationBarsPadding()
                                    .padding(horizontal = ForgeMetrics.screenPadding, vertical = 8.dp))
                }
            } else {
                Row(Modifier.fillMaxSize()) {
                    ForgeRail(tab, onSelect = { tab = it })
                    Box(Modifier.weight(1f).fillMaxHeight()) {
                        Content(tab, width, PaddingValues(bottom = ForgeMetrics.space4), screen)
                    }
                }
            }
        }
    }
}

@Composable
private fun Content(tab: ForgeTab, width: ForgeWidth, extra: PaddingValues,
                    screen: @Composable (ForgeTab, PaddingValues, ForgeWidth) -> Unit) {
    Box(Modifier.fillMaxSize().statusBarsPadding(), contentAlignment = Alignment.TopCenter) {
        Box(Modifier.widthIn(max = ForgeMetrics.maxContentWidth).fillMaxHeight()) {
            screen(tab, extra, width)
        }
    }
}

@Composable
private fun ForgeTabBar(current: ForgeTab, onSelect: (ForgeTab) -> Unit, modifier: Modifier = Modifier) {
    // Nearly opaque: Android cannot blur the scrolling content behind the bar as iOS glass does, and at the hero
    // fill's translucency the text under it read through.
    ForgeCard(modifier.widthIn(max = 480.dp).fillMaxWidth(), radius = 32.dp,
              fill = Forge.colors.surface.copy(alpha = 0.95f), contentPadding = 6.dp) {
        Row(Modifier.fillMaxWidth().height(58.dp), horizontalArrangement = Arrangement.SpaceEvenly,
            verticalAlignment = Alignment.CenterVertically) {
            ForgeTab.entries.forEach { t -> TabItem(t, t == current, Modifier.weight(1f)) { onSelect(t) } }
        }
    }
}

@Composable
private fun ForgeRail(current: ForgeTab, onSelect: (ForgeTab) -> Unit) {
    val colors = Forge.colors
    Column(
        Modifier.fillMaxHeight().windowInsetsPadding(WindowInsets.systemBars).padding(8.dp).width(88.dp)
            .background(colors.heroFill, RoundedCornerShape(ForgeMetrics.cardRadius))
            .border(BorderStroke(ForgeMetrics.hairline, colors.heroBorder), RoundedCornerShape(ForgeMetrics.cardRadius))
            .padding(vertical = 16.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        ForgeTab.entries.forEach { t -> TabItem(t, t == current, Modifier.fillMaxWidth()) { onSelect(t) } }
    }
}

@Composable
private fun TabItem(tab: ForgeTab, selected: Boolean, modifier: Modifier, onClick: () -> Unit) {
    val colors = Forge.colors
    val tint = if (selected) colors.charge else colors.textSecondary
    Column(
        modifier.clickable(role = Role.Tab, onClick = onClick).padding(vertical = 2.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Box(
            Modifier.size(width = 52.dp, height = 30.dp)
                .background(if (selected) colors.charge.copy(alpha = 0.16f) else colors.charge.copy(alpha = 0f),
                            RoundedCornerShape(percent = 50)),
            contentAlignment = Alignment.Center,
        ) { Icon(tab.icon, contentDescription = null, tint = tint) }
        Spacer(Modifier.height(2.dp))
        Text(stringResource(tab.labelRes), style = Forge.type.caption, color = tint, maxLines = 1,
             overflow = TextOverflow.Ellipsis)
    }
}
