package com.noop.ui

import com.noop.analytics.BaselineState
import com.noop.analytics.Baselines
import com.noop.analytics.ChargeDriver
import com.noop.analytics.RecoveryDrivers
import com.noop.analytics.RestScorer
import com.noop.analytics.ScoreConfidence
import com.noop.data.DailyMetric
import java.time.LocalDate
import java.time.format.DateTimeFormatter
import java.time.temporal.ChronoUnit
import java.util.Locale

/**
 * The recovery baseline's real seed count while it still cold-starts, the honest "calibrating N of
 * <seed>" progress shown in place of "No Data"; null once recovery exists or the baseline has crossed
 * the seed gate. [days] is oldest->newest (same order the engine folds). Pure + unit-tested.
 */
internal fun recoveryCalibrationNights(
    days: List<DailyMetric>,
    hasRecovery: Boolean,
    hrvBaselineEpoch: Double,
    seed: Int = Baselines.minNightsSeed,
): Int? {
    if (hasRecovery) return null
    val n = Baselines.foldHistory(
        days.map { it.avgHrv }, days.map { it.day }, Baselines.hrvCfg, hrvBaselineEpoch,
    ).nValid
    return n.takeIf { it in 0 until seed }
}

/**
 * The ordered "What shaped it" Charge driver rows for [displayDay], rebuilt purely from the visible
 * [days] history so the bars match the Charge ring's own inputs.
 */
internal fun recoveryChargeDrivers(
    days: List<DailyMetric>,
    displayDay: DailyMetric?,
): List<ChargeDriver> {
    val day = displayDay ?: return emptyList()
    val hrv = day.avgHrv ?: return emptyList()
    val rhr = day.restingHr?.toDouble() ?: return emptyList()

    val ordered = days.sortedBy { it.day }
    val hrvBase = Baselines.foldHistory(ordered.map { it.avgHrv }, Baselines.hrvCfg)
    if (!hrvBase.usable) return emptyList()
    val rhrBase = Baselines.foldHistory(ordered.map { it.restingHr?.toDouble() }, Baselines.restingHRCfg)
    val respBase = Baselines.foldHistory(ordered.map { it.respRateBpm }, Baselines.respCfg).takeIf { it.usable }

    val sleepPerf = RestScorer.restFromDaily(day)?.let { it / 100.0 } ?: day.efficiency

    return RecoveryDrivers.chargeDrivers(
        hrv = hrv,
        rhr = rhr,
        resp = day.respRateBpm,
        hrvBaseline = hrvBase,
        rhrBaseline = rhrBase,
        respBaseline = respBase,
        sleepPerf = sleepPerf,
        skinTempDev = day.skinTempDevC,
    )
}

/** Charge confidence tier for [displayDay] against the HRV baseline folded from [days]. */
internal fun chargeConfidenceTier(
    days: List<DailyMetric>,
    displayDay: DailyMetric?,
): ScoreConfidence {
    val hrvBase: BaselineState =
        Baselines.foldHistory(days.sortedBy { it.day }.map { it.avgHrv }, Baselines.hrvCfg)
    return ScoreConfidence.forCharge(displayDay?.recovery, hrvBase)
}

/** Most recent fully-scored recovery day to carry over on today while tonight's recovery is absent. */
internal fun lastScoredRecoveryDay(
    days: List<DailyMetric>,
    selectedDayKey: String,
    isToday: Boolean,
    todayScored: Boolean,
    isCalibrating: Boolean,
    today: String = "9999-12-31",
): DailyMetric? {
    if (!isToday || todayScored || isCalibrating) return null
    return days.lastOrNull { it.recovery != null && it.day != selectedDayKey && it.day <= today }
}

/** A prior day's Charge carried over on today while tonight's recovery has not been scored yet. */
internal data class LastCharge(val value: Double, val caption: String)

/** "d MMM" for a stored `yyyy-MM-dd` day key, used by the carried-over Charge caption. */
internal fun lastChargeDateLabel(dayKey: String): String =
    runCatching {
        LocalDate.parse(dayKey).format(DateTimeFormatter.ofPattern("d MMM", Locale.US))
    }.getOrDefault(dayKey)

/** Carry-over recency cap: the "Last night" framing only holds when the carried day is this fresh. */
internal const val CARRY_FRESHNESS_DAYS = 2L

/** True when the carried scored day is older than the freshness cap. */
internal fun isCarryStale(priorDayKey: String, today: String = LocalDate.now().toString()): Boolean =
    runCatching {
        ChronoUnit.DAYS.between(LocalDate.parse(priorDayKey), LocalDate.parse(today)) > CARRY_FRESHNESS_DAYS
    }.getOrDefault(false)

/** Honest Rest resolution for the selected day: own scored Rest wins, fresh same-day carry may fill today. */
internal fun freshRestScore(
    todayValue: Double?, lastDay: String?, lastValue: Double?,
    isTodaySelected: Boolean, today: String = LocalDate.now().toString(),
): Double? {
    if (todayValue != null) return todayValue
    if (!isTodaySelected || lastDay == null || lastValue == null) return null
    return if (isCarryStale(lastDay, today)) null else lastValue
}

