package com.noop.ui.forge

import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import com.noop.R
import com.noop.ui.rememberPoseStill
import kotlinx.coroutines.delay

/**
 * The raw "a strap history sync is running" signal, debounced as iOS does (`DebouncedSyncSignal`): `backfilling`
 * drops to false between every offload chunk, so a surface showing it would flicker. True at once when a sync
 * starts; false only after the signal has stayed off for [SYNC_SIGNAL_DEBOUNCE_MS].
 */
@Composable
internal fun rememberDebouncedSyncing(raw: Boolean): Boolean {
    var shown by remember { mutableStateOf(raw) }
    LaunchedEffect(raw) {
        if (raw) shown = true
        else if (shown) {
            delay(SYNC_SIGNAL_DEBOUNCE_MS)
            shown = false
        }
    }
    return shown
}

/** iOS `StrandMotion.syncIndicatorSignalDebounceNanoseconds`. */
private const val SYNC_SIGNAL_DEBOUNCE_MS = 3_000L

/**
 * The thin ember line under the Today wordmark while strap history syncs, after the iOS `LiquidSyncLine`: a segment
 * travels along a hairline track, and the line fades out once the sync has finished. Without it a sync was only
 * visible on the Live screen or in the quick-action sheet. Battery saver and reduced motion fill the track still.
 * Its clock runs only while a sync is shown.
 */
@Composable
internal fun ForgeSyncLine(backfilling: Boolean, modifier: Modifier = Modifier) {
    val syncing = rememberDebouncedSyncing(backfilling)
    val alpha by animateFloatAsState(if (syncing) 1f else 0f, tween(250))
    val ember = ForgeTokens.StrandPalette.forgeEmber.resolve()
    val label = stringResource(R.string.forge_qa_syncing)
    Box(
        modifier.width(120.dp).height(3.dp).alpha(alpha).clip(CircleShape).background(Forge.colors.divider)
            .then(if (syncing) Modifier.semantics { contentDescription = label } else Modifier.clearAndSetSemantics {}),
    ) {
        if (!syncing) return@Box
        if (rememberPoseStill()) {
            Box(Modifier.fillMaxSize().background(ember))
        } else {
            val phase by rememberInfiniteTransition().animateFloat(
                0f, 1f, infiniteRepeatable(tween(1_400, easing = LinearEasing)),
            )
            Box(
                Modifier.fillMaxHeight().fillMaxWidth(SEGMENT).graphicsLayer {
                    // The segment is SEGMENT of the track: it enters from the left and leaves at the right.
                    val track = size.width / SEGMENT
                    translationX = (track + size.width) * phase - size.width
                }.background(ember),
            )
        }
    }
}

private const val SEGMENT = 0.35f
