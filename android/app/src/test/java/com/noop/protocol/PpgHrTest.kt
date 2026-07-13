package com.noop.protocol

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.sin
import kotlin.random.Random
import org.junit.Test

/**
 * [PpgHr] — derive HR from the WHOOP 5/MG v26 optical PPG waveform by autocorrelation (#156).
 *
 * Internal ground truth (the Swift lane's method): a clean pulse-shaped signal autocorrelates
 * strongly at its period, so a synthetic 70 bpm sine at 24 Hz must recover ~70 bpm with high
 * confidence; white noise has no periodicity, so it must yield NO estimate (conf < 0.3). These two
 * cases pin both the frequency math (60·fs/lag) and the confidence gate.
 */
class PpgHrTest {

    private val fs = PpgHr.SAMPLE_RATE_HZ // 24

    /** Build [seconds] of a [bpm] sine at the 24 Hz grid, one [PpgHr.Sample] per sample. */
    private fun sine(bpm: Double, seconds: Int, baseTs: Long = 1_000_000L): List<PpgHr.Sample> {
        val freqHz = bpm / 60.0
        val total = seconds * fs
        return (0 until total).map { i ->
            val t = i.toDouble() / fs
            // Scale to ADC-count-ish integers; DC offset removed inside estimate().
            val v = (1000.0 * sin(2.0 * PI * freqHz * t)).toInt()
            PpgHr.Sample(ts = baseTs + (i.toLong() / fs), value = v)
        }
    }

    @Test
    fun recovers70BpmFromCleanSine() {
        // 16 s so several 8 s windows slide across it.
        val est = PpgHr.estimate(sine(bpm = 70.0, seconds = 16))
        assertTrue("expected at least one estimate from a clean sine", est.isNotEmpty())
        // Every window of a pure periodic signal should land within 2 bpm of the truth.
        for (e in est) {
            assertTrue("bpm ${e.bpm} not within 70±2", e.bpm in 68..72)
            assertTrue("confidence ${e.conf} below gate", e.conf >= PpgHr.MIN_CONFIDENCE)
            assertTrue("confidence ${e.conf} > 1", e.conf <= 1.0)
        }
    }

    @Test
    fun noiseYieldsNoEstimate() {
        val rng = Random(42)
        val noise = (0 until 16 * fs).map { i ->
            PpgHr.Sample(ts = 1_000_000L + (i.toLong() / fs), value = rng.nextInt(-1000, 1000))
        }
        val est = PpgHr.estimate(noise)
        // White noise has no periodic structure → autocorrelation never clears the 0.3 gate.
        assertTrue("noise produced estimates: $est", est.isEmpty())
    }

    @Test
    fun tooFewSamplesYieldsEmpty() {
        // A run shorter than 3 consecutive seconds cannot be estimated (mirrors Swift derivePpgHr,
        // which needs run.count >= 3 and a centred window of >= 3 s / 72 samples). 2 s → nothing.
        val short = sine(bpm = 70.0, seconds = 2) // 48 samples, run of 2
        assertEquals(emptyList<PpgHr.Estimate>(), PpgHr.estimate(short))
    }

    @Test
    fun recoversFromShortThreeSecondRun() {
        // Swift parity: a 3 s run DOES produce HR (each second's centred window holds >= 3 s). The
        // old Kotlin needed a full 8 s window and wrongly returned nothing here.
        val est = PpgHr.estimate(sine(bpm = 70.0, seconds = 3))
        assertTrue("expected estimates from a 3 s run", est.isNotEmpty())
        for (e in est) assertTrue("bpm ${e.bpm} not within 70±3", e.bpm in 67..73)
    }

    @Test
    fun prefersFundamentalNotHalfRate() {
        // A clean 50 bpm sine autocorrelates strongly at the true period AND at 2× the period
        // (25 bpm). The global-argmax estimator could lock onto the stronger low-lag-energy harmonic
        // and report ~25 bpm; fundamental-period preference must report ~50 (Swift parity, #219).
        val est = PpgHr.estimate(sine(bpm = 50.0, seconds = 16))
        assertTrue("expected estimates from a clean 50 bpm sine", est.isNotEmpty())
        for (e in est) assertTrue("bpm ${e.bpm} not near 50 (harmonic leak?)", e.bpm in 47..53)
    }

