package com.noop.ui.forge

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Close
import androidx.compose.material.icons.rounded.TrackChanges
import androidx.compose.material3.Button
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import com.noop.R
import com.noop.core.CoreGoals
import com.noop.core.CorePrefs
import com.noop.core.CoreRead
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.text.NumberFormat
import java.util.Locale

private fun whole(value: Double): String = NumberFormat.getIntegerInstance(Locale.getDefault()).format(Math.round(value))

/** Whether the wearer has any goal Today's card would show (`GoalsTodaySection.hasAnyGoal`). */
internal fun CoreGoals.Output.hasAnyGoal(): Boolean =
    period.isNotEmpty() || longTerm.isNotEmpty() || today.isNotEmpty()

/**
 * Fork (DX23876), Android parity plan 2.3: Today's goal invitation, as iOS shows it while there is no goal
 * (`GoalsInviteCard`): a weekly workouts goal at the recommended target, said with how often the wearer usually
 * trains, one tap to set it, "Other goals" to the goals page, the cross to hide it (`goals.todayInviteDismissed`,
 * switched back on in Settings › Goals).
 */
@Composable
internal fun ForgeGoalsInvite(onCreated: () -> Unit, onOtherGoals: () -> Unit) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var dismissed by remember { mutableStateOf(true) }
    var invite by remember { mutableStateOf<CoreGoals.Invite?>(null) }
    LaunchedEffect(Unit) {
        withContext(Dispatchers.IO) {
            CoreRead.open(context)
            dismissed = CorePrefs.read(context).optBoolean(CorePrefs.INVITE_DISMISSED, false)
            if (!dismissed) invite = CoreGoals.setup(context, dismissedTrainingWorkouts(context))?.invite
        }
    }
    val s = invite
    if (dismissed || s == null) return
    val colors = Forge.colors
    Column(verticalArrangement = Arrangement.spacedBy(ForgeMetrics.space2)) {
        SectionHeader(stringResource(R.string.forge_goals_more_title))
        ForgeCard(Modifier.fillMaxWidth(), radius = ForgeMetrics.groupedRadius) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(Icons.Rounded.TrackChanges, null, tint = colors.accent, modifier = Modifier.size(20.dp))
                Spacer(Modifier.width(ForgeMetrics.space2))
                Text(stringResource(R.string.forge_gi_title), style = Forge.type.headline, color = colors.text,
                     modifier = Modifier.weight(1f))
                IconButton(onClick = {
                    dismissed = true
                    scope.launch { withContext(Dispatchers.IO) { CorePrefs.write(context, CorePrefs.INVITE_DISMISSED, true) } }
                }) { Icon(Icons.Rounded.Close, stringResource(R.string.forge_gi_hide), tint = colors.textTertiary) }
            }
            Text(s.usual?.let { stringResource(R.string.forge_gi_usual, whole(it), whole(s.target)) }
                     ?: stringResource(R.string.forge_gi_plain),
                 style = Forge.type.footnote, color = colors.textSecondary)
            Spacer(Modifier.height(ForgeMetrics.space2))
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(ForgeMetrics.space3)) {
                Button(onClick = {
                    scope.launch {
                        withContext(Dispatchers.IO) { CoreGoals.addPeriodGoal("workouts", "week", s.target, null) }
                        onCreated()
                    }
                }) { Text(stringResource(R.string.forge_gi_button, whole(s.target)), style = Forge.type.footnote) }
                TextButton(onClick = onOtherGoals) {
                    Text(stringResource(R.string.forge_gi_other), style = Forge.type.footnote, color = colors.accent)
                }
            }
        }
    }
}

private val INTRO_PAGES = listOf(
    R.string.forge_gx_t1 to R.string.forge_gx_b1, R.string.forge_gx_t2 to R.string.forge_gx_b2,
    R.string.forge_gx_t3 to R.string.forge_gx_b3, R.string.forge_gx_t4 to R.string.forge_gx_b4,
    R.string.forge_gx_t5 to R.string.forge_gx_b5,
)

/**
 * The goals explainer (`GoalsIntroSheet`), shown the first time the goals page opens and again after Settings ›
 * Goals › "Show the explainer again": five pages, Next and Let's go, Skip. Each page carries its demo ([GoalsIntroDemo]),
 * the bar one animated as on iOS.
 */
@Composable
internal fun ForgeGoalsIntro(onDone: () -> Unit) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var page by remember { mutableIntStateOf(0) }
    fun finish() {
        scope.launch { withContext(Dispatchers.IO) { CorePrefs.write(context, CorePrefs.INTRO_SEEN, true) } }
        onDone()
    }
    val colors = Forge.colors
    SettingsColumn {
        Row(Modifier.fillMaxWidth()) {
            Spacer(Modifier.weight(1f))
            TextButton(onClick = ::finish) { Text(stringResource(R.string.forge_gx_skip), color = colors.accent) }
        }
        ForgeCard(Modifier.fillMaxWidth(), radius = ForgeMetrics.heroRadius) {
            Column(Modifier.fillMaxWidth().padding(vertical = ForgeMetrics.space6),
                   horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(ForgeMetrics.space3)) {
                Box(Modifier.fillMaxWidth().padding(horizontal = ForgeMetrics.space4).heightIn(min = 170.dp), contentAlignment = Alignment.CenterStart) {
                    GoalsIntroDemo(page)
                }
                Text(stringResource(INTRO_PAGES[page].first), style = Forge.type.title2, color = colors.text, textAlign = TextAlign.Start, modifier = Modifier.fillMaxWidth().padding(horizontal = ForgeMetrics.space4))
                Text(stringResource(INTRO_PAGES[page].second), style = Forge.type.body, color = colors.textSecondary,
                     textAlign = TextAlign.Start, modifier = Modifier.fillMaxWidth().padding(horizontal = ForgeMetrics.space4))
            }
        }
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.Center) {
            INTRO_PAGES.indices.forEach { i ->
                Box(Modifier.padding(4.dp).size(8.dp).androidxBackground(if (i == page) colors.accent else colors.inset)
                        .clickable(role = Role.Tab) { page = i })
            }
        }
        Button(onClick = { if (page < INTRO_PAGES.lastIndex) page++ else finish() }, modifier = Modifier.fillMaxWidth()) {
            Text(stringResource(if (page < INTRO_PAGES.lastIndex) R.string.forge_gx_next else R.string.forge_gx_go),
                 style = Forge.type.headline)
        }
    }
}

private fun Modifier.androidxBackground(c: androidx.compose.ui.graphics.Color) =
    this.then(Modifier.background(c, androidx.compose.foundation.shape.CircleShape))
