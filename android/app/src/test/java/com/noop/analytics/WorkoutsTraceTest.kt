package com.noop.analytics

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** The Workouts & GPS test mode line formatters and the live-readout parser (twin of the Swift WorkoutsTrace). */
class WorkoutsTraceTest {

    @Test fun workoutsTraceLineShapes() {
        assertEquals(
            "session event=start sport=running hrSamples=0",
            WorkoutsTrace.sessionLine(event = "start", sportKey = "running", hrSamples = 0),
        )
        assertEquals(
            "session event=end sport=running hrSamples=1200 durationSec=1260 gpsPoints=240",
            WorkoutsTrace.sessionLine(
                event = "end", sportKey = "running", hrSamples = 1200, durationSec = 1260, gpsPoints = 240,
            ),
        )
        assertEquals(
            "gps rawFixes=250 accepted=240 distanceM=5013 (filter: accuracy+speed gate)",
            WorkoutsTrace.gpsLine(rawFixes = 250, acceptedPoints = 240, distanceM = 5012.6),
        )
        assertEquals(
            "dedup sport=running kept=strap(richness=5) dropped=apple(richness=1) (same activity, richer kept)",
            WorkoutsTrace.dedupLine(
                sportKey = "running", keptSource = "strap", droppedSource = "apple",
                keptRichness = 5, droppedRichness = 1,
            ),
        )
        // #2187: the engine detected-bout decision line , analytics-only (no overlap) and dropped (overlaps a real).
        assertEquals(
            "detectedBout verdict=analyticsOnly durMin=42 avgBpm=148",
            WorkoutsTrace.detectedBoutLine(verdict = "analyticsOnly", durMin = 42, avgBpm = 148),
        )
        assertEquals(
            "detectedBout verdict=droppedOverlap durMin=42 avgBpm=148 overlapSource=manual",
            WorkoutsTrace.detectedBoutLine(
                verdict = "droppedOverlap", durMin = 42, avgBpm = 148, overlapSource = "manual",
            ),
        )
    }

    @Test fun workoutsReadoutParsesLastSession() {
        val tail = listOf(
            "[workouts] session event=start sport=running hrSamples=0",
            "[workouts] session event=end sport=running hrSamples=1200 durationSec=1260 gpsPoints=240",
        )
        assertEquals(
            "event=end sport=running hrSamples=1200 durationSec=1260 gpsPoints=240",
            WorkoutsReadout.lastSessionSummary(tail),
        )
        assertNull(WorkoutsReadout.lastSessionSummary(emptyList()))
    }
}
