package com.noop.ui

import com.noop.R
import android.provider.Settings
import androidx.compose.animation.core.AnimationSpec
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.composed
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalInspectionMode
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.delay

// MARK: - NoopMotion — the "Design Reset" motion set (WHOOP design language, 2026-06-22)
//
// Compose port of StrandDesign/NoopMotion.swift. The house motion language for the
// WHOOP-flavoured redesign: smooth, snappy, almost no bounce. Beauty is in the restraint —
// type, spacing and a single confident settle, NOT effects. NO glow here, nothing that
// pulses or loops. Three things screens reach for constantly:
//
//   • a refined spring set (screen / card / value)
//   • `CountUpText` — big scores/metrics tick up to their new value
//   • `Modifier.staggeredAppear(index)` — list/grid items fade + rise in, once, in sequence
//
// Every helper is public, GPU-cheap (alpha / translation / scale only), and honours Reduce
// Motion: under it, animations collapse to their final frame instantly with no offset, scale
// or counting. Android has no per-app accessibility flag equivalent to iOS
// `accessibilityReduceMotion`, so we read the system animator scale
// (`Settings.Global.ANIMATOR_DURATION_SCALE` == 0 → "Remove animations" / animations off),
// the canonical Android signal that the user has opted out of motion.

// MARK: - Reduce-motion detection (Android system signal)

/**
 * True when the user has disabled system animations (Settings → Accessibility → "Remove
 * animations", or Developer options → Animator duration scale = Off). The closest Android
 * analogue to iOS `accessibilityReduceMotion`: when on, every NOOP motion helper degrades to
 * its final frame instantly.
 *
 * Read once per composition from `Settings.Global.ANIMATOR_DURATION_SCALE`; previews
 * (inspection mode) always report `false` so design tooling shows the animated state.
 */
@Composable
fun rememberReduceMotion(): Boolean {
    if (LocalInspectionMode.current) return false
    val context = LocalContext.current
    return remember(context) {
        val scale = runCatching {
            Settings.Global.getFloat(context.contentResolver, Settings.Global.ANIMATOR_DURATION_SCALE)
        }.getOrDefault(1f)
        scale == 0f
    }
}

// MARK: - NoopMotion springs / tokens

object NoopMotion {

    // MARK: Springs — smooth, snappy, minimal bounce.
    // SwiftUI `spring(response:dampingFraction:)` maps to Compose `spring(dampingRatio, stiffness)`
    // where stiffness ≈ (2π / response)² and dampingRatio == dampingFraction.

    /** Screen-level spring — page pushes, sheet/tab swaps. response 0.46 / damping 0.88. */
    fun <T> screen(): AnimationSpec<T> =
        spring(dampingRatio = 0.88f, stiffness = stiffnessFor(0.46f))

    /** Card-level spring — card insert/remove, row reflow, expand/collapse. response 0.40 / damping 0.85. */
    fun <T> card(): AnimationSpec<T> =
        spring(dampingRatio = 0.85f, stiffness = stiffnessFor(0.40f))

    /** Value-level spring — number ticks, gauge fraction, chip/state changes. response 0.34 / damping 0.90. */
    fun <T> value(): AnimationSpec<T> =
        spring(dampingRatio = 0.90f, stiffness = stiffnessFor(0.34f))

    /** Convert a SwiftUI spring `response` (perceptual duration, seconds) to a Compose `stiffness`. */
    private fun stiffnessFor(response: Float): Float {
        val omega = (2.0 * Math.PI) / response.toDouble()
        return (omega * omega).toFloat()
    }

    // MARK: Stagger

    /** Per-item delay (ms) for a staggered list/grid reveal. Index 0 fires immediately; each
     *  subsequent item waits `index * staggerMs`. Mirrors the iOS 0.04s. */
    const val staggerMs: Int = 40

    /** The pre-reveal vertical offset (dp) for a staggered/appear item (rises UP into place). */
    val riseOffset: Dp = 8.dp

