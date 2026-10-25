package com.noop.ui.forge

import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.exp
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt
import kotlin.math.sin
import kotlin.math.sqrt

/**
 * Fork (DX23876), Android plan E-3: the organic score ring's geometry, a line-for-line port of the Swift
 * `OrganicScoreVisualModel` and `OrganicScorePreparation` in StrandDesign, so a score draws the same shape, strands
 * and particle field on Android as on iOS. Pure; the Compose renderer turns it into pixels. Device motion is not
 * ported: Android draws the still pose of the motion input.
 */
enum class OrganicMetric(val baseSeed: ULong) {
    Charge(0x434841524745UL), Effort(0x4546464F5254UL), Rest(0x52455354UL)
}

/** Renderer quality; Android always draws the full step. */
object OrganicQuality {
    const val PARTICLE_BUDGET = 320
    const val FILAMENT_BUDGET = 9
    const val ECHO_LIMIT = 3
    const val CONTOUR_SAMPLES = 256
}

data class OrganicIntensity(
    val particleDensity: Double, val waveStrength: Double, val pulseStrength: Double,
    val glowStrength: Double, val smokeStrength: Double, val echoLevel: Double,
) {
    companion object {
        val quiet = OrganicIntensity(0.0, 0.0, 0.0, 0.0, 0.0, 0.0)

        private val anchors = listOf(
            0.00 to OrganicIntensity(0.02, 0.03, 0.02, 0.06, 0.02, 0.10),
            0.20 to OrganicIntensity(0.08, 0.08, 0.06, 0.14, 0.06, 0.50),
            0.50 to OrganicIntensity(0.24, 0.22, 0.18, 0.30, 0.18, 1.00),
            0.80 to OrganicIntensity(0.54, 0.48, 0.44, 0.58, 0.42, 1.60),
            0.90 to OrganicIntensity(0.72, 0.66, 0.64, 0.76, 0.62, 2.00),
            1.00 to OrganicIntensity(1.00, 1.00, 1.00, 1.00, 1.00, 3.00),
        )

        fun interpolated(value: Double): OrganicIntensity {
            val clamped = min(max(value, 0.0), 1.0)
            val upperIndex = anchors.indexOfFirst { it.first >= clamped }
            if (upperIndex < 0) return anchors.last().second
            if (upperIndex == 0) return anchors[0].second
            val (lp, lo) = anchors[upperIndex - 1]
            val (up, hi) = anchors[upperIndex]
            val span = up - lp
            val f = if (span > 0) (clamped - lp) / span else 0.0
            fun mix(a: Double, b: Double) = a + (b - a) * f
            return OrganicIntensity(mix(lo.particleDensity, hi.particleDensity), mix(lo.waveStrength, hi.waveStrength),
                                    mix(lo.pulseStrength, hi.pulseStrength), mix(lo.glowStrength, hi.glowStrength),
                                    mix(lo.smokeStrength, hi.smokeStrength), mix(lo.echoLevel, hi.echoLevel))
        }
    }
}

