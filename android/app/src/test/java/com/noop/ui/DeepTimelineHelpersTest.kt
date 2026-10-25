package com.noop.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pins the pure Deep Timeline helpers (#575) shared with the macOS Repository.timelineSeries:
 * the adaptive bucket-vs-raw decision (so the chart never draws ~86k points), the in-process
 * bucketer, and the zoom/pan window math. Mirrors the Swift DeepTimelineFacadeTests pure cases.
 */
class DeepTimelineHelpersTest {

    // MARK: - Adaptive resolution

    @Test fun dayScalePicksCoarseBuckets() {
        val bucket = timelineBucketSeconds(86_400L, targetPoints = 600)
        assertTrue("a full day must downsample, not read raw seconds", bucket > 1L)
        assertTrue(bucket >= 120L)
    }

    @Test fun smallWindowPicksRawSeconds() {
        assertEquals(1L, timelineBucketSeconds(120L, 600))
        assertEquals(1L, timelineBucketSeconds(300L, 600))
        assertEquals(1L, timelineBucketSeconds(600L, 600)) // boundary: ideal == 1, still raw
    }

    @Test fun bucketSnapsToFriendlyStepAndIsMonotonic() {
        assertEquals(15L, timelineBucketSeconds(7_200L, 600)) // ideal 12 → 15
        val day = timelineBucketSeconds(86_400L, 600)
        val twoHour = timelineBucketSeconds(7_200L, 600)
        assertTrue("a wider window must not read finer than a narrower one", day >= twoHour)
    }

    // MARK: - In-process bucketer

    @Test fun downsampleMeanBinsOnGridAscending() {
        val pts = listOf(
            TimelinePoint(1_000L, 10.0),
            TimelinePoint(1_001L, 20.0), // same 60s bucket
            TimelinePoint(1_061L, 30.0), // next 60s bucket
        )
        val out = downsampleTimeline(pts, 60L)
        assertEquals(2, out.size)
        assertEquals(15.0, out[0].value, 0.001) // mean of 10,20
        assertEquals(30.0, out[1].value, 0.001)
        assertTrue(out[0].ts < out[1].ts)
    }

    // MARK: - Zoom / pan window math

    @Test fun zoomInShrinksSpanAndStaysInBounds() {
        val bounds = 0L..86_400L
        val zoomed = zoomedWindow(bounds, scale = 4f, anchorFraction = 0.5f, bounds = bounds)
        assertTrue("zoom in must shrink the window", (zoomed.last - zoomed.first) < 86_400L)
        assertTrue(zoomed.first >= bounds.first)
        assertTrue(zoomed.last <= bounds.last)
    }

    @Test fun zoomFlooredAtMinSpan() {
        val bounds = 0L..86_400L
        val zoomed = zoomedWindow(bounds, scale = 100_000f, anchorFraction = 0.5f, bounds = bounds, minSpan = 60L)
        assertTrue("must not zoom past the 60s floor", (zoomed.last - zoomed.first) >= 60L)
    }

    @Test fun panShiftsWindowAndClampsToBounds() {
        val bounds = 0L..86_400L
        val base = 0L..3_600L
        // Pan right past the end clamps so the window's end never exceeds bounds.
        val panned = pannedWindow(base, deltaSeconds = 1_000_000L, bounds = bounds)
        assertEquals(3_600L, panned.last - panned.first) // span preserved
        assertEquals(86_400L, panned.last)               // clamped to the day's end
        // Pan left past the start clamps to 0.
        val left = pannedWindow(3_000L..6_600L, deltaSeconds = -1_000_000L, bounds = bounds)
        assertEquals(0L, left.first)
    }
}
