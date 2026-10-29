package com.noop.ui.forge

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.IntrinsicSize
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Air
import androidx.compose.material.icons.rounded.BarChart
import androidx.compose.material.icons.rounded.Bedtime
import androidx.compose.material.icons.rounded.CalendarMonth
import androidx.compose.material.icons.rounded.DragHandle
import androidx.compose.material.icons.rounded.Favorite
import androidx.compose.material.icons.rounded.FitnessCenter
import androidx.compose.material.icons.rounded.Functions
import androidx.compose.material.icons.rounded.HourglassEmpty
import androidx.compose.material.icons.rounded.HowToReg
import androidx.compose.material.icons.rounded.Info
import androidx.compose.material.icons.rounded.MonitorHeart
import androidx.compose.material.icons.rounded.NorthEast
import androidx.compose.material.icons.rounded.Remove
import androidx.compose.material.icons.rounded.Report
import androidx.compose.material.icons.rounded.ShowChart
import androidx.compose.material.icons.rounded.SouthEast
import androidx.compose.material.icons.rounded.SwapHoriz
import androidx.compose.material.icons.rounded.Verified
import androidx.compose.material.icons.rounded.VerifiedUser
import androidx.compose.material.icons.rounded.AutoAwesome
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.noop.R
import com.noop.core.CoreRead
import com.noop.core.CoreTrainingLoad
import com.noop.ui.ProfileStore
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.text.NumberFormat
import java.time.LocalDate
import java.time.format.DateTimeFormatter
import java.util.Locale
import kotlin.math.abs
import kotlin.math.floor
import kotlin.math.roundToInt

/** A titled section with the iOS section gap above it (`SectionHeader` then its card). */
@Composable
private fun LoadSection(title: String, overline: String, content: @Composable () -> Unit) {
    Column(Modifier.padding(top = ForgeMetrics.sectionGap - ForgeMetrics.gap),
           verticalArrangement = Arrangement.spacedBy(ForgeMetrics.gap)) {
        OverlineHeader(title, overline)
        content()
    }
}

/** The detail a Training Load summary tile or explainer opens. */
private enum class LoadDetail { Adaptation, Recovery, History, Session, Maturity, Basis, Method }

/**
 * Fork (DX23876), Android parity plan 2.3: Training Load as iOS lays it out (`TrainingLoadView`): the two lanes, the
 * page's one statement, the room left today, a persistent overload warning, four summary tiles that open their
 * cards, strength and cardio development, the shape of the week and how it works. Every reading comes from the core's
 * `TrainingLoadPreparation.prepare`, the computation the iPhone runs.
 */
@Composable
fun ForgeTrainingLoadPage(onClose: () -> Unit) {
    val context = LocalContext.current
    var output by remember { mutableStateOf<CoreTrainingLoad.Output?>(null) }
    var loaded by remember { mutableStateOf(false) }
    var history by remember { mutableStateOf(false) }
    var detail by remember { mutableStateOf<LoadDetail?>(null) }
    LaunchedEffect(Unit) {
        output = withContext(Dispatchers.IO) {
            CoreRead.open(context)
            val profile = ProfileStore.from(context)
            CoreTrainingLoad.read(profile.hrMax.toDouble(), profile.sex, dismissedTrainingWorkouts(context),
                                  com.noop.core.CoreFeatures.exerciseVO2max(context))
        }
        loaded = true
    }
    if (history) { ForgeTrainingHistoryPage(onClose = { history = false }); return }
    BackHandler { if (detail != null) detail = null else onClose() }
    val o = output
    detail?.let { d ->
        if (o != null) { LoadDetailPage(o, d) { detail = null }; return }
    }
    SettingsColumn {
        PageTitle(stringResource(R.string.forge_tl_title), onClose)
        Text(stringResource(R.string.forge_tl_subtitle), style = Forge.type.subhead, color = Forge.sceneInk.secondary,
             modifier = Modifier.padding(horizontal = ForgeMetrics.space1))
        if (!loaded) return@SettingsColumn
        if (o == null) return@SettingsColumn
        HeroLanes(o)
        StatementCard(o)
        RoomCard(o)
        MaturityLine(o)
        SustainedCard(o)
        SummaryGrid(o) { detail = it }
        StrengthDevelopment(o)
        CardioDevelopment(o)
        ShapeCard(o)
        TrainingHistoryButton { history = true }
        val maturity = maturity(o)
        ExplainerRows(listOf(
            ExplainerItem("maturity", maturityIcon(maturity), maturityTitle(maturity), maturityDetail(maturity)),
            ExplainerItem("basis", Icons.Rounded.Verified, stringResource(R.string.forge_tl_rests_on),
                          stringResource(R.string.forge_tl_data_coverage)),
            ExplainerItem("method", Icons.Rounded.Functions, stringResource(R.string.forge_tl_each_number),
                          stringResource(R.string.forge_tl_transparent)),
        )) { item ->
            detail = when (item.id) { "maturity" -> LoadDetail.Maturity; "basis" -> LoadDetail.Basis; else -> LoadDetail.Method }
        }
    }
}

// MARK: - The two lanes

@Composable
internal fun HeroLanes(o: CoreTrainingLoad.Output) {
    val s = o.strength; val c = o.cardio
    val provisional = s.band == null && o.provisionalBand != null
    LoadHeroCard(TrainingLane.Strength, s.percent, LoadPill.of(s.band, s.guardState, provisional),
                 strengthFigure(s), o.ratios.mapNotNull { it.strength }, strengthEvidence(s), strengthCaveat(o),
                 provisionalNote(o) ?: capNote(s))
    LoadHeroCard(TrainingLane.Cardio, c.percent, LoadPill.of(c.band, c.guardState), cardioFigure(c),
                 o.ratios.mapNotNull { it.cardio }, cardioEvidence(c), cardioCaveat(o), capNote(c))
}

@Composable
private fun strengthFigure(l: CoreTrainingLoad.Lane): String =
    stringResource(R.string.forge_tl_working_sets, l.sevenDayWorkingSets) + " · " + weightedSets(l.sevenDayTotal)

@Composable
private fun weightedSets(total: Double): String =
    stringResource(R.string.forge_tl_weighted_sets, NumberFormat.getNumberInstance(Locale.getDefault()).apply {
        minimumFractionDigits = 1; maximumFractionDigits = 1 }.format(total))

@Composable
private fun trimp(l: CoreTrainingLoad.Lane): String = stringResource(R.string.forge_tl_trimp, l.sevenDayTotal.roundToInt())

