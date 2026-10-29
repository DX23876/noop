package com.noop.core

import android.content.Context
import com.noop.NoopApplication
import com.noop.ble.resolveLastSync
import com.noop.ui.NoopPrefs
import kotlinx.coroutines.runBlocking
import com.noop.ui.JournalCatalogItem
import com.noop.ui.ProfileStore
import com.noop.ui.loadJournalCatalogItems
import org.json.JSONArray
import org.json.JSONObject

/** The stored profile passed to Swift for goal-energy reads; the core resolves formulas and energy. */
internal fun JSONObject.withGoalProfile(profile: ProfileStore): JSONObject = put("energyProfile", JSONObject()
    .put("weightKg", profile.weightKg).put("heightCm", profile.heightCm)
    .put("age", profile.age).put("maxHR", profile.hrMax))

/** The wearer's opt-ins and energy choices the goal reader needs, as `GoalTrackingStore.goalHostState` reads them on Apple. */
internal fun JSONObject.withGoalHostSettings(context: Context): JSONObject =
    put("hydrationEnabled", NoopPrefs.hydrationTracking(context))
        // The Energy Plan's basal formula, so goals, Momentum and the plan price energy with one formula.
        .put("formulaLog", CoreEnergyPlan.formulaLog(context))
        .put("journalCatalog", journalCatalogWire(loadJournalCatalogItems(context)).toString())

/** The catalog in Swift's own `JournalCatalogItem` coding, so the core folds the same aliases Apple does. */
internal fun journalCatalogWire(items: List<JournalCatalogItem>): JSONArray = JSONArray(items.map { item ->
    val kind = if (item.kind.isNumeric) {
        JSONObject().put("numeric", JSONObject().apply { item.kind.unitLabel?.let { put("unitLabel", it) } })
    } else JSONObject().put("bool", JSONObject())
    JSONObject().put("canonical", item.canonical).put("kind", kind).put("group", item.group.name.lowercase())
        .put("sortIndex", item.sortIndex).put("hidden", item.hidden).put("custom", item.custom)
        .put("aliases", JSONArray())
        .apply { item.displayName?.let { put("displayName", it) } }
})

/** Only the active registry strap may contribute recency; an unattributable old global stamp stays unknown. */
internal fun goalLastSync(context: Context): Long {
    val app = context.applicationContext as? NoopApplication ?: return 0L
    val rows = runCatching { runBlocking { app.deviceRegistry.all() } }.getOrNull() ?: return 0L
    val active = rows.firstOrNull { it.id == app.activeDeviceId } ?: return 0L
    return resolveLastSync(NoopPrefs.lastSyncAtFor(context, active.peripheralId),
        NoopPrefs.lastSyncAt(context), rows.size) ?: 0L
}
