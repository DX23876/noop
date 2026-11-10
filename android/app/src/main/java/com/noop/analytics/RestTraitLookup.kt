package com.noop.analytics

/**
 * Fork (DX23876), AI-35: the stored traits each night's Rest score was computed with, `sleep_need_min` (minutes)
 * and `sleep_consistency` (percent), written by the shared core's daily pass beside `sleep_performance`. Every
 * Android readout that rebuilds a night's Rest from its daily row reads them here, so no screen scores a night
 * with a need the pass did not use. A night without stored traits carries the newest earlier night's; with none
 * stored it is the cold start (8 h, neutral regularity). Swift twin: StrandCore `RestTraitLookup`.
 */
data class RestTraitLookup(
    val needMinByDay: Map<String, Double>,
    val consistencyPctByDay: Map<String, Double>,
) {
    /** The need (hours) [day]'s Rest was scored with. */
    fun needHoursFor(day: String): Double {
        val key = traitDay(day) ?: return COLD_START_NEED_HOURS
        return needMinByDay[key]?.takeIf { it > 0 }?.div(60.0) ?: COLD_START_NEED_HOURS
    }

    /** The regularity (0..1) [day]'s Rest was scored with, null while it was still learning. */
    fun consistencyFor(day: String): Double? {
        val key = traitDay(day) ?: return null
        return consistencyPctByDay[key]?.let { (it / 100.0).coerceIn(0.0, 1.0) }
    }

    /** [day] itself when stored, else the newest earlier stored night. */
    private fun traitDay(day: String): String? =
        if (needMinByDay.containsKey(day)) day else needMinByDay.keys.filter { it < day }.maxOrNull()

    companion object {
        const val NEED_KEY = "sleep_need_min"
        const val CONSISTENCY_KEY = "sleep_consistency"
        const val COLD_START_NEED_HOURS = 8.0
        val EMPTY = RestTraitLookup(emptyMap(), emptyMap())
    }
}