@Composable
private fun cardioFigure(l: CoreTrainingLoad.Lane): String =
    if (l.isLowerBound) stringResource(R.string.forge_tl_at_least, trimp(l)) else trimp(l)

@Composable
private fun belowSince(l: CoreTrainingLoad.Lane): String {
    val since = LocalDate.parse(l.readingDay).minusDays((l.daysBelowUsual - 1).toLong()).toString()
    return stringResource(R.string.forge_tl_below_since, shortDate(since))
}

@Composable
internal fun strengthEvidence(l: CoreTrainingLoad.Lane): String = when {
    l.guardState == "tooFewSessions" -> stringResource(R.string.forge_tl_too_few_in_window)
    l.band == null -> stringResource(R.string.forge_tl_sets_rated_after_21, l.measuredCount, l.possibleCount)
    l.band == "below" && l.daysBelowUsual > 0 && l.readingDay != null -> belowSince(l)
    else -> stringResource(R.string.forge_tl_sets_rated_history, l.measuredCount, l.possibleCount)
}

@Composable
internal fun cardioEvidence(l: CoreTrainingLoad.Lane): String = when {
    l.guardState == "tooFewSessions" -> stringResource(R.string.forge_tl_too_few_in_window)
    l.band == null -> stringResource(R.string.forge_tl_sessions_complete_after_21, l.measuredCount, l.possibleCount)
    l.band == "below" && l.daysBelowUsual > 0 && l.readingDay != null -> belowSince(l)
    else -> stringResource(R.string.forge_tl_sessions_complete_history, l.measuredCount, l.possibleCount)
}

private fun share(l: CoreTrainingLoad.Lane): Double? =
    if (l.possibleCount > 0) l.measuredCount.toDouble() / l.possibleCount else null

@Composable
private fun strengthCaveat(o: CoreTrainingLoad.Output): String? {
    val l = o.strength
    val s = share(l) ?: return null
    if (s >= o.trustedShare) return null
    return stringResource(R.string.forge_tl_caveat_rpe, l.measuredCount, l.possibleCount)
}

@Composable
private fun cardioCaveat(o: CoreTrainingLoad.Output): String? {
    val l = o.cardio
    if (l.possibleCount <= 0) return null
    if (!o.cardioMeasured) return stringResource(R.string.forge_tl_caveat_no_trace)
    val s = share(l) ?: return null
    if (s >= o.trustedShare) return null
    return stringResource(R.string.forge_tl_caveat_lower_bound, l.measuredCount, l.possibleCount)
}

@Composable
internal fun capNote(l: CoreTrainingLoad.Lane): String? =
    if (l.guardState == "lowVolumeCap") stringResource(R.string.forge_tl_cap_note) else null

@Composable
private fun provisionalNote(o: CoreTrainingLoad.Output): String? {
    if (o.strength.band != null) return null
    val band = o.provisionalBand ?: return null
    val amount = stringResource(when (band) {
        "low" -> R.string.forge_tl_low
        "moderate" -> R.string.forge_tl_moderate
        "high" -> R.string.forge_tl_high
        else -> R.string.forge_tl_very_high
    })
    return amount + " · " + stringResource(R.string.forge_tl_provisional_amount)
}

// MARK: - The statement

private data class Advice(val icon: ImageVector, val color: Color, val text: String, val secondary: Color? = null)

@Composable
private fun verdictColor(v: CoreTrainingLoad.Verdict?): Color = when (v?.kind) {
    "status" -> statusColor(v.value)
    "loadOnly" -> bandColor(v.value)
    else -> Forge.colors.textTertiary
}

private fun verdictIcon(v: CoreTrainingLoad.Verdict): ImageVector =
    if (v.kind == "status") statusIcon(v.value) else bandIcon(v.value)

@Composable
private fun verdictLabel(v: CoreTrainingLoad.Verdict?): String = when (v?.kind) {
    "status" -> statusLabel(v.value)
    "loadOnly" -> bandLabel(v.value)
    else -> "—"
}

@Composable
private fun sentence(v: CoreTrainingLoad.Verdict, lane: String?, recoveryHolding: Boolean): String = stringResource(
    if (v.kind == "status") when (v.value) {
        "detraining" -> R.string.forge_tl_s_detraining
        "recovering" -> R.string.forge_tl_s_recovering
        "maintaining" -> R.string.forge_tl_s_maintaining
        "productive" -> if (recoveryHolding) R.string.forge_tl_s_productive_recovery else R.string.forge_tl_s_productive
        "unproductive" -> if (lane == "cardio") R.string.forge_tl_s_spin_cardio else R.string.forge_tl_s_spin_strength
        else -> if (lane == "cardio") R.string.forge_tl_s_much_cardio else R.string.forge_tl_s_much_strength
    } else when (v.value) {
        "below" -> R.string.forge_tl_s_load_below
        "usual" -> R.string.forge_tl_s_load_usual
        "higher" -> R.string.forge_tl_s_load_higher
        else -> R.string.forge_tl_s_load_much_higher
    })

