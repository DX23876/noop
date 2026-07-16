package com.noop.ui

import com.noop.R
import androidx.compose.ui.res.stringResource
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.unit.dp

// MARK: - WhatsNewSheet (ported from Strand/Screens/WhatsNewView.swift)
//
// A proper in-app changelog, shown automatically after an update and reachable any time
// from Settings. It also restates, up top, what NOOP is and what to expect, so people who
// never open GitHub still understand the experimental footing and the WHOOP 5/MG status.
//
// macOS parity notes:
//  - macOS rendered a fixed 560×640 panel with a header / scroll / footer split and a
//    hairline divider between each region. On phone the panel is presented full-screen
//    (the integration step wraps this in a Dialog/overlay), so we fill the surface and let
//    the body scroll. The header → divider → scroll → divider → "Got it" footer order is
//    preserved exactly, as is the "WHAT TO EXPECT" card then one card per release.
//  - The xmark.circle.fill close glyph maps to Icons.Filled.Close; the borderedProminent
//    "Got it" maps to a Palette.accent Material Button.

@Composable
fun WhatsNewSheet(onClose: () -> Unit) {
    Surface(
        modifier = Modifier.fillMaxSize(),
        color = Palette.surfaceBase,
    ) {
        Column(modifier = Modifier.fillMaxSize()) {
            // A scenic Charge-tinted hero behind the title region — the same premium backdrop
            // the Today rings float over, so the changelog opens on-brand.
            Box {
                ScenicHeroBackground(modifier = Modifier.matchParentSize(), domain = DomainTheme.Charge, starCount = 28)
                Header(onClose = onClose)
            }
            Hairline()

            Column(
                modifier = Modifier
                    .weight(1f)
                    .fillMaxWidth()
                    .verticalScroll(rememberScrollState())
                    .padding(20.dp),
                verticalArrangement = Arrangement.spacedBy(Metrics.sectionGap),
            ) {
                ExpectationsCard()
                // The newest release is the headline — give it the brand-green wash; the rest stay
                // frosted-neutral so the latest stands out at a glance.
                AppChangelog.releases.forEachIndexed { index, release ->
                    ReleaseCard(release, isLatest = index == 0)
                }
            }

            Hairline()
            Footer(onClose = onClose)
        }
    }
}

// MARK: - Header ("What's new" + "NOOP <version>" + close X)

@Composable
private fun Header(onClose: () -> Unit) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(20.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Column(
            modifier = Modifier.weight(1f),
            verticalArrangement = Arrangement.spacedBy(4.dp),
        ) {
            Overline("What's new", color = Palette.textTertiary)
            Text(uiString(R.string.l10n_whats_new_sheet_noop_appchangelog_current_version_05dae27c, AppChangelog.CURRENT_VERSION), style = NoopType.display(26f), color = Palette.textPrimary)
            Text(uiString(R.string.l10n_whats_new_sheet_release_notes_cd5af734), style = NoopType.caption, color = Palette.textSecondary)
        }
        IconButton(onClick = onClose, modifier = Modifier.size(36.dp)) {
            Icon(
                Icons.Filled.Close,
                contentDescription = uiString(R.string.l10n_whats_new_sheet_close_bbfa773e),
                tint = Palette.textTertiary,
                modifier = Modifier.size(22.dp),
            )
        }
    }
}

// MARK: - "WHAT TO EXPECT" card (icon + title + body per expectation)

@Composable
private fun ExpectationsCard() {
    NoopCard(padding = 20.dp, tint = Palette.accent) {
        Column(verticalArrangement = Arrangement.spacedBy(14.dp)) {
            Overline("What to expect")
            AppChangelog.expectations.forEach { e ->
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.spacedBy(12.dp),
                    verticalAlignment = Alignment.Top,
                ) {
                    Icon(
                        e.icon,
                        contentDescription = null,
                        tint = Palette.accent,
                        modifier = Modifier
                            .padding(top = 2.dp)
                            .size(22.dp),
                    )
                    Column(
                        modifier = Modifier.weight(1f),
                        verticalArrangement = Arrangement.spacedBy(3.dp),
                    ) {
                        Text(e.title, style = NoopType.headline, color = Palette.textPrimary)
                        Text(e.body, style = NoopType.subhead, color = Palette.textSecondary)
                    }
                }
            }
        }
    }
}

// MARK: - Release card (v-badge + title + date, then bulleted items)

@Composable
private fun ReleaseCard(release: AppChangelog.Release, isLatest: Boolean = false) {
    NoopCard(padding = 20.dp, tint = if (isLatest) Palette.accent else null) {
        Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                SourceBadge("v${release.version}")
                Text(
                    release.title,
                    style = NoopType.headline,
                    color = Palette.textPrimary,
                    modifier = Modifier.weight(1f),
                )
                Text(release.date, style = NoopType.caption, color = Palette.textTertiary)
            }
            release.items.forEach { item ->
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                    verticalAlignment = Alignment.Top,
                ) {
                    Box(
                        modifier = Modifier
                            .padding(top = 7.dp)
                            .size(5.dp)
                            .clip(CircleShape)
                            .background(Palette.accent),
                    )
                    Text(
                        item,
                        style = NoopType.subhead,
                        color = Palette.textSecondary,
                        modifier = Modifier.weight(1f),
                    )
                }
            }
        }
    }
}

// MARK: - Footer (primary "Got it" → onClose)

@Composable
private fun Footer(onClose: () -> Unit) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(16.dp),
        horizontalArrangement = Arrangement.End,
    ) {
        Button(
            onClick = onClose,
            colors = ButtonDefaults.buttonColors(
                containerColor = Palette.accent,
                contentColor = Palette.surfaceBase,
            ),
        ) {
            Text(uiString(R.string.l10n_whats_new_sheet_got_it_5b8027fa), style = NoopType.captionNumber)
        }
    }
}

// MARK: - Hairline divider (mirrors the macOS Divider().overlay(hairline))

@Composable
private fun Hairline() {
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .height(1.dp)
            .background(Palette.hairline),
    )
}