class OrganicScoreModel private constructor(
    val metric: OrganicMetric, val missing: Boolean, val intensity: OrganicIntensity, val seed: ULong,
    val effortLoad: Double,
) {
    val awaitsEffort: Boolean get() = metric == OrganicMetric.Effort && missing
    val bandHalfWidth: Double get() = 0.03 + intensity.glowStrength * 0.16

    fun particleUnit(index: Int, channel: Int): Double {
        val particle = index.toLong().toULong() * 0xD6E8FEB86659FD93UL
        val attribute = channel.toLong().toULong() * 0xA0761D6478BD642FUL
        return (mix(seed xor particle xor attribute) shr 11).toDouble() * (1.0 / 9_007_199_254_740_992.0)
    }

    fun particleCount(): Int {
        if (intensity.particleDensity <= 0) return 0
        val budget = OrganicQuality.PARTICLE_BUDGET
        val scaled = 8 + intensity.particleDensity * (budget - 8)
        return min(budget, max(8, scaled.roundToInt()))
    }

    fun filamentCount(): Int {
        if (intensity.waveStrength <= 0) return 1
        val scaled = 2 + intensity.glowStrength * (OrganicQuality.FILAMENT_BUDGET - 2)
        return min(OrganicQuality.FILAMENT_BUDGET, max(2, scaled.roundToInt()))
    }

    fun echoVisibilities(): List<Double> = (0 until OrganicQuality.ECHO_LIMIT).mapNotNull { i ->
        min(1.0, max(0.0, intensity.echoLevel - i)).takeIf { it > 0 }
    }

    companion object {
        const val BASE_RADIUS_FRACTION = 0.37
        const val DEFORMATION_RATIO = 0.19
        private const val QUIET_H = 0.62
        private const val QUIET_V = 0.44
        const val PARTICLE_CONTAINMENT = 0.93
        private const val EFFORT_MODERATE_START = 6.0 / 21.0
        private const val EFFORT_HIGH_START = 14.0 / 21.0

        fun effortLoad(normalized: Double): Double {
            val span = (EFFORT_HIGH_START + 0.12) - EFFORT_MODERATE_START
            val t = min(max((normalized - EFFORT_MODERATE_START) / span, 0.0), 1.0)
            return t * t * (3 - 2 * t)
        }

        fun resolve(metric: OrganicMetric, value: Double?, scaleMaximum: Double = 100.0): OrganicScoreModel {
            val seed = metric.baseSeed xor mix(0UL)
            if (value == null || !value.isFinite() || scaleMaximum <= 0) {
                return OrganicScoreModel(metric, true, OrganicIntensity.quiet, seed, 0.0)
            }
            val normalized = min(max(value / scaleMaximum, 0.0), 1.0)
            var intensity = OrganicIntensity.interpolated(normalized)
            val load = if (metric == OrganicMetric.Effort) effortLoad(normalized) else 0.0
            if (load > 0) {
                intensity = intensity.copy(pulseStrength = min(1.0, intensity.pulseStrength + load * 0.3),
                                           glowStrength = min(1.0, intensity.glowStrength + load * 0.2),
                                           smokeStrength = min(1.0, intensity.smokeStrength + load * 0.15))
            }
            return OrganicScoreModel(metric, false, intensity, seed, load)
        }

        /** SplitMix64's finaliser, as the Swift side computes it. */
        fun mix(input: ULong): ULong {
            var v = input + 0x9E3779B97F4A7C15UL
            v = (v xor (v shr 30)) * 0xBF58476D1CE4E5B9UL
            v = (v xor (v shr 27)) * 0x94D049BB133111EBUL
            return v xor (v shr 31)
        }

        fun interiorShare(density: Double) = 0.15 + min(max(density, 0.0), 1.0) * 0.45

        fun quietCentreRadius(angle: Double): Double {
            val c = cos(angle); val s = sin(angle)
            return (QUIET_H * QUIET_V) / sqrt((QUIET_V * c) * (QUIET_V * c) + (QUIET_H * s) * (QUIET_H * s))
        }
    }
}

/** One particle: offsets from the centre in units of the mean radius, size in points at a 104 pt ring. */
data class OrganicParticle(val x: Double, val y: Double, val size: Double, val alpha: Double)

/** Seed-dependent geometry prepared once per ring (`OrganicScorePreparation`). */
class OrganicPreparation(val model: OrganicScoreModel) {
    private class Swell(val width: Double, val drift: Double, val centre: Double, val frequency: Double,
                        val phase: Double, val amplitude: Double, val mean: Double, val harmonic: Double)
    private class Filament(val lag: Double, val lobes: Double, val phase: Double, val speed: Double)
    private class Particle(val angle: Double, val phase: Double, val speed: Double, val pull: Double,
                           val placement: Double, val offset: Double, val interior: Double, val frequency: Double,
                           val size: Double, val alpha: Double)

    private val tau = 2 * PI
    private val phases = (10..13).map { model.particleUnit(0, it) * tau }
    private val breathPeriod = 3.6 + model.particleUnit(0, 14) * 0.9
    private val breathPhase = model.particleUnit(0, 15) * PI * 2
    private val swells = (0 until 5).map { index ->
        fun u(c: Int) = model.particleUnit(100 + index, c)
        val width = 0.09 + u(30) * 0.10
        val area = width * sqrt(2 * PI)
        val sign = if (u(35) < 0.8) 1.0 else -1.0
        Swell(width, (u(31) - 0.5) * 0.24, u(32) * tau, 0.35 + u(33) * 0.45, u(34) * tau,
              sign * (0.18 + u(36) * 0.22), area / tau, area * exp(-width * width / 2) / PI)
    }
    private val filaments = (0 until OrganicQuality.FILAMENT_BUDGET).map { i ->
        Filament((model.particleUnit(i, 20) - 0.5) * 2.4, (6 + (model.particleUnit(i, 22) * 6).toInt()).toDouble(),
                 model.particleUnit(i, 21) * PI * 2, 0.4 + model.particleUnit(i, 23) * 0.7)
    }
    private val particles = (0 until OrganicQuality.PARTICLE_BUDGET).map { i ->
        fun u(c: Int) = model.particleUnit(i, c)
        Particle(u(0) * tau, u(1) * tau, 0.12 + u(2) * 0.22, 0.18 + u(6) * 0.22, u(7), u(3) * 2 - 1, sqrt(u(3)),
                 0.6 + u(8), if (u(9) < 0.08) 1.8 + u(4) * 0.8 else 0.5 + u(4) * 0.9, 0.35 + u(5) * 0.6)
    }