@Composable
private fun advice(o: CoreTrainingLoad.Output): Advice {
    val st = o.statement
    fun laneVerdict(lane: String?) = if (lane == "strength") o.strengthVerdict else o.cardioVerdict
    val overreaching = statusColor("overreaching")
    val unproductive = statusColor("unproductive")
    return when (st.kind) {
        "laneOnly" -> {
            val v = st.verdict ?: return noHistoryAdvice()
            Advice(verdictIcon(v), verdictColor(v), sentence(v, st.lane, o.recoveryState == "holding") + " " +
                   stringResource(R.string.forge_tl_other_lane_needs))
        }
        "aligned" -> {
            val v = st.verdict ?: return noHistoryAdvice()
            Advice(verdictIcon(v), verdictColor(v), sentence(v, null, o.recoveryState == "holding"))
        }
        "oneBehind" -> Advice(statusIcon("detraining"), verdictColor(laneVerdict(st.lane)), stringResource(
            if (st.lane == "strength") R.string.forge_tl_one_behind_strength else R.string.forge_tl_one_behind_cardio))
        "split" -> Advice(Icons.Rounded.SwapHoriz, verdictColor(laneVerdict(st.high)), stringResource(
            when {
                st.low == "strength" && st.severity == "mild" -> R.string.forge_tl_split_strength_mild
                st.low == "strength" -> R.string.forge_tl_split_strength_sharp
                st.severity == "mild" -> R.string.forge_tl_split_cardio_mild
                else -> R.string.forge_tl_split_cardio_sharp
            }), secondary = verdictColor(laneVerdict(st.low)))
        "excessive" -> Advice(statusIcon("overreaching"), overreaching, stringResource(
            when {
                st.lane == "strength" && st.flag == true -> R.string.forge_tl_excess_strength_strained
                st.lane == "strength" -> R.string.forge_tl_s_much_strength
                else -> R.string.forge_tl_s_much_cardio
            }))
        "bothExcessive" -> Advice(statusIcon("overreaching"), overreaching, stringResource(R.string.forge_tl_both_excessive))
        "spinning" -> Advice(statusIcon("unproductive"), unproductive, stringResource(
            when {
                st.lane == "strength" && st.flag == true -> R.string.forge_tl_spin_strength_both
                st.lane == "strength" -> R.string.forge_tl_s_spin_strength
                st.flag == true -> R.string.forge_tl_spin_cardio_both
                else -> R.string.forge_tl_s_spin_cardio
            }))
        "bothSpinning" -> Advice(statusIcon("unproductive"), unproductive, stringResource(R.string.forge_tl_both_spinning))
        "strainedRecovery" -> Advice(Icons.Rounded.Bedtime, unproductive, stringResource(R.string.forge_tl_strained_recovery))
        else -> noHistoryAdvice()
    }
}

@Composable
private fun noHistoryAdvice() = Advice(Icons.Rounded.HourglassEmpty, Forge.colors.textTertiary,
                                       stringResource(R.string.forge_tl_no_history))

/** A card with a faint wash and a hairline in one colour (`NoopCard(tint:)`). */
@Composable
private fun TintedCard(tint: Color, content: @Composable ColumnScope.() -> Unit) {
    val shape = RoundedCornerShape(ForgeMetrics.cardRadius)
    val surface = Forge.colors.surface
    Column(Modifier.fillMaxWidth().clip(shape).drawBehind {
        drawRect(surface)
        drawRect(Brush.linearGradient(listOf(tint.copy(alpha = 0.05f), tint.copy(alpha = 0.015f)),
                                      start = Offset.Zero, end = Offset(size.width, size.height)))
    }.border(BorderStroke(ForgeMetrics.hairline, tint.copy(alpha = 0.45f)), shape).padding(ForgeMetrics.cardPadding),
           verticalArrangement = Arrangement.spacedBy(ForgeMetrics.space2), content = content)
}

@Composable
private fun StatementCard(o: CoreTrainingLoad.Output) {
    val a = advice(o)
    TintedCard(a.color) {
        Text(stringResource(R.string.forge_tl_what_it_means).uppercase(), style = Forge.type.overline,
             color = Forge.colors.textSecondary)
        Row(verticalAlignment = Alignment.Top) {
            StatusBadge(a.icon, a.color, 40.dp)
            Spacer(Modifier.width(ForgeMetrics.space2))
            Text(a.text, style = Forge.type.subhead, color = Forge.colors.text, modifier = Modifier.weight(1f))
        }
        Row(horizontalArrangement = Arrangement.spacedBy(ForgeMetrics.space2)) {
            VerdictTile(stringResource(R.string.forge_th_strength), o.strengthVerdict, o.strength, Modifier.weight(1f))
            VerdictTile(stringResource(R.string.forge_tl_cardio), o.cardioVerdict, o.cardio, Modifier.weight(1f))
        }
    }
}

@Composable
private fun VerdictTile(title: String, verdict: CoreTrainingLoad.Verdict?, lane: CoreTrainingLoad.Lane, modifier: Modifier) {
    Column(modifier.background(Forge.colors.inset, RoundedCornerShape(14.dp)).padding(horizontal = 12.dp, vertical = 9.dp),
           verticalArrangement = Arrangement.spacedBy(1.dp)) {
        Text(title, style = Forge.type.caption, color = Forge.colors.textSecondary)
        Text(verdictLabel(verdict), style = Forge.type.subhead.copy(fontWeight = FontWeight.SemiBold),
             color = Forge.colors.text, maxLines = 1)
        lane.percent?.let { Text(signedPercent(it), style = Forge.type.captionNumber, color = Forge.colors.textSecondary) }
    }
}

// MARK: - Room, maturity, overload

@Composable
private fun RoomCard(o: CoreTrainingLoad.Output) {
    if (o.strengthRoom == null && o.cardioRoom == null && o.strengthSettles == null && o.cardioSettles == null) return
    ForgeCard(Modifier.fillMaxWidth()) {
        Text(stringResource(R.string.forge_tl_personal_range).uppercase(), style = Forge.type.overline,
             color = Forge.colors.textSecondary)
        Text(stringResource(R.string.forge_tl_room_today), style = Forge.type.headline, color = Forge.colors.text)
        Spacer(Modifier.height(ForgeMetrics.space2))
        RoomRow(TrainingLane.Strength, o.strengthRoom, o.strengthSettles, stringResource(R.string.forge_tl_weighted_sets_unit))
        RoomRow(TrainingLane.Cardio, o.cardioRoom, o.cardioSettles, "TRIMP")
        Spacer(Modifier.height(ForgeMetrics.space2))
        Text(stringResource(R.string.forge_tl_room_caption), style = Forge.type.caption, color = Forge.colors.textTertiary)
    }
}

private fun roomAmount(v: Double): String = NumberFormat.getIntegerInstance(Locale.getDefault()).format(floor(v).toLong())

@Composable
private fun RoomRow(lane: TrainingLane, room: CoreTrainingLoad.Room?, settles: String?, unit: String) {
    if (room == null && settles == null) return
    Row(Modifier.padding(vertical = ForgeMetrics.space1), verticalAlignment = Alignment.Top) {
        Icon(lane.icon, contentDescription = null, tint = lane.color, modifier = Modifier.width(20.dp).size(16.dp))
        Spacer(Modifier.width(ForgeMetrics.space2))
        Column(verticalArrangement = Arrangement.spacedBy(ForgeMetrics.space1)) {
            room?.let { r ->
                val above = roomAmount(r.beforeAbove)
                val well = r.beforeWellAbove
                val text = when {
                    r.beforeAbove > 0 && well != null -> stringResource(R.string.forge_tl_room_both, above, unit, roomAmount(well))
                    r.beforeAbove > 0 -> stringResource(R.string.forge_tl_room_above, above, unit)
                    well != null && well > 0 -> stringResource(R.string.forge_tl_room_past_above, roomAmount(well), unit)
                    else -> stringResource(R.string.forge_tl_room_past)
                }
                Text(text, style = Forge.type.subhead, color = Forge.colors.text)
            }
            settles?.let {
                val date = runCatching {
                    LocalDate.parse(it).format(DateTimeFormatter.ofPattern("EEEE d MMM", Locale.getDefault()))
                }.getOrDefault(it)
                Text(stringResource(R.string.forge_tl_settles, date), style = Forge.type.caption,
                     color = Forge.colors.textSecondary)
            }
        }
    }
}

