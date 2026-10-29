package com.noop.ui.forge

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.repeatOnLifecycle
import com.noop.R
import com.noop.core.CoreMomentum
import com.noop.core.CoreRead
import com.noop.core.CoreShadow
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

private data class MomentumFeedState(val loaded: Boolean = false, val messages: List<CoreMomentum.Message>? = null)

/** Distinguishes an unresolved feed, a failed read and an honestly empty result. */
@Composable
private fun momentumFeed(retry: Int): MomentumFeedState {
    val context = LocalContext.current
    val revision by CoreShadow.dataRevision.collectAsState()
    val lifecycleOwner = LocalLifecycleOwner.current
    var foregroundRefresh by remember { mutableIntStateOf(0) }
    LaunchedEffect(lifecycleOwner) {
        lifecycleOwner.lifecycle.repeatOnLifecycle(Lifecycle.State.RESUMED) {
            foregroundRefresh++
            var day = withContext(Dispatchers.IO) { CoreMomentum.logicalDay() }
            while (true) {
                delay(60_000)
                val currentDay = withContext(Dispatchers.IO) { CoreMomentum.logicalDay() }
                if (currentDay != null && currentDay != day) {
                    day = currentDay
                    foregroundRefresh++
                }
            }
        }
    }
    var state by remember { mutableStateOf(MomentumFeedState()) }
    LaunchedEffect(revision, retry, foregroundRefresh) {
        state = state.copy(loaded = false)
        val messages = withContext(Dispatchers.IO) {
            CoreRead.open(context)
            CoreMomentum.feed(context, dismissedTrainingWorkouts(context))
        }
        state = MomentumFeedState(loaded = true, messages = messages)
    }
    LaunchedEffect(state.messages?.firstOrNull()?.kind) {
        state.messages?.firstOrNull()?.let { CoreMomentum.noteShown(context, it.kind) }
    }
    return state
}

@Composable
internal fun ForgeTodayMomentum(viewModel: com.noop.ui.AppViewModel) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var retry by remember { mutableIntStateOf(0) }
    val state = momentumFeed(retry)
    var hideFailed by remember { mutableStateOf(false) }
    var page by rememberSaveable { mutableStateOf<String?>(null) }
    val top = state.messages?.firstOrNull()
    if (top != null) {
        Column(verticalArrangement = Arrangement.spacedBy(ForgeMetrics.space2)) {
            MomentumMessageCard(top, compact = true, onOpen = { page = "momentum" }, onHide = {
                scope.launch {
                    hideFailed = !withContext(Dispatchers.IO) { CoreMomentum.snooze(context, top.kind) }
                }
            })
            if (hideFailed) Text(stringResource(R.string.forge_momentum_hide_failed),
                style = Forge.type.caption, color = Forge.colors.textSecondary)
        }
    }
    fun close() { page = null; retry++ }
    page?.let { selected ->
        ForgeOverlayPage(onDismiss = ::close) {
            ForgeSceneBackdrop(ForgeBackdrop.Sky) {
                when (selected) {
                    "goalJourney" -> { BackHandler { page = "momentum" }; ForgeGoalsPage(onBack = { page = "momentum" }) }
                    "plan" -> { BackHandler { page = "momentum" }; ForgeCoachPlanPage(onBack = { page = "momentum" }) }
                    "chargeBreakdown" -> {
                        ForgeMomentumPage(onBack = ::close, onDestination = { page = it })
                        ChargeBreakdownHost(viewModel, onDismiss = { page = "momentum" })
                    }
                    "liveSession" -> {
                        BackHandler { page = "momentum" }
                        Hosted(stringResource(R.string.nav_live), onBack = { page = "momentum" }) { com.noop.ui.LiveScreen(viewModel) }
                    }
                    else -> ForgeMomentumPage(onBack = ::close, onDestination = { page = it })
                }
            }
        }
    }
}

@Composable
fun ForgeMomentumPage(onBack: () -> Unit, onDestination: (String) -> Unit) {
    var retry by remember { mutableIntStateOf(0) }
    val state = momentumFeed(retry)
    val messages = state.messages
    SettingsColumn {
        PageTitle(stringResource(R.string.forge_momentum_title), onBack)
        Text(stringResource(R.string.forge_momentum_subtitle), style = Forge.type.subhead, color = Forge.sceneInk.secondary)
        when {
            !state.loaded -> ForgeCard(Modifier.fillMaxWidth()) {
                Text(stringResource(R.string.forge_momentum_loading), style = Forge.type.headline, color = Forge.colors.text)
            }
            messages == null -> ForgeCard(Modifier.fillMaxWidth()) {
                Text(stringResource(R.string.forge_momentum_unavailable), style = Forge.type.body, color = Forge.colors.textSecondary)
                TextButton(onClick = { retry++ }) { Text(stringResource(R.string.forge_report_retry)) }
            }
            messages.isEmpty() -> ForgeCard(Modifier.fillMaxWidth()) {
                Text(stringResource(R.string.forge_momentum_empty), style = Forge.type.headline, color = Forge.colors.text)
                Text(stringResource(R.string.forge_momentum_quiet), style = Forge.type.body, color = Forge.colors.textSecondary)
            }
            else -> messages.forEach { MomentumMessageCard(it, onDestination = onDestination) }
        }
    }
}
