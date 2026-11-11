package com.noop.ui.forge

import com.noop.R
import com.noop.analytics.CyclePhaseEngine
import com.noop.core.CoreCycle
import com.noop.data.CycleLogStore
import com.noop.data.DailyMetric
import java.time.LocalDate
import java.time.temporal.ChronoUnit

/**
 * Fork (DX23876), Forge parity 2026-11: the cycle page's model, as iOS `ForgeCycleSnapshot`, `ForgeCyclePhase`,
 * `ForgeCycleTopic` and `ForgeCyclePush`. Everything the page draws is worked out once from the engine's result, the
 * logged starts and days and the nights; nothing here is a new estimate. Awareness only. Analysis migration required:
 * no.
 */
internal enum class CyclePhase(val title: Int, val short: Int) {
    Period(R.string.forge_cy_period, R.string.forge_cy_period),
    Follicular(R.string.forge_cy_follicular_phase, R.string.forge_cy_short_follicular),
    Shift(R.string.forge_cy_mid_cycle_shift, R.string.forge_cy_short_shift),
    Luteal(R.string.forge_cy_luteal_phase, R.string.forge_cy_short_luteal);

    /** `CycleTrainingPattern.Phase`; the shift has none. */
    val patternKey: String? get() = when (this) { Period -> "period"; Follicular -> "follicular"; Luteal -> "luteal"; Shift -> null }
}

/** The three cards a phase shows, with the general reads iOS `ForgeCycleTopic` gives. */
internal enum class CycleTopic(val title: Int) {
    Mind(R.string.forge_cy_topic_mind), Exercise(R.string.forge_cy_topic_exercise), Body(R.string.forge_cy_topic_body);

    fun summary(p: CyclePhase): Int = when (p to this) {
        CyclePhase.Period to Mind -> R.string.forge_cy_energy_and_mood_often_dip
        CyclePhase.Period to Exercise -> R.string.forge_cy_gentle_movement_eases_period_pain
        CyclePhase.Period to Body -> R.string.forge_cy_your_nights_cool_back_to
        CyclePhase.Follicular to Mind -> R.string.forge_cy_many_people_feel_steadier_in
        CyclePhase.Follicular to Exercise -> R.string.forge_cy_nothing_the_cycle_explains_holds
        CyclePhase.Follicular to Body -> R.string.forge_cy_your_nights_run_at_your
        CyclePhase.Shift to Mind -> R.string.forge_cy_most_people_notice_nothing_special
        CyclePhase.Shift to Exercise -> R.string.forge_cy_no_change_needed_train_as
        CyclePhase.Shift to Body -> R.string.forge_cy_your_nightly_temperature_has_started
        CyclePhase.Luteal to Mind -> R.string.forge_cy_in_the_days_before_your
        CyclePhase.Luteal to Exercise -> R.string.forge_cy_studies_find_only_small_differences
        else -> R.string.forge_cy_your_nights_run_warmer_and
    }

    fun more(p: CyclePhase): Int = when (p to this) {
        CyclePhase.Period to Mind -> R.string.forge_cy_warmth_rest_and_gentle_movement
        CyclePhase.Period to Exercise -> R.string.forge_cy_heavy_periods_can_leave_you
        CyclePhase.Period to Body -> R.string.forge_cy_the_drop_in_temperature_is
        CyclePhase.Follicular to Mind -> R.string.forge_cy_notice_what_you_feel_rather
        CyclePhase.Follicular to Exercise -> R.string.forge_cy_training_plans_built_on_cycle
        CyclePhase.Follicular to Body -> R.string.forge_cy_these_nights_are_the_reference
        CyclePhase.Shift to Mind -> R.string.forge_cy_some_feel_a_brief_pull
        CyclePhase.Shift to Exercise -> R.string.forge_cy_nothing_in_the_research_calls
        CyclePhase.Shift to Body -> R.string.forge_cy_the_rise_usually_follows_ovulation
        CyclePhase.Luteal to Mind -> R.string.forge_cy_breathing_exercises_daylight_and_regular
        CyclePhase.Luteal to Exercise -> R.string.forge_cy_hard_sessions_may_feel_a
        else -> R.string.forge_cy_charge_reads_hrv_and_resting
    }

