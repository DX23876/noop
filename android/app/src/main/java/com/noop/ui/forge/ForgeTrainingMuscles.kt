package com.noop.ui.forge

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.KeyboardArrowRight
import androidx.compose.material.icons.rounded.Accessibility
import androidx.compose.material.icons.rounded.FitnessCenter
import androidx.compose.material.icons.rounded.Speed
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import com.noop.R
import com.noop.core.CoreTraining
import com.noop.ui.NoopPrefs
import java.util.Locale
import kotlin.math.abs
import kotlin.math.roundToInt

/** The three views of the muscle analytics surface (`MuscleAnalyticsSurface.Mode`). */
enum class MuscleMode(val label: Int, val question: Int, val method: Int, val empty: Int) {
    Balance(R.string.forge_th_balance, R.string.forge_th_q_balance, R.string.forge_th_m_balance, R.string.forge_th_e_balance),
    Fatigue(R.string.forge_th_fatigue, R.string.forge_th_q_fatigue, R.string.forge_th_m_fatigue, R.string.forge_th_e_fatigue),
    Strength(R.string.forge_th_strength, R.string.forge_th_q_strength, R.string.forge_th_m_strength, R.string.forge_th_e_strength),
}

/** The wearer's figure choice, the key the iOS surface stores it under (`training.bodyFigure`). */
private const val FIGURE_KEY = "training.bodyFigure"

/**
 * A segmented control as iOS draws `.pickerStyle(.segmented)`: an inset track with the chosen segment raised on a
 * white thumb.
 */
@Composable
fun ForgeSegmented(options: List<String>, selected: Int, modifier: Modifier = Modifier, onSelect: (Int) -> Unit) {
    val colors = Forge.colors
    Row(modifier.height(32.dp).background(colors.inset, RoundedCornerShape(9.dp)).padding(2.dp)) {
        options.forEachIndexed { i, label ->
            val chosen = i == selected
            Box(Modifier.weight(1f).fillMaxWidthHeight()
                    .then(if (chosen) Modifier.shadow(2.dp, RoundedCornerShape(7.dp))
                              .background(if (colors.dark) colors.surfaceTop else Color.White, RoundedCornerShape(7.dp))
                          else Modifier)
                    .clickable { onSelect(i) },
                contentAlignment = Alignment.Center) {
                Text(label, style = Forge.type.subhead.copy(fontWeight = if (chosen) FontWeight.SemiBold else FontWeight.Normal),
                     color = colors.text, maxLines = 1)
            }
        }
    }
}

private fun Modifier.fillMaxWidthHeight(): Modifier = this.then(Modifier.fillMaxWidth()).then(Modifier.height(28.dp))

/**
 * The muscle analytics surface (`MuscleAnalyticsSurface`): Balance, Fatigue or Strength on the figure, front or back,
 * with what the readings cover; [compact] is the Training card, otherwise the Explore page lists the muscles too.
 */
