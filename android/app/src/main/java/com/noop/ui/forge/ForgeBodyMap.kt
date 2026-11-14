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
import androidx.compose.foundation.background
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.ui.draw.clip
import androidx.compose.ui.unit.Dp
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.height
import androidx.compose.ui.Alignment
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

    /**
     * The figure's own width-to-height ratio (`BodyAnatomy.aspectRatio`). The renderer fits the body
     * into its box and centres it, so a box of any other shape is dead space around a smaller body.
     */
    fun aspect(context: Context, gender: String = "male"): Float {
        val box = figure(context, gender, "front")?.viewBox ?: return 0.568f
        return if (box.height > 0) box.width / box.height else 0.568f
    }

    /** The muscles this face of the body has shapes for (`BodyAnatomy.muscles`). */
    fun drawnSlugs(context: Context, gender: String, side: String): Set<String> =
        figure(context, gender, side)?.parts?.filter { it.paths.isNotEmpty() }?.map { it.slug }?.toSet().orEmpty()

    /**
     * The face that carries this exercise's work (`TrainingMusclePicture.preferredSide`), so a row that
     * shows one figure shows the one with something on it: a chin-up drawn from the front is a grey man.
     * A muscle both faces draw settles nothing and counts for neither.
     */
    fun preferredSide(context: Context, values: Map<String, Double>, gender: String = "male"): String {
        val front = drawnSlugs(context, gender, "front")
        val back = drawnSlugs(context, gender, "back")
        var f = 0.0
        var b = 0.0
        for ((id, value) in values) {
            val slug = muscle(id) ?: continue
            val onFront = slug in front
            val onBack = slug in back
            if (onFront && !onBack) f += value
            if (onBack && !onFront) b += value
        }
        return if (b > f) "back" else "front"
    }

    /**
     * Work credited to a muscle the figure has no shape for, moved up to the group it belongs to
     * (`TrainingMusclePicture.values`). The art has no upper trapezius, so a shrug lit nothing at all.
     * The involvement figures themselves are untouched; this is only what a picture can show.
     */
    fun foldToDrawn(context: Context, values: Map<String, Double>, gender: String = "male"): Map<String, Double> {
        val drawn = drawnSlugs(context, gender, "front") + drawnSlugs(context, gender, "back")
        if (drawn.isEmpty()) return values
        val out = HashMap<String, Double>()
        for ((id, value) in values) {
            val slug = muscle(id)
            var key = id
            if (slug != null && slug !in drawn) {
                val up = parent[slug]
                val parentId = if (up != null && up in drawn) trainingId(up) else null
                if (parentId != null) key = parentId
            }
            out[key] = maxOf(out[key] ?: 0.0, value)
        }
        return out
    }

    /** A figure slug back to the training muscle id it came from, for `foldToDrawn`. */
    private fun trainingId(slug: String): String? = when (slug) {
        "chest" -> "chest"
        "deltoids" -> "side_delts"
        "trapezius" -> "traps"
        "quadriceps" -> "quadriceps"
        "abs" -> "abdominals"
        "obliques" -> "obliques"
        "hamstring" -> "hamstrings"
        "gluteal" -> "glutes"
        "upper-back" -> "upper_back"
        "feet" -> null
        "head" -> null
        else -> null
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

/**
 * The small front and back figures on a routine card (`TrainingMusclePicture`, `showsBack`).
 *
 * The box has the figure's own shape rather than a wider one: the renderer fits the body inside
 * whatever it is given and centres it, so a box wider than the art drew a small body in dead space.
 */
@Composable
fun MiniMusclePreview(values: Map<String, Double>, height: Dp = 82.dp) {
    val context = LocalContext.current
    val scale = ForgeBodyStyle.scale()
    val folded = MuscleMapArt.foldToDrawn(context, values)
    val fills = MuscleMapArt.intensities(folded).mapValues { MuscleMapArt.scaleColor(scale, it.value) }
    val label = stringResource(R.string.forge_th_planned_muscles)
    val width = height * MuscleMapArt.aspect(context)
    Row(Modifier.height(height).semantics { contentDescription = label },
        horizontalArrangement = Arrangement.spacedBy(ForgeMetrics.space1)) {
        ForgeBodyMap("male", "front", fills, Modifier.size(width, height))
        ForgeBodyMap("male", "back", fills, Modifier.size(width, height))
    }
}

/**
 * The picture a row shows for one exercise: the demonstration when the media pack is there, otherwise
 * the body with the muscles it works, on a plate of the row's own shape (`TrainingExercisePicture`).
 *
 * Every list of exercises carried one of four glyphs, a dumbbell, a stopwatch, a route or a gymnast,
 * which said nothing about the exercise: a bench press and a curl looked the same.
 */
@Composable
fun ExerciseMusclePicture(exerciseId: String, primary: List<String>, secondary: List<String>,
                          side: Dp = 56.dp) {
    val context = LocalContext.current
    val still = rememberExerciseStill(exerciseId, (side.value * 3).toInt())
    val colors = Forge.colors
    Box(Modifier.size(side).clip(RoundedCornerShape(10.dp))
            .background(if (still != null) Color.White else colors.surfaceTop),
        contentAlignment = Alignment.Center) {
        if (still != null) {
            androidx.compose.foundation.Image(still, contentDescription = null, modifier = Modifier.size(side),
                contentScale = androidx.compose.ui.layout.ContentScale.Crop)
        } else {
            val values = HashMap<String, Double>()
            for (id in primary) values[id] = 1.0
            for (id in secondary) values[id] = maxOf(values[id] ?: 0.0, 0.5)
            val folded = MuscleMapArt.foldToDrawn(context, values)
            val scale = ForgeBodyStyle.scale()
            val fills = MuscleMapArt.intensities(folded).mapValues { MuscleMapArt.scaleColor(scale, it.value) }
            val figureHeight = side - ForgeMetrics.space2
            ForgeBodyMap("male", MuscleMapArt.preferredSide(context, folded), fills,
                         Modifier.size(figureHeight * MuscleMapArt.aspect(context), figureHeight))
        }
    }
}
