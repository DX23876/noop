package com.noop.ui

import android.content.Context
import androidx.work.Constraints
import androidx.work.CoroutineWorker
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.NetworkType
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import com.noop.core.CoreHevyImport
import com.noop.core.CoreRead
import com.noop.core.CoreShadow
import java.util.concurrent.TimeUnit

/**
 * The automatic Hevy import (Discord 2026-11-27): a periodic worker on the interval the wearer chose in Data
 * Sources, with a network constraint. The core's `HevyAutoImport` decides whether a wake is due, so a pull by
 * hand shortly before is not repeated. Off by default, like the folder backup.
 */
object HevyAutoImportScheduler {
    private const val WORK = "noop_hevy_auto_import"

    /** Schedules, re-times or cancels the worker from the stored interval. UPDATE so a new interval takes
     *  effect without stacking a second job; cheap and safe to call on every launch. */
    fun reschedule(context: Context) {
        val wm = WorkManager.getInstance(context.applicationContext)
        val seconds = runCatching { CoreHevyImport.autoPlan(context).seconds }.getOrNull()
        if (seconds == null || !CoreHevyImport.connected(context)) {
            wm.cancelUniqueWork(WORK)
            return
        }
        val request = PeriodicWorkRequestBuilder<HevyAutoImportWorker>(seconds, TimeUnit.SECONDS)
            .setConstraints(Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build())
            .build()
        wm.enqueueUniquePeriodicWork(WORK, ExistingPeriodicWorkPolicy.UPDATE, request)
    }
}

class HevyAutoImportWorker(appContext: Context, params: WorkerParameters) : CoroutineWorker(appContext, params) {
    override suspend fun doWork(): Result {
        val context = applicationContext
        runCatching { CoreRead.open(context) }
        val brought = runCatching { CoreHevyImport.autoImportIfDue(context) }.getOrNull()
        if ((brought ?: 0) > 0) CoreShadow.noteDataChanged()
        // A failed run waits for the next period rather than retrying: Hevy being unreachable now says nothing
        // about an hour from now, and the next wake asks again anyway.
        return Result.success()
    }
}
