package com.noop.analytics

import com.noop.data.DailyMetric

/*
 * ChargeBaselines.kt — which nights the Charge baselines are folded from (#2525).
 *
 * Charge scores a night against personal baselines for HRV, resting HR, respiration and skin
 * temperature. Before #2525 those baselines were folded from the WHOLE imported vendor history plus only
 * the nights of the current scan window (21 by default). The wearer's own older nights dropped out on
 * every pass while the import never did, so an import kept roughly a third of the weight for good, pinned
 * to the wearer's state at the end of their subscription however old that was.
 *
 * The rule here is a correction of which nights count, not a new scoring method:
 *   - Only nights inside a fixed calendar window ([ChargeBaselines.windowDays], counted back from the anchor
 *     day) count. The window is the scan window's own 21 days, so a wearer with no import folds exactly the
 *     nights the 21-day pass always folded; what changes is that an imported night ages out like an own
 *     one, and that a full-history repair pass folds the same 21 days instead of the whole history.
 *   - The wearer's own (NOOP-computed) nights are the baseline. Imported vendor nights only SEED it: they
 *     take part while the own nights alone would not yet make a trusted baseline (`handoffNights`, the
 *     model's own `minNightsTrust`), and drop out entirely once they would. The two sources are different
 *     algorithms, so they are never mixed past the cold start.
 *   - The rule keeps no state. Every call decides from the nights it is given.
 *
 * Pure and Context-free; the engine feeds it this pass's fresh values, the dashboard the stored rows.
 * Byte-identical twin of the Swift `ChargeBaselines`.
 */
object ChargeBaselines {

    /**
     * Calendar days of nightly history a Charge baseline reads, counted back from the anchor day and
     * including it. Deliberately the default scan window (`analyzeRecent(maxDays = 21)`), so the own nights a
     * baseline reads are the ones the pass has just scored, and nothing changes for a wearer with no import.
     */
    const val windowDays: Int = 21

    /**
     * One metric's nightly history for a Charge baseline, oldest first, ready for
     * [Baselines.foldHistory] with day keys, plus the counts the diagnostic line reports.
     */
    data class History(
        /** `yyyy-MM-dd` keys, ascending, parallel to [values]. */
        val dayKeys: List<String>,
        /** The nightly values; null is a night that exists but carried no value (skip-and-hold). */
        val values: List<Double?>,
        /** True while imported vendor nights still take part (the own nights are not yet trusted on their
         *  own and the window holds at least one imported night). */
        val seededByImport: Boolean,
        /** Valid own nights on or after the epoch inside the window: the count the handoff is decided on. */
        val ownValidNights: Int,
        /** Imported nights this history carries (0 once the own nights have taken over). */
        val importedNights: Int,
    )

    /**
     * Build one metric's Charge history from the imported and own nights (#2525).
     *
     * [imported] are imported vendor nights as `(day, value)`; a null value is a night the import covers
     * without that metric. [own] are NOOP-computed nights, same shape. A repeated day keeps its last value in
     * either list. [anchorDay] is the `yyyy-MM-dd` day the window ends on (the scoring pass's local today).
     * [cfg] counts the valid own nights exactly as the fold will. [baselineEpoch] is the epoch (seconds) the
     * caller's fold will drop earlier nights by: the manual recalibration epoch, or a later device-era cut.
     * Own nights before it do not count toward the handoff, because the fold will not use them.
     * [handoffNights] is the valid own-night count at which the imported nights stop taking part.
     *
     * Days are filtered with pure civil-day arithmetic (no time zone), keeping only days on or before the
     * anchor and fewer than [windowDays] days before it. An unparseable key is dropped; an unparseable anchor
     * yields an empty history, so a caller can only ever under-state a baseline, never read one from nights it
     * cannot place. While seeding, an imported value wins a day both sources cover; an own night fills a day
     * the import does not cover or covers without a value (the precedence of the dashboard's `mergeDaily` and
     * of the engine merge before #2525, so a blank imported row can never shadow a night the strap measured).
     * Swift twin: `ChargeBaselines.history`.
     */
    fun history(
        imported: List<Pair<String, Double?>>,
        own: List<Pair<String, Double?>>,
        anchorDay: String,
        cfg: MetricCfg,
        baselineEpoch: Double,
        windowDays: Int = ChargeBaselines.windowDays,
        handoffNights: Int = Baselines.minNightsTrust,
    ): History {
        val empty = History(emptyList(), emptyList(), seededByImport = false, ownValidNights = 0, importedNights = 0)
        if (windowDays <= 0) return empty
        val anchor = Baselines.isoEpochDay(anchorDay) ?: return empty
        val inWindow = { day: String ->
            val d = Baselines.isoEpochDay(day)
            d != null && d <= anchor && anchor - d < windowDays
        }

        val ownByDay = HashMap<String, Double?>()
        for ((day, value) in own) if (inWindow(day)) ownByDay[day] = value
        val ownKeys = ownByDay.keys.sorted()
        val ownValues = ownKeys.map { ownByDay.getValue(it) }
        val ownValid = Baselines.foldHistory(ownValues, ownKeys, cfg, baselineEpoch).nValid

        val importedByDay = HashMap<String, Double?>()
        for ((day, value) in imported) if (inWindow(day)) importedByDay[day] = value

        // Handed off, or nothing to seed with: the own nights are the whole history.
        if (ownValid >= handoffNights || importedByDay.isEmpty()) {
            return History(ownKeys, ownValues, seededByImport = false, ownValidNights = ownValid, importedNights = 0)
        }

        // Seeding: every imported night in the window, then the own nights on the days it leaves open. An
        // imported night without a value leaves its day open too (`merged[day]` is null for an absent key and
        // for a null value alike), and the own night fills it. An own night without a value still registers
        // the day (a missing night), exactly as it would with no import. Mirrors Swift.
        val merged = HashMap<String, Double?>(importedByDay)
        for ((day, value) in ownByDay) {
            if (merged[day] != null) continue // an imported value wins
            merged[day] = value
        }
        val keys = merged.keys.sorted()
        return History(
            keys, keys.map { merged.getValue(it) }, seededByImport = true,
            ownValidNights = ownValid, importedNights = importedByDay.size,
        )
    }