    fun frame(time: Double): Frame = Frame(time)

    inner class Frame(private val time: Double) {
        private val swell: Double
        val brightness: Double
        private val active: List<DoubleArray>   // centre, amplitude, width, mean, harmonic

        init {
            val raw = 0.5 + 0.5 * sin(time * PI * 2 / breathPeriod + breathPhase)
            val breath = raw * raw * (3 - 2 * raw)
            val pulse = model.intensity.pulseStrength
            swell = 1 - pulse * 0.18 * (1 - breath)
            brightness = 1 + pulse * (0.22 + model.effortLoad * 0.1) * (breath - 0.5) * 2
            val count = if (model.intensity.waveStrength > 0) 2 + (pulse * 3).roundToInt() else 0
            active = swells.take(count).mapNotNull { s ->
                val cycle = max(0.0, sin(time * s.frequency + s.phase))
                val amplitude = s.amplitude * cycle * cycle * (0.5 + 0.5 * pulse)
                if (amplitude == 0.0) null
                else doubleArrayOf(s.centre + time * s.drift, amplitude, s.width, s.mean, s.harmonic)
            }
        }

        fun contourRadius(angle: Double): Double {
            if (model.intensity.waveStrength <= 0) return 1.0
            val waveform = (sin(angle * 8 + phases[0] + time * 0.62)
                + sin(angle * 5 + phases[1] - time * 0.47) * 0.38
                + sin(angle * 13 + phases[2] + time * 0.36) * 0.22) / 1.60
            val localPulse = 0.72 + 0.28 * model.intensity.pulseStrength * cos(angle * 2 + phases[3] + time * 0.41)
            var total = 0.0
            for (s in active) {
                var delta = (angle - s[0]) % tau
                if (delta > PI) delta -= tau else if (delta < -PI) delta += tau
                val bump = exp(-(delta * delta) / (2 * s[2] * s[2]))
                total += s[1] * (bump - s[3] - s[4] * cos(delta))
            }
            val wave = (waveform * localPulse * swell * 0.78 + total) * model.intensity.waveStrength
            return 1 + OrganicScoreModel.DEFORMATION_RATIO * wave
        }

        fun echoRadius(index: Int, angle: Double) = contourRadius(angle) + 0.063 * (index + 1)

        fun filamentFrame(index: Int) = Frame(time + filaments[index].lag)

        fun echoFrame(index: Int) = Frame(time - (index + 1) * 0.36)

        fun filamentRadius(index: Int, count: Int, angle: Double, base: Frame): Double {
            if (count <= 1) return contourRadius(angle)
            val f = filaments[index]
            val spread = index.toDouble() / (count - 1) * 2 - 1
            val ripple = sin(angle * f.lobes + f.phase + time * f.speed) * model.bandHalfWidth * 0.55
            return base.contourRadius(angle) + spread * model.bandHalfWidth * 0.6 + ripple
        }

        fun particle(index: Int): OrganicParticle? {
            val p = particles[index]
            val angle = p.angle + sin(time * p.speed + p.phase) * (0.05 + model.intensity.pulseStrength * 0.06)
            val inner = OrganicScoreModel.quietCentreRadius(angle) + 0.03
            val contour = contourRadius(angle)
            val current = cos(time * 0.22 + p.phase * 1.7) * 0.07
            val radius = if (p.placement >= OrganicScoreModel.interiorShare(model.intensity.particleDensity)) {
                val band = model.bandHalfWidth
                val offset = (p.offset + current) * band
                max(inner, contour + min(max(offset, -band), band) * 0.98)
            } else {
                val outer = (contour - model.bandHalfWidth) * OrganicScoreModel.PARTICLE_CONTAINMENT
                if (outer <= inner + 0.02) return null
                val unit = min(max(p.interior + current, 0.0), 1.0)
                inner + unit * (outer - inner)
            }
            val twinkle = 0.65 + 0.35 * sin(time * p.frequency + p.phase * 3)
            return OrganicParticle(cos(angle) * radius, sin(angle) * radius, p.size, p.alpha * twinkle)
        }
    }
}
