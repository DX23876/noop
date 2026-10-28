package com.noop.ui.forge

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import com.noop.R
import com.noop.core.CoreRead
import com.noop.core.CoreRhythmAge
import com.noop.ui.ProfileStore
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.text.NumberFormat
import java.time.LocalTime
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle
import java.util.Locale
import kotlin.math.abs

/**
 * Fork (DX23876), Android parity plan 2.3: the daily-rhythm screen after `RhythmAgeDetailView`: the rhythm age, the
 * day as 24 hourly bars against the typical day with its sentence, two plain comparisons, the busiest window, the
 * one step that helps most and the history. The shared core resolves every number and sentence.
 */
@Composable
internal fun ForgeRhythmAgePage(onBack: () -> Unit) {
    val context = LocalContext.current
    var output by remember { mutableStateOf<CoreRhythmAge.Output?>(null) }
    var loaded by remember { mutableStateOf(false) }
    LaunchedEffect(Unit) {
        output = withContext(Dispatchers.IO) { CoreRead.open(context); CoreRhythmAge.snapshot() }
        loaded = true
    }
    val actualAge = remember { ProfileStore.from(context).age }
    SettingsColumn {
        PageTitle(stringResource(R.string.forge_rhythm_title), onBack)
        val o = output
        if (o == null) {
            Text(stringResource(if (loaded) R.string.forge_rhythm_empty else R.string.forge_goals_loading),
                 style = Forge.type.body, color = Forge.sceneInk.secondary)
            return@SettingsColumn
        }
        when (o.state) {
            "collecting" -> RhythmCard {
                Text(stringResource(R.string.forge_rhythm_collected, (o.collectedHours ?: 0.0).toInt()),
                     style = Forge.type.title2, color = Forge.colors.text)
                Text(stringResource(R.string.forge_rhythm_wear), style = Forge.type.body, color = Forge.colors.textSecondary)
            }
            "reading" -> Reading(o, actualAge)
            else -> RhythmCard {
                Text(stringResource(R.string.forge_rhythm_empty), style = Forge.type.body, color = Forge.colors.textSecondary)
            }
        }
    }
}

@Composable
private fun RhythmCard(content: @Composable () -> Unit) {
    ForgeCard(Modifier.fillMaxWidth(), radius = ForgeMetrics.groupedRadius) {
        Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(ForgeMetrics.space3)) { content() }
    }
}

@Composable
private fun Reading(o: CoreRhythmAge.Output, actualAge: Int) {
    val advance = o.advance ?: 0.0
    val young = ForgeTokens.StrandPalette.agelessYoungDeep.resolve()
    val old = ForgeTokens.StrandPalette.agelessOld.resolve()
    RhythmCard {
        Text(stringResource(R.string.forge_rhythm_headline), style = Forge.type.overline, color = Forge.colors.textSecondary)
        Row(verticalAlignment = Alignment.Bottom) {
            if (actualAge > 0) {
                Text(one(actualAge + advance), style = Forge.type.title1, color = if (advance > 0) old else young)
                Spacer(Modifier.width(ForgeMetrics.space2))
            }
            Text(stringResource(R.string.forge_join_space, one(abs(advance)),
                                stringResource(if (advance > 0) R.string.forge_ageless_older else R.string.forge_ageless_younger)),
                 style = Forge.type.subhead, color = Forge.colors.textSecondary, modifier = Modifier.padding(bottom = 4.dp))
        }
    }
    RhythmCard {
        HourBars(o.hourly, o.typical)
        o.daySentence?.let { Text(it, style = Forge.type.body, color = Forge.colors.textSecondary) }
    }
    RhythmCard {
        Steps(stringResource(R.string.forge_rhythm_movement), listOf(R.string.forge_rhythm_less, R.string.forge_rhythm_like_most,
              R.string.forge_rhythm_more), o.movementLevel)
        Steps(stringResource(R.string.forge_rhythm_contrast), listOf(R.string.forge_rhythm_hardly, R.string.forge_rhythm_like_most,
              R.string.forge_rhythm_clear), o.contrastLevel)
        o.busiestStart?.let { start ->
            Row {
                Text(stringResource(R.string.forge_rhythm_most_active), style = Forge.type.subhead, color = Forge.colors.text,
                     modifier = Modifier.weight(1f))
                Text(stringResource(R.string.forge_rhythm_window, hour(start), hour(start + 3)), style = Forge.type.subhead,
                     color = Forge.colors.text)
            }
        }
    }
    o.lever?.let { lever ->
        Column(Modifier.fillMaxWidth().clip(RoundedCornerShape(ForgeMetrics.cardRadius))
                   .background(ForgeTokens.StrandPalette.agelessYoung.resolve().copy(alpha = 0.14f)).padding(ForgeMetrics.space4),
               verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Text(stringResource(R.string.forge_rhythm_helps), style = Forge.type.headline, color = young)
            Text(lever, style = Forge.type.body, color = young)
        }
    }
    if (o.history.size > 1) {
        RhythmCard {
            Text(stringResource(R.string.forge_ageless_over_time), style = Forge.type.title2, color = Forge.colors.text)
            val values = o.history.map { it.second } + 0.0
            val lo = values.min() - 1
            val hi = values.max() + 1
            BoxWithConstraints(Modifier.fillMaxWidth().height(120.dp)) {
                val w = maxWidth
                Box(Modifier.offset(y = 120.dp * ((hi - 0.0) / (hi - lo)).toFloat()).fillMaxWidth().height(1.dp)
                        .background(Forge.colors.divider))
                o.history.forEachIndexed { i, (_, value) ->
                    val x = w * (i.toFloat() / (o.history.size - 1))
                    val y = 120.dp * ((hi - value) / (hi - lo)).toFloat()
                    Box(Modifier.offset(x = x - 3.dp, y = y - 3.dp).size(6.dp).clip(CircleShape)
                            .background(ForgeTokens.StrandPalette.agelessYoung.resolve()))
                }
            }
            Text(stringResource(R.string.forge_rhythm_over_time_note), style = Forge.type.caption, color = Forge.colors.textSecondary)
        }
    }
}

