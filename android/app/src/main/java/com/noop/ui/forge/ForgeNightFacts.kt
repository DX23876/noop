package com.noop.ui.forge

import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import com.noop.core.CoreRead
import com.noop.core.SwiftCore
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONObject

/**
 * The four figures a night is summed up in: time in bed, efficiency, hours asleep and restorative sleep,
 * each against the wearer's usual.
 *
 * Every number here is the core's (`NightSummaryFacts`, through `sleep.nightFacts`), including the usual.
 * The night's own minutes go in from the screen so the card states the night it is showing, and nothing
 * else is worked out on this side: a Kotlin copy of the average would be free to drift from the one the
 * iPhone shows for the same night.
 */
data class NightFacts(
    val inBedMin: Double,
    val asleepMin: Double,
    val restorativeMin: Double,
    val efficiencyPct: Double?,
    val typicalAsleepMin: Double?,
    val typicalRestorativeMin: Double?,
) {
    companion object {
        /** Blocking; call off the main thread. Null without a core or without stages to sum. */
        fun of(night: CoreRead.Night): NightFacts? {
            if (!SwiftCore.available) return null
            val summary = SleepSummary.of(night)
            if (summary.inBedMin <= 0) return null
            val args = JSONObject()
                .put("inBedMin", summary.inBedMin.toDouble())
                .put("asleepMin", summary.asleepMin.toDouble())
                .put("deepMin", (summary.minutesByStage["deep"] ?: 0).toDouble())
                .put("remMin", (summary.minutesByStage["rem"] ?: 0).toDouble())
            night.efficiency?.let { args.put("storedEfficiency", it) }
            val answer = SwiftCore.call("sleep.nightFacts", args.toString()) ?: return null
            return runCatching {
                val o = JSONObject(answer)
                if (o.has("error")) return null
                NightFacts(
                    inBedMin = o.getDouble("inBedMin"),
                    asleepMin = o.getDouble("asleepMin"),
                    restorativeMin = o.getDouble("restorativeMin"),
                    efficiencyPct = o.optDoubleOrNull("efficiencyPct"),
                    typicalAsleepMin = o.optDoubleOrNull("typicalAsleepMin"),
                    typicalRestorativeMin = o.optDoubleOrNull("typicalRestorativeMin"),
                )
            }.getOrNull()
        }

        private fun JSONObject.optDoubleOrNull(key: String): Double? =
            if (has(key) && !isNull(key)) getDouble(key) else null
    }
}

/** The night's figures, read again whenever the shown night changes. */
@Composable
internal fun rememberNightFacts(night: CoreRead.Night): NightFacts? {
    var facts by remember(night.startTs, night.endTs) { mutableStateOf<NightFacts?>(null) }
    LaunchedEffect(night.startTs, night.endTs) {
        facts = withContext(Dispatchers.IO) { NightFacts.of(night) }
    }
    return facts
}