    /**
     * The Charge baselines the dashboard reads, resolved from the stored daily rows with the same rule the
     * engine's pass-2 fold applies (#2525), so the "What shaped it" rows, the calibration count and the
     * confidence tier describe the baseline the Charge headline was scored against.
     */
    data class Resolved(
        val hrvHistory: History,
        val restingHRHistory: History,
        val respHistory: History,
        val hrv: BaselineState,
        val restingHR: BaselineState,
        val resp: BaselineState,
    )

    /**
     * Resolve HRV, resting-HR and respiration baselines from stored rows: [imported] are the imported vendor
     * rows, [own] the NOOP-computed ("-noop") rows. HRV folds on [hrvEpoch], resting HR and respiration on
     * [recoveryEpoch], exactly as the engine does. The engine additionally cuts respiration at a device-era
     * boundary (#459), which needs a per-night source the stored rows do not carry; the two agree for every
     * single-brand history. Swift twin: `ChargeBaselines.resolve`.
     */
    fun resolve(
        imported: List<DailyMetric>,
        own: List<DailyMetric>,
        anchorDay: String,
        hrvEpoch: Double,
        recoveryEpoch: Double,
    ): Resolved {
        val hrvCfg = Baselines.hrvCfg
        val rhrCfg = Baselines.restingHRCfg
        val respCfg = Baselines.respCfg
        val hrvHistory = history(
            imported.map { it.day to it.avgHrv }, own.map { it.day to it.avgHrv },
            anchorDay, hrvCfg, hrvEpoch,
        )
        val rhrHistory = history(
            imported.map { it.day to it.restingHr?.toDouble() }, own.map { it.day to it.restingHr?.toDouble() },
            anchorDay, rhrCfg, recoveryEpoch,
        )
        val respHistory = history(
            imported.map { it.day to it.respRateBpm }, own.map { it.day to it.respRateBpm },
            anchorDay, respCfg, recoveryEpoch,
        )
        return Resolved(
            hrvHistory = hrvHistory,
            restingHRHistory = rhrHistory,
            respHistory = respHistory,
            hrv = Baselines.foldHistory(hrvHistory.values, hrvHistory.dayKeys, hrvCfg, hrvEpoch),
            restingHR = Baselines.foldHistory(rhrHistory.values, rhrHistory.dayKeys, rhrCfg, recoveryEpoch),
            resp = Baselines.foldHistory(respHistory.values, respHistory.dayKeys, respCfg, recoveryEpoch),
        )
    }

    /**
     * The Recovery test-mode line naming what each Charge baseline was folded from this pass. Per metric,
     * `own/N` means the own nights alone, N of them valid; `seed/N+M` means N valid own nights still seeded by
     * M imported nights. It reports only the composition the engine decided, not why the wearer's values
     * moved. Swift twin: `ChargeBaselines.logLine`, byte-identical.
     */
    fun logLine(
        anchorDay: String,
        hrv: History,
        restingHR: History,
        resp: History,
        skin: History,
        windowDays: Int = ChargeBaselines.windowDays,
    ): String {
        val part = { h: History ->
            if (h.seededByImport) "seed/${h.ownValidNights}+${h.importedNights}" else "own/${h.ownValidNights}"
        }
        return "charge baseline anchor=$anchorDay window=${windowDays}d hrv=${part(hrv)} " +
            "rhr=${part(restingHR)} resp=${part(resp)} skin=${part(skin)}"
    }
}