/** 24 hourly bars, with the typical day as a thin mark on each. */
@Composable
private fun HourBars(hourly: List<Double?>, typical: List<Double>) {
    val top = ((hourly.filterNotNull() + typical).maxOrNull() ?: 1.0).coerceAtLeast(1.0)
    Row(Modifier.fillMaxWidth().height(96.dp), horizontalArrangement = Arrangement.spacedBy(2.dp), verticalAlignment = Alignment.Bottom) {
        for (h in 0 until 24) {
            val v = hourly.getOrNull(h)
            val t = typical.getOrNull(h) ?: 0.0
            Box(Modifier.weight(1f).fillMaxHeight()) {
                Box(Modifier.align(Alignment.BottomCenter).fillMaxWidth().fillMaxHeight(((v ?: 0.0) / top).toFloat())
                        .clip(RoundedCornerShape(2.dp))
                        .background(if (v == null) Forge.colors.inset else ForgeTokens.StrandPalette.agelessYoung.resolve()))
                Box(Modifier.align(Alignment.BottomCenter).fillMaxHeight((t / top).toFloat())) {
                    Box(Modifier.align(Alignment.TopCenter).fillMaxWidth().height(2.dp).background(Forge.colors.textTertiary))
                }
            }
        }
    }
}

@Composable
private fun Steps(title: String, labels: List<Int>, selected: Int?) {
    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Text(title, style = Forge.type.subhead, color = Forge.colors.text)
        Row(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
            labels.forEachIndexed { i, label ->
                val on = i == selected
                Box(Modifier.weight(1f).clip(RoundedCornerShape(8.dp))
                        .background(if (on) ForgeTokens.StrandPalette.agelessYoung.resolve().copy(alpha = 0.25f) else Forge.colors.inset)
                        .padding(vertical = 6.dp), contentAlignment = Alignment.Center) {
                    Text(stringResource(label), style = Forge.type.caption,
                         color = if (on) Forge.colors.text else Forge.colors.textTertiary)
                }
            }
        }
    }
}

private fun one(v: Double): String =
    NumberFormat.getNumberInstance(Locale.getDefault()).apply { minimumFractionDigits = 1; maximumFractionDigits = 1 }.format(v)

/** An hour in the reader's own clock style. */
private fun hour(h: Int): String =
    LocalTime.of(h % 24, 0).format(DateTimeFormatter.ofLocalizedTime(FormatStyle.SHORT).withLocale(Locale.getDefault()))
