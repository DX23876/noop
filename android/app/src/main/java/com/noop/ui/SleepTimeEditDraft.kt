package com.noop.ui

import com.noop.analytics.SleepEditGuard
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

    /** Store a complete user-selected wake instant without deriving or shifting its calendar date. */
    fun withWakeCandidate(candidateWakeTs: Long): SleepTimeEditDraft =
        copy(endTs = candidateWakeTs)


    fun validatedWindow(
        nowTs: Long,
        slackSec: Long = 300L,
    ): Pair<Long, Long>? = SleepEditGuard.clampedEditWindow(startTs, endTs, nowTs, slackSec)
}
