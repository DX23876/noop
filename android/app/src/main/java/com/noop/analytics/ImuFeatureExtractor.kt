package com.noop.analytics

import com.noop.protocol.RawImuSample
import com.noop.protocol.Whoop5ImuFrame
import kotlin.math.roundToInt
import kotlin.math.sqrt

// ImuFeatureExtractor.kt — activity features from decoded WHOOP 5/MG raw 6-axis IMU (#423). Kotlin twin
// of StrandAnalytics/ImuFeatureExtractor.swift (parity contract).
//
// The 5/MG offload buffer decodes (Whoop5RawImu) to 100 Hz 3-axis accel (g) + 3-axis gyro (deg/s). At
// 100 Hz the accelerometer resolves gait cadence, impact/jerk, and rotational energy the 1 Hz gravity
// vector physically cannot (a 1.8 Hz step rate is above the 1 Hz stream's Nyquist limit). This turns a
// window of raw samples into a compact activity-feature vector for coarse sport / HAR classification.
//
// Per the repo's derived-signal rule: cadence here is an autocorrelation peak on the accel-magnitude AC
// over a genuinely high-rate stream (not a fixed-N-per-record buffer), reported with its own strength so
// a caller can ignore a weak/absent peak; it is a FEATURE, never fed to a physiological gate. Validated
// to recover MULTIPLE injected cadences, not one lucky match (see ImuFeatureExtractorTest).

/** Compact activity features over a window of raw IMU samples. */
data class ImuActivityFeatures(
    /** RMS of the accel-magnitude AC (gravity removed), in g — overall movement intensity. */
    val accelEnergyG: Double,
    /** Mean gyroscope magnitude over the window, in deg/s — rotational intensity. */
    val gyroEnergyDps: Double,
    /** RMS of the accel first-difference (jerk), in g/sample — impact / explosiveness. */
    val jerkRms: Double,
    /** Dominant cadence in the gait band, Hz — null when no rhythmic peak clears [minCadenceStrength].
     *  Multiply by 60 for steps/min. */
    val cadenceHz: Double?,
    /** Normalized strength (0..1) of that cadence peak — high = rhythmic, low = bursty or still. */
    val cadenceStrength: Double,
    val sampleCount: Int,
)

object ImuFeatureExtractor {

    /** Cadence search band, Hz — human gait/pedal foot rate (~72-210 steps/min). Below the IMU Nyquist. */
    val cadenceBand: ClosedFloatingPointRange<Double> = 1.2..3.5

    /** A cadence peak below this normalized autocorrelation strength is treated as "no rhythm" (→ null Hz). */
    const val minCadenceStrength = 0.20

    /** Extract features from [samples] (from one or more [Whoop5ImuFrame]s, in order) at [sampleRateHz]. */
    fun extract(samples: List<RawImuSample>, sampleRateHz: Int): ImuActivityFeatures {
        val n = samples.size
        if (n < 8 || sampleRateHz <= 0) {
            return ImuActivityFeatures(0.0, 0.0, 0.0, null, 0.0, n)
        }
        val amag = samples.map { sqrt(it.ax * it.ax + it.ay * it.ay + it.az * it.az) }
        val gmag = samples.map { sqrt(it.gx * it.gx + it.gy * it.gy + it.gz * it.gz) }

        val gyroEnergy = gmag.sum() / n
        // Accel AC: remove the DC (~gravity) then RMS.
        val mean = amag.sum() / n
        val ac = amag.map { it - mean }
        val accelEnergy = sqrt(ac.sumOf { it * it } / n)
        // Jerk: RMS of |accel| first difference.
        var jerkSq = 0.0
        for (i in 1 until n) { val d = amag[i] - amag[i - 1]; jerkSq += d * d }
        val jerk = sqrt(jerkSq / (n - 1))

        // Cadence: normalized autocorrelation of the AC series over the gait-band lags; the strongest
        // peak's frequency + strength. Strength = peak ACF / zero-lag ACF (0..1), so it's amplitude-scale
        // free (a faint but rhythmic walk and a hard one both read as rhythmic).
        val ac0 = ac.sumOf { it * it }
        var bestFreq: Double? = null
        var bestStrength = 0.0
        if (ac0 > 0) {
            val loLag = maxOf(1, (sampleRateHz / cadenceBand.endInclusive).roundToInt())
            val hiLag = minOf(n - 1, (sampleRateHz / cadenceBand.start).roundToInt())
            if (loLag < hiLag) {
                for (lag in loLag..hiLag) {
                    var s = 0.0
                    for (i in 0 until (n - lag)) s += ac[i] * ac[i + lag]
                    val strength = s / ac0
                    if (strength > bestStrength) {
                        bestStrength = strength
                        bestFreq = sampleRateHz.toDouble() / lag.toDouble()
                    }
                }
            }
        }
        val cadence = if (bestStrength >= minCadenceStrength) bestFreq else null
        return ImuActivityFeatures(
            accelEnergyG = accelEnergy, gyroEnergyDps = gyroEnergy, jerkRms = jerk,
            cadenceHz = cadence, cadenceStrength = maxOf(0.0, bestStrength), sampleCount = n,
        )
    }

    /** Convenience: extract over the concatenated samples of decoded IMU frames. */
    fun extract(frames: List<Whoop5ImuFrame>): ImuActivityFeatures {
        val rate = frames.firstOrNull()?.sampleRateHz ?: 100
        return extract(frames.flatMap { it.samples }, rate)
    }
}
