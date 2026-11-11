package com.noop.ui.forge

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.tween
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.Stable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.BlurEffect
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.TileMode
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.layout.positionInWindow
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.noop.ui.CardAppearance

/**
 * A card as the iOS screens draw it (`NoopCardChrome` with iOS's quiet edges and quiet rims): an opaque raised
 * surface with no rim, resting on a soft shadow in the light appearance and on its fill alone in the dark. A
 * [glass] card (Today's hero, the tab bar) shows the scene behind it instead, blurred under the translucent [fill]
 * on Android 12 and later and nearly opaque earlier or with no scene behind it, and keeps a hairline rim, as a
 * transparent card does on iOS.
 */
@Composable
fun ForgeCard(modifier: Modifier = Modifier, radius: Dp = ForgeMetrics.cardRadius,
              fill: Color? = null, glass: Boolean = false,
              contentPadding: Dp = ForgeMetrics.cardPadding,
              content: @Composable ColumnScope.() -> Unit) {
    val colors = Forge.colors
    val shape = RoundedCornerShape(radius)
    val scene = if (glass) LocalSceneGlass.current else null
    val blur = scene != null && blurSupported
    val position = remember { mutableStateOf(Offset.Zero) }
    // "Card transparency" (`StrandCard`): the whole surface fades by the wearer's opacity, fill, rim and shadow
    // alike, while the content stays solid. A see-through card gets the hairline rim back (`NoopCardChrome`).
    // The new design (preview) draws its cards as iOS's `ForgeCardModifier`: its own glass until a transparency is
    // chosen, no rim at any transparency, and the shadow fading with the fill.
    val newDesign = ForgeDesign.preview
    val opacity = when {
        glass -> 1f
        newDesign && !CardAppearance.chosen -> NEW_DESIGN_GLASS
        else -> CardAppearance.opacity
    }
    val transparent = opacity < 1f && !newDesign
    val surface = when {
        !glass -> (fill ?: colors.surface).let { it.copy(alpha = it.alpha * opacity) }
        blur -> fill ?: colors.heroFill
        else -> (fill ?: colors.heroFill).let { it.copy(alpha = maxOf(it.alpha, 0.92f)) }
    }
    // iOS: opacity 0.06, radius 8, y 5 under an opaque card in the light appearance (`NoopCardChrome`).
    val lifted = !glass && !colors.dark && opacity > 0f
    val shadow = CARD_SHADOW.copy(alpha = CARD_SHADOW.alpha * opacity)
    val rim = when {
        glass -> colors.heroBorder
        transparent -> colors.divider.copy(alpha = colors.divider.alpha * opacity)
        else -> null
    }
    Box(modifier
            .then(if (lifted) Modifier.shadow(6.dp, shape, ambientColor = shadow, spotColor = shadow)
                  else Modifier)
            .clip(shape).onGloballyPositioned { position.value = it.positionInWindow() }) {
        if (blur && scene != null) {
            Box(Modifier.matchParentSize().graphicsLayer {
                renderEffect = BlurEffect(60f, 60f, TileMode.Clamp)
                clip = true
            }.drawBehind { with(scene) { drawScene(position.value) } })
        }
        Column(
            Modifier.fillMaxWidth().background(surface)
                .then(if (rim != null) Modifier.border(BorderStroke(ForgeMetrics.hairline, rim), shape) else Modifier)
                .padding(contentPadding),
            content = content,
        )
    }
}

private val CARD_SHADOW = Color.Black.copy(alpha = 0.06f)

/** The new design's card fill when no Card transparency was chosen (iOS `ForgeCardModifier.defaultGlassPercent`). */
private const val NEW_DESIGN_GLASS = 0.78f

/** The Charge band a score falls in (`ChargeBand.of`): below 25, 50, 70 and 88. */
enum class ChargeBand { Depleted, Low, Moderate, Primed, Peak;
    companion object {
        fun of(score: Double): ChargeBand = when {
            score < 25 -> Depleted
            score < 50 -> Low
            score < 70 -> Moderate
            score < 88 -> Primed
            else -> Peak
        }
    }
}