@Composable
fun MuscleAnalyticsSurface(muscles: CoreTraining.MuscleAnalytics, compact: Boolean,
                           onOpen: (MuscleMode, String) -> Unit = { _, _ -> }) {
    val context = LocalContext.current
    val prefs = remember { context.getSharedPreferences(NoopPrefs.NAME, android.content.Context.MODE_PRIVATE) }
    var mode by rememberSaveable { mutableStateOf(MuscleMode.Balance) }
    var back by rememberSaveable { mutableStateOf(false) }
    var figure by remember { mutableStateOf(prefs.getString(FIGURE_KEY, "male") ?: "male") }
    var figureMenu by remember { mutableStateOf(false) }
    val colors = Forge.colors
    Column(verticalArrangement = Arrangement.spacedBy(ForgeMetrics.space3)) {
        ForgeSegmented(MuscleMode.entries.map { stringResource(it.label) }, mode.ordinal, Modifier.fillMaxWidth()) {
            mode = MuscleMode.entries[it]
        }
        Text(stringResource(mode.question), style = Forge.type.subhead, color = colors.textSecondary)
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(ForgeMetrics.space2)) {
            ForgeSegmented(listOf(stringResource(R.string.forge_th_front), stringResource(R.string.forge_th_back)),
                           if (back) 1 else 0, Modifier.weight(1f)) { back = it == 1 }
            Box {
                Box(Modifier.size(width = 50.dp, height = 36.dp)
                        .background(colors.charge.copy(alpha = 0.15f), RoundedCornerShape(18.dp))
                        .clickable { figureMenu = true },
                    contentAlignment = Alignment.Center) {
                    Icon(Icons.Rounded.Accessibility, contentDescription = null, tint = colors.charge,
                         modifier = Modifier.size(20.dp))
                }
                DropdownMenu(expanded = figureMenu, onDismissRequest = { figureMenu = false }) {
                    listOf("male" to R.string.forge_th_male_figure, "female" to R.string.forge_th_female_figure)
                        .forEach { (value, label) ->
                            DropdownMenuItem(text = { Text(stringResource(label)) }, onClick = {
                                figure = value; figureMenu = false
                                prefs.edit().putString(FIGURE_KEY, value).apply()
                            })
                        }
                }
            }
        }
        val fills = mapFills(muscles, mode)
        val ids = currentIds(muscles, mode)
        ForgeBodyMap(figure, if (back) "back" else "front", fills,
                     Modifier.fillMaxWidth().height(if (compact) 250.dp else 330.dp),
                     description = stringResource(mode.question),
                     onTap = { slug ->
                         val best = MuscleMapArt.ids(slug, ids).maxByOrNull { score(muscles, mode, it) }
                         if (best != null) onOpen(mode, best)
                     })
        if (ids.isEmpty()) {
            Text(stringResource(mode.empty), style = Forge.type.subhead, color = colors.textSecondary)
        } else {
            CoverageRow(muscles, mode)
            if (!compact) {
                Column {
                    ids.take(12).forEach { id ->
                        Row(Modifier.fillMaxWidth().clickable { onOpen(mode, id) }.padding(vertical = ForgeMetrics.space2),
                            verticalAlignment = Alignment.CenterVertically) {
                            Text(muscleName(id), style = Forge.type.subhead, color = colors.text, modifier = Modifier.weight(1f))
                            Text(summary(muscles, mode, id), style = Forge.type.caption, color = colors.textSecondary)
                            Icon(Icons.AutoMirrored.Rounded.KeyboardArrowRight, contentDescription = null,
                                 tint = colors.textTertiary, modifier = Modifier.size(16.dp))
                        }
                        HubDivider()
                    }
                }
            }
        }
        Text(stringResource(mode.method), style = Forge.type.caption, color = colors.textTertiary)
    }
}

@Composable
private fun CoverageRow(muscles: CoreTraining.MuscleAnalytics, mode: MuscleMode) {
    val coverage = when (mode) {
        MuscleMode.Balance -> muscles.balanceCoverage
        MuscleMode.Fatigue -> muscles.fatigueCoverage
        MuscleMode.Strength -> muscles.strengthCoverage
    }
    val tint = Forge.colors.textSecondary
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(ForgeMetrics.space3)) {
        Label(Icons.Rounded.FitnessCenter, stringResource(R.string.forge_th_sets_mapped, coverage.mappedSets, coverage.workingSets), tint)
        Label(Icons.Rounded.Speed, stringResource(R.string.forge_th_rated, coverage.ratedSets), tint)
        if (mode == MuscleMode.Balance && !muscles.personalBaseline) {
            Text(stringResource(R.string.forge_th_baseline_growing), style = Forge.type.caption, color = tint)
        }
    }
}

@Composable
private fun Label(icon: ImageVector, text: String, tint: Color) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        Icon(icon, contentDescription = null, tint = tint, modifier = Modifier.size(14.dp))
        Spacer(Modifier.width(6.dp))
        Text(text, style = Forge.type.caption, color = tint, maxLines = 1)
    }
}

