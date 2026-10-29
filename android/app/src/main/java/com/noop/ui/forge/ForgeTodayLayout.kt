package com.noop.ui.forge

import com.noop.ui.KeyMetric
import com.noop.ui.KeyMetricPrefs
import com.noop.ui.SleepLayoutPrefs
import com.noop.ui.SleepSection
import com.noop.ui.TodayLayoutPrefs
import com.noop.ui.TodaySection

/**
 * Fork (DX23876), Android parity: the Shown / Hidden draft every layout editor edits, after the Apple
 * `EditableLayoutDraft`. [hide] keeps at least one item shown unless [allowEmpty].
 */
data class EditableLayoutDraft<T>(val visible: List<T>, val hidden: List<T>) {
    fun moveVisible(from: Int, to: Int): EditableLayoutDraft<T> {
        if (from !in visible.indices || to !in visible.indices || from == to) return this
        return copy(visible = visible.toMutableList().apply { add(to, removeAt(from)) })
    }

    fun hide(item: T, allowEmpty: Boolean = false): EditableLayoutDraft<T> {
        if (item !in visible || (!allowEmpty && visible.size <= 1)) return this
        return EditableLayoutDraft(visible - item, hidden + item)
    }

    fun show(item: T): EditableLayoutDraft<T> {
        if (item !in hidden) return this
        return EditableLayoutDraft(visible + item, hidden - item)
    }

    companion object {
        /** [visible] in its order, every other item of [allItems] hidden in canonical order. */
        fun <T> of(visible: List<T>, allItems: List<T>) = EditableLayoutDraft(visible, allItems.filterNot { it in visible })
    }
}

/**
 * Today's layout as the Forge screen draws it: the Apple `LiquidTodayDefaults` (the fresh layout of the default
 * Today style) plus what Android does not draw yet. Classic and Liquid share the `today.*` keys; an UNSET key
 * reads as this default, a saved one wins. Display-only. Analysis migration required: no.
 */
object TodayLayoutDefaults {
    /** Hero, the day's story, the numbers, energy, workouts, heart rate, the user's cards; the self-gating extras follow. */
    val sectionOrder: List<TodaySection> = listOf(
        TodaySection.HERO, TodaySection.SYNTHESIS, TodaySection.GOALS, TodaySection.KEY_METRICS,
        TodaySection.TRAINING_LOAD, TodaySection.ENERGY, TodaySection.WORKOUTS, TodaySection.HEART_RATE,
        TodaySection.YOUR_CARDS, TodaySection.COACH, TodaySection.LIVE_SESSION, TodaySection.MENSTRUAL_CYCLE,
        TodaySection.JOURNAL, TodaySection.ADDED_CARDS, TodaySection.RECOVERY_VITALS, TodaySection.DATA_SOURCES,
    )

    /** Recovery Vitals starts hidden: HRV, resting heart rate and respiration are already Key Metrics. */
    val hiddenSections: List<TodaySection> = listOf(TodaySection.RECOVERY_VITALS)

    /**
     * Sections the Forge Today never draws, left out of the editor. Data Sources as on iOS; the rest are iOS
     * sections Android has no card for yet. Their stored position and visibility survive a save, so a layout
     * restored on the iPhone keeps them, and each leaves this set when its card lands.
     */
    val excludedSections: Set<TodaySection> = setOf(
        TodaySection.DATA_SOURCES, TodaySection.LIVE_SESSION, TodaySection.TRAINING_LOAD, TodaySection.WORKOUTS,
        TodaySection.RECOVERY_VITALS, TodaySection.YOUR_CARDS, TodaySection.MENSTRUAL_CYCLE, TodaySection.JOURNAL,
        TodaySection.ADDED_CARDS,
    )

    /** Calories, Charge, Effort and Rest stay out of the untouched grid: the Energy card and the hero show them. */
    val keyMetrics: List<KeyMetric> = KeyMetric.defaultOrder.filterNot {
        it in setOf(KeyMetric.CALORIES, KeyMetric.CHARGE, KeyMetric.EFFORT, KeyMetric.REST)
    }

    const val KEY_METRICS_COLUMNS = 2

    /** Customised once either section key has been written; unhiding everything writes an explicit "". */
    fun isLayoutCustomised(orderRaw: String?, hiddenRaw: String?): Boolean =
        !orderRaw?.trim().isNullOrEmpty() || hiddenRaw != null

    /** The full order without the excluded sections, and the hidden set, for drawing and for the editor. */
    fun layout(orderRaw: String?, hiddenRaw: String?): Pair<List<TodaySection>, Set<TodaySection>> {
        val (order, hidden) = if (isLayoutCustomised(orderRaw, hiddenRaw)) {
            TodayLayoutPrefs.decodeOrder(orderRaw) to TodayLayoutPrefs.decodeHidden(hiddenRaw).toSet()
        } else {
            sectionOrder to hiddenSections.toSet()
        }
        return order.filterNot { it in excludedSections } to hidden
    }

