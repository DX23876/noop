package com.noop.data

/**
 * Fork (DX23876), Forge parity 2026-11: what a wearer notes about a cycle day beside the period start, as iOS
 * `CycleLog` stores it: one metricSeries row per fact under the isolated `noop-cycle` source, `flow` with the level
 * as its value, `ovulation_test` as 1, and each symptom and mood its own value-1 row (`symptom.cramps`,
 * `mood.irritable`). Clearing one is a real row delete. None of it feeds the cycle estimate. Analysis migration
 * required: no.
 */
class CycleLogStore(
    private val upsertRows: suspend (List<MetricSeriesRow>) -> Unit,
    private val queryRows: suspend (String, String, String, String) -> List<MetricSeriesRow>,
    private val deletePoint: suspend (String, String, String) -> Unit,
) {
    constructor(repo: WhoopRepository) : this(
        { rows -> repo.upsertMetricSeries(rows) },
        { deviceId, key, from, to -> repo.metricSeries(deviceId, key, from, to) },
        { deviceId, day, key -> repo.deleteMetricSeriesPoint(deviceId, day, key) },
    )

    /** One day's notes. [flow] is 1 spotting, 2 light, 3 medium, 4 heavy. */
    data class Day(val flow: Int? = null, val symptoms: Set<String> = emptySet(), val moods: Set<String> = emptySet(),
                   val ovulationTest: Boolean = false) {
        val isEmpty: Boolean get() = flow == null && symptoms.isEmpty() && moods.isEmpty() && !ovulationTest
    }

    /** Every logged cycle day in the range, by "yyyy-MM-dd". */
    suspend fun read(from: String, to: String): Map<String, Day> {
        val out = mutableMapOf<String, Day>()
        fun day(k: String) = out[k] ?: Day()
        queryRows(SOURCE, FLOW, from, to).forEach { r ->
            val level = Math.round(r.value).toInt()
            if (level in 1..4) out[r.day] = day(r.day).copy(flow = level)
        }
        queryRows(SOURCE, OVULATION_TEST, from, to).filter { it.value >= 1 }.forEach { out[it.day] = day(it.day).copy(ovulationTest = true) }
        SYMPTOMS.forEach { id ->
            queryRows(SOURCE, SYMPTOM + id, from, to).filter { it.value >= 1 }.forEach { r ->
                out[r.day] = day(r.day).let { it.copy(symptoms = it.symptoms + id) }
            }
        }
        MOODS.forEach { id ->
            queryRows(SOURCE, MOOD + id, from, to).filter { it.value >= 1 }.forEach { r ->
                out[r.day] = day(r.day).let { it.copy(moods = it.moods + id) }
            }
        }
        return out
    }

    /** Replace one day's notes with [log]: rows no longer set are deleted, not zeroed. */
    suspend fun save(day: String, log: Day, previous: Day) {
        val upserts = mutableListOf<MetricSeriesRow>()
        val deletes = mutableListOf<String>()
        if (log.flow != null) upserts += MetricSeriesRow(SOURCE, day, FLOW, log.flow.toDouble())
        else if (previous.flow != null) deletes += FLOW
        if (log.ovulationTest) upserts += MetricSeriesRow(SOURCE, day, OVULATION_TEST, 1.0)
        else if (previous.ovulationTest) deletes += OVULATION_TEST
        log.symptoms.forEach { upserts += MetricSeriesRow(SOURCE, day, SYMPTOM + it, 1.0) }
        (previous.symptoms - log.symptoms).forEach { deletes += SYMPTOM + it }
        log.moods.forEach { upserts += MetricSeriesRow(SOURCE, day, MOOD + it, 1.0) }
        (previous.moods - log.moods).forEach { deletes += MOOD + it }
        if (upserts.isNotEmpty()) upsertRows(upserts)
        deletes.forEach { deletePoint(SOURCE, day, it) }
    }

    companion object {
        const val SOURCE = CycleTrackingStore.SOURCE_ID
        const val FLOW = "flow"
        const val OVULATION_TEST = "ovulation_test"
        const val SYMPTOM = "symptom."
        const val MOOD = "mood."
        /** Stable storage ids, in the order the sheet shows them (iOS `CycleLog.symptoms` and `moods`). */
        val SYMPTOMS = listOf("cramps", "headache", "bloating", "tender_breasts", "back_pain", "acne", "tired", "cravings")
        val MOODS = listOf("calm", "happy", "irritable", "low", "anxious", "sensitive")
    }
}
