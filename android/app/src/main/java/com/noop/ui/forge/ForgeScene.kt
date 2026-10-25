package com.noop.ui.forge

import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.fillMaxSize
import android.app.Activity
import android.os.Build
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.Immutable
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.Stable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.translate
import androidx.compose.ui.graphics.painter.Painter
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.layout.positionInWindow
import androidx.compose.ui.platform.LocalView
import androidx.core.view.WindowCompat
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.res.painterResource
import com.noop.R
import java.util.Calendar

/**
 * Fork (DX23876), Android plan E-3: the day-cycle scene behind the Forge screens, the Alps set the iOS app shows
 * by default (`SceneMotif.alps`), picked by the local hour with the same ten slots as `DayCycleScene`.
 */
object DayCycleScene {
    /** The slot 1...10 for an hour; the same table as the Swift `DayCycleScene.slot(hour:)`. */
    fun slot(hour: Int): Int = when (((hour % 24) + 24) % 24) {
        in 0..4 -> 1
        5 -> 2
        6 -> 3
        7 -> 6
        8, 9 -> 7
        10, 11 -> 8
        in 12..16 -> 10
        17, 18 -> 9
        19, 20 -> 5
        else -> 4
    }

    /** Dusk, night and first light: text drawn straight on the scene needs the on-dark ink. */
    fun isDark(hour: Int): Boolean {
        val h = ((hour % 24) + 24) % 24
        return h <= 5 || h >= 19
    }

    private val alps = intArrayOf(
        R.drawable.forge_alps1, R.drawable.forge_alps2, R.drawable.forge_alps3, R.drawable.forge_alps4,
        R.drawable.forge_alps5, R.drawable.forge_alps6, R.drawable.forge_alps7, R.drawable.forge_alps8,
        R.drawable.forge_alps9, R.drawable.forge_alps10,
    )

    fun drawable(hour: Int): Int = alps[slot(hour) - 1]
}

/**
 * The scene as cards see it: the same image and wash the backdrop draws, so a card can paint the part of the scene
 * that lies behind it, blurred, which is what iOS glass shows. [origin] and [size] are the backdrop's window
 * position and size, kept current by the backdrop.
 */
@Stable
class SceneGlass(val painter: Painter, val wash: List<Color>) {
    var origin by mutableStateOf(Offset.Zero)
    var size by mutableStateOf(IntSize.Zero)

    /** Draws the scene into a box at window position [at], cropped and top-aligned as the backdrop draws it. */
    fun DrawScope.drawScene(at: Offset) {
        val w = size.width.toFloat(); val h = size.height.toFloat()
        if (w <= 0f || h <= 0f) return
        val img = painter.intrinsicSize
        val scale = maxOf(w / img.width, h / img.height)
        val dw = img.width * scale; val dh = img.height * scale
        translate(origin.x - at.x + (w - dw) / 2, origin.y - at.y) {
            with(painter) { draw(Size(dw, dh)) }
        }
        translate(origin.x - at.x, origin.y - at.y) {
            drawRect(Brush.verticalGradient(wash, startY = 0f, endY = h), size = Size(w, h))
        }
    }
}

val LocalSceneGlass = staticCompositionLocalOf<SceneGlass?> { null }

/** The ink for text drawn straight on the scene, not on a card. */
@Immutable
data class SceneInk(val text: Color, val secondary: Color, val tertiary: Color, val dark: Boolean)

val LocalSceneInk = staticCompositionLocalOf<SceneInk?> { null }

/** Whether this Android draws real blur (RenderEffect, Android 12 and later). */
val blurSupported: Boolean get() = Build.VERSION.SDK_INT >= Build.VERSION_CODES.S

/**
 * The scene full-bleed behind [content], top-aligned so the sky shows, with a wash of the canvas colour that
 * deepens downwards so cards and text further down stay legible; in dark mode the whole scene is dimmed.
 */
@Composable
fun ForgeSceneBackdrop(modifier: Modifier = Modifier, content: @Composable BoxScope.() -> Unit) {
    val colors = Forge.colors
    val hour = remember { Calendar.getInstance().get(Calendar.HOUR_OF_DAY) }
    val painter = painterResource(DayCycleScene.drawable(hour))
    // Dusk, night and first light are dark scenes: text drawn straight on them takes the on-dark ink even in the
    // light appearance (`DayCycleScene.isDark`, as on iOS), and so do the status bar icons. The wash darkens such a
    // scene in the light appearance too, so the on-dark ink stays legible further down the screen.
    val sceneDark = colors.dark || DayCycleScene.isDark(hour)
    val wash = when {
        colors.dark -> listOf(colors.canvas.copy(alpha = 0.35f), colors.canvas.copy(alpha = 0.6f), colors.canvas.copy(alpha = 0.9f))
        sceneDark -> forgeColors(dark = true).canvas.let {
            listOf(it.copy(alpha = 0.15f), it.copy(alpha = 0.4f), it.copy(alpha = 0.7f))
        }
        else -> listOf(colors.canvas.copy(alpha = 0f), colors.canvas.copy(alpha = 0.25f), colors.canvas.copy(alpha = 0.75f))
    }
    val glass = remember(painter, wash) { SceneGlass(painter, wash) }
    val ink = if (sceneDark && !colors.dark) SceneInk(colors.onDark, colors.onDarkSecondary, colors.onDarkTertiary, true)
              else SceneInk(colors.text, colors.textSecondary, colors.textTertiary, sceneDark)
    val view = LocalView.current
    SideEffect {
        (view.context as? Activity)?.window?.let { window ->
            WindowCompat.getInsetsController(window, view).isAppearanceLightStatusBars = !sceneDark
        }
    }
    Box(modifier.fillMaxSize().background(colors.canvas).onGloballyPositioned {
        glass.origin = it.positionInWindow(); glass.size = it.size
    }) {
        Image(
            painter = painter,
            contentDescription = null,
            contentScale = ContentScale.Crop,
            alignment = Alignment.TopCenter,
            modifier = Modifier.matchParentSize(),
        )
        Box(Modifier.matchParentSize().background(Brush.verticalGradient(wash)))
        CompositionLocalProvider(LocalSceneGlass provides glass, LocalSceneInk provides ink) { content() }
    }
}