    fun visibleSections(orderRaw: String?, hiddenRaw: String?): List<TodaySection> {
        val (order, hidden) = layout(orderRaw, hiddenRaw)
        return order.filterNot { it in hidden }
    }

    /** The editor's starting draft: the drawn sections, shown then hidden, each in stored order. */
    fun sectionDraft(orderRaw: String?, hiddenRaw: String?): EditableLayoutDraft<TodaySection> {
        val (order, hidden) = layout(orderRaw, hiddenRaw)
        return EditableLayoutDraft(order.filterNot { it in hidden }, order.filter { it in hidden })
    }

    /** Reset: the fresh layout, without the excluded sections. */
    fun defaultSectionDraft(): EditableLayoutDraft<TodaySection> {
        val order = sectionOrder.filterNot { it in excludedSections }
        return EditableLayoutDraft(order.filterNot { it in hiddenSections }, order.filter { it in hiddenSections })
    }

    /**
     * The two stored strings for a saved [draft], as the Apple sheet writes them: shown, hidden, then the excluded
     * sections in default order; an excluded section stays hidden only if it was. [storedHiddenRaw] is the hidden
     * set the editor opened with (the fresh default when nothing was stored).
     */
    fun encodeSections(draft: EditableLayoutDraft<TodaySection>, storedHidden: Set<TodaySection>): Pair<String, String> {
        val excluded = TodaySection.defaultOrder.filter { it in excludedSections }
        val order = TodayLayoutPrefs.encode(draft.visible + draft.hidden + excluded)
        val hidden = TodayLayoutPrefs.encodeHidden(draft.hidden + excluded.filter { it in storedHidden })
        return order to hidden
    }

    /** Whether a Key Metrics list came from the user (empty tiles stay as "—") or from the default (dropped). */
    data class KeyMetricSelection(val metrics: List<KeyMetric>, val isExplicit: Boolean)

    fun keyMetricSelection(raw: String?): KeyMetricSelection {
        val trimmed = raw?.trim().orEmpty()
        if (trimmed.isEmpty()) return KeyMetricSelection(keyMetrics, isExplicit = false)
        return KeyMetricSelection(KeyMetricPrefs.decodeEnabled(trimmed), isExplicit = true)
    }

    /** Tiles with a value first, in the selection's order; empty ones follow only when the user chose them. */
    fun arrangedKeyMetrics(selection: KeyMetricSelection, hasValue: (KeyMetric) -> Boolean): List<KeyMetric> {
        val populated = selection.metrics.filter(hasValue)
        if (!selection.isExplicit) return populated
        return populated + selection.metrics.filterNot(hasValue)
    }

    /** The stored column choice when there is one, two otherwise, one at the largest text sizes. */
    fun keyMetricsColumns(stored: Int?, largeText: Boolean): Int {
        if (largeText) return 1
        return stored?.let(KeyMetricPrefs::columns) ?: KEY_METRICS_COLUMNS
    }
}

/**
 * The Sleep tab's arrangeable cards as Forge Sleep draws them: Stages (the night's breakdown) and the sleep-debt
 * ledger. The other Apple Sleep cards have no Android card yet; like Today's excluded sections they stay out of the
 * editor and keep their stored place.
 */
object SleepLayoutDefaults {
    val drawn: List<SleepSection> = listOf(SleepSection.STAGES, SleepSection.SLEEP_DEBT)

    fun draft(orderRaw: String?, hiddenRaw: String?): EditableLayoutDraft<SleepSection> {
        val order = SleepLayoutPrefs.decodeOrder(orderRaw).filter { it in drawn }
        val hidden = SleepLayoutPrefs.decodeHidden(hiddenRaw).toSet()
        return EditableLayoutDraft(order.filterNot { it in hidden }, order.filter { it in hidden })
    }

    fun visible(orderRaw: String?, hiddenRaw: String?): List<SleepSection> = draft(orderRaw, hiddenRaw).visible

    fun defaultDraft(): EditableLayoutDraft<SleepSection> =
        EditableLayoutDraft.of(SleepSection.defaultOrder.filter { it in drawn }, SleepSection.defaultOrder.filter { it in drawn })

    /** Shown, hidden, then the cards Android does not draw in stored order, keeping their stored visibility. */
    fun encode(draft: EditableLayoutDraft<SleepSection>, orderRaw: String?, hiddenRaw: String?): Pair<String, String> {
        val others = SleepLayoutPrefs.decodeOrder(orderRaw).filterNot { it in drawn }
        val storedHidden = SleepLayoutPrefs.decodeHidden(hiddenRaw).toSet()
        return SleepLayoutPrefs.encode(draft.visible + draft.hidden + others) to
            SleepLayoutPrefs.encodeHidden(draft.hidden + others.filter { it in storedHidden })
    }
}
