package com.noop.ui.forge

import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.snap
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.requiredSize
import androidx.compose.foundation.layout.requiredWidth
import androidx.compose.foundation.layout.size
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableDoubleStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.withFrameNanos
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.BlendMode
import androidx.compose.ui.graphics.BlurEffect
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.Shadow
import androidx.compose.ui.graphics.TileMode
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.lerp
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.Dp
import com.noop.ui.rememberPoseStill
import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.min
import kotlin.math.sin

/** The canvas reaches past the ring's square so echoes and smoke fade out instead of being cut. */
private const val OVERSCAN = 1.3f

private val unitCircle: List<Pair<Float, Float>> = (0 until OrganicQuality.CONTOUR_SAMPLES).map {
    val a = it.toDouble() / OrganicQuality.CONTOUR_SAMPLES * 2 * PI
    cos(a).toFloat() to sin(a).toFloat()
}
private val sampleAngles = DoubleArray(OrganicQuality.CONTOUR_SAMPLES) { it.toDouble() / OrganicQuality.CONTOUR_SAMPLES * 2 * PI }

/** One frame of one ring: every path and particle the layers draw, computed once and shared by them. */
private class RingFrame(val primary: Path, val echoes: List<Pair<Path, Double>>, val strands: List<Pair<Path, Double>>,
                        val particles: List<OrganicParticle>, val brightness: Double)

private class RingCache(val preparation: OrganicPreparation) {
    private var key: Triple<Double, Float, Float>? = null
    private var frame: RingFrame? = null

    fun at(time: Double, size: Size): RingFrame {
        val k = Triple(time, size.width, size.height)
        frame?.let { if (key == k) return it }
        val model = preparation.model
        val centre = Offset(size.width / 2, size.height / 2)
        val radius = min(size.width, size.height) / OVERSCAN * OrganicScoreModel.BASE_RADIUS_FRACTION.toFloat()
        fun closed(radiusAt: (Double) -> Double) = Path().apply {
            for (i in sampleAngles.indices) {
                val r = radius * radiusAt(sampleAngles[i]).toFloat()
                val (c, s) = unitCircle[i]
                if (i == 0) moveTo(centre.x + c * r, centre.y + s * r) else lineTo(centre.x + c * r, centre.y + s * r)
            }
            close()
        }
        val geometry = preparation.frame(time)
        val primary = closed(geometry::contourRadius)
        val echoes = model.echoVisibilities().mapIndexed { index, visibility ->
            val g = geometry.echoFrame(index)
            closed { g.echoRadius(index, it) } to visibility
        }
        val count = model.filamentCount()
        val strands = (0 until count).map { index ->
            val base = geometry.filamentFrame(index)
            val path = if (count == 1) primary else closed { geometry.filamentRadius(index, count, it, base) }
            val middle = if (count == 1) 1.0 else 1 - abs(index.toDouble() / (count - 1) * 2 - 1)
            path to middle
        }
        val particles = (0 until model.particleCount()).mapNotNull(geometry::particle)
        return RingFrame(primary, echoes, strands, particles, geometry.brightness).also { key = k; frame = it }
    }
}

/**
 * The organic score ring, drawn as the iOS `OrganicScoreRing` draws it: an inner atmosphere, a blurred bloom of the
 * whole band, echo contours, drifting smoke, a haze filling the band, fine strands weaving across it, a particle
 * field with haloed sparkles and a bright core line. Line widths and blur radii are the iOS values in points, read
 * as dp. Blur needs Android 12 or later; earlier versions draw the soft layers unblurred and fainter. Battery saver
 * and reduced motion pose the ring still, as on iOS.
 */
