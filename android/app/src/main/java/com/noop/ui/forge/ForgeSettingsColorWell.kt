package com.noop.ui.forge

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.gestures.drag
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.dp
import com.noop.ui.AccentColor
import kotlin.math.roundToInt

/** The colour at a hue, saturation and brightness, through the framework converter (Material 3 has no HSV helper). */
private fun hsv(h: Float, s: Float, v: Float): Color =
    Color(android.graphics.Color.HSVToColor(floatArrayOf(h.coerceIn(0f, 360f), s.coerceIn(0f, 1f), v.coerceIn(0f, 1f))))

/**
 * The colour well under "Custom colour", the counterpart of the SwiftUI `ColorPicker` iOS shows when the accent is
 * Custom: a square for saturation and brightness over a rail for the hue. [onHexChange] gets `#RRGGBB` on every move,
 * and the accent follows it live.
 */
@Composable
internal fun ForgeColorWell(hex: String, onHexChange: (String) -> Unit) {
    // Seeded from the stored colour once: the well only exists while Custom is the chosen accent.
    val seed = remember {
        FloatArray(3).also {
            val c = AccentColor.parseHex(hex, Color(0xFF149A78))
            android.graphics.Color.RGBToHSV((c.red * 255).roundToInt(), (c.green * 255).roundToInt(), (c.blue * 255).roundToInt(), it)
        }
    }
    var hue by remember { mutableFloatStateOf(seed[0]) }
    var sat by remember { mutableFloatStateOf(seed[1]) }
    var value by remember { mutableFloatStateOf(seed[2]) }
    fun emit() {
        val c = hsv(hue, sat, value)
        onHexChange(String.format("#%02X%02X%02X", (c.red * 255).roundToInt(), (c.green * 255).roundToInt(), (c.blue * 255).roundToInt()))
    }
    val density = LocalDensity.current
    val colors = Forge.colors
    val ring = colors.surface
    Column(Modifier.fillMaxWidth().padding(vertical = ForgeMetrics.space2), verticalArrangement = Arrangement.spacedBy(ForgeMetrics.space3)) {
        BoxWithConstraints(Modifier.fillMaxWidth().height(150.dp).clip(RoundedCornerShape(12.dp))
            .border(ForgeMetrics.hairline, colors.border, RoundedCornerShape(12.dp))) {
            val widthPx = constraints.maxWidth.toFloat()
            val heightPx = constraints.maxHeight.toFloat()
            Box(Modifier.matchParentSize()
                .background(Brush.horizontalGradient(listOf(Color.White, hsv(hue, 1f, 1f))))
                .background(Brush.verticalGradient(listOf(Color.Transparent, Color.Black)))
                .pointerInput(Unit) {
                    awaitEachGesture {
                        // The first touch is taken so the scrolling page cannot steal a drag inside the square.
                        val down = awaitFirstDown().also { it.consume() }
                        fun move(x: Float, y: Float) {
                            sat = (x / widthPx).coerceIn(0f, 1f)
                            value = (1f - y / heightPx).coerceIn(0f, 1f)
                            emit()
                        }
                        move(down.position.x, down.position.y)
                        drag(down.id) { move(it.position.x, it.position.y); it.consume() }
                    }
                })
            Box(Modifier
                .offset(x = with(density) { (sat * widthPx).toDp() } - 9.dp, y = with(density) { ((1f - value) * heightPx).toDp() } - 9.dp)
                .size(18.dp).clip(CircleShape).background(hsv(hue, sat, value)).border(2.dp, ring, CircleShape))
        }
        BoxWithConstraints(Modifier.fillMaxWidth().height(22.dp).clip(RoundedCornerShape(50))) {
            val widthPx = constraints.maxWidth.toFloat()
            Box(Modifier.matchParentSize()
                .background(Brush.horizontalGradient((0..6).map { hsv(it * 60f, 1f, 1f) }))
                .pointerInput(Unit) {
                    awaitEachGesture {
                        val down = awaitFirstDown().also { it.consume() }
                        fun move(x: Float) {
                            hue = (x / widthPx).coerceIn(0f, 1f) * 360f
                            emit()
                        }
                        move(down.position.x)
                        drag(down.id) { move(it.position.x); it.consume() }
                    }
                })
            Box(Modifier.offset(x = with(density) { ((hue / 360f) * widthPx).toDp() } - 11.dp)
                .size(22.dp).clip(CircleShape).background(hsv(hue, 1f, 1f)).border(2.dp, ring, CircleShape))
        }
    }
}