private fun maturity(o: CoreTrainingLoad.Output): String {
    val values = listOf(o.strength.maturity, o.cardio.maturity)
    return when {
        "immediate" in values -> "immediate"
        "earlyEstimate" in values -> "earlyEstimate"
        "baselineGrowing" in values -> "baselineGrowing"
        else -> "personalBaseline"
    }
}

private fun maturityIcon(m: String): ImageVector = when (m) {
    "immediate" -> Icons.Rounded.BarChart
    "earlyEstimate" -> Icons.Rounded.AutoAwesome
    "baselineGrowing" -> Icons.Rounded.ShowChart
    else -> Icons.Rounded.VerifiedUser
}

@Composable
private fun maturityTitle(m: String): String = stringResource(when (m) {
    "immediate" -> R.string.forge_tl_current_load
    "earlyEstimate" -> R.string.forge_tl_early_estimate
    "baselineGrowing" -> R.string.forge_th_baseline_growing
    else -> R.string.forge_tl_personal_baseline
})

@Composable
private fun maturityDetail(m: String): String = stringResource(when (m) {
    "immediate" -> R.string.forge_tl_m_immediate
    "earlyEstimate" -> R.string.forge_tl_m_early
    "baselineGrowing" -> R.string.forge_tl_m_growing
    else -> R.string.forge_tl_m_personal
})

@Composable
private fun MaturityLine(o: CoreTrainingLoad.Output) {
    val m = maturity(o)
    if (m == "personalBaseline") return
    Row(Modifier.padding(horizontal = ForgeMetrics.space1), verticalAlignment = Alignment.Top) {
        Icon(maturityIcon(m), contentDescription = null, tint = TrainingTint.cyan, modifier = Modifier.size(14.dp))
        Spacer(Modifier.width(ForgeMetrics.space2))
        Column(verticalArrangement = Arrangement.spacedBy(1.dp)) {
            Text(maturityTitle(m), style = Forge.type.caption.copy(fontWeight = FontWeight.SemiBold), color = Forge.sceneInk.text)
            Text(maturityDetail(m), style = Forge.type.caption, color = Forge.sceneInk.secondary)
        }
    }
}

@Composable
private fun SustainedCard(o: CoreTrainingLoad.Output) {
    val lanes = o.sustainedLanes ?: return
    val weeks = o.sustainedWeeks ?: return
    val color = statusColor("overreaching")
    TrainingWashCard(color, Icons.Rounded.Report) {
        Column(verticalArrangement = Arrangement.spacedBy(ForgeMetrics.space2)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                StatusBadge(Icons.Rounded.Report, color, 34.dp)
                Spacer(Modifier.width(ForgeMetrics.space2))
                Text(stringResource(R.string.forge_tl_persistent), style = Forge.type.headline, color = Forge.colors.text)
            }
            val which = stringResource(when {
                "strength" in lanes && "cardio" in lanes -> R.string.forge_tl_strength_and_cardio
                "strength" in lanes -> R.string.forge_th_strength
                else -> R.string.forge_tl_cardio
            })
            Text(stringResource(R.string.forge_tl_sustained_text, weeks, which), style = Forge.type.subhead,
                 color = Forge.colors.text)
            Text(stringResource(R.string.forge_tl_not_diagnosis), style = Forge.type.caption, color = Forge.colors.textSecondary)
        }
    }
}

// MARK: - At a glance

@Composable
private fun adaptation(state: String): Triple<ImageVector, String, Color> = when (state) {
    "improving" -> Triple(Icons.Rounded.NorthEast, stringResource(R.string.forge_tl_a_improving), TrainingTint.positive)
    "declining" -> Triple(Icons.Rounded.SouthEast, stringResource(R.string.forge_tl_a_declining), TrainingTint.warning)
    "stable" -> Triple(Icons.Rounded.DragHandle, stringResource(R.string.forge_tl_a_stable), TrainingTint.cyan)
    "unclear" -> Triple(Icons.Rounded.Remove, stringResource(R.string.forge_tl_a_unclear), Forge.colors.textSecondary)
    else -> Triple(Icons.Rounded.HourglassEmpty, stringResource(R.string.forge_tl_a_not_enough), Forge.colors.textTertiary)
}

@Composable
private fun recoverySummary(o: CoreTrainingLoad.Output): String = when (o.recoveryState) {
    "strained" -> stringResource(R.string.forge_tl_recovery_strained, o.strainedNights, o.nightsRead)
    "holding" -> stringResource(R.string.forge_tl_recovery_holding, o.strainedNights, o.nightsRead)
    else -> stringResource(R.string.forge_tl_recovery_unknown)
}

@Composable
private fun recoveryTint(o: CoreTrainingLoad.Output): Color = when (o.recoveryState) {
    "strained" -> TrainingTint.warning
    "holding" -> TrainingTint.positive
    else -> Forge.colors.textTertiary
}

@Composable
private fun comparison(value: Double): String = stringResource(when {
    value >= 15 -> R.string.forge_tl_above_your_usual
    value <= -15 -> R.string.forge_tl_below_your_usual
    else -> R.string.forge_tl_about_your_usual
})

@Composable
private fun sessionText(l: CoreTrainingLoad.Lane): String =
    if (l.measuredCount <= 0) "—" else stringResource(R.string.forge_tl_au, l.sevenDayTotal.roundToInt())

