package com.noop.ui

import android.content.Context

// MARK: - Reorderable Today sections (#today-layout)
//
// The Today screen's below-the-hero sections (Synthesis, Key Metrics, Workouts, Heart Rate, Recovery
// Vitals, Your Cards) rendered in one fixed order. This lets the user REORDER them, with the default being
// the original order so nothing changes for anyone who never opens the editor. Display-only — no metric is
// computed or stored differently; this only decides the SEQUENCE the already-built sections render in. The
// Charge/Effort/Rest hero + intro/conditional cards stay pinned above this block.
//
// Stored as a single comma-joined string of section keys in SharedPreferences ("today.sectionOrder"), the
// same mechanism KeyMetricPrefs/DashboardCards use. Mirrors the macOS TodayLayoutPrefs.swift +
// @AppStorage("today.sectionOrder"). Every known section ALWAYS renders: unknown tokens are dropped, and
// any known section missing from the saved order is APPENDED in default-order position — so a newly-added
// section shows up rather than vanishing. This reorders, it never hides.

/**
 * One reorderable Today section (below the pinned hero). The [raw] is the stable persisted identifier —
 * keep it byte-identical to the macOS `TodaySection` enum so a backup/restore reads the same layout on
 * either OS.
 */
enum class TodaySection(val raw: String, val title: String) {
    SYNTHESIS("synthesis", "Synthesis"),
    KEY_METRICS("keyMetrics", "Key Metrics"),
    WORKOUTS("workouts", "Workouts"),
    HEART_RATE("heartRate", "Heart Rate"),
    RECOVERY_VITALS("recoveryVitals", "Recovery Vitals"),
    YOUR_CARDS("yourCards", "Your Cards");

    companion object {
        fun fromRaw(raw: String?): TodaySection? = entries.firstOrNull { it.raw == raw }

        /** The original, hard-coded section order — the default when the layout isn't customised. */
        val defaultOrder: List<TodaySection> = listOf(
            SYNTHESIS, KEY_METRICS, WORKOUTS, HEART_RATE, RECOVERY_VITALS, YOUR_CARDS,
        )
    }
}

/**
 * Display-only persistence for the Today section order. Holds the sections in display order; every known
 * section always renders (a missing one is appended), so this reorders but never hides. SharedPreferences
 * isn't reactive, so Today reads this once into remembered state (like the other prefs) and re-reads on the
 * recomposition the editor's write triggers. Mirrors the macOS TodayLayoutPrefs (@AppStorage
 * "today.sectionOrder").
 */
object TodayLayoutPrefs {
    private const val KEY_ORDER = "today.sectionOrder"

    /** Every known section in display order (saved order first, then any newly-added section appended). */
    fun order(context: Context): List<TodaySection> =
        decodeOrder(NoopPrefs.of(context).getString(KEY_ORDER, null))

    /** Persist the section order. */
    fun setOrder(context: Context, sections: List<TodaySection>) {
        NoopPrefs.of(context).edit().putString(KEY_ORDER, encode(sections)).apply()
    }

    /** Encode an ordered list of sections into the stored comma-joined string. */
    fun encode(sections: List<TodaySection>): String = sections.joinToString(",") { it.raw }

    /**
     * Decode the stored string into the FULL ordered section list. An empty/unset string yields the
     * default order. Unknown tokens are ignored, duplicates collapsed, and any known section missing from
     * the saved order is APPENDED in default-order position — so every section always renders and a newly
     * added section can never be lost.
     */
    fun decodeOrder(raw: String?): List<TodaySection> {
        val trimmed = raw?.trim().orEmpty()
        if (trimmed.isEmpty()) return TodaySection.defaultOrder
        val seen = LinkedHashSet<TodaySection>()
        trimmed.split(",").forEach { token ->
            TodaySection.fromRaw(token.trim())?.let { seen.add(it) }
        }
        // Append any known section not named in the saved order (e.g. one added in a later app version) so
        // nothing vanishes — the reorder is order-only, never a hide.
        TodaySection.defaultOrder.forEach { seen.add(it) }
        return seen.toList()
    }
}
