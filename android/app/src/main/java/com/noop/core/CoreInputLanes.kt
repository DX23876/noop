package com.noop.core

import android.content.Context
import com.noop.data.WhoopDatabase

/**
 * The input lanes Android used to write to Room first and mirror into the core (parity plan 1.3). Fork (DX23876),
 * Android without Room (`docs/fork/android/CORE-ONLY-PLAN.md`): Android's data access now writes the core's own
 * tables ([CoreDb]), so there is nothing to mirror and the lanes are always the core's. The calls stay so their
 * callers keep their shape; each does nothing.
 */
@Suppress("UNUSED_PARAMETER")
class CoreInputLanes(private val context: Context, private val db: WhoopDatabase) {
    companion object {
        /** The core's lanes always hold Android's rows: they are the same tables. */
        val ready: Boolean get() = true

        /** Primary keys, in the core's column order. */
        val KEYS = linkedMapOf(
            "workout" to listOf("deviceId", "startTs", "sport"),
            "appleDaily" to listOf("deviceId", "day"),
            "labMarker" to listOf("id"),
            "liveSession" to listOf("deviceId", "startTs"),
            "metricSeries" to listOf("deviceId", "day", "key"),
            "dailyMetric" to listOf("deviceId", "day"),
            "sleepSession" to listOf("deviceId", "startTs"),
            "dayOwnership" to listOf("day"),
        )

        fun forgetRepairAfterRestore(context: Context) = Unit
    }

    suspend fun ensure() = Unit

    suspend fun mirror(table: String, keys: List<List<Any?>>) = Unit

    suspend fun keysWhere(table: String, where: String, args: Array<Any?>): List<List<Any?>> = emptyList()
}