private fun currentIds(m: CoreTraining.MuscleAnalytics, mode: MuscleMode): List<String> = when (mode) {
    MuscleMode.Balance -> m.balance.map { it.muscleId }
    MuscleMode.Fatigue -> m.fatigue.map { it.muscleId }
    MuscleMode.Strength -> m.strength.map { it.muscleId }
}

private fun score(m: CoreTraining.MuscleAnalytics, mode: MuscleMode, id: String): Double = when (mode) {
    MuscleMode.Balance -> m.balance.firstOrNull { it.muscleId == id }?.effectiveSets ?: 0.0
    MuscleMode.Fatigue -> m.fatigue.firstOrNull { it.muscleId == id }?.relative ?: 0.0
    MuscleMode.Strength -> abs(m.strength.firstOrNull { it.muscleId == id }?.slopePerWeek ?: 0.0)
}

/** The figure's colours per mode (`MuscleAnalyticsSurface.mapIntensities` with its colour scale). */
@Composable
private fun mapFills(m: CoreTraining.MuscleAnalytics, mode: MuscleMode): Map<String, Color> = when (mode) {
    MuscleMode.Balance -> {
        val scale = ForgeBodyStyle.scale()
        MuscleMapArt.intensities(m.balance.associate { it.muscleId to it.effectiveSets })
            .mapValues { MuscleMapArt.scaleColor(scale, it.value) }
    }
    MuscleMode.Fatigue -> {
        val scale = ForgeBodyStyle.fatigueScale()
        MuscleMapArt.boundedIntensities(m.fatigue.associate { it.muscleId to it.relative })
            .mapValues { MuscleMapArt.scaleColor(scale, it.value) }
    }
    MuscleMode.Strength -> {
        // A reading with a clear direction gets its own colour, at an intensity that grows with the slope; the
        // steepest reading wins where several share one figure muscle.
        val up = ForgeTokens.StrandPalette.recovery100.resolve()
        val down = ForgeTokens.StrandPalette.statusCritical.resolve()
        val flat = ForgeTokens.StrandPalette.metricCyan.resolve()
        val merged = HashMap<String, Double>()
        for (r in m.strength) {
            if (r.direction == "unclear" || r.direction == "insufficientEvidence") continue
            val slug = MuscleMapArt.muscle(r.muscleId) ?: continue
            val slope = r.slopePerWeek ?: continue
            if (abs(slope) >= abs(merged[slug] ?: -1.0)) merged[slug] = slope
        }
        // An override colour fills at full opacity in MuscleMap, whatever the intensity.
        merged.mapValues { (_, slope) -> if (slope > 0) up else if (slope < 0) down else flat }
    }
}

@Composable
private fun summary(m: CoreTraining.MuscleAnalytics, mode: MuscleMode, id: String): String {
    val locale = Locale.getDefault()
    return when (mode) {
        MuscleMode.Balance -> m.balance.firstOrNull { it.muscleId == id }
            ?.let { stringResource(R.string.forge_th_share_recent, it.share * 100) } ?: "—"
        MuscleMode.Fatigue -> m.fatigue.firstOrNull { it.muscleId == id }
            ?.let { stringResource(R.string.forge_th_share_typical, it.relative * 100) } ?: "—"
        MuscleMode.Strength -> {
            val r = m.strength.firstOrNull { it.muscleId == id }
            when {
                r == null -> stringResource(R.string.forge_th_not_assessable)
                r.direction == "unclear" -> stringResource(R.string.forge_th_direction_unclear)
                r.slopePerWeek == null -> stringResource(R.string.forge_th_not_assessable)
                else -> String.format(locale, stringResource(R.string.forge_th_per_week), r.slopePerWeek * 100)
            }
        }
    }
}