/** Carried recovery caption stamp, keyed on the scored day's own date and recency. */
internal fun carriedCaption(priorDayKey: String, today: String = LocalDate.now().toString()): String {
    val prefix = if (isCarryStale(priorDayKey, today)) "Latest sleep" else "Last night"
    return "$prefix · ${lastChargeDateLabel(priorDayKey)}"
}

/** Honest state of one score/tile on Today, never a bare blank. Mirrors Swift `ScoreState`. */
sealed class ScoreState {
    data class Scored(val value: Double) : ScoreState()
    data class Calibrating(val nightsRemaining: Int) : ScoreState()
    data class CarriedLastNight(val dateLabel: String, val stale: Boolean = false) : ScoreState()
    object NeedsStrap : ScoreState()

    val title: String
        get() = when (this) {
            is Scored -> ""
            is Calibrating -> "Calibrating"
            is CarriedLastNight -> if (stale) "Latest sleep · $dateLabel" else "Last night · $dateLabel"
            NeedsStrap -> "Needs the strap"
        }

    val detail: String
        get() = when (this) {
            is Scored -> ""
            is Calibrating -> {
                val nights = if (nightsRemaining == 1) "night" else "nights"
                "Building your baseline. About $nightsRemaining more $nights until your scores are personal."
            }
            is CarriedLastNight ->
                if (stale) "This is your last scored session. Wear the strap overnight for a fresh score."
                else "Tonight's lands after you sleep with the strap on."
            NeedsStrap -> "No data for today. Was your strap worn and connected overnight?"
        }
}

/** Resolve the honest [ScoreState] for the Today score side. */
internal fun scoreStateForToday(
    todayRecovery: Double?,
    calibratingNights: Int?,
    carriedDay: DailyMetric?,
    seed: Int = Baselines.minNightsSeed,
    today: String = LocalDate.now().toString(),
): ScoreState = when {
    todayRecovery != null -> ScoreState.Scored(todayRecovery)
    calibratingNights != null -> ScoreState.Calibrating((seed - calibratingNights).coerceAtLeast(1))
    carriedDay != null -> ScoreState.CarriedLastNight(lastChargeDateLabel(carriedDay.day), isCarryStale(carriedDay.day, today))
    else -> ScoreState.NeedsStrap
}

/** Honest live-recording state of the strap, for the Today/Live chip. Mirrors Swift `RecordingState`. */
sealed class RecordingState {
    object Recording : RecordingState()
    data class LastSynced(val minutesAgo: Long) : RecordingState()
    object NotRecording : RecordingState()
    object HistoryExperimental : RecordingState()

    val title: String
        get() = when (this) {
            Recording -> "Recording"
            is LastSynced -> "Last synced ${minutesAgo}m ago"
            NotRecording -> "Not recording"
            HistoryExperimental -> "Connected"
        }

    val detail: String
        get() = when (this) {
            Recording -> "Your strap is connected and saving data."
            is LastSynced -> "Reconnect to pull the latest."
            NotRecording -> "Strap not connected. Tap to connect."
            HistoryExperimental -> "History sync is experimental on 5.0."
        }

    val tone: StrandTone
        get() = when (this) {
            Recording -> StrandTone.Positive
            is LastSynced -> StrandTone.Neutral
            NotRecording -> StrandTone.Critical
            HistoryExperimental -> StrandTone.Accent
        }
}

/** Resolve the honest [RecordingState] from the live BLE state + last-sync timestamp. */
internal fun recordingStateFor(
    connected: Boolean,
    liveHeartRate: Int?,
    lastSyncAtSec: Long?,
    nowSec: Long,
): RecordingState = when {
    connected && liveHeartRate != null -> RecordingState.Recording
    lastSyncAtSec != null -> {
        val secs = (nowSec - lastSyncAtSec).coerceAtLeast(0L)
        RecordingState.LastSynced((secs + 59L) / 60L)
    }
    else -> RecordingState.NotRecording
}

/** Whether this night's sleep staging is low-confidence, using the core [ScoreConfidence] rule. */
internal fun restStageLowConfidence(d: DailyMetric?): Boolean {
    val asleepMin = d?.totalSleepMin ?: return false
    val efficiency = d.efficiency ?: return false
    val restorativeMin = (d.deepMin ?: 0.0) + (d.remMin ?: 0.0)
    val hasStaged = restorativeMin > 0.0
    if (ScoreConfidence.forRest(hasSession = true, hasStagedSleep = hasStaged) != ScoreConfidence.SOLID) {
        return false
    }
    return ScoreConfidence.forRest(
        hasSession = true,
        hasStagedSleep = hasStaged,
        asleepSeconds = asleepMin * 60.0,
        restorativeSeconds = restorativeMin * 60.0,
        efficiency = efficiency,
    ) == ScoreConfidence.BUILDING
}

/** Short "it's coming, not broken" caption for an unscored tile on today only. */
internal fun buildingHint(metric: KeyMetric, isToday: Boolean): String? {
    if (!isToday) return null
    return when (metric) {
        KeyMetric.REST -> "Building, wear it tonight"
        KeyMetric.EFFORT -> "Building, moves as you do"
        KeyMetric.CHARGE -> "Building, wear it tonight"
        KeyMetric.BLOOD_OXYGEN -> "Building, wear it tonight"
        KeyMetric.STEPS -> "Building, moves as you do"
        else -> null
    }
}