@Composable
private fun sessionQuota(l: CoreTrainingLoad.Lane): String? =
    if (l.possibleCount > 0) stringResource(R.string.forge_tl_sessions_rated, l.measuredCount, l.possibleCount) else null

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun SummaryGrid(o: CoreTrainingLoad.Output, open: (LoadDetail) -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(ForgeMetrics.gap)) {
        Row(Modifier.height(IntrinsicSize.Min), horizontalArrangement = Arrangement.spacedBy(ForgeMetrics.gap)) {
            SummaryTile(Icons.Rounded.ShowChart, TrainingTint.positive, stringResource(R.string.forge_tl_adaptation),
                        modifier = Modifier.weight(1f).fillMaxHeight(), onClick = { open(LoadDetail.Adaptation) }) {
                Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                    AdaptationMini(TrainingLane.Strength, o.strengthAdaptation)
                    AdaptationMini(TrainingLane.Cardio, o.cardioAdaptation)
                }
            }
            SummaryTile(Icons.Rounded.Bedtime, recoveryTint(o), stringResource(R.string.forge_tl_recovery),
                        detail = recoverySummary(o), modifier = Modifier.weight(1f).fillMaxHeight(), onClick = { open(LoadDetail.Recovery) }) {
                FlowRow(horizontalArrangement = Arrangement.spacedBy(ForgeMetrics.space2),
                        verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    RecoveryDot(o, stringResource(R.string.forge_tl_hrv), "hrv")
                    RecoveryDot(o, stringResource(R.string.forge_tl_rhr), "rhr")
                    RecoveryDot(o, stringResource(R.string.forge_tl_breathing), "respRate")
                }
            }
        }
        Row(Modifier.height(IntrinsicSize.Min), horizontalArrangement = Arrangement.spacedBy(ForgeMetrics.gap)) {
            SummaryTile(Icons.Rounded.CalendarMonth, TrainingTint.cyan, stringResource(R.string.forge_tl_last_8_weeks),
                        modifier = Modifier.weight(1f).fillMaxHeight(), onClick = { open(LoadDetail.History) }) {
                Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                    HistoryMini(TrainingLane.Strength, o.history.takeLast(8).map { it.strength })
                    HistoryMini(TrainingLane.Cardio, o.history.takeLast(8).map { it.cardio })
                }
            }
            val s = o.session
            val detail = listOfNotNull(
                s.percent?.let { signedPercent(it) + " · " + comparison(it) } ?: stringResource(R.string.forge_tl_needs_two_weeks),
                sessionQuota(s)).joinToString("\n")
            SummaryTile(Icons.Rounded.HowToReg, TrainingTint.cyan, stringResource(R.string.forge_tl_session_load),
                        headline = sessionText(s), detail = detail, modifier = Modifier.weight(1f),
                        onClick = { open(LoadDetail.Session) })
        }
    }
}

@Composable
private fun AdaptationMini(lane: TrainingLane, state: String) {
    val (icon, text, color) = adaptation(state)
    Row(verticalAlignment = Alignment.CenterVertically) {
        Icon(lane.icon, contentDescription = null, tint = lane.color, modifier = Modifier.size(14.dp))
        Spacer(Modifier.width(6.dp))
        Icon(icon, contentDescription = null, tint = color, modifier = Modifier.size(12.dp))
        Spacer(Modifier.width(4.dp))
        Text(text, style = Forge.type.caption, color = color, maxLines = 2)
    }
}

@Composable
private fun RecoveryDot(o: CoreTrainingLoad.Output, title: String, key: String) {
    val read = key in o.readOnLatestNight
    val flagging = key in o.flaggingOnLatestNight
    val color = if (!read) Forge.colors.textTertiary else if (flagging) TrainingTint.warning else TrainingTint.positive
    Row(verticalAlignment = Alignment.CenterVertically) {
        Box(Modifier.size(7.dp).background(color, CircleShape))
        Spacer(Modifier.width(4.dp))
        Text(title, style = Forge.type.caption, color = Forge.colors.textSecondary, maxLines = 1)
    }
}

@Composable
private fun HistoryMini(lane: TrainingLane, bands: List<String?>) {
    val color = lane.color
    Row(horizontalArrangement = Arrangement.spacedBy(3.dp), verticalAlignment = Alignment.CenterVertically) {
        Icon(lane.icon, contentDescription = null, tint = color, modifier = Modifier.size(14.dp))
        bands.forEach { band ->
            val alpha = when (band) { "below" -> 0.3f; "usual" -> 0.55f; "higher" -> 0.8f; "muchHigher" -> 1f; else -> 0f }
            Box(Modifier.weight(1f).height(14.dp).background(
                if (band == null) Forge.colors.inset else color.copy(alpha = alpha), RoundedCornerShape(3.dp)))
        }
    }
}

// MARK: - Development

@Composable
private fun StrengthDevelopment(o: CoreTrainingLoad.Output) {
    LoadSection(stringResource(R.string.forge_tl_strength_development), stringResource(R.string.forge_tl_last_six_weeks)) { ForgeCard(Modifier.fillMaxWidth()) {
        if (o.rising + o.unclear + o.falling > 0) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(ForgeMetrics.space4)) {
                LiftDirectionDonut(o.rising, o.unclear, o.falling)
                Column(verticalArrangement = Arrangement.spacedBy(ForgeMetrics.space3)) {
                    CountLabel(o.rising, Icons.Rounded.NorthEast, TrainingTint.positive, stringResource(R.string.forge_tl_rising))
                    CountLabel(o.unclear, Icons.Rounded.Remove, Forge.colors.textTertiary, stringResource(R.string.forge_tl_unclear))
                    CountLabel(o.falling, Icons.Rounded.SouthEast, TrainingTint.critical, stringResource(R.string.forge_tl_falling))
                }
            }
            Spacer(Modifier.height(ForgeMetrics.space3))
            Text(stringResource(R.string.forge_tl_lifts_caption), style = Forge.type.caption, color = Forge.colors.textTertiary)
        } else {
            Text(stringResource(R.string.forge_tl_lifts_empty), style = Forge.type.subhead, color = Forge.colors.textSecondary)
        }
    }
    }
}

@Composable
private fun CountLabel(count: Int, icon: ImageVector, color: Color, title: String) {
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        StatusBadge(icon, color, 26.dp)
        Text(NumberFormat.getIntegerInstance(Locale.getDefault()).format(count),
             style = numberStyle(Forge.type.heroNumber, 20), color = Forge.colors.text)
        Text(title, style = Forge.type.caption, color = Forge.colors.textSecondary)
    }
}