/** The Explore muscles page (`MuscleAnalyticsView`): the full surface, then one muscle's detail when tapped. */
@Composable
fun MuscleAnalyticsPage(muscles: CoreTraining.MuscleAnalytics, onClose: () -> Unit) {
    var open by remember { mutableStateOf<Pair<MuscleMode, String>?>(null) }
    open?.let { (mode, id) ->
        BackHandler { open = null }
        MuscleDetail(muscles, mode, id, onBack = { open = null })
        return
    }
    SettingsColumn {
        PageTitle(stringResource(R.string.forge_th_muscle_analytics), onClose, trailing = {
            androidx.compose.material3.TextButton(onClick = onClose) {
                Text(stringResource(R.string.forge_th_done), color = Forge.colors.charge,
                     style = Forge.type.subhead.copy(fontWeight = FontWeight.SemiBold))
            }
        })
        ForgeCard(Modifier.fillMaxWidth()) {
            MuscleAnalyticsSurface(muscles, compact = false) { mode, id -> open = mode to id }
        }
        Text(stringResource(R.string.forge_th_musclemap_license), style = Forge.type.caption, color = Forge.colors.charge,
             modifier = Modifier.padding(horizontal = ForgeMetrics.space1))
    }
}

/** One muscle's reading (`MuscleMetricDetailView`), as grouped sections. */
@Composable
private fun MuscleDetail(m: CoreTraining.MuscleAnalytics, mode: MuscleMode, id: String, onBack: () -> Unit) {
    val locale = Locale.getDefault()
    val balance = m.balance.firstOrNull { it.muscleId == id }
    val fatigue = m.fatigue.firstOrNull { it.muscleId == id }
    val strength = m.strength.firstOrNull { it.muscleId == id }
    val percentFormat = stringResource(R.string.forge_percent)
    fun percent(v: Double) = String.format(locale, percentFormat, (v * 100).roundToInt())
    val oneDecimal = java.text.NumberFormat.getNumberInstance(locale).apply {
        minimumFractionDigits = 1; maximumFractionDigits = 1
    }
    SettingsColumn {
        PageTitle(muscleName(id), onBack)
        val interpretation = when (mode) {
            MuscleMode.Balance -> when (balance?.state) {
                "belowUsual" -> R.string.forge_th_i_below
                "withinUsualVariation" -> R.string.forge_th_i_within
                "aboveUsual" -> R.string.forge_th_i_above
                else -> R.string.forge_th_i_growing
            }
            MuscleMode.Fatigue -> R.string.forge_th_i_fatigue
            MuscleMode.Strength -> when (strength?.direction) {
                "increasing" -> R.string.forge_th_i_up
                "decreasing" -> R.string.forge_th_i_down
                "stable" -> R.string.forge_th_i_stable
                "unclear" -> R.string.forge_th_i_unclear
                else -> R.string.forge_th_i_insufficient
            }
        }
        DetailSection(stringResource(R.string.forge_th_interpretation)) {
            Text(stringResource(interpretation), style = Forge.type.body, color = Forge.colors.text)
        }
        if (mode == MuscleMode.Balance && balance != null) {
            DetailSection(stringResource(R.string.forge_th_distribution)) {
                ValueRow(stringResource(R.string.forge_th_effective_sets), oneDecimal.format(balance.effectiveSets))
                ValueRow(stringResource(R.string.forge_th_recent_share), percent(balance.share))
                balance.usualShare?.let { ValueRow(stringResource(R.string.forge_th_usual_share), percent(it)) }
            }
            EvidenceSection(balance.evidence)
        }
        if (mode == MuscleMode.Fatigue && fatigue != null) {
            DetailSection(stringResource(R.string.forge_th_estimate)) {
                ValueRow(stringResource(R.string.forge_th_vs_typical), percent(fatigue.relative))
                ValueRow(stringResource(R.string.forge_th_decay_time),
                         String.format(locale, stringResource(R.string.forge_th_hours), fatigue.tauHours))
                ValueRow(stringResource(R.string.forge_th_decay_basis),
                         stringResource(if (fatigue.personal) R.string.forge_th_personal_feedback else R.string.forge_th_documented_default))
            }
            EvidenceSection(fatigue.evidence)
        }
        if (mode == MuscleMode.Strength && strength != null) {
            DetailSection(stringResource(R.string.forge_th_exercise_evidence)) {
                strength.exercises.forEach { e ->
                    Column(Modifier.padding(vertical = ForgeMetrics.space1)) {
                        Text(e.title, style = Forge.type.body, color = Forge.colors.text)
                        val trend = when {
                            e.points < 4 -> stringResource(R.string.forge_th_of_four, e.points)
                            e.unclear || e.slopePerWeek == null -> stringResource(R.string.forge_th_direction_unclear)
                            else -> String.format(locale, stringResource(R.string.forge_th_per_week_sessions),
                                                  e.slopePerWeek * 100, e.points)
                        }
                        Text(trend, style = Forge.type.caption, color = Forge.colors.textSecondary)
                    }
                }
            }
        }
    }
}