    /** The studies a card stands on; the Exercise card in the period adds the one on period pain. */
    fun sources(p: CyclePhase): List<Int> = when (this) {
        Mind -> listOf(R.string.forge_cy_baker_and_lee_2018_sleep)
        Exercise -> listOfNotNull(R.string.forge_cy_mcnulty_and_colleagues_2020_sports,
                                  if (p == CyclePhase.Period) R.string.forge_cy_armour_and_colleagues_2019_cochrane else null)
        Body -> listOf(R.string.forge_cy_schmalenberger_and_colleagues_2019_journal)
    }
}

/** One localisable line: a string resource and its arguments. */
internal data class CycleText(val res: Int, val args: List<Any> = emptyList())

/** iOS `ForgeCyclePush`: the one-line answer the Mind and Exercise cards lead with, and the tone it is drawn in. */
internal data class CyclePush(val headline: CycleText, val reason: List<CycleText>, val tone: Tone) {
    enum class Tone { Period, Follicular, Shift, Rest, Effort, Charge, Text }

    companion object {
        fun make(topic: CycleTopic, phase: CyclePhase, charge: Double?, pattern: CoreCycle.Pattern?): CyclePush? = when (topic) {
            CycleTopic.Body -> null
            CycleTopic.Mind -> mind(phase)
            CycleTopic.Exercise -> exercise(phase, charge, pattern)
        }

        private fun mind(p: CyclePhase) = when (p) {
            CyclePhase.Period -> CyclePush(CycleText(R.string.forge_cy_energy_may_be_lower_today),
                listOf(CycleText(R.string.forge_cy_common_in_the_first_days)), Tone.Period)
            CyclePhase.Follicular -> CyclePush(CycleText(R.string.forge_cy_usually_steadier_days),
                listOf(CycleText(R.string.forge_cy_a_good_stretch_for_things)), Tone.Follicular)
            CyclePhase.Shift -> CyclePush(CycleText(R.string.forge_cy_usually_nothing_to_notice),
                listOf(CycleText(R.string.forge_cy_a_few_people_feel_a)), Tone.Shift)
            CyclePhase.Luteal -> CyclePush(CycleText(R.string.forge_cy_mood_and_sleep_may_dip),
                listOf(CycleText(R.string.forge_cy_common_before_a_period_keep)), Tone.Rest)
        }

        private fun exercise(p: CyclePhase, charge: Double?, pattern: CoreCycle.Pattern?): CyclePush {
            val verdict = p.patternKey?.let { pattern?.verdicts?.get(it) }
            if (verdict?.kind == "harder") {
                return CyclePush(CycleText(R.string.forge_cy_take_it_a_bit_easier),
                                 listOf(harderReason(verdict, pattern!!.rpeThreshold)), Tone.Effort)
            }
            val chargeText = charge?.let { CycleText(R.string.forge_cy_charge_n, listOf(Math.round(it).toInt())) }
            return when (charge?.let { ChargeBand.of(it) }) {
                ChargeBand.Primed, ChargeBand.Peak -> {
                    val why = when (verdict?.kind) {
                        "easier" -> R.string.forge_cy_your_sessions_in_this_phase_2
                        "noDifference" -> R.string.forge_cy_your_cycle_makes_no_clear
                        else -> R.string.forge_cy_nothing_in_your_cycle_holds
                    }
                    CyclePush(CycleText(R.string.forge_cy_good_day_to_push), listOfNotNull(chargeText, CycleText(why)), Tone.Charge)
                }
                ChargeBand.Moderate -> CyclePush(CycleText(R.string.forge_cy_train_as_planned),
                    listOfNotNull(chargeText, CycleText(R.string.forge_cy_keep_the_hardest_sets_for)), Tone.Text)
                ChargeBand.Low, ChargeBand.Depleted -> CyclePush(CycleText(R.string.forge_cy_keep_it_easy_today),
                    listOfNotNull(chargeText, CycleText(R.string.forge_cy_your_body_is_still_recovering)), Tone.Effort)
                null -> CyclePush(CycleText(R.string.forge_cy_train_by_feel), listOf(CycleText(R.string.forge_cy_no_charge_yet_today)), Tone.Text)
            }
        }

        /** The harder reason: the rating gap when it crosses the threshold, else the volume drop in whole percent. */
        fun harderReason(v: CoreCycle.Verdict, threshold: Double): CycleText {
            val rpe = v.rpeDelta
            if (rpe != null && rpe >= threshold) return CycleText(R.string.forge_cy_in_this_phase_your_sessions, listOf(String.format(java.util.Locale.getDefault(), "%.1f", rpe)))
            return CycleText(R.string.forge_cy_in_this_phase_you_lifted, listOf(Math.round((v.volumeDrop ?: 0.0) * 100).toInt()))
        }

        /** The "In your data" line for the Exercise page: the pattern, or how far the learning has come. */
        fun patternLine(pattern: CoreCycle.Pattern?, phase: CyclePhase): CycleText? {
            pattern ?: return null
            val key = phase.patternKey ?: return null
            val v = pattern.verdicts[key] ?: return null
            return when (v.kind) {
                "harder" -> harderReason(v, pattern.rpeThreshold)
                "easier" -> CycleText(R.string.forge_cy_your_sessions_in_this_phase)
                "noDifference" -> CycleText(R.string.forge_cy_your_cycle_makes_no_clear)
                else -> CycleText(R.string.forge_cy_still_learning_your_pattern_n, listOf(
                    minOf(pattern.progressCycles, pattern.minCycles), pattern.minCycles,
                    minOf(pattern.progressRated, pattern.minSessionsPerPhase), pattern.minSessionsPerPhase))
            }
        }
    }
}