@Composable
fun OrganicRing(score: Double?, tint: Color, diameter: Dp, metric: OrganicMetric, modifier: Modifier = Modifier,
                onScene: Boolean = false) {
    val colors = Forge.colors
    // On a card the card's appearance decides; straight on the scene (the Sleep ring) the scene's does.
    val sceneInk = Forge.sceneInk
    val onLight = if (onScene) !sceneInk.dark else !colors.dark
    val model = remember(metric, score == null, score) { OrganicScoreModel.resolve(metric, score) }
    val cache = remember(model) { RingCache(OrganicPreparation(model)) }
    val color = if (model.missing && !model.awaitsEffort) colors.missing else tint
    val still = rememberPoseStill()
    val clock = remember { mutableDoubleStateOf(0.0) }
    if (!still) {
        LaunchedEffect(Unit) {
            val start = withFrameNanos { it }
            while (true) withFrameNanos { clock.doubleValue = (it - start) / 1e9 }
        }
    }
    val glow = model.intensity.glowStrength
    val smoke = model.intensity.smokeStrength
    val density = LocalDensity.current
    fun Float.pt() = this * density.density
    // `breathe` is read inside the draw lambdas so only the drawing repeats each frame, never composition.
    fun breathe(f: RingFrame) = if (still) 1.0 else f.brightness
    fun blurred(radiusPt: Float) = Modifier.requiredSize(diameter * OVERSCAN).graphicsLayer {
        if (blurSupported) renderEffect = BlurEffect(radiusPt.pt(), radiusPt.pt(), TileMode.Decal)
    }
    // Without blur the soft layers would read as hard bands, so they draw fainter there.
    val soft = if (blurSupported) 1f else 0.45f

    Box(modifier.size(diameter), contentAlignment = Alignment.Center) {
        if (model.awaitsEffort) {
            Canvas(blurred(5f)) {
                val f = cache.at(clock.doubleValue, size)
                drawPath(f.primary, color.copy(alpha = (if (onLight) 0.06f else 0.08f) * soft), style = Stroke(3f.pt()))
            }
            Canvas(Modifier.requiredSize(diameter * OVERSCAN)) {
                val f = cache.at(clock.doubleValue, size)
                drawPath(f.primary, color.copy(alpha = if (onLight) 0.22f else 0.25f), style = Stroke(1f.pt()))
            }
        } else {
            // Inner atmosphere.
            Canvas(Modifier.requiredSize(diameter * OVERSCAN)) {
                val radius = min(size.width, size.height) / OVERSCAN * OrganicScoreModel.BASE_RADIUS_FRACTION.toFloat()
                val g = (0.05 + glow * 0.16).toFloat()
                drawCircle(Brush.radialGradient(0f to Color.Transparent, 0.55f to color.copy(alpha = g * 0.25f),
                                                0.92f to color.copy(alpha = g), 1f to Color.Transparent,
                                                center = center, radius = radius), radius = radius, center = center)
            }
            // Bloom: the whole band, thick and blurred, behind everything else.
            if (!model.missing) Canvas(blurred((5 + glow * 9).toFloat())) {
                val f = cache.at(clock.doubleValue, size)
                val b = breathe(f)
                val radius = min(size.width, size.height) / OVERSCAN * OrganicScoreModel.BASE_RADIUS_FRACTION.toFloat()
                val band = (model.bandHalfWidth * radius).toFloat()
                val alpha = min(1.0, ((if (onLight) 0.22 else 0.35) + glow * 0.4) * b).toFloat() * soft
                drawPath(f.primary, color.copy(alpha = alpha),
                         style = Stroke((band * 2.6f + 4f.pt()) * (0.9f + 0.1f * b.toFloat())))
            }
            // Echoes, then smoke, then the haze that fills the band.
            Canvas(Modifier.requiredSize(diameter * OVERSCAN)) {
                val f = cache.at(clock.doubleValue, size)
                f.echoes.forEachIndexed { i, (path, visibility) ->
                    drawPath(path, color.copy(alpha = ((0.16 - i * 0.03) * visibility).toFloat()), style = Stroke(0.9f.pt()))
                }
            }
            if (smoke > 0) Canvas(blurred((3 + smoke * 4).toFloat())) {
                val f = cache.at(clock.doubleValue, size)
                val radius = min(size.width, size.height) / OVERSCAN * OrganicScoreModel.BASE_RADIUS_FRACTION.toFloat()
                val band = (model.bandHalfWidth * radius).toFloat()
                drawPath(f.primary, color.copy(alpha = ((if (onLight) 0.10 else 0.16) + smoke * 0.2).toFloat() * soft),
                         style = Stroke(band * 1.6f + 3f.pt()))
            }
            if (!model.missing) Canvas(blurred((1.5 + glow * 2.5).toFloat())) {
                val f = cache.at(clock.doubleValue, size)
                val radius = min(size.width, size.height) / OVERSCAN * OrganicScoreModel.BASE_RADIUS_FRACTION.toFloat()
                val band = (model.bandHalfWidth * radius).toFloat()
                val alpha = min(1.0, ((if (onLight) 0.18 else 0.22) + glow * 0.3) * breathe(f)).toFloat() * soft
                drawPath(f.primary, color.copy(alpha = alpha), style = Stroke(band * 2))
            }
            // The band itself, the particle field and the core line, crisp. On dark the light adds up, as iOS
            // draws it with plusLighter; on the light card it blends normally so it does not wash out to white.
            Canvas(Modifier.requiredSize(diameter * OVERSCAN)) {
                val f = cache.at(clock.doubleValue, size)
                val blend = if (onLight) BlendMode.SrcOver else BlendMode.Plus
                f.strands.forEach { (path, middle) ->
                    val alpha = if (model.missing) 0.5 else (0.28 + 0.5 * middle) * (0.55 + glow * 0.45)
                    drawPath(path, color.copy(alpha = alpha.toFloat()),
                             style = Stroke(if (model.missing) 1.15f.pt() else (0.7f + middle.toFloat() * 0.8f).pt()),
                             blendMode = blend)
                }
                drawParticles(f, color, onLight, blend, density.density)
                if (!model.missing && !onLight) {
                    drawPath(f.primary, Color.White.copy(alpha = (0.18 + glow * 0.35).toFloat()), style = Stroke(0.6f.pt()))
                }
            }
        }
        ScoreNumber(score, diameter, still, onLight)
    }
}

