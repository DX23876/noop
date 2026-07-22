package com.noop.ui

import com.noop.ble.LiveState
import kotlin.math.roundToInt

// MARK: - Derived live HR
//
// HR to display: the reported value when > 0, else derived from the latest R-R
// interval in milliseconds (the strap streams R-R even when its HR field reads 0).

internal fun displayHr(bpm: Int?, live: LiveState): Int? {
    // #39: prefer the spike-filtered median (AppViewModel.bpm) over raw live.heartRate, which carries
    // PPG harmonic spikes (real ~92 read as 170+). Raw / R-R are last-resort fallbacks.
    if (bpm != null && bpm > 0) return bpm
    live.heartRate?.let { if (it > 0) return it }
    val lastRr = live.rr.lastOrNull()
    if (lastRr != null && lastRr > 0) return (60_000.0 / lastRr).roundToInt()
    return null
}

internal fun hrIsDerived(live: LiveState): Boolean =
    (live.heartRate ?: 0) <= 0 && live.rr.isNotEmpty()

/** HR as a fraction of HR-max (0..1). */
internal fun hrFraction(hr: Int?, hrMax: Int): Double {
    if (hr == null || hrMax <= 0) return 0.0
    return (hr.toDouble() / hrMax).coerceIn(0.0, 1.0)
}

/** Current zone 1..5 from %HR-max (WHOOP/Karvonen-style bands: 50/60/70/80/90). */
internal fun hrZone(fraction: Double): Int = when {
    fraction < 0.60 -> 1
    fraction < 0.70 -> 2
    fraction < 0.80 -> 3
    fraction < 0.90 -> 4
    else -> 5
}

/** One streamed live-HR reading with the wall-clock time it arrived (epoch millis). Carrying the
 *  time — not a bare bpm — is what lets the hero render a real time x-axis (#198). */
data class LiveHrSample(val timeMs: Long, val bpm: Double)

/** A short, time-stamped HR series for the hero chart. Prefers the accumulated live-HR history
 *  (which moves over time); falls back to per-beat HR from R-R, then to a flat pair while the
 *  buffer fills. The old version derived ONLY from R-R, which is sparse on WHOOP 4, so it sat on a
 *  flat 2-point line even while HR was clearly changing (issue #18). The R-R / flat fallbacks have
 *  no real per-sample timestamps, so we synthesise a 1 Hz trailing window ending "now" — the x-axis
 *  still reads as clock time and scrolls, matching the live buffer (#198). */
internal fun hrSeries(history: List<LiveHrSample>, live: LiveState, hr: Int?): List<LiveHrSample> {
    if (history.size > 1) return history
    val beats = live.rr.takeLast(60).mapNotNull { rr ->
        if (rr > 0) 60_000.0 / rr else null
    }
    if (beats.size > 1) return synthesiseSeries(beats)
    if (hr != null) return synthesiseSeries(listOf(hr.toDouble(), hr.toDouble()))
    return emptyList()
}

/** Wrap a bare value series in trailing 1 Hz timestamps ending "now", so the fallbacks chart on the
 *  same time x-axis as the live buffer. */
private fun synthesiseSeries(values: List<Double>): List<LiveHrSample> {
    val now = System.currentTimeMillis()
    val n = values.size
    return values.mapIndexed { i, v ->
        LiveHrSample(timeMs = now + (i - (n - 1)) * 1000L, bpm = v)
    }
}

/** The live-HR hero's rolling buffer cap: 180 samples at the 1 Hz tick (#941) is a strict ~3 minutes. */
internal const val LIVE_HR_BUFFER_CAP = 180

/** One 1 Hz tick of the hero buffer (#941): bank the latest smoothed HR when it is present and
 *  physiologically plausible (30..220, the same range guard the old on-change append used), then trim
 *  the buffer to the rolling cap. Pure so the guard + cap behaviour is JVM-testable. */
internal fun appendLiveHrSample(
    history: MutableList<LiveHrSample>,
    bpm: Int?,
    timeMs: Long,
    cap: Int = LIVE_HR_BUFFER_CAP,
) {
    val v = bpm ?: return
    if (v !in 30..220) return
    history.add(LiveHrSample(timeMs = timeMs, bpm = v.toDouble()))
    while (history.size > cap) history.removeAt(0)
}
