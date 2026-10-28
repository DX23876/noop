package com.noop.ui.forge

import com.noop.ui.AppearancePrefs
import com.noop.ui.AppearanceMode
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Typography
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.Immutable
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.ExperimentalTextApi
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.Font
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontVariation
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.noop.R
import com.noop.ui.forge.ForgeTokens.NoopVisualStyle as Chrome
import com.noop.ui.forge.ForgeTokens.StrandPalette as P

/**
 * Fork (DX23876), Android plan E-3: the colours and type of the Forge screens, resolved from [ForgeTokens] (the
 * Apple design system) for the light or the dark appearance. Screens read [Forge.colors] and [Forge.type]; no
 * colour or size is written in a screen.
 */
@Immutable
data class ForgeColors(
    val dark: Boolean,
    val canvas: Color, val surface: Color, val surfaceTop: Color, val inset: Color,
    val border: Color, val divider: Color,
    val text: Color, val textSecondary: Color, val textTertiary: Color,
    val onDark: Color, val onDarkSecondary: Color, val onDarkTertiary: Color,
    val heroFill: Color, val heroBorder: Color,
    val accent: Color,
    val charge: Color, val effort: Color, val rest: Color, val missing: Color,
    val recoveryStops: List<Pair<Float, Color>>,
    val sleepDeep: Color, val sleepLight: Color, val sleepRem: Color, val sleepAwake: Color,
    val heart: Color,
)

@Immutable
data class ForgeType(
    val title1: TextStyle, val title2: TextStyle, val headline: TextStyle, val body: TextStyle,
    val bodyNumber: TextStyle, val subhead: TextStyle, val caption: TextStyle, val captionNumber: TextStyle,
    val footnote: TextStyle, val overline: TextStyle, val heroNumber: TextStyle,
)

private fun ForgeColor.pick(dark: Boolean) = Color(if (dark) this.dark else this.light)

fun forgeColors(dark: Boolean): ForgeColors = ForgeColors(
    dark = dark,
    canvas = Chrome.canvas.pick(dark), surface = Chrome.surface.pick(dark), surfaceTop = Chrome.surfaceTop.pick(dark),
    inset = Chrome.inset.pick(dark), border = Chrome.border.pick(dark), divider = Chrome.divider.pick(dark),
    text = Chrome.primaryText.pick(dark), textSecondary = Chrome.secondaryText.pick(dark),
    textTertiary = Chrome.tertiaryText.pick(dark),
    onDark = P.onDarkPrimary.pick(dark), onDarkSecondary = P.onDarkSecondary.pick(dark),
    onDarkTertiary = P.onDarkTertiary.pick(dark),
    heroFill = P.heroFill.pick(dark), heroBorder = P.heroBorder.pick(dark),
    accent = ForgeTokens.Color.systemBlue.pick(dark),
    charge = P.chargeColor.pick(dark), effort = P.organicEffort.pick(dark), rest = P.organicRest.pick(dark),
    missing = P.organicMissing.pick(dark),
    // The Signature style's recovery ramp, the stops `StrandPalette.recoveryStops` gives the score ring.
    recoveryStops = listOf(
        0.00f to P.recovery000.pick(dark), 0.30f to P.recovery030.pick(dark), 0.55f to P.recovery055.pick(dark),
        0.78f to P.recovery078.pick(dark), 1.00f to P.recovery100.pick(dark),
    ),
    sleepDeep = P.sleepDeep.pick(dark), sleepLight = P.sleepLight.pick(dark), sleepRem = P.sleepREM.pick(dark),
    sleepAwake = P.sleepAwake.pick(dark),
    heart = P.liquidHeart.pick(dark),
)

/**
 * The faces standing in for Apple's, which may not ship outside Apple's platforms: Nunito where iOS uses SF Pro
 * Rounded (titles, the hero numbers, tile values) and Inter where it uses SF Pro (everything else). Both are under
 * the SIL Open Font License (`assets/licenses/`), each one variable file set to every weight.
 */
@OptIn(ExperimentalTextApi::class)
private fun variable(res: Int) = FontFamily((100..900 step 100).map { w ->
    Font(res, FontWeight(w), variationSettings = FontVariation.Settings(FontVariation.weight(w)))
})

private val roundedFamily = variable(R.font.nunito)
private val textFamily = variable(R.font.inter)

private fun ForgeFont.style(color: Color = Color.Unspecified) = TextStyle(
    fontSize = size.sp, fontWeight = FontWeight(weight), color = color,
    fontFamily = if (rounded) roundedFamily else textFamily,
)

val forgeType = ForgeType(
    title1 = ForgeTokens.StrandFont.title1.style(), title2 = ForgeTokens.StrandFont.title2.style(),
    headline = ForgeTokens.StrandFont.headline.style(), body = ForgeTokens.StrandFont.body.style(),
    bodyNumber = ForgeTokens.StrandFont.bodyNumber.style(), subhead = ForgeTokens.StrandFont.subhead.style(),
    caption = ForgeTokens.StrandFont.caption.style(), captionNumber = ForgeTokens.StrandFont.captionNumber.style(),
    footnote = ForgeTokens.StrandFont.footnote.style(),
    overline = ForgeTokens.StrandFont.overline.style().copy(letterSpacing = ForgeTokens.StrandFont.overlineTracking.sp),
    heroNumber = ForgeTokens.StrandFont.heroNumber.style(),
)

