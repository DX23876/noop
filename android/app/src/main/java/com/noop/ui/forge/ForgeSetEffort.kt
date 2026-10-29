package com.noop.ui.forge

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Check
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableDoubleStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.noop.R
import java.text.NumberFormat
import kotlin.math.abs

/**
 * Fork (DX23876), Android parity: per-set effort as the iOS live session logs it (`EffortChoice`, `EffortBadge`,
 * `EffortPickerSheet`). Settings › Training picks the scale; the same six described levels serve both, RPE being
 * 10 minus the reps in reserve.
 */
internal object SetEffort {
    /** Reps in reserve of each level, hardest first, with its words. */
    private val levels = listOf(0.0 to R.string.forge_ef_0, 0.5 to R.string.forge_ef_05, 1.0 to R.string.forge_ef_1,
                                2.0 to R.string.forge_ef_2, 3.0 to R.string.forge_ef_3, 4.0 to R.string.forge_ef_4)

    data class Choice(val value: Double, val title: Int, val level: Int)

    fun choices(scale: String): List<Choice> =
        levels.mapIndexed { i, (rir, title) -> Choice(if (scale == "rir") rir else 10 - rir, title, i) }

    /** The level nearest to a stored rating on its scale. */
    fun level(scale: String, value: Double): Int =
        choices(scale).minByOrNull { abs(it.value - value) }?.level ?: 0

    @Composable
    fun color(level: Int): Color = when (level) {
        0 -> ForgeTokens.StrandPalette.metricPurple
        1 -> ForgeTokens.StrandPalette.zone5
        2 -> ForgeTokens.StrandPalette.zone4
        3 -> ForgeTokens.StrandPalette.zone3
        4 -> ForgeTokens.StrandPalette.zone2
        else -> ForgeTokens.StrandPalette.zone1
    }.resolve()

    fun format(value: Double): String =
        NumberFormat.getNumberInstance().apply { minimumFractionDigits = 0; maximumFractionDigits = 1 }.format(value)
}

/** A value on its effort colour: tinted fill, coloured edge and the normal text colour; unrated reads as a dash. */
@Composable
internal fun EffortBadge(text: String, color: Color?, modifier: Modifier = Modifier) {
    val shape = RoundedCornerShape(8.dp)
    Box(modifier
            .background(color?.copy(alpha = 0.28f) ?: Forge.colors.inset, shape)
            .then(if (color != null) Modifier.border(1.5.dp, color, shape) else Modifier),
        contentAlignment = Alignment.Center) {
        Text(text, style = Forge.type.subhead.copy(fontWeight = FontWeight.Bold, fontFeatureSettings = "tnum"),
             color = if (color == null) Forge.colors.textTertiary else Forge.colors.text)
    }
}

/** "How hard was that set?": tap a described level, or set an exact value in half steps. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun EffortPickerSheet(scale: String, current: Double?, onPick: (Double?) -> Unit, onDismiss: () -> Unit) {
    val range = if (scale == "rir") 0.0..10.0 else 1.0..10.0
    var exact by remember { mutableDoubleStateOf(current ?: if (scale == "rir") 2.0 else 8.0) }
    fun pick(value: Double?) { onPick(value); onDismiss() }
    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
                     containerColor = Forge.colors.surface) {
        Column(Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).navigationBarsPadding()
                   .padding(horizontal = ForgeMetrics.screenPadding).padding(bottom = ForgeMetrics.space4),
               verticalArrangement = Arrangement.spacedBy(ForgeMetrics.space2)) {
            Text(stringResource(R.string.forge_ef_title), style = Forge.type.headline, color = Forge.colors.text)
            SetEffort.choices(scale).forEach { choice ->
                Row(Modifier.fillMaxWidth().clickable { pick(choice.value) }.padding(vertical = ForgeMetrics.space1),
                    verticalAlignment = Alignment.CenterVertically) {
                    EffortBadge(SetEffort.format(choice.value), SetEffort.color(choice.level), Modifier.size(44.dp, 32.dp))
                    Spacer(Modifier.size(ForgeMetrics.space3))
                    Text(stringResource(choice.title), style = Forge.type.body, color = Forge.colors.text,
                         modifier = Modifier.weight(1f))
                    if (current == choice.value) Icon(Icons.Rounded.Check, contentDescription = null, tint = Forge.colors.accent)
                }
            }
            Text(stringResource(if (scale == "rir") R.string.forge_ef_rir_note else R.string.forge_ef_rpe_note),
                 style = Forge.type.caption, color = Forge.colors.textSecondary)
            Text(stringResource(R.string.forge_ef_exact).uppercase(), style = Forge.type.overline, color = Forge.colors.textSecondary)
            Row(verticalAlignment = Alignment.CenterVertically) {
                Stepper(SetEffort.format(exact),
                        onMinus = { exact = (exact - 0.5).coerceAtLeast(range.start) },
                        onPlus = { exact = (exact + 0.5).coerceAtMost(range.endInclusive) })
                Spacer(Modifier.weight(1f))
                TextButton(onClick = { pick(exact) }) {
                    Text(stringResource(R.string.forge_ef_use, SetEffort.format(exact)), color = Forge.colors.accent)
                }
            }
            if (current != null) TextButton(onClick = { pick(null) }, modifier = Modifier.fillMaxWidth()) {
                Text(stringResource(R.string.forge_ef_clear), color = ForgeTokens.Color.systemRed.resolve())
            }
        }
    }
}
