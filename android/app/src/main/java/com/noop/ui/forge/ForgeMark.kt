package com.noop.ui.forge

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.size
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.drawscope.Fill
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.text.font.FontWeight

/** The NOOP Forge "F", the same three polygons as the Swift `ForgeMark` in its 400 by 410 design box. */
@Composable
fun ForgeMark(height: Dp, modifier: Modifier = Modifier) {
    val colors = Forge.colors
    val ember = Color(if (colors.dark) ForgeTokens.StrandPalette.forgeEmber.dark else ForgeTokens.StrandPalette.forgeEmber.light)
    val ink = Forge.sceneInk.text
    Canvas(modifier.size(width = height * (400f / 410f), height = height)) {
        val sx = size.width / 400f
        val sy = size.height / 410f
        fun poly(points: List<Pair<Float, Float>>) = Path().apply {
            points.forEachIndexed { i, (x, y) -> if (i == 0) moveTo(x * sx, y * sy) else lineTo(x * sx, y * sy) }
            close()
        }
        drawPath(poly(UPPER), ink, style = Fill)
        drawPath(poly(LOWER), ink, style = Fill)
        drawPath(poly(ARM), ember, style = Fill)
    }
}

private val UPPER = listOf(152f to 0f, 400f to 0f, 330f to 100f, 150f to 100f, 0f to 275f, 0f to 152f)
private val LOWER = listOf(124f to 160f, 350f to 160f, 280f to 262f, 127f to 262f, 0f to 410f, 0f to 305f)
private val ARM = listOf(210f to 160f, 350f to 160f, 280f to 262f, 123f to 262f)

/** The header wordmark: the letters of NOOP spaced apart, then the Forge "F", as the iOS Today header shows it. */
@Composable
fun ForgeWordmark(modifier: Modifier = Modifier) {
    val colors = Forge.colors
    Row(modifier.semantics(mergeDescendants = true) { contentDescription = BRAND },
        horizontalArrangement = Arrangement.spacedBy(13.dp), verticalAlignment = Alignment.CenterVertically) {
        BRAND_LETTERS.forEach { ch ->
            Text(ch.toString(), style = Forge.type.title2.copy(fontSize = 17.sp, fontWeight = FontWeight.Bold),
                 color = Forge.sceneInk.text.copy(alpha = 0.9f))
        }
        ForgeMark(14.dp)
    }
}

/** The brand name is not translated. */
private const val BRAND = "NOOP Forge"
private const val BRAND_LETTERS = "NOOP"
