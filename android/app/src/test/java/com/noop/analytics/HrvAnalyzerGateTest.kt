package com.noop.analytics

import com.noop.data.RrInterval
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * #585 — the spot honesty gate ([HrvAnalyzer.analyzeRaw]'s optional `maxRejectedFraction`).
 *
 * Swift parity twin of the gate tests in `StrandAnalytics/Tests/.../HRVAnalyzerTests.swift`. Two
 * guarantees:
 *  1. a spot reading is REFUSED when too large a fraction of input beats was rejected as noise, even
 *     though >= MIN_BEATS clean intervals survive;
 *  2. the NIGHTLY windowed `analyze(...)` passes NO ceiling, so it is byte-identical to the un-gated
 *     raw analysis on the same beats — overnight HRV must not move.
 */
class HrvAnalyzerGateTest {

    @Test
    fun spotGateRefusesWhenTooManyBeatsRejected() {
        // 40 input: 24 valid 800 ms + 16 out-of-range 100 ms (dropped by the range filter).
        // 24 clean survive (>= MIN_BEATS 20), but 16/40 = 0.40 rejected > 0.35 gate -> refused (empty).
        val rr = List(24) { 800.0 } + List(16) { 100.0 }
        val gated = HrvAnalyzer.analyzeRaw(rr, maxRejectedFraction = 0.35)
        assertNull("0.40 rejected > 0.35 gate must refuse the spot reading", gated.rmssd)
        assertNull(gated.sdnn)
        assertEquals(40, gated.nInput)
        assertEquals(0, gated.nClean)

        // SAME beats with NO gate (null) still produce a value — 24 clean >= MIN_BEATS.
        val ungated = HrvAnalyzer.analyzeRaw(rr)
        assertEquals(24, ungated.nClean)
        assertEquals(0.0, ungated.rmssd!!, 1e-9)   // all-800 survivors -> no successive diffs
    }

    @Test
    fun spotGateAllowsWhenRejectionUnderCeiling() {
        // 40 input: 30 valid 800 ms + 10 out-of-range -> 10/40 = 0.25 rejected < 0.35 gate -> allowed.
        val rr = List(30) { 800.0 } + List(10) { 100.0 }
        val gated = HrvAnalyzer.analyzeRaw(rr, maxRejectedFraction = 0.35)
        assertEquals(30, gated.nClean)
        assertEquals(0.0, gated.rmssd!!, 1e-9)
    }

    @Test
    fun nightlyWindowedRmssdUnchangedWithDefaultedGate() {
        // The nightly windowed analyze(...) passes NO maxRejectedFraction, so the gate is skipped and the
        // result is byte-identical to analyzeRaw(...) on the same beats — even when the series WOULD trip
        // a spot gate (here 0.40 rejected). Overnight HRV must not move (#585).
        val rr = (0 until 24).map { RrInterval(deviceId = "d", ts = (1000 + it).toLong(), rrMs = 800) } +
            (0 until 16).map { RrInterval(deviceId = "d", ts = (1100 + it).toLong(), rrMs = 100) }
        val windowed = HrvAnalyzer.analyze(rr, windowStart = 1000L, windowEnd = 2000L)
        // The spot gate WOULD refuse this (0.40 > 0.35); the nightly path must NOT.
        assertEquals(24, windowed.nClean)
        assertNotNull(windowed.rmssd)
        val raw = HrvAnalyzer.analyzeRaw(rr.map { it.rrMs.toDouble() })
        assertEquals(raw.rmssd!!, windowed.rmssd!!, 1e-12)
        assertEquals(raw.sdnn ?: Double.NaN, windowed.sdnn ?: Double.NaN, 1e-12)
        assertEquals(raw.nClean, windowed.nClean)
    }
}
