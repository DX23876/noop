package com.noop.ui.forge

import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.ui.graphics.drawscope.clipRect
import androidx.compose.ui.graphics.lerp
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.dp
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
import android.content.Context
import com.noop.R
import com.noop.ui.BackgroundImageBackdrop
import com.noop.ui.BackgroundImageStore
import com.noop.ui.CardAppearance
import com.noop.ui.NoopPrefs
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
 * The scene as cards see it: the same image and wash the backdrop draws over its top [sceneHeight], so a card can
 * paint the part of the scene that lies behind it, blurred, which is what iOS glass shows. [origin] and [size] are
 * the backdrop's window position and size, kept current by the backdrop.
 */
@Stable
class SceneGlass(val painter: Painter, val wash: Array<Pair<Float, Color>>, val sceneHeight: Float) {
    var origin by mutableStateOf(Offset.Zero)
    var size by mutableStateOf(IntSize.Zero)

    /** Draws the scene into a box at window position [at], cropped and top-aligned as the backdrop draws it. */
    fun DrawScope.drawScene(at: Offset) {
        val w = size.width.toFloat(); val h = sceneHeight
        if (w <= 0f || h <= 0f) return
        val img = painter.intrinsicSize
        val scale = maxOf(w / img.width, h / img.height)
        val dw = img.width * scale; val dh = img.height * scale
        translate(origin.x - at.x, origin.y - at.y) {
            clipRect(0f, 0f, w, h) {
                translate((w - dw) / 2, 0f) { with(painter) { draw(Size(dw, dh)) } }
            }
            drawRect(Brush.verticalGradient(*wash, startY = 0f, endY = h), size = Size(w, h))
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
 * What a screen draws behind its content, as the iOS screens do: [Scene] is Today's day-cycle scene at the top,
 * fading into the canvas over [SCENE_HEIGHT] (`SceneScreenBackground`); [Night] is the Sleep tab's night band with a
 * dark wash for its heading (`sleepNightTopBackground`); [Sky] is the quiet time-of-day gradient the other tabs show
 * at the top (`LiquidSkyStatic` under `liquidScaffoldSky`).
 */
enum class ForgeBackdrop { Scene, Night, Sky }

/** How far down the screen Today's scene reaches before it has faded into the canvas. */
val SCENE_HEIGHT = 600.dp

/** How far the scene reaches with "Sky behind cards" on (`SceneScreenBackground(height: 1100)` in `LiquidScaffoldSky`). */
val SCENE_BEHIND_CARDS_HEIGHT = 1100.dp

/**
 * The Appearance choices behind every Forge screen, the same keys the classic screens and iOS read: the time-of-day
 * sky (`noop.showDayCycleBackground`) and "Sky behind cards" (`noop.skyBehindCards`). Held as state so a switch in
 * Settings repaints the open screens at once; [load] re-reads them after the classic Settings may have changed them.
 */
object ForgeBackground {
    var dayCycle by mutableStateOf(true)
        private set
    var behindCards by mutableStateOf(true)
        private set

    fun load(context: Context) {
        dayCycle = NoopPrefs.showDayCycleBackground(context)
        behindCards = NoopPrefs.skyBehindCards(context)
        CardAppearance.init(context)
    }

    fun setDayCycle(context: Context, on: Boolean) { NoopPrefs.setShowDayCycleBackground(context, on); dayCycle = on }
    fun setBehindCards(context: Context, on: Boolean) { NoopPrefs.setSkyBehindCards(context, on); behindCards = on }
    fun setCardOpacity(context: Context, percent: Int) {
        NoopPrefs.setCardOpacityPercent(context, percent)
        CardAppearance.opacity = (percent.coerceIn(0, 100) / 100f)
    }
}
private val NIGHT_HEIGHT = 440.dp
private val SKY_HEIGHT = 240.dp

/**
 * How much of the canvas lies over the scene at a point down [SCENE_HEIGHT]: the iOS mask (opaque, 0.9 at 0.34,
 * 0.4 at 0.62, gone at 0.92) at 95 % opacity, written as a canvas wash so a glass card can draw the same picture.
 * The top 22 % carries the iOS whisper of canvas for the header as well.
 */
internal val SCENE_WASH_STOPS: List<Pair<Float, Float>> = listOf(
    0.00f to 0.05f + 0.12f, 0.22f to 0.05f, 0.34f to 0.145f, 0.62f to 0.62f, 0.92f to 1f, 1f to 1f,
)

/**
 * The backdrop behind [content] for [kind], with the ink for text drawn straight on it and the status bar icons that
 * read over it. On Today the scene sits behind the hero only; Sleep's heading always sits on the night band.
 */
@Composable
fun ForgeSceneBackdrop(kind: ForgeBackdrop, modifier: Modifier = Modifier, content: @Composable BoxScope.() -> Unit) {
    val colors = Forge.colors
    val hour = remember { Calendar.getInstance().get(Calendar.HOUR_OF_DAY) }
    val density = LocalDensity.current
    val painter = painterResource(if (kind == ForgeBackdrop.Night) R.drawable.forge_alps1 else DayCycleScene.drawable(hour))
    // The precedence of `LiquidScaffoldSky`: a custom image first, then the scene behind every card ("Sky behind
    // cards" with the time-of-day sky on), then each tab's own band; with the sky off only the plain canvas.
    val image = BackgroundImageStore.isActive
    val fullScene = !image && ForgeBackground.dayCycle && ForgeBackground.behindCards
    val plain = !image && !ForgeBackground.dayCycle
    val sceneHeight = if (fullScene) SCENE_BEHIND_CARDS_HEIGHT else SCENE_HEIGHT
    val sceneHeightPx = with(density) { sceneHeight.toPx() }
    val washStops = remember(colors.canvas) {
        SCENE_WASH_STOPS.map { (at, alpha) -> at to colors.canvas.copy(alpha = alpha) }.toTypedArray()
    }
    val glass = remember(painter, washStops, sceneHeightPx) { SceneGlass(painter, washStops, sceneHeightPx) }
    // Dusk, night and first light are dark scenes: the header on Today takes the on-dark ink even in the light
    // appearance (`DayCycleScene.isDark`, as `ScreenScaffold` does on iOS); the night band is dark at every hour.
    val sceneDark = when {
        image || plain -> colors.dark
        kind == ForgeBackdrop.Night -> true
        kind == ForgeBackdrop.Scene || fullScene -> colors.dark || DayCycleScene.isDark(hour)
        else -> colors.dark
    }
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
        when {
            image -> BackgroundImageBackdrop(Modifier.matchParentSize())
            plain -> Unit
            fullScene -> Box(Modifier.fillMaxWidth().height(SCENE_BEHIND_CARDS_HEIGHT)) {
                Image(painter, contentDescription = null, contentScale = ContentScale.Crop,
                      alignment = Alignment.TopCenter, modifier = Modifier.matchParentSize())
                Box(Modifier.matchParentSize().background(Brush.verticalGradient(*washStops)))
                if (kind == ForgeBackdrop.Night) {
                    Box(Modifier.fillMaxWidth().height(250.dp).background(Brush.verticalGradient(
                        listOf(Color.Black.copy(alpha = 0.5f), Color.Black.copy(alpha = 0.18f), Color.Transparent))))
                }
            }
            kind == ForgeBackdrop.Scene -> Box(Modifier.fillMaxWidth().height(SCENE_HEIGHT)) {
                Image(painter, contentDescription = null, contentScale = ContentScale.Crop,
                      alignment = Alignment.TopCenter, modifier = Modifier.matchParentSize())
                Box(Modifier.matchParentSize().background(Brush.verticalGradient(*washStops)))
            }
            kind == ForgeBackdrop.Night -> Box(Modifier.fillMaxWidth().height(NIGHT_HEIGHT)) {
                Image(painter, contentDescription = null, contentScale = ContentScale.Crop,
                      alignment = Alignment.TopCenter, modifier = Modifier.matchParentSize())
                // A fixed protection wash keeps the on-dark heading readable over every frame of the artwork.
                Box(Modifier.fillMaxWidth().height(250.dp).background(Brush.verticalGradient(
                    listOf(Color.Black.copy(alpha = 0.5f), Color.Black.copy(alpha = 0.18f), Color.Transparent))))
            }
            else -> {
                val sky = LiquidSky.at(hour + Calendar.getInstance().get(Calendar.MINUTE) / 60.0, light = !colors.dark)
                Box(Modifier.fillMaxWidth().height(SKY_HEIGHT).background(Brush.verticalGradient(
                    0f to sky.top, 0.45f to sky.mid, 0.9f to sky.horizon, 1f to sky.horizon)))
                Box(Modifier.fillMaxWidth().height(SKY_HEIGHT).background(Brush.verticalGradient(
                    0f to Color.Transparent, 0.45f to Color.Transparent, 1f to LiquidSky.settle(!colors.dark))))
            }
        }
        // Glass shows the scene behind it wherever the scene is drawn; over a photo or the plain canvas it stays frosted.
        CompositionLocalProvider(LocalSceneGlass provides glass.takeIf { !image && !plain && (kind == ForgeBackdrop.Scene || fullScene) },
                                 LocalSceneInk provides ink) { content() }
    }
}

/**
 * The time-of-day sky of the iOS scaffold (`liquidSkyAt` in `LiquidSky.swift`): ten keyframes per appearance,
 * interpolated by the hour, and the colour it settles into at the bottom.
 */
object LiquidSky {
    data class Stop(val h: Double, val top: Long, val mid: Long, val hor: Long)
    data class Sky(val top: Color, val mid: Color, val horizon: Color)

    private val dark = listOf(
        Stop(0.0, 0x191A1F, 0x1D1E23, 0x22242B), Stop(5.0, 0x1A1B20, 0x1D1F24, 0x23252C),
        Stop(6.5, 0x1B1C21, 0x1F2026, 0x25272E), Stop(8.5, 0x1C1D22, 0x202229, 0x272A31),
        Stop(11.0, 0x1D1E23, 0x21232A, 0x292C33), Stop(14.0, 0x1D1E23, 0x22242B, 0x292C34),
        Stop(17.5, 0x1C1D22, 0x202229, 0x272930), Stop(19.5, 0x1B1C21, 0x1F2026, 0x24262D),
        Stop(22.0, 0x191A1F, 0x1D1E23, 0x22242B), Stop(24.0, 0x191A1F, 0x1D1E23, 0x22242B),
    )
    private val light = listOf(
        Stop(0.0, 0xDCE3ED, 0xE5EAF1, 0xEEF1F5), Stop(5.0, 0xDDE5EE, 0xE7EBF1, 0xEFF2F5),
        Stop(6.5, 0xE1E8EF, 0xE9EDF2, 0xF0F2F5), Stop(8.5, 0xE3EBF1, 0xEAF0F3, 0xF1F3F5),
        Stop(11.0, 0xE1EAF0, 0xE9EEF2, 0xF1F3F5), Stop(14.0, 0xDFE8EF, 0xE8EDF2, 0xF0F2F5),
        Stop(17.5, 0xE1E7ED, 0xE8ECF1, 0xEFF1F4), Stop(19.5, 0xDDE4EC, 0xE6EAF0, 0xEEF1F4),
        Stop(22.0, 0xDAE2EC, 0xE4E9F0, 0xEDF0F4), Stop(24.0, 0xDCE3ED, 0xE5EAF1, 0xEEF1F5),
    )

    fun at(hour: Double, light: Boolean): Sky {
        val keys = if (light) this.light else dark
        var i = 0
        while (i < keys.size - 2 && keys[i + 1].h <= hour) i++
        val a = keys[i]; val b = keys[i + 1]
        val t = ((hour - a.h) / (b.h - a.h)).coerceIn(0.0, 1.0).toFloat()
        return Sky(mix(a.top, b.top, t), mix(a.mid, b.mid, t), mix(a.hor, b.hor, t))
    }

    /** The colour the sky settles into at its foot (`LiquidSkyStatic.settle`). */
    fun settle(light: Boolean): Color = if (light) Color(0xFFF2F2F7) else Color(0xFF1D1E23)

    private fun mix(a: Long, b: Long, t: Float): Color =
        lerp(Color(0xFF000000 or a), Color(0xFF000000 or b), t)
}
