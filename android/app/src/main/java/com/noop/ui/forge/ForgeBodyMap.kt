package com.noop.ui.forge

import android.content.Context
import android.graphics.Region
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.size
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.asAndroidPath
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.withTransform
import androidx.compose.ui.graphics.lerp
import androidx.compose.ui.graphics.vector.PathParser
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import com.noop.R
import org.json.JSONObject

/**
 * Fork (DX23876), Android parity plan 2.3: the muscle figure the iOS Training screens draw with the MuscleMap package
 * (MIT, Melih Colpan; `MuscleMap.BodyView` with `.heatmap` and `.showSubGroups()`). The outlines are the package's
 * own, copied into `assets/musclemap/body.json` by `Tools/musclemap_android_asset.py`; the fill rules follow
 * `BodyRenderer.resolveFill` and the colour ramp `HeatmapColorScale` with linear interpolation, which is what
 * `.heatmap` applies whatever curve the scale names.
 */
object MuscleMapArt {
    class Part(val slug: String, val paths: List<Path>)
    class Figure(val viewBox: Rect, val parts: List<Part>)

    @Volatile private var figures: Map<String, Figure>? = null

    /** The figure for `male`/`female` and `front`/`back`; empty when the asset cannot be read. */
    fun figure(context: Context, gender: String, side: String): Figure? {
        val loaded = figures ?: synchronized(this) {
            figures ?: load(context).also { figures = it }
        }
        return loaded["$gender/$side"]
    }

    private fun load(context: Context): Map<String, Figure> = runCatching {
        val doc = JSONObject(context.assets.open("musclemap/body.json").bufferedReader().use { it.readText() })
        val out = HashMap<String, Figure>()
        for (gender in listOf("male", "female")) for (side in listOf("front", "back")) {
            val o = doc.getJSONObject(gender).getJSONObject(side)
            val box = o.getJSONArray("viewBox")
            val parts = o.getJSONArray("parts")
            out["$gender/$side"] = Figure(
                Rect(box.getDouble(0).toFloat(), box.getDouble(1).toFloat(),
                     (box.getDouble(0) + box.getDouble(2)).toFloat(), (box.getDouble(1) + box.getDouble(3)).toFloat()),
                (0 until parts.length()).map { i ->
                    val p = parts.getJSONObject(i)
                    val strings = listOf("common", "left", "right").flatMap { key ->
                        p.optJSONArray(key)?.let { a -> (0 until a.length()).map(a::getString) }.orEmpty()
                    }
                    Part(p.getString("slug"), strings.map { PathParser().parsePathString(it).toPath() })
                })
        }
        out
    }.getOrDefault(emptyMap())

    /** A sub-group's parent (`Muscle.parentGroup`): an unshaded sub-group takes its parent's colour. */
    val parent = mapOf(
        "upper-chest" to "chest", "lower-chest" to "chest",
        "inner-quad" to "quadriceps", "outer-quad" to "quadriceps", "hip-flexors" to "quadriceps",
        "upper-abs" to "abs", "lower-abs" to "abs",
        "front-deltoid" to "deltoids", "rear-deltoid" to "deltoids",
        "upper-trapezius" to "trapezius", "lower-trapezius" to "trapezius",
        "serratus" to "obliques", "ankles" to "feet", "adductors" to "hamstring", "neck" to "head",
    )

    /** A training muscle id to the figure's muscle (`TrainingMuscleMapAppearance.muscle`). */
    fun muscle(id: String): String? = when (id) {
        "chest" -> "chest"
        "upper_chest" -> "upper-chest"
        "lower_chest" -> "lower-chest"
        "serratus" -> "serratus"
        "front_delts" -> "front-deltoid"
        "side_delts" -> "deltoids"
        "rear_delts" -> "rear-deltoid"
        "rotator_cuff" -> "rotator-cuff"
        "triceps" -> "triceps"
        "biceps" -> "biceps"
        "forearms" -> "forearm"
        "lats", "upper_back" -> "upper-back"
        "rhomboids" -> "rhomboids"
        "traps" -> "trapezius"
        "upper_traps" -> "upper-trapezius"
        "lower_traps" -> "lower-trapezius"
        "lower_back" -> "lower-back"
        "abdominals" -> "abs"
        "upper_abs" -> "upper-abs"
        "lower_abs" -> "lower-abs"
        "obliques" -> "obliques"
        "quadriceps" -> "quadriceps"
        "inner_quadriceps" -> "inner-quad"
        "outer_quadriceps" -> "outer-quad"
        "hamstrings" -> "hamstring"
        "glutes", "abductors" -> "gluteal"
        "hip_flexors" -> "hip-flexors"
        "adductors" -> "adductors"
        "calves" -> "calves"
        "tibialis" -> "tibialis"
        "neck" -> "neck"
        else -> null
    }

    /** The training muscle ids drawn as one figure muscle (`TrainingMuscleMapAppearance.ids(for:)`). */
    fun ids(slug: String, all: Collection<String>): List<String> = all.filter { muscle(it) == slug }

    /** Values relative to their largest, merged per figure muscle (`TrainingMuscleMapAppearance.intensities`). */
    fun intensities(values: Map<String, Double>): Map<String, Double> {
        val maximum = maxOf(0.01, values.values.maxOrNull() ?: 0.01)
        val merged = HashMap<String, Double>()
        for ((key, value) in values) {
            val m = muscle(key) ?: continue
            merged[m] = maxOf(merged[m] ?: 0.0, (value / maximum).coerceIn(0.0, 1.0))
        }
        return merged
    }

