package com.noop.ui.forge

import android.content.Context
import androidx.compose.animation.animateContentSize
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Bedtime
import androidx.compose.material.icons.rounded.ChevronRight
import androidx.compose.material.icons.rounded.Close
import androidx.compose.material.icons.rounded.DirectionsWalk
import androidx.compose.material.icons.rounded.Flag
import androidx.compose.material.icons.rounded.Info
import androidx.compose.material.icons.rounded.LocalFireDepartment
import androidx.compose.material.icons.rounded.MonitorHeart
import androidx.compose.material.icons.rounded.Accessibility
import androidx.compose.material.icons.rounded.SettingsInputAntenna
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.noop.R
import com.noop.core.CoreMomentum
import com.noop.core.CoreRead
import com.noop.core.SwiftCore
import com.noop.ui.AppViewModel
import com.noop.ui.NoopPrefs
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject

/**
 * Fork (DX23876), Forge parity 2026-11: the data's notices on the new design's Today, as Apple's `ForgeNotices`: the
 * Momentum signals worth an entry, each through the week-long cooldown of its topic. The cooldown itself is the shared
 * `TimelineFeed.admit` in the core (`timeline.admit`), so both apps admit the same notices; the log lives under
 * Apple's key and stays opaque here. Analysis migration required: no.
 */
internal object TodayNotices {
    const val LOG_KEY = "forge.timeline.noticeLog"
    const val LESS_OFTEN_KEY = "forge.timeline.lessOften"
    const val MUTED_KEY = "forge.timeline.mutedTopics"

    data class Notice(val key: String, val at: Long, val topic: String, val tone: String, val headline: String,
                      val detail: String, val destination: String?, val actionTitle: String?)

    /** The Momentum kinds that become notices, by topic (`ForgeNotices.topic`); the rest are said elsewhere. */
    fun topic(kind: String): String? = when (kind) {
        "healthAlert", "hrvTrend" -> "bodySignals"
        "strapBattery" -> "device"
        "restDayNeeded", "planDeviation" -> "load"
        "sleepCatchUp" -> "sleep"
        "milestone", "weightMilestone", "streak", "weeklyTrainingGoal" -> "goals"
        else -> null
    }

    /** Momentum's tone as the severity the cooldown compares: a step up in tone is "clearly worse". */
    fun severity(tone: String): Double = when (tone) {
        "positive" -> 1.0
        "caution" -> 3.0
        "critical" -> 4.0
        else -> 2.0
    }

    /** A reached milestone or a streak is its own news each time. */
    fun isEvent(kind: String): Boolean = kind == "milestone" || kind == "weightMilestone" || kind == "streak"

    fun key(m: CoreMomentum.Message): String = if (topic(m.kind) == "goals") "${m.kind}|${m.headline}" else m.kind

    private fun list(context: Context, key: String): Set<String> =
        (NoopPrefs.of(context).getString(key, "") ?: "").split(",").filter { it.isNotEmpty() }.toSet()

    /** The admitted notices for [day], each at the moment it first appeared; the log is written back. Blocking. */
    fun notices(context: Context, momentum: List<CoreMomentum.Message>, day: String, nowSec: Long): List<Notice> {
        if (!SwiftCore.available) return emptyList()
        val byKey = LinkedHashMap<String, Notice>()
        val candidates = JSONArray()
        val muted = list(context, MUTED_KEY)
        for (m in momentum) {
            val topic = topic(m.kind) ?: continue
            val k = key(m)
            if (byKey.containsKey(k) || topic in muted) continue
            candidates.put(JSONObject().put("key", k).put("topic", topic).put("severity", severity(m.tone)).put("isEvent", isEvent(m.kind)))
            byKey[k] = Notice(k, nowSec, topic, m.tone, m.headline,
                              listOfNotNull(m.detail, m.actionLine).filter { it.isNotEmpty() }.joinToString(" "),
                              m.destination, m.actionTitle)
        }
        val prefs = NoopPrefs.of(context)
        val args = JSONObject().put("candidates", candidates).put("log", prefs.getString(LOG_KEY, "[]") ?: "[]")
            .put("day", day).put("now", nowSec.toDouble()).put("lessOften", JSONArray(list(context, LESS_OFTEN_KEY).toList()))
        val out = SwiftCore.call("timeline.admit", args.toString())?.let { runCatching { JSONObject(it) }.getOrNull() } ?: return emptyList()
        out.optString("log").takeIf { it.isNotEmpty() && it != prefs.getString(LOG_KEY, null) }?.let {
            prefs.edit().putString(LOG_KEY, it).apply()
        }
        val admitted = out.optJSONArray("admitted") ?: return emptyList()
        return (0 until admitted.length()).mapNotNull { i ->
            val a = admitted.getJSONObject(i)
            byKey[a.getString("key")]?.copy(at = a.optDouble("at", nowSec.toDouble()).toLong())
        }
    }
}

