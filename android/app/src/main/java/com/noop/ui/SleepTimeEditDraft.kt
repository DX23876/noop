package com.noop.ui

import com.noop.analytics.SleepEditGuard
import java.time.Instant
import java.time.ZoneId

/**
 * The two endpoints edited by Android's sleep-time dialog (#515).
 *
 * Bed and wake changes stay in this draft until [validatedWindow] is saved, so changing one picker
 * can never persist an intermediate window against the session's stale opposite endpoint.
 */
internal data class SleepTimeEditDraft(
    val startTs: Long,
    val endTs: Long,
) {
    fun withBedCandidate(
        candidateBedTs: Long,
        nowTs: Long,
        zone: ZoneId = ZoneId.systemDefault(),
    ): SleepTimeEditDraft = copy(
        startTs = SleepEditGuard.autoCorrectedBed(
            previousBedTs = startTs,
            candidateBedTs = candidateBedTs,
            originalWakeTs = endTs,
            nowTs = nowTs,
            zone = zone,
        ),
    )

    /** Resolve a picked wake time to the first occurrence strictly after the drafted bedtime. */
    fun withWakeTime(
        hour: Int,
        minute: Int,
        zone: ZoneId = ZoneId.systemDefault(),
    ): SleepTimeEditDraft {
        val bed = Instant.ofEpochSecond(startTs).atZone(zone)
        var wake = bed.withHour(hour).withMinute(minute).withSecond(0).withNano(0)
        if (!wake.isAfter(bed)) wake = wake.plusDays(1)
        return copy(endTs = wake.toEpochSecond())
    }

    fun validatedWindow(
        nowTs: Long,
        slackSec: Long = 300L,
    ): Pair<Long, Long>? = SleepEditGuard.clampedEditWindow(startTs, endTs, nowTs, slackSec)
}
