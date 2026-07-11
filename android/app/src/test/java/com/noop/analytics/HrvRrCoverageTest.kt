package com.noop.analytics

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * #257 — the R-R integrity diagnostics ([HrvAnalyzer.rrCoverage] / [HrvAnalyzer.duplicateBeatCount])
 * that surface a heartbeat OVER-COUNT (the "HRV reads ~2x too high" class of bug) in the always-on
 * `hrv diag` log. Byte-parity twin of `HRVAnalyzerTests` on the Swift side.
 */
class HrvRrCoverageTest {

    @Test fun coverage_cleanStreamIsNearOne() {
        // 5 beats of 1000 ms spanning ts 100..104 (4 s wall clock). sum=5000 ms, span=4000 ms → 1.25.
        val cov = HrvAnalyzer.rrCoverage(
            listOf(100L, 101L, 102L, 103L, 104L),
            listOf(1000.0, 1000.0, 1000.0, 1000.0, 1000.0),
        )
        assertEquals(1.25, cov, 1e-9)
    }

    @Test fun coverage_doubleCountedBeatsExceedsOne() {
        // Each beat stored TWICE at the same second (the #257 over-count): sum=6000 ms over a 2 s span → 3.0.
        val cov = HrvAnalyzer.rrCoverage(
            listOf(100L, 100L, 101L, 101L, 102L, 102L),
            listOf(1000.0, 1000.0, 1000.0, 1000.0, 1000.0, 1000.0),
        )
        assertEquals(3.0, cov, 1e-9)
    }

    @Test fun coverage_zeroForTooFewBeatsOrZeroSpan() {
        assertEquals(0.0, HrvAnalyzer.rrCoverage(emptyList(), emptyList()), 1e-9)
        assertEquals(0.0, HrvAnalyzer.rrCoverage(listOf(100L), listOf(1000.0)), 1e-9)
        assertEquals(0.0, HrvAnalyzer.rrCoverage(listOf(100L, 100L), listOf(1000.0, 1000.0)), 1e-9) // span 0
    }

    @Test fun duplicateBeats_zeroWhenAllDistinct() {
        assertEquals(0, HrvAnalyzer.duplicateBeatCount(listOf(100L, 101L, 102L), listOf(1000.0, 1010.0, 1020.0)))
    }

    @Test fun duplicateBeats_countsExactRepeats() {
        // (100,1000) appears twice → 1 extra copy; (101,1010) distinct.
        assertEquals(1, HrvAnalyzer.duplicateBeatCount(listOf(100L, 100L, 101L), listOf(1000.0, 1000.0, 1010.0)))
        // three identical beats → 2 extra copies.
        assertEquals(2, HrvAnalyzer.duplicateBeatCount(listOf(100L, 100L, 100L), listOf(1000.0, 1000.0, 1000.0)))
        // same ts but DIFFERENT rrMs are distinct beats, not duplicates.
        assertEquals(0, HrvAnalyzer.duplicateBeatCount(listOf(100L, 100L), listOf(1000.0, 1010.0)))
    }
}
