package com.noop.ui.forge

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.ui.unit.dp
import androidx.compose.material3.pulltorefresh.PullToRefreshContainer
import androidx.compose.material3.pulltorefresh.rememberPullToRefreshState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.input.nestedscroll.nestedScroll
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.noop.ble.WhoopBleClient
import com.noop.core.CoreSourceRefresh
import com.noop.ui.AppViewModel

/**
 * "Fetch now" on every tab of the new design: pull down, and every connected source is asked.
 *
 * The gesture is not new here — the classic Today screen has synced the strap on a pull since long
 * before, and the Apple side has a `.refreshable` hook in its screen scaffold. It was lost in the move
 * to the new design, on both platforms. This brings it back, with one difference: it asks the SOURCES,
 * not just the strap, because a wearer does not know which of them feeds the card they are looking at.
 *
 * Who may be asked, how often, and what the one line says is the shared core's
 * (`ConnectedSourceRefresh`), so the same pull on an iPhone answers the same way.
 */
@OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)
@Composable
internal fun ForgePullToRefresh(viewModel: AppViewModel, content: @Composable () -> Unit) {
    val services by viewModel.refreshServices.collectAsStateWithLifecycle()
    val live by viewModel.live.collectAsStateWithLifecycle()
    // Read live inside the gesture's own lambda: material3 1.2.1 captures `enabled` ONCE, so a plain
    // Boolean would freeze whatever was true at the first composition — the trap the classic Today
    // screen documents, where the strap is usually not connected yet when the tab first draws.
    val strapReady = WhoopBleClient.canRequestSync(live.connected, live.bonded, live.backfilling)
    var strapReadyNow by remember { mutableStateOf(strapReady) }
    strapReadyNow = strapReady

    LaunchedEffect(Unit) { viewModel.refreshConnectedServices() }

    val state = rememberPullToRefreshState(
        // Nothing connected means nothing to fetch: a gesture that cannot do anything must not pretend.
        enabled = { services.isNotEmpty() || strapReadyNow },
    )
    var fetching by remember { mutableStateOf(false) }
    LaunchedEffect(state.isRefreshing) {
        if (!state.isRefreshing) return@LaunchedEffect
        fetching = true
        val verdict = try {
            viewModel.refreshConnectedSources(strapReady = strapReadyNow)
        } finally {
            fetching = false
        }
        RefreshVerdictHost.show(verdict)
        // The services are done; the strap, if it was asked, carries on behind its own progress. Holding
        // the spinner for it would leave it turning for minutes.
        state.endRefresh()
    }

    Box(Modifier.fillMaxSize().nestedScroll(state.nestedScrollConnection)) {
        content()
        androidx.compose.foundation.layout.Column(
            Modifier.align(Alignment.TopCenter),
            horizontalAlignment = androidx.compose.ui.Alignment.CenterHorizontally,
        ) {
            // A running import, on every tab the gesture reaches rather than on Today alone: the page an
            // import was started from is not the page the wearer waits on. Draws nothing when none runs.
            com.noop.ui.ImportProgressBanner()
            // While a pull is still asking, so the gesture's own spinner is not the only sign.
            if (fetching) RefreshStrip(androidx.compose.ui.res.stringResource(com.noop.R.string.forge_refresh_fetching))
            RefreshVerdictLine()
        }
        // Material draws its circle even at rest (progress 0), which reads as a permanent grey dot at the
        // top of an idle tab; compose it only while something is actually happening. The gesture itself
        // flows through the nestedScroll above, so this cannot disable it.
        if (state.progress > 0f || state.isRefreshing) {
            PullToRefreshContainer(state = state, modifier = Modifier.align(Alignment.TopCenter))
        }
    }
}

/**
 * What the last pull brought, for the few seconds it is worth saying.
 *
 * Held outside the screens so the line survives a tab change: the import banner it is drawn in hangs on
 * all four tabs, and a wearer who pulls on Training and swipes to Sleep should still learn how it went.
 */
internal object RefreshVerdictHost {
    private val _verdict = kotlinx.coroutines.flow.MutableStateFlow<CoreSourceRefresh.Verdict?>(null)
    val verdict: kotlinx.coroutines.flow.StateFlow<CoreSourceRefresh.Verdict?> = _verdict

    /** How long the line stands before it fades. Long enough to read, short enough not to linger. */
    const val SHOWN_MS = 3_000L

    fun show(value: CoreSourceRefresh.Verdict) {
        // "None" is a pull that asked nothing but the strap, or nothing at all: there is nothing to say,
        // and saying "up to date" would be a promise the offload has not kept yet.
        _verdict.value = if (value is CoreSourceRefresh.Verdict.None) null else value
    }

    fun clear() { _verdict.value = null }
}

/**
 * What the last pull brought, for three seconds.
 *
 * The wording is this platform's, from its own catalogue; the core decided WHAT to say, not how. A
 * failure keeps the count beside it, because naming only the failure would throw away what did arrive.
 */
/** The one shape both strips take, so the "fetching" line and the verdict cannot drift apart. */
@Composable
private fun RefreshStrip(text: String) {
    androidx.compose.material3.Surface(
        modifier = Modifier.padding(ForgeMetrics.space3),
        color = Forge.colors.surface,
        shape = androidx.compose.foundation.shape.RoundedCornerShape(ForgeMetrics.cardRadius),
        tonalElevation = 0.dp,
    ) {
        androidx.compose.material3.Text(
            text, style = Forge.type.caption, color = Forge.colors.text,
            modifier = Modifier.padding(horizontal = ForgeMetrics.space3, vertical = ForgeMetrics.space2),
        )
    }
}

@Composable
private fun RefreshVerdictLine(modifier: Modifier = Modifier) {
    val verdict by RefreshVerdictHost.verdict.collectAsStateWithLifecycle()
    val shown = verdict ?: return
    LaunchedEffect(shown) {
        kotlinx.coroutines.delay(RefreshVerdictHost.SHOWN_MS)
        RefreshVerdictHost.clear()
    }
    val text = when (shown) {
        is CoreSourceRefresh.Verdict.UpToDate ->
            androidx.compose.ui.res.stringResource(com.noop.R.string.forge_refresh_up_to_date)
        is CoreSourceRefresh.Verdict.Refreshed ->
            androidx.compose.ui.res.stringResource(com.noop.R.string.forge_refresh_refreshed)
        is CoreSourceRefresh.Verdict.Brought ->
            androidx.compose.ui.res.stringResource(com.noop.R.string.forge_refresh_brought, shown.total)
        is CoreSourceRefresh.Verdict.Partial -> {
            val who = shown.failed.joinToString(", ") { sourceName(it) }
            if (shown.brought > 0) {
                androidx.compose.ui.res.stringResource(
                    com.noop.R.string.forge_refresh_failed_brought, who, shown.brought)
            } else {
                androidx.compose.ui.res.stringResource(com.noop.R.string.forge_refresh_failed, who)
            }
        }
        is CoreSourceRefresh.Verdict.None -> return
    }
    RefreshStrip(text)
}

/** A source as the wearer knows it. Product names stay as they are; the strap never reaches this line. */
private fun sourceName(source: CoreSourceRefresh.Source): String = when (source) {
    CoreSourceRefresh.Source.HEALTH -> "Health Connect"
    CoreSourceRefresh.Source.HEVY -> "Hevy"
    CoreSourceRefresh.Source.STRAP -> "Strap"
}
