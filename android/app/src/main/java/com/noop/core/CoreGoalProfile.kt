package com.noop.core

import android.content.Context
import com.noop.NoopApplication
import com.noop.ble.resolveLastSync
import com.noop.ui.NoopPrefs
import kotlinx.coroutines.runBlocking
import com.noop.ui.ProfileStore
import org.json.JSONObject

/** The stored profile passed to Swift for goal-energy reads; the core resolves formulas and energy. */
internal fun JSONObject.withGoalProfile(profile: ProfileStore): JSONObject = put("energyProfile", JSONObject()
    .put("weightKg", profile.weightKg).put("heightCm", profile.heightCm)
    .put("age", profile.age).put("maxHR", profile.hrMax))

/** Only the active registry strap may contribute recency; an unattributable old global stamp stays unknown. */
internal fun goalLastSync(context: Context): Long {
    val app = context.applicationContext as? NoopApplication ?: return 0L
    val rows = runCatching { runBlocking { app.deviceRegistry.all() } }.getOrNull() ?: return 0L
    val active = rows.firstOrNull { it.id == app.activeDeviceId } ?: return 0L
    return resolveLastSync(NoopPrefs.lastSyncAtFor(context, active.peripheralId),
        NoopPrefs.lastSyncAt(context), rows.size) ?: 0L
}