@Composable
private fun EvidenceSection(rows: List<CoreTraining.Evidence>) {
    if (rows.isEmpty()) return
    DetailSection(stringResource(R.string.forge_th_contributing)) {
        rows.forEach { row ->
            Column(Modifier.padding(vertical = ForgeMetrics.space1)) {
                Text(row.exercise, style = Forge.type.body, color = Forge.colors.text)
                Text(row.session, style = Forge.type.caption, color = Forge.colors.textSecondary)
            }
        }
    }
}

@Composable
private fun DetailSection(title: String, content: @Composable () -> Unit) {
    Column {
        SectionHeader(title, Modifier.padding(bottom = ForgeMetrics.space1))
        ForgeCard(Modifier.fillMaxWidth(), radius = ForgeMetrics.groupedRadius) { content() }
    }
}

@Composable
private fun ValueRow(label: String, value: String) {
    Row(Modifier.fillMaxWidth().heightIn(min = 36.dp), verticalAlignment = Alignment.CenterVertically) {
        Text(label, style = Forge.type.body, color = Forge.colors.text, modifier = Modifier.weight(1f))
        Text(value, style = Forge.type.body, color = Forge.colors.textSecondary, textAlign = TextAlign.End)
    }
}

/** A training muscle id in the wearer's language (`TrainingDisplayNames.muscle`). */
@Composable
fun muscleName(id: String): String = MUSCLE_NAMES[id]?.let { stringResource(it) }
    ?: id.replace('_', ' ').replace('-', ' ').replaceFirstChar { it.titlecase(Locale.getDefault()) }

private val MUSCLE_NAMES = mapOf(
    "chest" to R.string.forge_m_chest, "upper_chest" to R.string.forge_m_upper_chest,
    "lower_chest" to R.string.forge_m_lower_chest, "serratus" to R.string.forge_m_serratus,
    "front_delts" to R.string.forge_m_front_delts, "side_delts" to R.string.forge_m_side_delts,
    "rear_delts" to R.string.forge_m_rear_delts, "rotator_cuff" to R.string.forge_m_rotator_cuff,
    "triceps" to R.string.forge_m_triceps, "biceps" to R.string.forge_m_biceps, "forearms" to R.string.forge_m_forearms,
    "lats" to R.string.forge_m_lats, "upper_back" to R.string.forge_m_upper_back, "rhomboids" to R.string.forge_m_rhomboids,
    "traps" to R.string.forge_m_traps, "upper_traps" to R.string.forge_m_upper_traps,
    "lower_traps" to R.string.forge_m_lower_traps, "lower_back" to R.string.forge_m_lower_back,
    "abdominals" to R.string.forge_m_abdominals, "upper_abs" to R.string.forge_m_upper_abs,
    "lower_abs" to R.string.forge_m_lower_abs, "obliques" to R.string.forge_m_obliques,
    "quadriceps" to R.string.forge_m_quadriceps, "inner_quadriceps" to R.string.forge_m_inner_quadriceps,
    "outer_quadriceps" to R.string.forge_m_outer_quadriceps, "hamstrings" to R.string.forge_m_hamstrings,
    "glutes" to R.string.forge_m_glutes, "hip_flexors" to R.string.forge_m_hip_flexors,
    "adductors" to R.string.forge_m_adductors, "abductors" to R.string.forge_m_abductors,
    "calves" to R.string.forge_m_calves, "tibialis" to R.string.forge_m_tibialis, "neck" to R.string.forge_m_neck,
)