/** The ring colour of a Charge score: its band's stop on the recovery ramp (`chargeRingColor`). */
fun ForgeColors.chargeRing(score: Double): Color = recoveryStops[ChargeBand.of(score).ordinal].second

/** A key metric tile: icon plate, small caps label, the value with its unit. */
@Composable
fun MetricTile(icon: ImageVector, tint: Color, label: String, value: String?, unit: String?, noData: String,
               modifier: Modifier = Modifier, delta: String? = null, below: (@Composable () -> Unit)? = null) {
    val colors = Forge.colors
    val newDesignTile = ForgeDesign.preview
    ForgeCard(modifier, contentPadding = 14.dp) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            // iOS's `TodayMetricTile`: a round plate at 13 % of the tint.
            Box(Modifier.size(30.dp).background(tint.copy(alpha = 0.13f), CircleShape),
                contentAlignment = Alignment.Center) {
                Icon(icon, contentDescription = null, tint = tint, modifier = Modifier.size(16.dp))
            }
            Spacer(Modifier.width(ForgeMetrics.space2 + ForgeMetrics.space1))
            // Two lines before it gives way: a longer name ("Effort this week", German "Blutsauerstoff") reads whole
            // instead of ending in an ellipsis in a half-width tile.
            // The new design names the tile in sentence case in the text colour, as iOS's `ForgeMetricTile`; the
            // shipped design keeps its small caps.
            if (newDesignTile) Text(label, style = Forge.type.subhead.copy(fontWeight = FontWeight.SemiBold), color = colors.text,
                                    maxLines = 2, overflow = TextOverflow.Ellipsis)
            else Text(label.uppercase(), style = Forge.type.overline, color = colors.textSecondary, maxLines = 2,
                      overflow = TextOverflow.Ellipsis)
        }
        Spacer(Modifier.padding(top = ForgeMetrics.space2 + ForgeMetrics.space1))
        if (value == null) {
            // Held at the height of a value line, so a tile without data stays as tall as its neighbour.
            Box(contentAlignment = Alignment.BottomStart) {
                Text(noData, style = Forge.type.title1, color = Color.Transparent, maxLines = 1, softWrap = false,
                     modifier = Modifier.width(1.dp).clearAndSetSemantics {})
                // Two lines, so a longer quiet line ("Not synced yet") wraps in a narrow tile instead of being cut.
                Text(noData, style = Forge.type.subhead, color = colors.textTertiary, maxLines = 2,
                     overflow = TextOverflow.Ellipsis, modifier = Modifier.padding(bottom = 4.dp))
            }
        } else {
            Row(verticalAlignment = Alignment.Bottom) {
                // The value and unit give way first, shrinking together until they fit (a narrow phone, a large
                // font); the change chip always shows whole.
                val title = Forge.type.title1
                val small = Forge.type.subhead
                var scale by remember(value, unit) { mutableFloatStateOf(1f) }
                Text(
                    buildAnnotatedString {
                        withStyle(title.toSpanStyle().copy(fontSize = title.fontSize * scale, color = colors.text)) {
                            append(value)
                        }
                        if (unit != null) {
                            withStyle(small.toSpanStyle().copy(fontSize = small.fontSize * scale,
                                                               color = colors.textSecondary)) { append("\u2009" + unit) }
                        }
                    },
                    style = title, maxLines = 1, softWrap = false, modifier = Modifier.weight(1f),
                    onTextLayout = { if (it.hasVisualOverflow && scale > MIN_TILE_SCALE) scale *= 0.92f },
                )
                if (delta != null && !newDesignTile) {
                    Text(delta, style = Forge.type.captionNumber, color = colors.textSecondary, maxLines = 1,
                         softWrap = false,
                         modifier = Modifier.padding(bottom = 4.dp)
                             .background(colors.inset.copy(alpha = 0.6f), RoundedCornerShape(8.dp))
                             .padding(horizontal = 5.dp, vertical = 2.dp))
                }
            }
        }
        // In the new design the change sits under the figure on its own line, as iOS draws it, so the figure keeps
        // the tile's width in three columns.
        if (delta != null && newDesignTile && value != null) {
            Spacer(Modifier.padding(top = ForgeMetrics.space1))
            Text(delta, style = Forge.type.captionNumber, color = colors.textSecondary, maxLines = 1, softWrap = false,
                 modifier = Modifier.background(colors.inset.copy(alpha = 0.6f), RoundedCornerShape(8.dp))
                     .padding(horizontal = 6.dp, vertical = 2.dp))
        }
        if (below != null) {
            Spacer(Modifier.padding(top = ForgeMetrics.space2))
            below()
        }
    }
}