    /** Values already on 0…1, clamped and merged (`TrainingMuscleMapAppearance.boundedIntensities`). */
    fun boundedIntensities(values: Map<String, Double>): Map<String, Double> {
        val merged = HashMap<String, Double>()
        for ((key, value) in values) {
            val m = muscle(key) ?: continue
            merged[m] = maxOf(merged[m] ?: 0.0, value.coerceIn(0.0, 1.0))
        }
        return merged
    }

    /** `HeatmapColorScale.color(for:)` with linear interpolation between neighbouring stops. */
    fun scaleColor(colors: List<Color>, intensity: Double): Color {
        if (colors.isEmpty()) return Color.Gray
        if (colors.size == 1) return colors[0]
        val scaled = intensity.coerceIn(0.0, 1.0) * (colors.size - 1)
        val lower = scaled.toInt()
        val upper = minOf(lower + 1, colors.size - 1)
        val fraction = scaled - lower
        if (fraction < 0.01) return colors[lower]
        return lerp(colors[lower], colors[upper], fraction.toFloat())
    }
}

/** The colours of the Training figures (`TrainingMuscleMapAppearance`). */
object ForgeBodyStyle {
    @Composable fun hairline() = Forge.colors.border
    @Composable fun scale() = listOf(Forge.colors.border, ForgeTokens.StrandPalette.metricCyan.resolve(),
                                     Forge.colors.accent, ForgeTokens.StrandPalette.effortColor.resolve())
    @Composable fun fatigueScale() = listOf(Forge.colors.border, ForgeTokens.StrandPalette.statusWarning.resolve(),
                                            ForgeTokens.StrandPalette.effortColor.resolve())
}

/**
 * One side of the figure, centred in its box at the artwork's aspect, each muscle filled from [fills] (figure muscle
 * slug to colour); [onTap] gets the tapped muscle, sub-groups winning over their parents as on iOS.
 */
@Composable
fun ForgeBodyMap(gender: String, side: String, fills: Map<String, Color>, modifier: Modifier = Modifier,
                 description: String? = null, onTap: ((String) -> Unit)? = null) {
    val context = LocalContext.current
    val figure = remember(gender, side) { MuscleMapArt.figure(context, gender, side) } ?: return
    val hairline = Forge.colors.border
    val defaultFill = hairline.copy(alpha = hairline.alpha * 0.65f)
    val headColor = hairline.copy(alpha = hairline.alpha * 0.75f)
    val stroke = Forge.colors.textTertiary.copy(alpha = 0.22f)
    val hairColor = Forge.colors.textTertiary.copy(alpha = 0.45f)
    fun fill(slug: String): Color = when (slug) {
        "hair" -> hairColor
        "head" -> headColor
        else -> fills[slug] ?: MuscleMapArt.parent[slug]?.let { fills[it] } ?: defaultFill
    }
    val box = figure.viewBox
    Canvas(modifier
        .then(if (description != null) Modifier.semantics { contentDescription = description } else Modifier)
        .then(if (onTap == null) Modifier else Modifier.pointerInput(figure) {
            detectTapGestures { offset ->
                val scale = minOf(size.width / box.width, size.height / box.height)
                val x = (offset.x - (size.width - box.width * scale) / 2) / scale + box.left
                val y = (offset.y - (size.height - box.height * scale) / 2) / scale + box.top
                hit(figure, x, y)?.let(onTap)
            }
        })) {
        val scale = minOf(size.width / box.width, size.height / box.height)
        val dx = (size.width - box.width * scale) / 2 - box.left * scale
        val dy = (size.height - box.height * scale) / 2 - box.top * scale
        withTransform({ translate(dx, dy); scale(scale, scale, Offset.Zero) }) {
            val line = Stroke(width = 0.5.dp.toPx() / scale)
            for (part in figure.parts) {
                val color = fill(part.slug)
                for (path in part.paths) {
                    drawPath(path, color)
                    drawPath(path, stroke, style = line)
                }
            }
        }
    }
}

/** The muscle under a point in artwork coordinates: sub-groups first, then the rest in drawing order. */
private fun hit(figure: MuscleMapArt.Figure, x: Float, y: Float): String? {
    val ordered = figure.parts.filter { it.slug in MuscleMapArt.parent } + figure.parts.filterNot { it.slug in MuscleMapArt.parent }
    for (part in ordered) {
        if (part.slug == "hair" || part.slug == "head") continue
        for (path in part.paths) {
            val android = path.asAndroidPath()
            val bounds = android.computeBoundsCompat()
            if (!bounds.contains(x.toInt(), y.toInt())) continue
            val region = Region().apply { setPath(android, Region(bounds)) }
            if (region.contains(x.toInt(), y.toInt())) return part.slug
        }
    }
    return null
}

private fun android.graphics.Path.computeBoundsCompat(): android.graphics.Rect {
    val r = android.graphics.RectF()
    @Suppress("DEPRECATION") computeBounds(r, true)
    return android.graphics.Rect(r.left.toInt() - 1, r.top.toInt() - 1, r.right.toInt() + 1, r.bottom.toInt() + 1)
}

/** The small front and back figures on a routine card (`TrainingMiniMusclePreview`). */
@Composable
fun MiniMusclePreview(values: Map<String, Double>) {
    val scale = ForgeBodyStyle.scale()
    val fills = MuscleMapArt.intensities(values).mapValues { MuscleMapArt.scaleColor(scale, it.value) }
    val label = stringResource(R.string.forge_th_planned_muscles)
    Row(Modifier.size(72.dp, 82.dp).semantics { contentDescription = label },
        horizontalArrangement = Arrangement.spacedBy(2.dp)) {
        ForgeBodyMap("male", "front", fills, Modifier.weight(1f).size(35.dp, 82.dp))
        ForgeBodyMap("male", "back", fills, Modifier.weight(1f).size(35.dp, 82.dp))
    }
}