@Composable
private fun CardioDevelopment(o: CoreTrainingLoad.Output) {
    LoadSection(stringResource(R.string.forge_tl_cardio_development), stringResource(R.string.forge_tl_vo2_eight_weeks)) { ForgeCard(Modifier.fillMaxWidth()) {
        val latest = o.vo2Primary
        val one = NumberFormat.getNumberInstance(Locale.getDefault()).apply { minimumFractionDigits = 1; maximumFractionDigits = 1 }
        if (latest != null) {
            Row(verticalAlignment = Alignment.Bottom) {
                Text(one.format(latest.value), style = numberStyle(Forge.type.heroNumber, 40, FontWeight.Bold),
                     color = Forge.colors.text)
                Spacer(Modifier.width(ForgeMetrics.space2))
                Text("ml/kg/min", style = Forge.type.caption, color = Forge.colors.textTertiary,
                     modifier = Modifier.padding(bottom = 6.dp))
            }
            if (o.vo2Line.size >= 2) VO2maxSparkline(o.vo2Line.map { it.value }, TrainingTint.effort)
            val source = when {
                latest.segment == o.appleSource -> stringResource(R.string.forge_tl_vo2_apple)
                latest.segment == "nes" -> stringResource(R.string.forge_tl_vo2_estimator, "Nes 2011")
                latest.segment == "uth" -> stringResource(R.string.forge_tl_vo2_estimator, "Uth 2004")
                else -> stringResource(R.string.forge_tl_vo2_noop)
            }
            Text(source, style = Forge.type.caption, color = Forge.colors.textSecondary)
            o.vo2Apple?.let {
                Text(stringResource(R.string.forge_tl_apple_last, one.format(it.value), shortDate(it.day)),
                     style = Forge.type.caption, color = Forge.colors.textTertiary)
            }
        } else {
            Text(stringResource(R.string.forge_tl_vo2_empty), style = Forge.type.subhead, color = Forge.colors.textSecondary)
        }
        o.exerciseVO2max?.let {
            Spacer(Modifier.height(ForgeMetrics.space3))
            androidx.compose.material3.HorizontalDivider(color = Forge.colors.border.copy(alpha = 0.5f), thickness = ForgeMetrics.hairline)
            Spacer(Modifier.height(ForgeMetrics.space3))
            ExerciseVO2maxRow(it)
        }
        Spacer(Modifier.height(ForgeMetrics.space3))
        androidx.compose.material3.HorizontalDivider(color = Forge.colors.border.copy(alpha = 0.5f), thickness = ForgeMetrics.hairline)
        Spacer(Modifier.height(ForgeMetrics.space3))
        EvidenceRow(o)
    }
    }
}

/** The Lab's experimental instrument, labelled as one (`exerciseVO2maxRow` on iOS). */
@Composable
private fun ExerciseVO2maxRow(x: CoreTrainingLoad.ExerciseVO2max) {
    val one = NumberFormat.getNumberInstance(Locale.getDefault()).apply { minimumFractionDigits = 1; maximumFractionDigits = 1 }
    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Text(stringResource(R.string.forge_tl_xvo2_title), style = Forge.type.subhead.copy(fontWeight = FontWeight.SemiBold),
             color = Forge.colors.text)
        val week = x.mondayKey
        if (x.value != null && week != null) {
            Text(stringResource(R.string.forge_tl_xvo2_week, one.format(x.value), shortDate(week), x.sessionsUsed, x.sessionsOnFoot),
                 style = Forge.type.caption, color = Forge.colors.textSecondary)
        } else {
            Text(stringResource(R.string.forge_tl_xvo2_none), style = Forge.type.caption, color = Forge.colors.textSecondary)
        }
        val graded = x.weekSessionsWithGrade ?: 0
        val grade = when {
            x.value == null || graded <= 0 -> stringResource(R.string.forge_tl_xvo2_flat)
            graded == x.weekSessions -> stringResource(R.string.forge_tl_xvo2_climbs)
            else -> stringResource(R.string.forge_tl_xvo2_some_climbs, graded, x.weekSessions ?: 0)
        }
        Text(grade, style = Forge.type.caption, color = Forge.colors.textTertiary)
        Text(stringResource(R.string.forge_tl_xvo2_rough), style = Forge.type.caption, color = Forge.colors.textTertiary)
        val mae = x.meanAbsoluteError
        val validation = if (x.pairs < x.pairsNeeded || mae == null) {
            stringResource(R.string.forge_tl_xvo2_pairs, x.pairs, x.pairsNeeded)
        } else {
            val agreement = Math.round((x.directionAgreement ?: 0.0) * 100).toInt()
            stringResource(if (x.passes) R.string.forge_tl_xvo2_passes else R.string.forge_tl_xvo2_fails, x.pairs, one.format(mae), agreement)
        }
        Text(validation, style = Forge.type.caption, color = Forge.colors.textTertiary)
    }
}

@Composable
private fun EvidenceRow(o: CoreTrainingLoad.Output) {
    val (color, icon) = when (o.evidence) {
        "rising" -> TrainingTint.positive to Icons.Rounded.NorthEast
        "falling" -> TrainingTint.critical to Icons.Rounded.SouthEast
        "unclear" -> Forge.colors.textSecondary to Icons.Rounded.Remove
        else -> Forge.colors.textTertiary to Icons.Rounded.HourglassEmpty
    }
    val direction = when (o.evidence) {
        "rising" -> stringResource(R.string.forge_tl_improving)
        "falling" -> stringResource(R.string.forge_tl_declining)
        "unclear" -> stringResource(R.string.forge_tl_no_clear_direction)
        else -> ""
    }
    val text = when (o.evidenceSource) {
        "appleVO2max" -> stringResource(R.string.forge_tl_evidence_apple, direction)
        "heartRateEfficiency" -> stringResource(R.string.forge_tl_evidence_efficiency, o.evidenceSport ?: "",
                                                o.evidenceSessions ?: 0, direction)
        else -> stringResource(R.string.forge_tl_evidence_none)
    }
    Row(verticalAlignment = Alignment.Top) {
        StatusBadge(icon, color, 26.dp)
        Spacer(Modifier.width(ForgeMetrics.space3))
        Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(stringResource(R.string.forge_tl_performance_evidence), style = Forge.type.subhead.copy(fontWeight = FontWeight.SemiBold),
                 color = Forge.colors.text)
            Text(text, style = Forge.type.caption, color = Forge.colors.textSecondary)
        }
    }
}

// MARK: - Shape of the week

