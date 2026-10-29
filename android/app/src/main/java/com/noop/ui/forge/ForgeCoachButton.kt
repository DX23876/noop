package com.noop.ui.forge

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.systemBars
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.AutoAwesome
import androidx.compose.material3.Icon
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import com.noop.R
import com.noop.core.CoreCoach
import com.noop.core.CoreRead
import com.noop.ui.AppViewModel
import com.noop.ui.BottomBarStyleStore
import com.noop.ui.CoachTodayPrefs
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext
import kotlin.math.roundToInt

/**
 * The floating Coach button (`CoachFloatingButton`): a round button over every tab that opens the chat. It rests in
 * one of four corners kept clear of the tab bar and the header, or where the wearer dragged it (then `custom`, kept
 * as fractions of the window so it survives rotation); locked, it cannot be dragged and a tap still opens the chat.
 * A dot marks a message the coach started that has not been seen. Shown while the coach, its Today entries and the
 * button itself are on.
 */
@Composable
internal fun ForgeCoachButton(viewModel: AppViewModel) {
    val context = LocalContext.current
    CoachTodayPrefs.version // read, so a change in Settings moves or hides the button at once
    if (!BottomBarStyleStore.coachEnabled || !CoachTodayPrefs.shown(context) || !CoachTodayPrefs.floating(context)) return
    var open by rememberSaveable { mutableStateOf(false) }
    var unseen by remember { mutableStateOf(false) }
    var label by remember { mutableStateOf<String?>(null) }
    // A brief or a nudge can arrive while the app is open, so the dot is read again every minute.
    LaunchedEffect(open) {
        if (open) return@LaunchedEffect
        while (true) {
            withContext(Dispatchers.IO) {
                CoreRead.open(context)
                unseen = CoreCoach.unseen()
                if (label == null) label = CoreCoach.settings()?.labels?.get("askCoach")
            }
            delay(60_000)
        }
    }

    val corner = CoachTodayPrefs.corner(context)
    val locked = CoachTodayPrefs.locked(context)
    val spot = CoachTodayPrefs.spot(context)
    val density = LocalDensity.current
    val insets = WindowInsets.systemBars
    val colors = Forge.colors
    BoxWithConstraints(Modifier.fillMaxSize()) {
        val w = constraints.maxWidth.toFloat()
        val h = constraints.maxHeight.toFloat()
        val half = with(density) { (SIZE / 2).toPx() }
        val margin = with(density) { MARGIN.toPx() }
        val top = insets.getTop(density) + with(density) { TOP_CHROME.toPx() } + half
        val bottom = h - insets.getBottom(density) - with(density) { BOTTOM_CHROME.toPx() } - half
        val leading = half + margin
        val trailing = w - half - margin
        // A pinned corner wins; `custom` uses the dragged fractions, and before any drag the bottom-right corner.
        val baseX = when (corner) {
            "topLeading", "bottomLeading" -> leading
            "custom" -> spot?.first?.times(w) ?: trailing
            else -> trailing
        }
        val baseY = when (corner) {
            "topLeading", "topTrailing" -> top
            "custom" -> spot?.second?.times(h) ?: bottom
            else -> bottom
        }
        var drag by remember { mutableStateOf(Offset.Zero) }
        val x by animateFloatAsState(baseX)
        val y by animateFloatAsState(baseY)
        val cx = (x + drag.x).coerceIn(leading, trailing)
        val cy = (y + drag.y).coerceIn(half + margin, h - half - margin)

        Box(
            Modifier
                .offset { IntOffset((cx - half).roundToInt(), (cy - half).roundToInt()) }
                .size(SIZE)
                .shadow(10.dp, CircleShape)
                .background(colors.accent, CircleShape)
                .border(1.dp, Color.White.copy(alpha = 0.18f), CircleShape)
                .pointerInput(locked, baseX, baseY, w, h) {
                    if (locked) return@pointerInput
                    detectDragGestures(
                        onDragEnd = {
                            val nx = (baseX + drag.x).coerceIn(leading, trailing)
                            val ny = (baseY + drag.y).coerceIn(half + margin, h - half - margin)
                            CoachTodayPrefs.setSpot(context, nx / w, ny / h)
                            drag = Offset.Zero
                        },
                        onDragCancel = { drag = Offset.Zero },
                    ) { change, amount -> change.consume(); drag += amount }
                }
                .clickable(role = Role.Button, onClickLabel = label) { open = true },
            contentAlignment = Alignment.Center,
        ) {
            Icon(Icons.Rounded.AutoAwesome, contentDescription = label, tint = Color.White, modifier = Modifier.size(24.dp))
        }
        if (unseen) {
            Box(
                Modifier
                    .offset { IntOffset((cx + half - with(density) { 10.dp.toPx() }).roundToInt(),
                                        (cy - half - with(density) { 1.dp.toPx() }).roundToInt()) }
                    .size(11.dp)
                    .background(TrainingTint.critical, CircleShape)
                    .border(2.dp, colors.canvas, CircleShape),
            )
        }
    }

    if (open) {
        ForgeOverlayPage(onDismiss = { open = false; unseen = false }) {
            ForgeSceneBackdrop(ForgeBackdrop.Sky) {
                ForgeCoachChatPages(viewModel, stringResource(R.string.nav_coach), onBack = { open = false; unseen = false })
            }
        }
    }
}

/** The button's size and its clearances after `CoachButtonCorner`. */
private val SIZE = 56.dp
private val MARGIN = 18.dp
private val BOTTOM_CHROME = 96.dp
// Forge's Today header (title, date and its round buttons) is taller than the iOS one.
private val TOP_CHROME = 100.dp
