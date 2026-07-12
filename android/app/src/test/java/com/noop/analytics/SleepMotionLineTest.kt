package com.noop.analytics

import com.noop.protocol.DeviceFamily
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * #319 diagnostic: [AnalyticsEngine.sleepMotionLine] exposes the motion-coverage + staging context behind a
 * Rest score in the Sleep & Rest test-mode export. Pins the exact wire string as the byte-parity reference
 * for the Swift twin `AnalyticsEngine.sleepMotionLine` (StrandAnalytics), tested identically in swift-packages.
 */
class SleepMotionLineTest {

    @Test
    fun `sparse WHOOP4 night on V1`() {
        assertEquals(
            "sleep-motion day=2026-07-12 grav=118 hr=590 sparse=true stager=V1 family=whoop4",
            RestScorer.sleepMotionLine(
                day = "2026-07-12", grav = 118, hr = 590, sparse = true,
                useSleepStagerV2 = false, family = DeviceFamily.WHOOP4))
    }

    @Test
    fun `dense 5MG night on V2`() {
        assertEquals(
            "sleep-motion day=2026-07-12 grav=800 hr=590 sparse=false stager=V2 family=whoop5",
            RestScorer.sleepMotionLine(
                day = "2026-07-12", grav = 800, hr = 590, sparse = false,
                useSleepStagerV2 = true, family = DeviceFamily.WHOOP5))
    }
}