    /** Returns [spec] normally, or `null` when [reduced] (so the call site can snap instantly). */
    fun <T> gated(spec: AnimationSpec<T>, reduced: Boolean): AnimationSpec<T>? =
        if (reduced) null else spec
}

// MARK: - CountUpText
//
// Animates a numeric value counting up (or down) to its latest value whenever `value`
// changes, and on first appear (from 0 → value). Reduce Motion → final value shown instantly.

/**
 * A text view whose number animates from its previous value to the new one. Use for the big
 * scores / hero metric read-outs. Mirrors iOS `CountUpText`.
 *
 * ```
 * CountUpText(
 *     value = score,
 *     format = { "${it.roundToInt()}" },
 *     style = NoopType.display(72f),
 *     color = Palette.textPrimary,
 * )
 * ```
 *
 * @param value the number to display / animate to.
 * @param format maps the (interpolated) number to its display string — round, clamp, add units here.
 * @param style the text style (e.g. `NoopType.display(72f)`).
 * @param color the text colour (e.g. `Palette.textPrimary`).
 * @param spec the count-up curve. Defaults to `NoopMotion.value()`.
 */
@Composable
fun CountUpText(
    value: Double,
    format: (Double) -> String,
    style: TextStyle,
    color: Color,
    modifier: Modifier = Modifier,
    spec: AnimationSpec<Float> = NoopMotion.value(),
) {
    val reduced = rememberReduceMotion()

    // First composition starts the run from 0 → value (animated) or snaps (reduced); after that
    // the target tracks `value` and `animateFloatAsState` interpolates between commits.
    var target by remember { mutableStateOf(if (reduced) value.toFloat() else 0f) }
    LaunchedEffect(value, reduced) { target = value.toFloat() }

    val animated by animateFloatAsState(
        targetValue = target,
        animationSpec = if (reduced) tween(durationMillis = 0) else spec,
        label = uiString(R.string.l10n_noop_motion_countuptext_749c73fb),
    )
    val shown = if (reduced) value.toFloat() else animated

    Text(
        text = format(shown.toDouble()),
        style = style,
        color = color,
        maxLines = 1,
        modifier = modifier,
    )
}

// MARK: - Staggered appear
//
// Fade-in + 8dp rise, sequenced by `index`. Runs ONCE per element (guarded by a saved flag) so
// re-composition / scroll recycling don't re-trigger it. Reduce Motion → instant, no offset.

/**
 * Fade-in + 8dp rise on first appearance, delayed by `index * 40ms` for a sequenced list/grid
 * reveal. Runs ONCE per element. Honours Reduce Motion (appears instantly, no offset). Mirrors
 * iOS `.staggeredAppear(index:)`.
 *
 * @param index position in the sequence (0 = first / no delay).
 * @param isVisible set `false` to opt an element out (it stays fully shown).
 */
fun Modifier.staggeredAppear(index: Int, isVisible: Boolean = true): Modifier = composed {
    val reduced = rememberReduceMotion()
    // Flips true once we've appeared (or immediately under Reduce Motion). rememberSaveable so a
    // recompose / config change never replays the entrance.
    var hasAppeared by rememberSaveable { mutableStateOf(false) }

    val progress by animateFloatAsState(
        targetValue = if (!isVisible || hasAppeared || reduced) 1f else 0f,
        animationSpec = if (reduced) tween(0) else NoopMotion.card(),
        label = uiString(R.string.l10n_noop_motion_staggeredappear_7e1a3335),
    )

    LaunchedEffect(isVisible, reduced) {
        if (!isVisible || hasAppeared) return@LaunchedEffect
        if (reduced) {
            hasAppeared = true
        } else {
            delay((index.coerceAtLeast(0) * NoopMotion.staggerMs).toLong())
            hasAppeared = true
        }
    }

    val rise = with(LocalDensity.current) { NoopMotion.riseOffset.toPx() }
    this
        .alpha(if (!isVisible) 1f else progress)
        .graphicsLayer { translationY = if (!isVisible) 0f else (1f - progress) * rise }
}
