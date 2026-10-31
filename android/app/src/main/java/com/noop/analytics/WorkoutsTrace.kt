package com.noop.analytics

// WorkoutsTrace.kt - the Workouts & GPS test-mode line formatters and live-readout parser (twin of the Swift
// WorkoutsTrace / WorkoutsReadout). Kept when the old auto-detect trace beside them was retired (2026-10-31).

/**
 * Pure line formatters + the live-readout parser for the Workouts & GPS test mode. Kotlin twin of the Swift
 * WorkoutsTrace / WorkoutsReadout. The app emitters own the live state; these own the line SHAPE so both
 * platforms read identically. No state, no IO, no PII. No em-dashes.
 */
object WorkoutsTrace {

    /** A session-lifecycle line. [event] is "start" / "end" / "discarded"; the counts are the captured HR
     *  window size and (for an end) the duration + accepted GPS points. Sport is the normalised key. */
    fun sessionLine(
        event: String,
        sportKey: String,
        hrSamples: Int,
        durationSec: Int? = null,
        gpsPoints: Int? = null,
    ): String {
        val sb = StringBuilder("session event=$event sport=$sportKey hrSamples=$hrSamples")
        if (durationSec != null) sb.append(" durationSec=$durationSec")
        if (gpsPoints != null) sb.append(" gpsPoints=$gpsPoints")
        return sb.toString()
    }

    /**
     * A GPS-fix-progress line: raw fixes seen, how many the filter accepted, and the running distance.
     *
     * [rawFixes] is OPTIONAL: macOS sees the pre-filter raw stream and passes a real count so the line shows
     * a true accept rate. Android's LocationTracker pre-filters upstream, so the raw count is NOT available
     * at the GpsSession seam (every fix here is already accepted); it passes null and the line renders
     * `rawFixes=n/a` rather than implying an accept rate the platform cannot measure. Mirrors Swift gpsLine.
     */
    fun gpsLine(rawFixes: Int?, acceptedPoints: Int, distanceM: Double): String =
        "gps rawFixes=${rawFixes?.toString() ?: "n/a"} accepted=$acceptedPoints " +
            "distanceM=${Math.round(distanceM)} (filter: accuracy+speed gate)"

    /** A cross-source dedup decision line: two same-activity rows collapsed to the richer one. */
    fun dedupLine(
        sportKey: String,
        keptSource: String,
        droppedSource: String,
        keptRichness: Int,
        droppedRichness: Int,
    ): String =
        "dedup sport=$sportKey kept=$keptSource(richness=$keptRichness) " +
            "dropped=$droppedSource(richness=$droppedRichness) (same activity, richer kept)"

    /**
     * An analytics detected-bout decision line (#975/#2187): the IntelligenceEngine derives a bout from raw
     * HR for metrics only. A non-overlap is `analyticsOnly`; an overlap with a real manual/imported session
     * is `droppedOverlap` or `droppedOverlapBackfilled` when missing fields were enriched. `durMin` is the
     * whole-minute bout length; on an overlap, `overlapSource` names the real row it collided with. No PII
     * (a source label + minutes + bpm only). Swift twin WorkoutsTrace.detectedBoutLine.
     */
    fun detectedBoutLine(
        verdict: String,
        durMin: Int,
        avgBpm: Int,
        overlapSource: String? = null,
    ): String {
        var line = "detectedBout verdict=$verdict durMin=$durMin avgBpm=$avgBpm"
        if (overlapSource != null) line += " overlapSource=$overlapSource"
        return line
    }
}

/**
 * Pure values for the Workouts & GPS live-readout panel. Kotlin twin of the Swift WorkoutsReadout. Parses
 * the WORKOUTS-tagged log tail the emitters write. No state, no IO, no em-dashes. (Android defers the Compose
 * readout panel for ALL modes, matching the existing split; this twin exists for parity + tests.)
 */
object WorkoutsReadout {

    /** The last session summary for the `lastSessionSummary` id: the most recent session-lifecycle line's
     *  fragment, or null when none is present. */
    fun lastSessionSummary(taggedTail: List<String>): String? {
        for (line in taggedTail.asReversed()) {
            val i = line.indexOf("session ")
            if (i >= 0) {
                val frag = line.substring(i + "session ".length).trim()
                if (frag.isNotEmpty()) return frag
            }
        }
        return null
    }
}