@Composable
private fun shapeText(l: CoreTrainingLoad.Lane): String {
    val parts = mutableListOf<String>()
    l.weekOverWeek?.let { parts += stringResource(R.string.forge_tl_against_last_week, signedPercent(it)) }
    if (l.monotony != null && l.strain != null) {
        val monotony = NumberFormat.getNumberInstance(Locale.getDefault()).apply { minimumFractionDigits = 1; maximumFractionDigits = 1 }
            .format(l.monotony)
        parts += stringResource(R.string.forge_tl_monotony_strain, monotony, l.strain.roundToInt().toString())
    }
    return if (parts.isEmpty()) stringResource(R.string.forge_tl_shape_empty) else parts.joinToString(" · ")
}

@Composable
private fun ShapeCard(o: CoreTrainingLoad.Output) {
    val lanes = listOf(o.strength, o.cardio)
    if (lanes.none { it.monotony != null || it.weekOverWeek != null }) return
    LoadSection(stringResource(R.string.forge_tl_shape), stringResource(R.string.forge_tl_spread_ramp)) { ForgeCard(Modifier.fillMaxWidth()) {
        ShapeRow(Icons.Rounded.FitnessCenter, stringResource(R.string.forge_th_strength), o.strength)
        Spacer(Modifier.height(ForgeMetrics.space3))
        androidx.compose.material3.HorizontalDivider(color = Forge.colors.border.copy(alpha = 0.5f), thickness = ForgeMetrics.hairline)
        Spacer(Modifier.height(ForgeMetrics.space3))
        ShapeRow(Icons.Rounded.Favorite, stringResource(R.string.forge_tl_cardiovascular), o.cardio)
        Spacer(Modifier.height(ForgeMetrics.space3))
        Text(stringResource(R.string.forge_tl_shape_caption), style = Forge.type.caption, color = Forge.colors.textTertiary)
    }
    }
}

@Composable
private fun ShapeRow(icon: ImageVector, title: String, l: CoreTrainingLoad.Lane) {
    Row(verticalAlignment = Alignment.Top) {
        StatusBadge(icon, bandColor(l.band), 26.dp)
        Spacer(Modifier.width(ForgeMetrics.space3))
        Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(title, style = Forge.type.subhead.copy(fontWeight = FontWeight.SemiBold), color = Forge.colors.text)
            Text(shapeText(l), style = Forge.type.caption, color = Forge.colors.textSecondary)
        }
    }
}

// MARK: - Detail pages

@Composable
private fun LoadDetailPage(o: CoreTrainingLoad.Output, d: LoadDetail, onClose: () -> Unit) {
    val title = when (d) {
        LoadDetail.Adaptation -> stringResource(R.string.forge_tl_adaptation)
        LoadDetail.Recovery -> stringResource(R.string.forge_tl_recovery)
        LoadDetail.History -> stringResource(R.string.forge_tl_last_8_weeks)
        LoadDetail.Session -> stringResource(R.string.forge_tl_session_load)
        LoadDetail.Maturity -> maturityTitle(maturity(o))
        LoadDetail.Basis -> stringResource(R.string.forge_tl_rests_on)
        LoadDetail.Method -> stringResource(R.string.forge_tl_each_number)
    }
    SettingsColumn {
        PageTitle(title, onClose, trailing = {
            TextButton(onClick = onClose) {
                Text(stringResource(R.string.forge_th_done), color = Forge.colors.charge,
                     style = Forge.type.subhead.copy(fontWeight = FontWeight.SemiBold))
            }
        })
        when (d) {
            LoadDetail.Adaptation -> {
                OverlineHeader(stringResource(R.string.forge_tl_adaptation), stringResource(R.string.forge_tl_performance_evidence))
                ForgeCard(Modifier.fillMaxWidth()) {
                    AdaptationRow(Icons.Rounded.FitnessCenter, stringResource(R.string.forge_th_strength), o.strengthAdaptation)
                    Spacer(Modifier.height(ForgeMetrics.space3))
                    AdaptationRow(Icons.Rounded.Favorite, stringResource(R.string.forge_tl_cardiovascular), o.cardioAdaptation)
                    Spacer(Modifier.height(ForgeMetrics.space3))
                    Text(stringResource(R.string.forge_tl_adaptation_caption), style = Forge.type.caption, color = Forge.colors.textTertiary)
                }
            }
            LoadDetail.Recovery -> {
                OverlineHeader(stringResource(R.string.forge_tl_recovery), stringResource(R.string.forge_tl_last_seven_nights))
                ForgeCard(Modifier.fillMaxWidth()) {
                    Row(horizontalArrangement = Arrangement.spacedBy(ForgeMetrics.space2)) {
                        RecoveryTile(o, stringResource(R.string.forge_tl_hrv), Icons.Rounded.MonitorHeart, "hrv", Modifier.weight(1f))
                        RecoveryTile(o, stringResource(R.string.forge_tl_rhr), Icons.Rounded.Favorite, "rhr", Modifier.weight(1f))
                        RecoveryTile(o, stringResource(R.string.forge_tl_breathing), Icons.Rounded.Air, "respRate", Modifier.weight(1f))
                    }
                    if (o.nightsRead > 0) {
                        Spacer(Modifier.height(ForgeMetrics.space3))
                        NightsMeter(o.strainedNights, o.nightsRead, o.recoveryNights)
                    }
                    Spacer(Modifier.height(ForgeMetrics.space3))
                    Text(recoverySummary(o), style = Forge.type.caption, color = Forge.colors.textSecondary)
                }
            }
            LoadDetail.History -> {
                OverlineHeader(stringResource(R.string.forge_tl_last_8_weeks), stringResource(R.string.forge_tl_status_history))
                ForgeCard(Modifier.fillMaxWidth()) {
                    LoadRatioChart(o.ratios.map { it.day }, o.ratios.map { it.strength }, o.ratios.map { it.cardio })
                    Spacer(Modifier.height(ForgeMetrics.space3))
                    StatusHistoryStrip(o.history.map { Triple(it.day, it.strength, it.cardio) })
                    Spacer(Modifier.height(ForgeMetrics.space3))
                    Text(stringResource(R.string.forge_tl_history_caption), style = Forge.type.caption, color = Forge.colors.textTertiary)
                }
            }
            LoadDetail.Session -> {
                OverlineHeader(stringResource(R.string.forge_tl_session_load), stringResource(R.string.forge_tl_your_rating))
                val s = o.session
                TintedCard(TrainingTint.cyan) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Icon(Icons.Rounded.HowToReg, contentDescription = null, tint = TrainingTint.cyan)
                        Spacer(Modifier.width(ForgeMetrics.space2))
                        Text(stringResource(R.string.forge_tl_session_load), style = Forge.type.headline,
                             color = Forge.colors.text, modifier = Modifier.weight(1f))
                        s.percent?.let {
                            Text(signedPercent(it), style = numberStyle(Forge.type.heroNumber, 18),
                                 color = if (abs(it) < 15) Forge.colors.textSecondary else TrainingTint.cyan)
                        }
                    }
                    Text(sessionText(s), style = numberStyle(Forge.type.heroNumber, 28), color = Forge.colors.text)
                    Text(s.percent?.let { comparison(it) } ?: stringResource(R.string.forge_tl_needs_two_weeks),
                         style = Forge.type.subhead, color = Forge.colors.textSecondary)
                    Text(if (s.possibleCount > 0) stringResource(R.string.forge_tl_session_coverage, s.measuredCount, s.possibleCount)
                         else stringResource(R.string.forge_tl_session_coverage_none),
                         style = Forge.type.caption, color = Forge.colors.textTertiary)
                }
            }
            LoadDetail.Maturity -> Text(maturityDetail(maturity(o)), style = Forge.type.body, color = Forge.colors.textSecondary)
            LoadDetail.Basis -> ForgeCard(Modifier.fillMaxWidth()) {
                BasisRow(Icons.Rounded.FitnessCenter, share(o.strength), o.trustedShare, strengthCoverage(o))
                Spacer(Modifier.height(ForgeMetrics.space3))
                BasisRow(Icons.Rounded.Favorite, share(o.cardio), o.trustedShare, cardioCoverage(o.cardio))
            }
            LoadDetail.Method -> ForgeCard(Modifier.fillMaxWidth()) {
                listOf(R.string.forge_tl_strength_load to R.string.forge_tl_method_strength,
                       R.string.forge_tl_cardiovascular_load to R.string.forge_tl_method_cardio,
                       R.string.forge_tl_session_load to R.string.forge_tl_method_session,
                       R.string.forge_tl_how_comparison to R.string.forge_tl_method_comparison,
                       R.string.forge_tl_load_adaptation to R.string.forge_tl_method_adaptation,
                       R.string.forge_tl_sources to R.string.forge_tl_method_sources).forEachIndexed { i, (t, d) ->
                    if (i > 0) {
                        Spacer(Modifier.height(ForgeMetrics.space3))
                        androidx.compose.material3.HorizontalDivider(color = Forge.colors.border.copy(alpha = 0.5f),
                                                                    thickness = ForgeMetrics.hairline)
                        Spacer(Modifier.height(ForgeMetrics.space3))
                    }
                    Text(stringResource(t), style = Forge.type.headline, color = Forge.colors.text)
                    Spacer(Modifier.height(4.dp))
                    Text(stringResource(d), style = Forge.type.subhead, color = Forge.colors.textSecondary)
                }
            }
        }
    }
}

