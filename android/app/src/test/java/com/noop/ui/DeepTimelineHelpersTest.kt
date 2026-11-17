package com.noop.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
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

    // MARK: - Annotation scoping (#979 parity)
    //
    // Case-for-case twins of the Swift OverviewHRChartAnnotationTests, down to the epoch numbers, so the
    // Deep Timeline on both platforms bands the same night and keeps the same glyphs. The window is one
    // day: 86 400 s from t = 100 000 (an arbitrary epoch , only the relative positions matter).

    private val day = 100_000L..186_400L

    private fun workout(start: Long, end: Long) = TimelineWorkoutSpan(start, end, "running")

    /** The LONGEST overlapping block wins, exactly like the classic Today: a 7h night beats a 40m nap. */
    @Test fun mainSleepPicksLongestOverlappingBlock() {
        val night = 95_000L..120_200L     // 25 200 s = 7h, straddles the day start
        val nap = 150_000L..152_400L      // 2 400 s afternoon nap
        assertEquals(night, mainSleepSpan(listOf(nap, night), day))
    }

    /** A night that merely STRADDLES the window edge still counts , overlap, not containment. */
    @Test fun mainSleepKeepsStraddlingNight() {
        assertEquals(80_000L..110_000L, mainSleepSpan(listOf(80_000L..110_000L), day))
    }

    /** Blocks entirely OUTSIDE the window never band it , including exact edge-touching ones, which
     *  contribute zero visible band. */
    @Test fun mainSleepDropsNonOverlappingAndEdgeTouching() {
        val candidates = listOf(
            10_000L..50_000L,     // before
            90_000L..100_000L,    // ends exactly at the window start → zero band
            186_400L..190_000L,   // starts exactly at the window end → zero band
            200_000L..220_000L,   // after
        )
        assertNull(mainSleepSpan(candidates, day))
    }

    /** No candidates → no band, never a fabricated one. */
    @Test fun mainSleepEmptyIsNull() {
        assertNull(mainSleepSpan(emptyList(), day))
    }

    /** Overlapping workouts keep their supplied order; disjoint ones are dropped. */
    @Test fun workoutsKeepsOverlappingInOrder() {
        val morning = workout(110_000L, 113_600L)
        val evening = workout(170_000L, 173_600L)
        val lastWeek = workout(10_000L, 13_600L)
        val kept = workoutSpansOverlapping(listOf(morning, lastWeek, evening), day)
        assertEquals(listOf(morning.start, evening.start), kept.map { it.start })
    }

    /** Edge-TOUCHING workouts are kept (inclusive both sides, mirroring Today's workout filter , a
     *  session ending exactly at midnight still belongs to the day it filled). */
    @Test fun workoutsKeepsEdgeTouching() {
        val kept = workoutSpansOverlapping(
            listOf(workout(96_400L, 100_000L), workout(186_400L, 190_000L)),
            day,
        )
        assertEquals(2, kept.size)
    }

    /** A workout spanning the WHOLE window (an ultra, a long hike) is kept. */
    @Test fun workoutsKeepsWindowSpanning() {
        assertEquals(1, workoutSpansOverlapping(listOf(workout(90_000L, 200_000L)), day).size)
    }

    @Test fun workoutsEmptyIsEmpty() {
        assertTrue(workoutSpansOverlapping(emptyList(), day).isEmpty())
    }
}
