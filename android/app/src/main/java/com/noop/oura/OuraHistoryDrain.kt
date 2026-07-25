package com.noop.oura

/**
 * Pure, testable decision core for the Oura history drain + durable resume cursor (#91 / #291).
 * Byte-identical Kotlin twin of Swift's `OuraHistoryDrain` struct.
 *
 * The `0x11` history summary carries no cursor — only `bytes_left` (a remaining-byte count) and a
 * `moreData` flag. A healthy drain runs until `bytes_left == 0`; the resume cursor commits from the
 * newest STORED sample's ring-time at drain end. Byte counts are never persisted.
 *
 * Two cursors, deliberately separate:
 *  - [maxSeenRingTime] tracks EVERY history record (anchored or not) and steers only the in-session
 *    CONTINUATION requests (open_oura `drain_events` advances `start = max_ts + 1` per batch — a
 *    non-advancing re-request makes the ring restart its serve: the observed 5x re-serve loop).
 *  - [maxStoredRingTime] tracks only anchored, STORED samples and is the only value the DURABLE
 *    cursor may commit from (honest-data invariant).
 *
 * All ring-times are the unsigned 32-bit value carried as a Long (0..0xFFFFFFFF), the Kotlin
 * stand-in for Swift's UInt32.
 */
class OuraHistoryDrain {
    private var minBytesLeftSeen = Long.MAX_VALUE
    private var stallCount = 0

    /** Newest STORED ring-time seen this drain — the value the resume cursor commits to at drain end. */
    var maxStoredRingTime: Long = 0
        private set

    /**
     * Newest ring-time SEEN this drain across ALL history records (anchored or not) — the in-session
     * continuation cursor's source.
     */
    var maxSeenRingTime: Long = 0
        private set

    /** History records seen since the last GetEvents request — open_oura's `batch_events` progress test. */
    var eventsSinceLastRequest: Long = 0
        private set

    /**
     * A real stored sample older than where we sought this fetch: the ring's clock reset (or it ignored
     * the seek), so the persisted cursor is stale → full pull next connect.
     */
    var sawPreResumeData = false
        private set

    /** Reset the per-drain state at the start of a fetch. Mirrors the live source's fetch-start reset. */
    fun reset() {
        minBytesLeftSeen = Long.MAX_VALUE
        stallCount = 0
        maxStoredRingTime = 0
        maxSeenRingTime = 0
        eventsSinceLastRequest = 0
        sawPreResumeData = false
    }

    /**
     * Fold in one history summary; returns whether the drain should CONTINUE.
     *
     * `moreData == false` (`bytes_left == 0`) always completes. Otherwise two backstops force-stop a
     * misbehaving ring while keeping banked progress: the STALL guard (`bytes_left` must shrink across
     * summaries — [MAX_STALL_SUMMARIES] flat reads means it's looping) and the DEADLINE guard
     * (`elapsedSeconds` past [MAX_DRAIN_SECONDS]).
     */
    fun onSummary(bytesLeft: Long, moreData: Boolean, elapsedSeconds: Double): Boolean {
        if (!moreData) return false
        if (bytesLeft < minBytesLeftSeen) {
            minBytesLeftSeen = bytesLeft
            stallCount = 0
        } else {
            stallCount += 1
            if (stallCount >= MAX_STALL_SUMMARIES) return false
        }
        if (elapsedSeconds > MAX_DRAIN_SECONDS) return false
        return true
    }

    /**
     * Record a STORED history sample's ring-time toward the resume cursor. Call ONLY where a sample
     * resolved a REAL anchored time (never a wall-clock fallback). Ignores corrupt (over-ceiling)
     * times, and flags a reboot when a real sample predates `resumeCursorAtFetchStart` (0 = full pull,
     * no floor).
     */
    fun noteStoredRingTime(rt: Long, resumeCursorAtFetchStart: Long) {
        if (rt > MAX_PLAUSIBLE_RESUME_TICKS) return
        if (rt > maxStoredRingTime) maxStoredRingTime = rt
        if (resumeCursorAtFetchStart > 0 && rt < resumeCursorAtFetchStart) sawPreResumeData = true
    }

    /**
     * Record ANY history record's ring-time toward the in-session continuation cursor (anchored or
     * not), and count it toward the batch-progress test. Ignores corrupt (over-ceiling) times.
     */
    fun noteSeenRingTime(rt: Long) {
        if (rt > MAX_PLAUSIBLE_RESUME_TICKS) return
        if (rt > maxSeenRingTime) maxSeenRingTime = rt
        eventsSinceLastRequest += 1
    }

    /**
     * The cursor for the NEXT in-session GetEvents request, or null to stop (open_oura `drain_events`:
     * `progressed = batch_events > 0 && next > start; if !progressed break`). Re-sending a
     * non-advancing cursor makes the ring RESTART serving from it, so a flat batch ends the drain
     * instead of retrying. On advance, the batch counter re-arms for the next request's progress test.
     */
    fun continuationCursor(lastRequestCursor: Long): Long? {
        if (eventsSinceLastRequest <= 0) return null
        val next = maxSeenRingTime + 1
        if (next <= lastRequestCursor) return null
        eventsSinceLastRequest = 0
        return next
    }

    /**
     * The cursor to persist at drain end, given the current cursor and whether [maxStoredRingTime]
     * resolves under the CURRENT anchor. A reboot ([sawPreResumeData]) resets to 0 (honest full pull
     * next connect); otherwise the cursor advances to [maxStoredRingTime] only if it moved forward AND
     * resolves. Unchanged in every other case.
     */
    fun resumeCursorAtDrainEnd(currentCursor: Long, resolvesUnderAnchor: Boolean): Long {
        if (sawPreResumeData) return 0
        if (maxStoredRingTime > currentCursor && resolvesUnderAnchor) return maxStoredRingTime
        return currentCursor
    }

    companion object {
        /**
         * A ring-time above this is corrupt (~1.6 years of ticks) and must not set the resume cursor,
         * or the next session would seek into nonsense. Bounds the cursor at the source.
         */
        const val MAX_PLAUSIBLE_RESUME_TICKS = 500_000_000L

        /** `bytes_left` not shrinking for this many straight summaries = the ring is looping; stop. */
        const val MAX_STALL_SUMMARIES = 3

        /**
         * A healthy full pull finishes in ~1-2 min; past this something upstream is wrong — stop, keep
         * the banked progress, and let the next self-chained pass / periodic re-fetch continue.
         */
        const val MAX_DRAIN_SECONDS = 300.0

        /**
         * Sanitize a cursor loaded from persistence: a value above the plausibility ceiling is pre-fix
         * garbage and must reset to a full pull.
         */
        fun sanitizeLoadedCursor(persisted: Long): Long =
            if (persisted in 0..MAX_PLAUSIBLE_RESUME_TICKS) persisted else 0
    }
}
