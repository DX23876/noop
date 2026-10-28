package com.noop.ui.forge

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.AutoAwesome
import androidx.compose.material.icons.rounded.Bedtime
import androidx.compose.material.icons.rounded.Check
import androidx.compose.material.icons.rounded.Close
import androidx.compose.material.icons.rounded.Edit
import androidx.compose.material.icons.rounded.SwapHoriz
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
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
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LifecycleEventEffect
import com.noop.core.CoreCoach
import com.noop.core.CoreRead
import com.noop.ui.NoopPrefs
import com.noop.ui.UnitPrefs
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.text.DateFormat
import java.util.Date

/**
 * The coach's suggestion for today's session (`MorningSuggestionCard`): Accept, Change or Not this one right on Today.
 * Which card shows is the shared `MorningSuggestionState`, read through `coach.morning`. Opening Today runs the day's
 * brief once when the wearer switched the suggestion on, as iOS does; while it runs the card reads the coach again
 * every second and a half so the spinner gives way to the proposal. No dismiss control: Not this one is the dismiss.
 */
@Composable
internal fun ForgeMorningSuggestion() {
    val context = LocalContext.current
    if (!NoopPrefs.coachEnabled(context)) return
    val scale = remember { UnitPrefs.effortScale(context).raw }
    val scope = rememberCoroutineScope()
    val selectTab = LocalForgeTabSelect.current
    var card by remember { mutableStateOf<CoreCoach.Morning?>(null) }
    var showPlan by remember { mutableStateOf(false) }
    var resumes by remember { mutableIntStateOf(0) }
    LifecycleEventEffect(Lifecycle.Event.ON_RESUME) { resumes++ }

    suspend fun refresh(op: String? = null, generate: Boolean = false, id: String? = null, accept: Boolean? = null) {
        val run = scope.async(Dispatchers.IO) { CoreCoach.morning(scale, op, generate, id = id, accept = accept) }
        if (generate || op == "confirmWake") {
            while (run.isActive) {
                delay(1_500)
                if (run.isActive) withContext(Dispatchers.IO) { CoreCoach.morning(scale) }?.let { card = it }
            }
        }
        run.await()?.let { card = it }
    }

    LaunchedEffect(resumes) {
        withContext(Dispatchers.IO) { CoreRead.open(context); CoreCoach.configureFromStores(context) }
        refresh()
        if (card?.on == true) refresh(generate = true)
    }

    val c = card ?: return
    val colors = Forge.colors
    when (c.kind) {
        "generating" -> ForgeCard(Modifier.fillMaxWidth()) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                CircularProgressIndicator(Modifier.size(16.dp), color = colors.charge, strokeWidth = 2.dp)
                Text(c.labels["generating"].orEmpty(), style = Forge.type.subhead, color = colors.textSecondary)
            }
        }
        "waiting" -> ForgeCard(Modifier.fillMaxWidth()) {
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Icon(Icons.Rounded.AutoAwesome, contentDescription = null, tint = colors.accent, modifier = Modifier.size(18.dp))
                    Text(c.title.orEmpty(), style = Forge.type.subhead, color = colors.text)
                }
                Text(c.summary.orEmpty(), style = Forge.type.body, color = colors.text)
                c.rationale?.let { Text(it, style = Forge.type.footnote, color = colors.textSecondary) }
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    MorningAction(Icons.Rounded.Check, c.labels["accept"].orEmpty(), prominent = true) {
                        scope.launch { refresh("decide", id = c.id, accept = true) }
                    }
                    MorningAction(Icons.Rounded.SwapHoriz, c.labels["change"].orEmpty()) { showPlan = true }
                    MorningAction(Icons.Rounded.Close, c.labels["decline"].orEmpty()) {
                        scope.launch { refresh("decide", id = c.id, accept = false) }
                    }
                }
            }
        }
        "confirmWake" -> ForgeCard(Modifier.fillMaxWidth()) {
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Icon(Icons.Rounded.Bedtime, contentDescription = null, tint = colors.effort, modifier = Modifier.size(18.dp))
                    Text(c.labels["wakeTitle"].orEmpty(), style = Forge.type.subhead, color = colors.text)
                }
                val time = c.wake?.let { DateFormat.getTimeInstance(DateFormat.SHORT).format(Date(it * 1000)) }.orEmpty()
                Text(c.wakeText.orEmpty().replace("%@", time), style = Forge.type.body, color = colors.text)
                Text(c.labels["wakeHint"].orEmpty(), style = Forge.type.footnote, color = colors.textSecondary)
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    MorningAction(Icons.Rounded.Check, c.labels["confirm"].orEmpty(), prominent = true) {
                        scope.launch { refresh("confirmWake") }
                    }
                    MorningAction(Icons.Rounded.Edit, c.labels["fix"].orEmpty()) { selectTab(ForgeTab.Sleep) }
                }
            }
        }
        else -> Unit
    }

    if (showPlan) {
        ForgeOverlayPage(onDismiss = { showPlan = false; scope.launch { refresh() } }) {
            ForgeSceneBackdrop(ForgeBackdrop.Sky) {
                ForgeCoachPlanPage(onBack = { showPlan = false; scope.launch { refresh() } })
            }
        }
    }
}

/** One pill action of the card, the first filled with the accent as on iOS. */
@Composable
private fun MorningAction(icon: ImageVector, label: String, prominent: Boolean = false, onClick: () -> Unit) {
    val colors = Forge.colors
    Row(
        Modifier.clip(RoundedCornerShape(50))
            .background(if (prominent) colors.accent else colors.inset)
            .clickable(role = Role.Button, onClick = onClick)
            .padding(horizontal = 10.dp, vertical = 7.dp),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(5.dp),
    ) {
        val tint = if (prominent) colors.onDark else colors.textSecondary
        Icon(icon, contentDescription = null, tint = tint, modifier = Modifier.size(14.dp))
        Text(label, style = Forge.type.footnote, color = tint)
    }
}
