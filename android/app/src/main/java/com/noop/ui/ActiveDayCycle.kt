package com.noop.ui

import com.noop.data.DailyMetric
import com.noop.data.MetricSeriesRow

/** Active boundary shared by every additive Today metric; steps are optional on counter-less devices. */
internal data class ActiveDayCycle(val ownerDay: String, val onsetTs: Long, val steps: Int?)

internal fun effectiveActiveStrapId(published: String?, fallback: String): String =
    published?.takeIf { it.isNotBlank() } ?: fallback

/** Resolve the newest valid boundary even when this device has no raw step counter. */
internal fun resolveActiveDayCycle(
    visibleDays: List<DailyMetric>,
    computedDays: List<DailyMetric>,
    onsetMarkers: List<MetricSeriesRow>,
    nowSeconds: Long,
): ActiveDayCycle? {
    val visibleDayKeys = visibleDays.mapTo(HashSet()) { it.day }
    val computedByDay = computedDays.associateBy { it.day }
    return onsetMarkers.asSequence()
        .filter { it.value.isFinite() && it.value > 0.0 && it.value <= nowSeconds.toDouble() }
        .filter { it.day in visibleDayKeys }
        .maxByOrNull { it.value }
        ?.let { marker ->
            ActiveDayCycle(marker.day, marker.value.toLong(), computedByDay[marker.day]?.steps)
        }
}