    @Test
    fun flatSignalYieldsEmpty() {
        val flat = (0 until 16 * fs).map { i ->
            PpgHr.Sample(ts = 1_000_000L + (i.toLong() / fs), value = 500)
        }
        // Zero variance → zero energy → no estimate (never a divide-by-zero).
        assertTrue(PpgHr.estimate(flat).isEmpty())
    }

    @Test
    fun lowHrWithRecordRateArtifactDoesNotSnapTo60() {
        // A true ~50 bpm pulse PLUS a per-record sawtooth that resets every fs samples — the
        // record-rate artifact (#194). It autocorrelates at lag = fs (60 bpm) and is discontinuous at
        // record boundaries; without the boundary-gated notch a sleeping HR would snap to 60. Recover ~50.
        val f = 50.0 / 60.0
        val samples = ArrayList<PpgHr.Sample>()
        for (s in 0 until 10) {
            for (i in 0 until fs) {
                val pulse = 1000.0 * sin(2.0 * PI * f * (s * fs + i) / fs)
                val sawtooth = 25.0 * i // 0..575 within a record, drops at the boundary
                samples.add(PpgHr.Sample(ts = 1_000_000L + s, value = (pulse + sawtooth).toInt()))
            }
        }
        val est = PpgHr.estimate(samples)
        assertTrue("a real low-HR pulse under a record-rate artifact must still estimate", est.isNotEmpty())
        for (e in est) assertTrue("snapped to ${e.bpm} — artifact not removed", e.bpm in 46..54)
    }

    @Test
    fun true60BpmIsPreservedNotNotchedAway() {
        // A clean 60 bpm pulse is also period-fs but flows smoothly across record boundaries — the
        // boundary gate must NOT treat it as the artifact and erase it.
        val est = PpgHr.estimate(sine(bpm = 60.0, seconds = 10))
        assertTrue("true 60 bpm must not be notched away", est.isNotEmpty())
        for (e in est) assertTrue("bpm ${e.bpm} not near 60", e.bpm in 57..63)
    }

    @Test
    fun subLagInterpolationRecoversHrsThatIntegerLagQuantizes() {
        // Derived-biosignal standard (CLAUDE.md): recover MULTIPLE injected values, not one. Each true HR
        // here sits BETWEEN integer autocorrelation lags at 24 Hz (period = 1440/bpm samples), so the nearest
        // integer lag is > 2 bpm off and the default integer-lag estimator quantizes AWAY from the truth,
        // while the opt-in parabolic sub-lag interpolation (Variant A) refines the ACF peak and recovers it
        // within ±2 bpm. Twin of the Swift PpgHrTests case. (Exact-integer-lag rates 120/160/180 are avoided.)
        for (trueBpm in listOf(137.0, 150.0, 163.0, 170.0)) {
            val samples = sine(bpm = trueBpm, seconds = 16)

            // Default OFF = byte-identical to today: integer-lag quantization, never within ±2 of the truth.
            val off = PpgHr.estimate(samples)
            assertTrue("expected estimates from a clean $trueBpm bpm sine", off.isNotEmpty())
            for (e in off) {
                assertTrue(
                    "default path should quantize away from $trueBpm (got ${e.bpm})",
                    abs(e.bpm - trueBpm) > 2,
                )
            }

            // Variant ON: parabolic sub-lag interpolation lands within ±2 bpm of the true rate.
            val on = PpgHr.estimate(samples, subLagInterp = true)
            assertTrue("expected estimates with the variant on for $trueBpm", on.isNotEmpty())
            for (e in on) {
                assertTrue(
                    "sub-lag interp should recover $trueBpm±2 (got ${e.bpm})",
                    abs(e.bpm - trueBpm) <= 2,
                )
                assertTrue("confidence ${e.conf} below gate", e.conf >= PpgHr.MIN_CONFIDENCE)
            }
        }
    }
}