/**
 * The one hint under Today's rings, as Apple's `ForgeTodayHint`: the most pressing thing the day holds, put away with
 * a cross for today, the other candidates one tap away under it. Pure; the card below draws it.
 */
internal object TodayHints {
    const val DISMISSED_KEY = "forge.today.hintDismissed"

    sealed interface Source {
        data class Notice(val notice: TodayNotices.Notice) : Source
        data object WeighIn : Source
    }

    data class Hint(val id: String, val source: Source, val title: String, val detail: String?)

    private val toneRank = mapOf("critical" to 0, "caution" to 1, "neutral" to 2, "positive" to 3)

    /**
     * The day's candidates, most pressing first: a raised warning, then the other notices (care before news), then a
     * missing weigh-in. Apple also ranks a plan waiting for an answer and the newest coach note between them; Android's
     * Today has neither yet. Dismissed ones are left out.
     */
    fun candidates(notices: List<TodayNotices.Notice>, weighIn: Boolean, weighTitle: String, weighDetail: String,
                   dismissed: Set<String>): List<Hint> {
        fun hint(n: TodayNotices.Notice) = Hint(n.key, Source.Notice(n), n.headline, n.detail.ifEmpty { null })
        val out = mutableListOf<Hint>()
        out += notices.filter { it.tone == "critical" }.sortedByDescending { it.at }.map(::hint)
        out += notices.filter { it.tone != "critical" }
            .sortedWith(compareBy<TodayNotices.Notice>({ toneRank[it.tone] ?: 9 }, { -it.at })).map(::hint)
        if (weighIn) out += Hint("hint.weighIn", Source.WeighIn, weighTitle, weighDetail)
        return out.filter { it.id !in dismissed }
    }

    /**
     * The day's admitted notices and whether a weight goal misses its weigh-in (Apple's `weighInDue`), the inputs of
     * [candidates]. Blocking; the hint card and the timeline both read it, so the timeline can leave out the hint's entry.
     */
    suspend fun load(context: Context, live: CoreMomentum.Live, day: String): Pair<List<TodayNotices.Notice>, Boolean> {
        CoreRead.open(context)
        val dismissedWorkouts = dismissedTrainingWorkouts(context)
        val momentum = CoreMomentum.feed(context, dismissedWorkouts, live).orEmpty()
        val notices = TodayNotices.notices(context, momentum, day, System.currentTimeMillis() / 1000)
        val weightGoal = com.noop.core.CoreGoals.snapshot(context, dismissedWorkouts)?.longTerm.orEmpty()
            .any { it.kind == "weight" && (it.status == "active" || it.status == "paused") }
        val weighIn = weightGoal && run {
            val last = com.noop.core.CoreBody.snapshot(context, days = 30)?.weighIns?.maxOfOrNull { it.day }
            last == null || last < java.time.LocalDate.now().minusDays(7).toString()
        }
        return notices to weighIn
    }

    /** The dismissed hints of [day] from their stored form ("day|id" lines); other days' lines are ignored. */
    fun dismissed(raw: String, day: String): Set<String> =
        raw.split("\n").mapNotNull { line ->
            val parts = line.split("|", limit = 2)
            if (parts.size == 2 && parts[0] == day) parts[1] else null
        }.toSet()

    /** [raw] with [id] dismissed for [day], keeping only that day's lines so the store never grows. */
    fun dismissing(id: String, day: String, raw: String): String =
        (raw.split("\n").filter { it.startsWith("$day|") } + "$day|$id").joinToString("\n")
}

/** A notice's symbol from its topic and its colour from its tone, as Apple's `noticeLook`. */
@Composable
private fun hintLook(source: TodayHints.Source): Pair<ImageVector, Color> {
    val colors = Forge.colors
    return when (source) {
        TodayHints.Source.WeighIn -> Icons.Rounded.Accessibility to colors.rest
        is TodayHints.Source.Notice -> {
            val n = source.notice
            val tint = when (n.tone) {
                "positive" -> colors.charge
                "caution" -> colors.effort
                "critical" -> if (n.key == "healthAlert") ForgeTokens.Color.systemRed.resolve() else colors.effort
                else -> colors.accent
            }
            val icon = when (n.topic) {
                "sleep" -> Icons.Rounded.Bedtime
                "load" -> Icons.Rounded.LocalFireDepartment
                "bodySignals" -> Icons.Rounded.MonitorHeart
                "movement" -> Icons.Rounded.DirectionsWalk
                "goals" -> Icons.Rounded.Flag
                "device" -> Icons.Rounded.SettingsInputAntenna
                else -> Icons.Rounded.Info
            }
            icon to tint
        }
    }
}