/** iOS `ForgeCycleSnapshot`: everything the page draws, from the engine's result, the logged starts and days and the nights. */
internal data class CycleSnapshot(
    val cycleDay: Int?,
    val dayRange: IntRange?,
    val length: Int,
    val phase: CyclePhase?,
    val shiftDay: Int?,
    val periodLength: Int,
    /** The likely next-period window, in days from today. */
    val nextWindow: IntRange?,
    val startDate: LocalDate?,
    val periodDays: Set<String>,
    val cyclesSeen: Int,
    val engineConfidence: CyclePhaseEngine.Confidence?,
    val temps: List<Pair<Int, Double>> = emptyList(),
    val compare: Compare? = null,
    val moodsThisPhase: Map<String, Int> = emptyMap(),
    val fertile: CoreCycle.Fertile? = null,
    val fertileDays: Set<String> = emptySet(),
) {
    /** This cycle's luteal nights against its first half, for the Body, Exercise and Mind cards. */
    data class Compare(val tempDelta: Double?, val rhrDelta: Double?, val hrvDelta: Double?, val chargeNow: Double?,
                       val chargeBefore: Double?, val wakeNow: Double?, val wakeBefore: Double?)

    val wheelDays: Int get() = minOf(45, maxOf(length, cycleDay ?: 0, (cycleDay ?: 0) + (nextWindow?.last ?: 0)))
    val todayOnWheel: Int? get() = cycleDay ?: dayRange?.let { (it.first + it.last) / 2 }
    val tempFloor: Double get() = minOf(-0.4, (temps.minOfOrNull { it.second } ?: 0.0) - 0.1)
    val tempCeiling: Double get() = maxOf(0.5, (temps.maxOfOrNull { it.second } ?: 0.0) + 0.1)

    fun isFertile(day: Int): Boolean = fertile?.let { day in it.firstDay..it.lastDay } ?: false

    val cycleDayText: CycleText get() = when {
        cycleDay != null -> CycleText(R.string.forge_cy_day_n, listOf(cycleDay))
        dayRange != null -> CycleText(R.string.forge_cy_day_n_to_n, listOf(dayRange.first, dayRange.last))
        else -> CycleText(R.string.forge_cy_day_unknown)
    }

    val nextLine: CycleText? get() {
        val w = nextWindow ?: return null
        return when {
            w.last <= 0 -> CycleText(R.string.forge_cy_period_likely_any_day_now)
            w.first <= 0 -> CycleText(R.string.forge_cy_period_likely_within_n_days, listOf(w.last))
            else -> CycleText(R.string.forge_cy_period_likely_in_n_to, listOf(w.first, w.last))
        }
    }

    val historyLine: CycleText get() =
        if (cyclesSeen > 1) CycleText(R.string.forge_cy_n_cycles_logged, listOf(cyclesSeen)) else CycleText(R.string.forge_cy_every_period_start_you_logged)

    /** The status line under the dial and on the cards: a title and an optional detail. */
    val fertileLine: Pair<CycleText, CycleText?>? get() = when (fertile?.status) {
        "before" -> {
            val n = fertile.daysUntil ?: 0
            (if (n == 1) CycleText(R.string.forge_cy_likely_fertile_from_tomorrow)
             else CycleText(R.string.forge_cy_n_days_until_your_likely, listOf(n))) to null
        }
        "during" -> CycleText(R.string.forge_cy_likely_fertile_today) to
            CycleText(R.string.forge_cy_day_n_of_n, listOf(fertile.day ?: 0, fertile.of ?: 0))
        "over" -> CycleText(R.string.forge_cy_fertile_days_are_over) to shiftDay?.let { CycleText(R.string.forge_cy_rise_on_day_n, listOf(it)) }
        else -> null
    }

    /** The first likely fertile day as a date while it still lies ahead; what the reminder arms. */
    val fertileStartAhead: LocalDate? get() =
        if (fertile?.status == "before" && startDate != null) startDate.plusDays((fertile.firstDay - 1).toLong()) else null

    /** The phase colour of one day of this cycle on the dial. */
    fun phase(onDay: Int): CyclePhase? {
        if (onDay <= periodLength && cycleDay != null) return CyclePhase.Period
        val shift = shiftDay ?: return if (todayOnWheel?.let { onDay <= it } == true) CyclePhase.Follicular else null
        return when {
            onDay < shift - 1 -> CyclePhase.Follicular
            onDay <= shift + 1 -> CyclePhase.Shift
            else -> CyclePhase.Luteal
        }
    }

    companion object {
        const val DEFAULT_CYCLE_DAYS = CyclePhaseEngine.defaultCycleDays

        private fun date(key: String): LocalDate? = runCatching { LocalDate.parse(key) }.getOrNull()
        private fun diff(a: LocalDate, b: LocalDate): Int = ChronoUnit.DAYS.between(a, b).toInt()

        /**
         * [fertile] asks the shared `FertileWindow` (past rise days, this cycle's rise, the positive test day, the
         * cycle day); null when fertile days are hidden.
         */
        fun make(result: CyclePhaseEngine.Result?, starts: List<String>, log: Map<String, CycleLogStore.Day>,
                 days: List<DailyMetric>, today: LocalDate,
                 fertile: ((List<Int>, Int?, Int?, Int?) -> CoreCycle.Fertile?)? = null): CycleSnapshot {
            val startDates = starts.mapNotNull(::date).sorted()
            // The current cycle runs from the newest logged start, if it is recent enough to still be this cycle.
            val current = startDates.filter { !it.isAfter(today) }.maxOrNull()?.takeIf { diff(it, today) <= 45 }
            val cycleDay = current?.let { diff(it, today) + 1 }
            // The usual length: the engine's, else the median gap between logged starts, else the default.
            val gaps = startDates.zipWithNext { a, b -> diff(a, b) }.filter { it in 21..40 }.sorted()
            val length = result?.cycleLengthDays ?: if (gaps.isEmpty()) DEFAULT_CYCLE_DAYS else gaps[gaps.size / 2]
            // Period days: from each start, the days with flow logged, else the first five.
            val periodDays = mutableSetOf<String>()
            fun window(s: LocalDate) = (0 until 10).map { s.plusDays(it.toLong()).toString() }
            for (s in startDates) {
                val w = window(s)
                val n = maxOf((w.indices.filter { log[w[it]]?.flow != null }.maxOrNull()?.plus(1)) ?: 5, 1)
                w.take(n).forEach { periodDays += it }
            }
            log.forEach { (k, d) -> if (d.flow != null) periodDays += k }
            var periodLength = 5
            if (current != null) {
                val w = window(current)
                w.indices.filter { log[w[it]]?.flow != null }.maxOrNull()?.let { periodLength = it + 1 }
            }
            // The engine's shift marker inside this cycle, as a cycle day.
            val shiftDay = current?.let { start ->
                result?.shiftMarkers?.mapNotNull { date(it.day) }?.filter { it.isAfter(start) && !it.isAfter(today) }
                    ?.maxOrNull()?.let { diff(start, it) + 1 }
            }
            // The phase: the logged period first (the wearer's own fact), then this cycle's rise, then the engine.
            val phase = when {
                cycleDay != null && cycleDay <= periodLength -> CyclePhase.Period
                cycleDay != null && shiftDay != null ->
                    if (cycleDay < shiftDay - 1) CyclePhase.Follicular else if (cycleDay <= shiftDay + 1) CyclePhase.Shift else CyclePhase.Luteal
                else -> when (result?.phase) {
                    CyclePhaseEngine.Phase.FOLLICULAR -> CyclePhase.Follicular
                    CyclePhaseEngine.Phase.PERI_OVULATORY -> CyclePhase.Shift
                    CyclePhaseEngine.Phase.LUTEAL -> CyclePhase.Luteal
                    else -> null
                }
            }
            val nextWindow = result?.nextPeriodWindow?.let { w ->
                val a = date(w.earliestDay); val b = date(w.latestDay)
                if (a == null || b == null) null else diff(today, a).let { lo -> diff(today, b).let { hi -> if (hi < lo) null else lo..hi } }
            }
            val dayRange = result?.cycleDayLow?.let { lo -> result.cycleDayHigh?.let { lo..maxOf(lo, it) } }
            var snap = CycleSnapshot(cycleDay, dayRange, length, phase, shiftDay, periodLength, nextWindow, current, periodDays,
                                     starts.size, result?.confidence)
            if (current != null) {
                val byDay = days.associateBy { it.day }
                val nights = (0 until (cycleDay ?: 0)).mapNotNull { offset ->
                    byDay[current.plusDays(offset.toLong()).toString()]?.let { offset + 1 to it }
                }
                snap = snap.copy(temps = nights.mapNotNull { (d, m) -> m.skinTempDevC?.let { d to it } })
                if (shiftDay != null && phase == CyclePhase.Luteal) {
                    val before = nights.filter { it.first > periodLength && it.first < shiftDay - 1 }.map { it.second }
                    val after = nights.filter { it.first > shiftDay + 1 }.map { it.second }
                    fun mean(xs: List<Double>): Double? = if (xs.size >= 3) xs.average() else null
                    fun delta(f: (DailyMetric) -> Double?): Double? {
                        val a = mean(after.mapNotNull(f)) ?: return null
                        val b = mean(before.mapNotNull(f)) ?: return null
                        return a - b
                    }
                    val moods = mutableMapOf<String, Int>()
                    nights.filter { it.first > shiftDay + 1 }.forEach { (_, m) ->
                        log[m.day]?.moods?.forEach { moods[it] = (moods[it] ?: 0) + 1 }
                    }
                    snap = snap.copy(
                        compare = Compare(delta { it.skinTempDevC }, delta { it.restingHr?.toDouble() }, delta { it.avgHrv },
                                          mean(after.mapNotNull { it.recovery }), mean(before.mapNotNull { it.recovery }),
                                          mean(after.mapNotNull { it.disturbances?.toDouble() }),
                                          mean(before.mapNotNull { it.disturbances?.toDouble() })),
                        moodsThisPhase = moods)
                }
            }
            if (fertile != null && current != null && cycleDay != null) {
                // The rise days of completed past cycles, newest first, then this cycle's own rise or test.
                val pastRises = cycles(starts, log, result).sortedByDescending { it.start }.drop(1).mapNotNull { c ->
                    val a = date(c.start); val b = c.shift?.let(::date)
                    if (a == null || b == null) null else diff(a, b) + 1
                }
                val testDay = (0 until cycleDay).firstOrNull { log[current.plusDays(it.toLong()).toString()]?.ovulationTest == true }?.plus(1)
                fertile(pastRises, shiftDay, testDay, cycleDay)?.let { e ->
                    snap = snap.copy(fertile = e,
                        fertileDays = (e.firstDay..e.lastDay).map { current.plusDays((it - 1).toLong()).toString() }.toSet())
                }
            }
            return snap
        }

        /** Every logged cycle with the temperature rise the engine found inside it, for the training pattern. */
        fun cycles(starts: List<String>, log: Map<String, CycleLogStore.Day>, result: CyclePhaseEngine.Result?): List<CoreCycle.Cycle> {
            val sorted = starts.sorted()
            val shifts = result?.shiftMarkers?.map { it.day }?.sorted().orEmpty()
            return sorted.mapIndexed { i, start ->
                val end = sorted.getOrNull(i + 1) ?: "9999-12-31"
                val shift = shifts.firstOrNull { it > start && it < end }
                val s = date(start)
                val flowed = s?.let { d -> (0 until 10).filter { log[d.plusDays(it.toLong()).toString()]?.flow != null }.maxOrNull() }
                CoreCycle.Cycle(start, shift, flowed?.plus(1) ?: 5)
            }
        }
    }
}
