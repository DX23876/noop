package com.noop.ui

import android.content.Context

// MARK: - Reorderable Today sections (#today-layout)
//
// The Today screen's sections — the Charge/Effort/Rest hero, the Start-session entry, Synthesis, Key
// Metrics, Workouts, Heart Rate, Recovery Vitals, Your Cards — rendered in one fixed order. This lets the
// user REORDER them, with the default being the original order so nothing changes for anyone who never
// rearranges. Display-only — no metric is computed or stored differently; this only decides the SEQUENCE
// the already-built sections render in.
//
// Stored as a single comma-joined string of section keys in SharedPreferences ("today.sectionOrder"), the
// same mechanism KeyMetricPrefs/DashboardCards use. Mirrors the macOS TodayLayoutPrefs.swift +
// @AppStorage("today.sectionOrder"). Every known section ALWAYS renders: unknown tokens are dropped, and
// any known section missing from the saved order is INSERTED at its default-order position relative to the
// saved sections — so a section added in a later version (e.g. the hero, which joined the reorderable set
// after the first cut) surfaces where users expect it rather than teleporting to the bottom of an existing
// saved order. This reorders, it never hides.

/**
 * One reorderable Today section. The [raw] is the stable persisted identifier — keep it byte-identical to
 * the macOS `TodaySection` enum so a backup/restore reads the same layout on either OS.
 */
enum class TodaySection(val raw: String, val title: String) {
    HERO("hero", "Charge / Effort / Rest"),
    LIVE_SESSION("liveSession", "Start session"),
    SYNTHESIS("synthesis", "Synthesis"),
    KEY_METRICS("keyMetrics", "Key Metrics"),
    WORKOUTS("workouts", "Workouts"),
    HEART_RATE("heartRate", "Heart Rate"),
    RECOVERY_VITALS("recoveryVitals", "Recovery Vitals"),
    YOUR_CARDS("yourCards", "Your Cards"),
    JOURNAL("journal", "Journal");

    companion object {
        fun fromRaw(raw: String?): TodaySection? = entries.firstOrNull { it.raw == raw }

        /** The original, hard-coded section order — the default when the layout isn't customised. The
         *  journal widget (#656) is last by default, where it was first added, above the data-sources card. */
        val defaultOrder: List<TodaySection> = listOf(
            HERO, LIVE_SESSION, SYNTHESIS, KEY_METRICS, WORKOUTS, HEART_RATE, RECOVERY_VITALS, YOUR_CARDS,
            JOURNAL,
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
}