/** Spacing and shapes in dp, from the same tokens. */
object ForgeMetrics {
    val screenPadding = ForgeTokens.NoopMetrics.screenPadding.dp
    val cardPadding = ForgeTokens.NoopMetrics.cardPadding.dp
    val cardRadius = ForgeTokens.NoopMetrics.cardRadius.dp
    val groupedRadius = ForgeTokens.NoopMetrics.groupedRadius.dp
    val heroRadius = ForgeTokens.NoopMetrics.heroRadius.dp
    val gap = ForgeTokens.NoopMetrics.gap.dp
    val sectionGap = ForgeTokens.NoopMetrics.sectionGap.dp
    val rowSpacing = ForgeTokens.NoopMetrics.rowSpacing.dp
    val space1 = ForgeTokens.NoopMetrics.space1.dp
    val space2 = ForgeTokens.NoopMetrics.space2.dp
    val space3 = ForgeTokens.NoopMetrics.space3.dp
    val space4 = ForgeTokens.NoopMetrics.space4.dp
    val space5 = ForgeTokens.NoopMetrics.space5.dp
    val space6 = ForgeTokens.NoopMetrics.space6.dp
    val space8 = ForgeTokens.NoopMetrics.space8.dp
    val chartHeight = ForgeTokens.NoopMetrics.chartHeight.dp
    val hairline = ForgeTokens.NoopMetrics.hairlineWidth.dp
    val minHitTarget = ForgeTokens.NoopButtonMetrics.minHitTarget.dp
    val tabBarClearance = ForgeTokens.NoopMetrics.tabBarClearance.dp
    /** Content never stretches wider than this on a tablet or an unfolded foldable. */
    val maxContentWidth = 720.dp
}

/** Material's own text styles on Inter, for the Material components the Forge screens use. */
private val forgeTypography = Typography().let { t ->
    t.copy(
        displayLarge = t.displayLarge.copy(fontFamily = roundedFamily), displayMedium = t.displayMedium.copy(fontFamily = roundedFamily),
        displaySmall = t.displaySmall.copy(fontFamily = roundedFamily), headlineLarge = t.headlineLarge.copy(fontFamily = roundedFamily),
        headlineMedium = t.headlineMedium.copy(fontFamily = roundedFamily), headlineSmall = t.headlineSmall.copy(fontFamily = roundedFamily),
        titleLarge = t.titleLarge.copy(fontFamily = textFamily), titleMedium = t.titleMedium.copy(fontFamily = textFamily),
        titleSmall = t.titleSmall.copy(fontFamily = textFamily), bodyLarge = t.bodyLarge.copy(fontFamily = textFamily),
        bodyMedium = t.bodyMedium.copy(fontFamily = textFamily), bodySmall = t.bodySmall.copy(fontFamily = textFamily),
        labelLarge = t.labelLarge.copy(fontFamily = textFamily), labelMedium = t.labelMedium.copy(fontFamily = textFamily),
        labelSmall = t.labelSmall.copy(fontFamily = textFamily),
    )
}

private val LocalForgeColors = staticCompositionLocalOf { forgeColors(dark = false) }

object Forge {
    val colors: ForgeColors @Composable get() = LocalForgeColors.current
    val type: ForgeType get() = forgeType
    /** Ink for text straight on the scene (headers, section titles); the normal text colours off a scene. */
    val sceneInk: SceneInk @Composable get() = LocalSceneInk.current
        ?: colors.let { SceneInk(it.text, it.textSecondary, it.textTertiary, it.dark) }
}

/**
 * Light or dark: the app's Appearance choice (`AppearancePrefs`, shared with the classic screens and set in
 * Forge Settings), the system's when that is System, as on iOS.
 */
@Composable
fun forgeDark(): Boolean = when (AppearancePrefs.mode) {
    AppearanceMode.LIGHT -> false
    AppearanceMode.DARK -> true
    AppearanceMode.SYSTEM -> isSystemInDarkTheme()
}

/** The Forge theme, light or dark by [forgeDark]; the whole screen darkens, not only the cards. */
@Composable
fun ForgeTheme(dark: Boolean = forgeDark(), content: @Composable () -> Unit) {
    val colors = forgeColors(dark)
    val material = if (dark) {
        darkColorScheme(primary = colors.accent, background = colors.canvas, surface = colors.surface,
                        onBackground = colors.text, onSurface = colors.text, outline = colors.border)
    } else {
        lightColorScheme(primary = colors.accent, background = colors.canvas, surface = colors.surface,
                         onBackground = colors.text, onSurface = colors.text, outline = colors.border)
    }
    CompositionLocalProvider(LocalForgeColors provides colors) {
        MaterialTheme(colorScheme = material, typography = forgeTypography, content = content)
    }
}
