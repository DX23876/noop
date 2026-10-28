package com.noop.ui

import android.content.Context
import androidx.annotation.StringRes
import com.noop.R

// MARK: - Reorderable Today sections (#today-layout)
//
// The Today screen's sections — the Charge/Effort/Rest hero, the Start-session entry, Synthesis, Key
// Metrics, Workouts, Heart Rate, Recovery Vitals, Your Cards — rendered in one fixed order. This lets the
// user REORDER or HIDE them, with the default being the original order so nothing changes for anyone who
// never customizes Today. Display-only — no metric is computed or stored differently; this only decides
// which already-built sections render and in what sequence.
//
// Stored as a single comma-joined string of section keys in SharedPreferences ("today.sectionOrder"), the
// same mechanism KeyMetricPrefs/DashboardCards use. Mirrors the macOS TodayLayoutPrefs.swift +
// @AppStorage("today.sectionOrder"). Every known section stays in the order registry: unknown tokens are
// dropped, and missing known sections are inserted at their default positions. Explicit reversible
// visibility lives separately in "today.hiddenSections", byte-identical to the Apple-platform key.

/**
 * One reorderable Today section. The [raw] is the stable persisted identifier — keep it byte-identical to
 * the macOS `TodaySection` enum so a backup/restore reads the same layout on either OS.
 */
enum class TodaySection(val raw: String, @StringRes val titleRes: Int) {
    COACH("coach", R.string.forge_lay_section_coach),
    HERO("hero", R.string.today_section_hero),
    LIVE_SESSION("liveSession", R.string.today_section_live_session),
    // The raw `synthesis` is the persisted key; only the label follows the card's name, Momentum.
    SYNTHESIS("synthesis", R.string.forge_lay_section_momentum),
    /** Goals: where each one stands and what there is to tick off today, one card. */
    GOALS("goals", R.string.forge_lay_section_goals),
    KEY_METRICS("keyMetrics", R.string.today_section_key_metrics),
    /** Strength and cardio load against the wearer's usual. */
    TRAINING_LOAD("trainingLoad", R.string.forge_lay_section_training_load),
    /** Today's energy: basal, active, total burn and where the day is heading. */
    ENERGY("energy", R.string.forge_lay_section_energy),
    WORKOUTS("workouts", R.string.today_section_workouts),
    HEART_RATE("heartRate", R.string.today_section_heart_rate),
    RECOVERY_VITALS("recoveryVitals", R.string.today_section_recovery_vitals),
    YOUR_CARDS("yourCards", R.string.today_section_your_cards),
    MENSTRUAL_CYCLE("menstrualCycle", R.string.today_section_menstrual_cycle),
    JOURNAL("journal", R.string.today_section_journal),
    DATA_SOURCES("dataSources", R.string.forge_lay_section_data_sources),

    /** Cards hosted from the Trends / Sleep tabs (#today-hosted-cards). Renders the [HostedCardPrefs]
     *  selection in order; empty (and effectively invisible) until the user adds a card in Customise.
     *  Appended LAST so [decodeOrder]'s back-fill lands it predictably for existing saved orders. */
    ADDED_CARDS("addedCards", R.string.today_section_added_cards);

    companion object {
        fun fromRaw(raw: String?): TodaySection? = entries.firstOrNull { it.raw == raw }

        /** The Apple `TodaySection.defaultOrder`, so an order saved on either platform back-fills the same way.
         *  Coach leads it; the journal sits above data sources, added cards last. */
        val defaultOrder: List<TodaySection> = listOf(
            COACH, HERO, LIVE_SESSION, SYNTHESIS, GOALS, KEY_METRICS, TRAINING_LOAD, ENERGY, WORKOUTS, HEART_RATE,
            RECOVERY_VITALS, YOUR_CARDS, MENSTRUAL_CYCLE, JOURNAL, DATA_SOURCES, ADDED_CARDS,
        )
    }
}

/**
 * Display-only persistence for the Today section order and explicit hidden set. Every known section remains
 * in the order registry, while visibility is stored separately so hiding stays reversible.
 * SharedPreferences isn't reactive, so Today reads this into remembered state and refreshes it after save.
 * Mirrors the Apple-platform TodayLayoutPrefs.
 */
