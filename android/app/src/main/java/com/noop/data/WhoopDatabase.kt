package com.noop.data

import android.content.Context
import com.noop.core.CoreDb
import com.noop.push.PushDao

/**
 * The app's data access. Fork (DX23876), Android without Room (`docs/fork/android/CORE-ONLY-PLAN.md`): the store is
 * the shared core's (`files/core/noop-core.sqlite`, GRDB's migrations), and [whoopDao] runs every statement there
 * ([CoreWhoopDao], generated from the declarations Room used to implement). An earlier build's Room file is adopted
 * once on the first start (`CoreRoomAdoption`). Raw IMU stays out of the store: the core's
 * `v41-drop-raw-imu-sample` removed its table, and Test Centre captures go to `ImuSessionFileStore` files.
 */
class WhoopDatabase private constructor() {
    private val dao: WhoopDao = CoreWhoopDao()

    fun whoopDao(): WhoopDao = dao

    fun pushDao(): PushDao = PushDao(this)

    companion object {
        /** The Room store's file name in earlier builds; only `CoreRoomAdoption` and the Test Centre look for it. */
        const val DB_NAME = "noop_whoop.db"

        /** The last Room schema version (42), kept for the migration-step trace the Test Centre logs. */
        const val SCHEMA_VERSION = 42

        @Volatile
        private var instance: WhoopDatabase? = null

        /** Process-wide singleton. Safe to call from any thread. */
        fun get(context: Context): WhoopDatabase =
            instance ?: synchronized(this) {
                instance ?: WhoopDatabase().also { CoreDb.init(context) ; instance = it }
            }
    }
}

/**
 * Room's `withTransaction` shape for the callers that group writes. The core commits each `CoreDb` call in its own
 * transaction, so the block runs in order but its statements are not one unit: a failure part-way leaves the writes
 * before it, as a sequence of separate Room calls would.
 */
suspend fun <R> WhoopDatabase.withTransaction(block: suspend () -> R): R = block()