@Composable
private fun AdaptationRow(icon: ImageVector, title: String, state: String) {
    val (glyph, text, color) = adaptation(state)
    Row(verticalAlignment = Alignment.CenterVertically) {
        StatusBadge(icon, color, 30.dp)
        Spacer(Modifier.width(ForgeMetrics.space3))
        Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(title, style = Forge.type.subhead.copy(fontWeight = FontWeight.SemiBold), color = Forge.colors.text)
            Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(glyph, contentDescription = null, tint = color, modifier = Modifier.size(12.dp))
                Spacer(Modifier.width(4.dp))
                Text(text, style = Forge.type.caption, color = color)
            }
        }
    }
}

@Composable
private fun RecoveryTile(o: CoreTrainingLoad.Output, title: String, icon: ImageVector, key: String, modifier: Modifier) {
    val read = key in o.readOnLatestNight
    val flagging = key in o.flaggingOnLatestNight
    val color = if (!read) Forge.colors.textTertiary else if (flagging) TrainingTint.warning else TrainingTint.positive
    val state = stringResource(if (!read) R.string.forge_tl_no_data else if (flagging) R.string.forge_tl_flagging else R.string.forge_tl_normal)
    Column(modifier.background(color.copy(alpha = if (read) 0.13f else 0.05f), RoundedCornerShape(16.dp))
               .padding(vertical = ForgeMetrics.space3),
           horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(6.dp)) {
        if (read) StatusBadge(icon, color, 44.dp)
        else Box(Modifier.size(44.dp).background(Forge.colors.inset, CircleShape), contentAlignment = Alignment.Center) {
            Icon(icon, contentDescription = null, tint = Forge.colors.textTertiary, modifier = Modifier.size(20.dp))
        }
        Text(title, style = Forge.type.caption.copy(fontWeight = FontWeight.SemiBold), color = Forge.colors.text, maxLines = 1)
        Text(state, style = Forge.type.caption, color = Forge.colors.textSecondary)
    }
}

@Composable
private fun BasisRow(icon: ImageVector, share: Double?, trusted: Double, text: String) {
    val color = share?.let { if (it >= trusted) TrainingTint.positive else TrainingTint.warning } ?: Forge.colors.textTertiary
    Row(verticalAlignment = Alignment.CenterVertically) {
        CoverageRing(share ?: 0.0, color, icon)
        Spacer(Modifier.width(ForgeMetrics.space3))
        Text(text, style = Forge.type.subhead, color = Forge.colors.textSecondary)
    }
}

/** How much of the effort weighting is measured (`strengthCoverage`), counted rather than a percentage. */
@Composable
private fun strengthCoverage(o: CoreTrainingLoad.Output): String {
    val l = o.strength
    if (l.possibleCount <= 0) return stringResource(R.string.forge_tl_cov_no_sets)
    return when {
        l.measuredCount == l.possibleCount -> stringResource(R.string.forge_tl_cov_all_sets, l.possibleCount)
        l.measuredCount.toDouble() / l.possibleCount < o.trustedShare ->
            stringResource(R.string.forge_tl_cov_few_sets, l.measuredCount, l.possibleCount)
        else -> stringResource(R.string.forge_tl_cov_some_sets, l.measuredCount, l.possibleCount)
    }
}

@Composable
private fun cardioCoverage(l: CoreTrainingLoad.Lane): String = when {
    l.possibleCount <= 0 -> stringResource(R.string.forge_tl_cov_no_cardio)
    l.measuredCount < l.possibleCount -> stringResource(R.string.forge_tl_cov_partial_cardio, l.measuredCount, l.possibleCount)
    else -> stringResource(R.string.forge_tl_cov_all_cardio, l.possibleCount)
}