object TodayLayoutPrefs {
    private const val KEY_ORDER = "today.sectionOrder"
    private const val KEY_HIDDEN = "today.hiddenSections"

    /** The stored strings as written, null while unset (an unset key reads as the style's fresh default). */
    fun orderRaw(context: Context): String? = NoopPrefs.of(context).getString(KEY_ORDER, null)

    fun hiddenRaw(context: Context): String? = NoopPrefs.of(context).getString(KEY_HIDDEN, null)

    fun setRaw(context: Context, order: String, hidden: String) {
        NoopPrefs.of(context).edit().putString(KEY_ORDER, order).putString(KEY_HIDDEN, hidden).apply()
    }

    /** Every known section in display order (saved order first, then any newly-added section appended). */
    fun order(context: Context): List<TodaySection> =
        decodeOrder(NoopPrefs.of(context).getString(KEY_ORDER, null))

    /** Persist the section order. */
    fun setOrder(context: Context, sections: List<TodaySection>) {
        NoopPrefs.of(context).edit().putString(KEY_ORDER, encode(sections)).apply()
    }

    /** The explicitly hidden sections in their editor order. Empty/unset means every section is visible. */
    fun hidden(context: Context): List<TodaySection> =
        decodeHidden(NoopPrefs.of(context).getString(KEY_HIDDEN, null))

    /** Persist the explicit reversible hidden list. */
    fun setHidden(context: Context, sections: List<TodaySection>) {
        NoopPrefs.of(context).edit().putString(KEY_HIDDEN, encodeHidden(sections)).apply()
    }

    /** Encode an ordered list of sections into the stored comma-joined string. */
    fun encode(sections: List<TodaySection>): String = sections.joinToString(",") { it.raw }

    fun encodeHidden(sections: List<TodaySection>): String = sections.joinToString(",") { it.raw }

    /**
     * Decode the stored string into the FULL ordered section list. An empty/unset string yields the
     * default order. Unknown tokens are ignored, duplicates collapsed, and any known section missing from
     * the saved order is INSERTED at its default-order position relative to the saved sections (before the
     * first saved section that follows it in the default order; appended when none does) — so every
     * section always renders, and one added in a later app version surfaces where users expect it instead
     * of teleporting to the bottom of an existing saved order (the hero joined the set after the first cut).
     */
    fun decodeOrder(raw: String?): List<TodaySection> {
        val trimmed = raw?.trim().orEmpty()
        if (trimmed.isEmpty()) return TodaySection.defaultOrder
        val saved = ArrayList<TodaySection>()
        trimmed.split(",").forEach { token ->
            TodaySection.fromRaw(token.trim())?.let { if (it !in saved) saved.add(it) }
        }
        if (saved.isEmpty()) return TodaySection.defaultOrder
        // Iterate entries (not defaultOrder) so a future enum case accidentally left out of defaultOrder
        // can never be silently hidden; a section without a default index sorts after everything. Twin of
        // the Swift decodeOrder's degraded path; defaultOrder covering every entry is pinned by the tests.
        fun defIdx(s: TodaySection): Int =
            TodaySection.defaultOrder.indexOf(s).let { if (it == -1) TodaySection.defaultOrder.size else it }
        for (missing in TodaySection.entries) {
            if (missing in saved) continue
            val insertAt = saved.indexOfFirst { defIdx(it) > defIdx(missing) }
            if (insertAt == -1) saved.add(missing) else saved.add(insertAt, missing)
        }
        return saved
    }

    /**
     * Decode only explicitly hidden sections. Unknown tokens are ignored and duplicates collapsed. Missing
     * entries stay visible, so a section added by a future release automatically surfaces.
     */
    fun decodeHidden(raw: String?): List<TodaySection> {
        val hidden = LinkedHashSet<TodaySection>()
        raw?.split(",")?.forEach { token -> TodaySection.fromRaw(token.trim())?.let(hidden::add) }
        return hidden.toList()
    }

    /** The full saved order filtered by the explicit hidden set. */
    fun visibleOrder(orderRaw: String?, hiddenRaw: String?): List<TodaySection> {
        val hidden = decodeHidden(hiddenRaw).toSet()
        return decodeOrder(orderRaw).filterNot { it in hidden }
    }
}
