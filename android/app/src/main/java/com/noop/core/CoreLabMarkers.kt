package com.noop.core

import com.noop.data.LabMarkerRow
import org.json.JSONArray
import org.json.JSONObject

/**
 * Fork (DX23876), Android parity plan 1.3: the Lab Book's readings from the shared core (`read.labMarkers`), which has
 * held every lab marker the phone wrote since the input lanes moved (2026-10-28). Behind the same Lab switch as the
 * daily rows; [com.noop.data.WhoopRepository.labMarkersByCategory] reads it. Blocking; call off the main thread.
 */
object CoreLabMarkers {
    fun read(deviceId: String, category: String): List<LabMarkerRow>? {
        if (!SwiftCore.available) return null
        val json = SwiftCore.call("read.labMarkers", JSONObject().put("deviceId", deviceId).put("category", category).toString())
            ?: return null
        return parse(json)
    }

    /** Null for anything but the expected shape (a missing field included), so the caller reads Room instead. */
    internal fun parse(json: String): List<LabMarkerRow>? = runCatching { parseOrThrow(json) }.getOrNull()

    private fun parseOrThrow(json: String): List<LabMarkerRow>? {
        val a = runCatching { JSONArray(json) }.getOrNull() ?: return null
        return (0 until a.length()).map { i ->
            val o = a.getJSONObject(i)
            fun s(k: String) = if (o.has(k) && !o.isNull(k)) o.getString(k) else null
            LabMarkerRow(
                id = o.getString("id"), deviceId = o.getString("deviceId"), markerKey = o.getString("markerKey"),
                category = o.getString("category"), day = o.getString("day"), takenAt = o.getLong("takenAt"),
                value = if (o.has("value") && !o.isNull("value")) o.getDouble("value") else null, valueText = s("valueText"),
                unit = o.getString("unit"), source = o.getString("source"), note = s("note"), referenceText = s("referenceText"),
            )
        }
    }
}