/** The smallest a tile value shrinks to before it is cut. */
private const val MIN_TILE_SCALE = 0.6f

/** Small caps section header, as the iOS screens title their sections. */
@Composable
fun SectionHeader(text: String, modifier: Modifier = Modifier) {
    // The new design heads its sections as iOS's ForgeSectionTitle: sentence case, bold, in the text colour.
    if (ForgeDesign.preview) Text(text, style = Forge.type.headline.copy(fontWeight = FontWeight.Bold), color = Forge.colors.text,
                                  modifier = modifier.fillMaxWidth().padding(horizontal = ForgeMetrics.space1))
    else Text(text.uppercase(), style = Forge.type.overline, color = Forge.colors.textSecondary,
              modifier = modifier.fillMaxWidth().padding(horizontal = ForgeMetrics.space1))
}

/**
 * Forge pages shown over the tabs (Settings, pairing), drawn in the app's own edge-to-edge window by
 * [ForgeOverlayHost] rather than in a dialog window, which kept the screen behind showing under the navigation
 * bar and drew its own status bar.
 */
@Stable
class ForgeOverlay {
    internal var page by mutableStateOf<(@Composable () -> Unit)?>(null)
    internal var dismiss: () -> Unit = {}
}

val LocalForgeOverlay = staticCompositionLocalOf { ForgeOverlay() }

/**
 * True while a page lies fully over this content (an overlay page, the new design's More page): what animates
 * every frame, as the score rings do, pauses there instead of drawing for nobody.
 */
val LocalForgeCovered = androidx.compose.runtime.compositionLocalOf { false }

/** Draws [content] and, over it, the page a [ForgeOverlayPage] has open; Back closes that page. */
@Composable
fun ForgeOverlayHost(content: @Composable () -> Unit) {
    val overlay = remember { ForgeOverlay() }
    CompositionLocalProvider(LocalForgeOverlay provides overlay) {
        Box(Modifier.fillMaxSize()) {
            // The first page slides in over the tab and the last one slides out to it, as the pages inside a
            // stack already do; the closing page keeps drawing until its exit has run.
            val current = overlay.page
            var shown by remember { mutableStateOf<(@Composable () -> Unit)?>(null) }
            val progress = remember { Animatable(0f) }
            // A page fully in covers the tabs; while it slides in or out they still show. Derived, so the content
            // sees one change at the end of the slide, not one per frame.
            val pageIn by remember { androidx.compose.runtime.derivedStateOf { overlay.page != null && progress.value >= 1f } }
            val coveredBelow = LocalForgeCovered.current
            CompositionLocalProvider(LocalForgeCovered provides (coveredBelow || pageIn)) { content() }
            LaunchedEffect(current) {
                if (current != null) {
                    shown = current
                    progress.animateTo(1f, tween(280))
                } else {
                    progress.animateTo(0f, tween(220))
                    shown = null
                }
            }
            if (current != null) BackHandler { overlay.dismiss() }
            (current ?: shown)?.let { page ->
                Box(Modifier.fillMaxSize().graphicsLayer {
                    translationX = (1f - progress.value) * size.width
                    alpha = progress.value
                }) { page() }
            }
        }
    }
}

/** Opens [content] full screen over the tabs while this is in the composition; [onDismiss] runs on Back. */
@Composable
fun ForgeOverlayPage(onDismiss: () -> Unit, content: @Composable () -> Unit) {
    val overlay = LocalForgeOverlay.current
    val page by rememberUpdatedState(content)
    val dismiss by rememberUpdatedState(onDismiss)
    DisposableEffect(overlay) {
        overlay.page = { page() }
        overlay.dismiss = { dismiss() }
        onDispose { overlay.page = null }
    }
}
