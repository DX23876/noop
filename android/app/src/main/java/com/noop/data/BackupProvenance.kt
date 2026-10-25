package com.noop.data

/**
 * Build provenance for exports (#1410): a `manifest.json` entry recording which build produced a
 * `.noopbak`, and an `APP_VERSION_CHANGED` event marking each in-app version transition so a SINGLE
 * export answers "what ran when" across the whole retention window. Pure JSON only — the ZIP container
 * and the event write live in the app layer; this is the byte-parity twin of Swift `BackupProvenance.swift`.
 *
 * Neither is telemetry: both are LOCAL metadata inside the user's own backup, nothing leaves the device.
 *
 * The JSON is a minimal, sorted-key object built by hand so it is byte-identical to Swift's
 * `JSONSerialization(.sortedKeys)` and testable in a plain JVM (no `org.json` stub).
 */
private fun jsonString(value: String): String = buildString(value.length + 2) {
    append('"')
    value.forEach { char ->
        when (char) {
            '"' -> append("\\\"")
            '\\' -> append("\\\\")
            '\b' -> append("\\b")
            '\u000c' -> append("\\f")
            '\n' -> append("\\n")
            '\r' -> append("\\r")
            '\t' -> append("\\t")
            else -> if (char.code in 0x00..0x1f) {
                append("\\u")
                append(char.code.toString(radix = 16).padStart(length = 4, padChar = '0'))
            } else {
                append(char)
            }
        }
    }
    append('"')
}

private fun sortedJsonObject(entries: List<Pair<String, Any>>): String =
    entries.sortedBy { it.first }.joinToString(separator = ",", prefix = "{", postfix = "}") { (k, v) ->
        val value = when (v) {
            is String -> jsonString(v)
            else -> v.toString()   // Int/Long → unquoted numeric literal
        }
        "\"$k\":$value"
    }

/** The `manifest.json` entry inside a `.noopbak` — "which build produced this file" (#1410 tier 1). */
object BackupManifest {
    /** Canonical entry name inside the `.noopbak` ZIP. Matches the Swift exporter byte-for-byte. */
    const val ENTRY_NAME = "manifest.json"

    /** Twin of Swift `BackupManifest.json`; keys + kinds identical, values platform-specific. */
    fun json(appVersion: String, appBuild: String, platform: String, schemaVersion: Int, exportedAtMs: Long): String =
        sortedJsonObject(
            listOf(
                "appVersion" to appVersion,
                "appBuild" to appBuild,
                "platform" to platform,
                "schemaVersion" to schemaVersion,
                "exportedAt" to exportedAtMs,
            )
        )
}

/** The `APP_VERSION_CHANGED` event appended on an in-app version transition (#1410 tier 2). */
object AppVersionEvent {
    /** The `event.kind` for a version transition. Rides the existing `event` table (`payloadJSON` string). */
    const val KIND = "APP_VERSION_CHANGED"

    /** Record only when a PRIOR version was seen AND it differs — first launch (null/blank prior) records nothing. */
    fun shouldRecord(lastSeen: String?, current: String): Boolean =
        !lastSeen.isNullOrEmpty() && lastSeen != current

    /** Twin of Swift `AppVersionEvent.payloadJson`: deterministic `from`, `schemaVersion`, `to`. */
    fun payloadJson(from: String, to: String, schemaVersion: Int): String =
        sortedJsonObject(listOf("from" to from, "to" to to, "schemaVersion" to schemaVersion))
}