private fun DrawScope.drawParticles(f: RingFrame, tint: Color, onLight: Boolean, blend: BlendMode, pt: Float) {
    val side = min(size.width, size.height) / OVERSCAN
    val radius = side * OrganicScoreModel.BASE_RADIUS_FRACTION.toFloat()
    val particleScale = side / (104f * pt)
    val core = if (onLight) tint else lerp(tint, Color.White, 0.55f)
    for (p in f.particles) {
        val s = (p.size * particleScale).toFloat() * pt
        val point = Offset(center.x + (p.x * radius).toFloat(), center.y + (p.y * radius).toFloat())
        if (p.size * particleScale > 1.7) {
            drawCircle(tint.copy(alpha = (p.alpha * 0.25).toFloat()), radius = s * 2.6f / 2, center = point,
                       blendMode = blend)
        }
        drawCircle(core.copy(alpha = min(1.0, p.alpha * (if (onLight) 1.0 else 1.25)).toFloat()), radius = s / 2,
                   center = point, blendMode = blend)
    }
}

/** The score in the middle: counts up to a new value, dark ink with a paper halo on light, a shadow on dark. */
@Composable
private fun ScoreNumber(score: Double?, diameter: Dp, still: Boolean, onLight: Boolean) {
    val colors = Forge.colors
    val shown by animateFloatAsState(
        targetValue = (score ?: 0.0).toFloat(),
        animationSpec = if (still) snap() else tween(950, easing = FastOutSlowInEasing), label = "score",
    )
    val size = with(LocalDensity.current) { (diameter * 0.27f).toSp() }
    val shadow = if (!onLight) Shadow(Color.Black.copy(alpha = 0.72f), Offset(0f, 2f), 8f)
                 else Shadow(Color.White.copy(alpha = 0.85f), Offset.Zero, 6f)
    Text(if (score == null) DASH else "%.0f".format(shown),
         style = Forge.type.heroNumber.copy(fontSize = size, shadow = shadow), textAlign = TextAlign.Center,
         color = if (!onLight) colors.onDark else colors.text, maxLines = 1,
         modifier = Modifier.requiredWidth(diameter * 0.62f))
}

/** A missing score shows a dash, never a zero. */
private const val DASH = "–"
