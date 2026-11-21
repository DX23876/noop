package com.noop.ui.forge

import android.content.Context
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.AutoAwesome
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.produceState
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.unit.dp
import com.noop.R
import com.noop.core.CoreCoach
import com.noop.ui.AppViewModel
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext

/**
 * Fork (DX23876), owner 2026-11-21: the coach in each main page's header, as iOS's `ForgeCoachButton`. It replaces the
 * coach's tab, so the bar holds the same five tabs as the iPhone's. [kind] is `CoachEntryPage.Kind`'s raw value
 * (today, training, nutrition, sleep, health) and [day] the shown day, `yyyy-MM-dd`.
 */
data class CoachPage(val kind: String, val day: String?)

/**
 * Opens the coach sheet, from a header (with its page) or from any "ask the coach" (null: no page). Null while the
 * coach is off or in the shipped design, which hides the header buttons. Provided by `ForgeRoot`.
 */
val LocalForgeOpenCoach = staticCompositionLocalOf<((CoachPage?) -> Unit)?> { null }

/** The page's two suggested questions, the same as iOS's `ForgeCoachButton.suggestions`. */
internal fun coachPageSuggestions(context: Context, kind: String): List<String> = when (kind) {
    "today" -> listOf(R.string.coach_page_today_1, R.string.coach_page_today_2)
    "training" -> listOf(R.string.coach_page_training_1, R.string.coach_page_training_2)
    "nutrition" -> listOf(R.string.coach_page_nutrition_1, R.string.coach_page_nutrition_2)
    "sleep" -> listOf(R.string.coach_page_sleep_1, R.string.coach_page_sleep_2)
    "health" -> listOf(R.string.coach_page_health_1, R.string.coach_page_health_2)
    else -> emptyList()
}.map(context::getString)

/** The header's coach button: a sparkle with a dot while the coach wrote something on its own that is unseen. */
@Composable
internal fun ForgeHeaderCoachButton(kind: String, day: String?) {
    val open = LocalForgeOpenCoach.current ?: return
    // A brief or a nudge can arrive while a page is open, so the dot is read again every minute, as the floating button's.
    val unseen by produceState(false) {
        while (true) {
            value = withContext(Dispatchers.IO) { CoreCoach.unseen() }
            delay(60_000)
        }
    }
    val label = stringResource(R.string.nav_coach)
    Box(Modifier.size(ForgeMetrics.minHitTarget).clickable(role = Role.Button, onClickLabel = label) { open(CoachPage(kind, day)) },
        contentAlignment = Alignment.Center) {
        // A round button like its neighbours (the strap, the plus, the search), as iOS's glass circle.
        HeaderCircle { Icon(Icons.Rounded.AutoAwesome, contentDescription = label, tint = Forge.sceneInk.text, modifier = Modifier.size(18.dp)) }
        if (unseen) {
            Box(Modifier.align(Alignment.TopEnd).offset(x = (-4).dp, y = 4.dp).size(9.dp)
                    .background(Forge.colors.accent, CircleShape))
        }
    }
}

/** The 36 dp round ground of a header button, the same as Today's plus: iOS draws these as glass circles. */
@Composable
internal fun HeaderCircle(content: @Composable () -> Unit) {
    val colors = Forge.colors
    Box(Modifier.size(36.dp).background(colors.heroFill, CircleShape).border(1.dp, colors.heroBorder, CircleShape),
        contentAlignment = Alignment.Center) { content() }
}

/**
 * The chat as a sheet that comes up halfway and drags to full height, as iOS's half sheet: the page the question is
 * about stays in sight. The same chat as before; its pages keep their own Back.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun ForgeCoachSheet(viewModel: AppViewModel, onDismiss: () -> Unit) {
    val state = rememberModalBottomSheetState(skipPartiallyExpanded = false)
    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = state, containerColor = Forge.colors.canvas) {
        LaunchedSeen()
        Box(Modifier.fillMaxWidth().fillMaxHeight(0.94f)) {
            ForgeCoachChatPages(viewModel, stringResource(R.string.nav_coach), onBack = onDismiss)
        }
    }
}

/** Opening the chat is having seen it, as iOS's `markCoachMessagesSeen` on appear. */
@Composable
private fun LaunchedSeen() {
    androidx.compose.runtime.LaunchedEffect(Unit) { withContext(Dispatchers.IO) { CoreCoach.seen() } }
}