@Composable
private fun HintMark(source: TodayHints.Source) {
    val (icon, tint) = hintLook(source)
    Box(Modifier.size(40.dp).background(tint, RoundedCornerShape(11.dp)), contentAlignment = Alignment.Center) {
        Icon(icon, contentDescription = null, tint = Color.White, modifier = Modifier.size(20.dp))
    }
}

/**
 * The day's one hint under the rings, as Apple's `hintCard`. A notice opens where its Momentum action leads (the
 * Charge page, the goals, the plan); the weigh-in opens the body page.
 */
@Composable
internal fun TodayHintCard(viewModel: AppViewModel, day: String, onCharge: () -> Unit, onGoals: () -> Unit,
                           onPlan: () -> Unit, onWeight: () -> Unit) {
    val context = LocalContext.current
    val colors = Forge.colors
    val live = rememberMomentumLive(viewModel)
    val revision by com.noop.core.CoreShadow.dataRevision.collectAsState()
    var dismissedRaw by remember { mutableStateOf(NoopPrefs.of(context).getString(TodayHints.DISMISSED_KEY, "") ?: "") }
    var open by remember { mutableStateOf(false) }
    val weighTitle = stringResource(R.string.forge_hint_weigh_title)
    val weighDetail = stringResource(R.string.forge_hint_weigh_detail)
    val loaded by produceState<Pair<List<TodayNotices.Notice>, Boolean>>(emptyList<TodayNotices.Notice>() to false, revision, live, day) {
        value = withContext(Dispatchers.IO) { TodayHints.load(context, live, day) }
    }
    val hints = TodayHints.candidates(loaded.first, loaded.second, weighTitle, weighDetail,
                                      TodayHints.dismissed(dismissedRaw, day))
    val top = hints.firstOrNull() ?: return
    fun act(h: TodayHints.Hint) {
        when (val s = h.source) {
            TodayHints.Source.WeighIn -> onWeight()
            is TodayHints.Source.Notice -> when (s.notice.destination) {
                "chargeBreakdown" -> onCharge()
                "goalJourney" -> onGoals()
                "plan" -> onPlan()
                else -> Unit
            }
        }
    }
    ForgeCard(Modifier.fillMaxWidth().animateContentSize()) {
        Row(verticalAlignment = Alignment.Top) {
            HintMark(top.source)
            Spacer(Modifier.width(ForgeMetrics.space3))
            Column(Modifier.weight(1f).clickable(role = Role.Button) { act(top) }) {
                Text(top.title, style = Forge.type.headline, color = colors.text)
                top.detail?.let { Text(it, style = Forge.type.subhead, color = colors.textSecondary, maxLines = 2,
                                       modifier = Modifier.padding(top = 4.dp)) }
            }
            IconButton(onClick = {
                dismissedRaw = TodayHints.dismissing(top.id, day, dismissedRaw)
                NoopPrefs.of(context).edit().putString(TodayHints.DISMISSED_KEY, dismissedRaw).apply()
            }, modifier = Modifier.padding(top = 0.dp).size(36.dp)) {
                Icon(Icons.Rounded.Close, contentDescription = stringResource(R.string.forge_hint_dismiss), tint = colors.textTertiary,
                     modifier = Modifier.size(16.dp))
            }
        }
        if (hints.size > 1) {
            if (open) hints.drop(1).forEach { h ->
                Box(Modifier.padding(start = 52.dp, top = ForgeMetrics.space2).fillMaxWidth().height(ForgeMetrics.hairline).background(colors.divider))
                Row(Modifier.fillMaxWidth().clickable(role = Role.Button) { act(h) }.padding(top = ForgeMetrics.space2),
                    verticalAlignment = Alignment.CenterVertically) {
                    HintMark(h.source)
                    Spacer(Modifier.width(ForgeMetrics.space3))
                    Text(h.title, style = Forge.type.subhead.copy(fontWeight = FontWeight.Medium), color = colors.text, maxLines = 2,
                         modifier = Modifier.weight(1f))
                    Icon(Icons.Rounded.ChevronRight, contentDescription = null, tint = colors.textTertiary, modifier = Modifier.size(16.dp))
                }
            }
            Text(if (open) stringResource(R.string.forge_hint_show_less) else stringResource(R.string.forge_hint_more, hints.size - 1),
                 style = Forge.type.subhead.copy(fontWeight = FontWeight.Medium), color = colors.accent,
                 modifier = Modifier.padding(start = 52.dp, top = ForgeMetrics.space3).clickable(role = Role.Button) { open = !open })
        }
    }
}
