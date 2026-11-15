package com.noop.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.noop.R
import com.noop.ingest.ImportProgress

/**
 * Fork (DX23876), 2026-11-15: a running import, on a screen the wearer did not start it from.
 *
 * A Health Connect import runs for minutes, and it used to be visible only as greyed buttons on the page
 * it was started from — so leaving that page, which is the natural thing to do while waiting, left no
 * sign that anything was happening at all. Nothing here works anything out: it draws
 * [ImportProgress.state] and nothing else, so it cannot say something the notification and the import
 * page do not.
 *
 * Draws nothing when no import is running, so a caller can place it unconditionally.
 */
@Composable
fun ImportProgressBanner(modifier: Modifier = Modifier) {
    val progress by ImportProgress.state.collectAsStateWithLifecycle()
    val state = progress ?: return
    val context = LocalContext.current
    Row(
        modifier = modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(Metrics.cardRadius))
            .frostedCardSurface(tint = Palette.accent, cornerRadius = Metrics.cardRadius)
            .padding(Metrics.space14),
        horizontalArrangement = Arrangement.spacedBy(Metrics.space12),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        // Indeterminate on purpose: Health Connect does not say how many records a type holds before it
        // is read, so a filled bar would be an invented total. The count below is what is actually known.
        CircularProgressIndicator(color = Palette.accent, strokeWidth = 2.dp, modifier = Modifier.size(20.dp))
        Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(
                stringResource(R.string.forge_import_progress_title),
                style = NoopType.subhead,
                color = Palette.textPrimary,
            )
            Text(ImportProgress.stepLabel(context, state), style = NoopType.footnote, color = Palette.textSecondary)
        }
    }
}
