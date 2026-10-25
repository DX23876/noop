package com.noop.data

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.json.JSONObject

/**
 * Pins the #1410 build-provenance JSON. The expected strings are byte-identical to what Swift's
 * `JSONSerialization(.sortedKeys)` emits for the same inputs (see `BackupProvenanceTests.swift`) —
 * keys alphabetical, compact, numbers unquoted — so an analyst reads one shape across platforms.
 */
class BackupProvenanceTest {

    @Test fun manifest_json_is_sorted_and_parity_with_swift() {
        assertEquals(
            """{"appBuild":"221","appVersion":"10.1.1","exportedAt":1723900000000,"platform":"android","schemaVersion":30}""",
            BackupManifest.json(
                appVersion = "10.1.1", appBuild = "221", platform = "android",
                schemaVersion = 30, exportedAtMs = 1_723_900_000_000L,
            ),
        )
    }

    @Test fun versionEvent_payload_is_sorted() {
        assertEquals(
            """{"from":"10.1.0","schemaVersion":30,"to":"10.1.1"}""",
            AppVersionEvent.payloadJson(from = "10.1.0", to = "10.1.1", schemaVersion = 30),
        )
    }

    @Test fun versionEvent_payload_escapes_named_controls_like_swift() {
        val from = "10.1\n0"
        val to = "10.1\t1\u0001"
        val json = AppVersionEvent.payloadJson(from = from, to = to, schemaVersion = 30)

        assertEquals(
            """{"from":"10.1\n0","schemaVersion":30,"to":"10.1\t1\u0001"}""",
            json,
        )
        val decoded = JSONObject(json)
        assertEquals(from, decoded.getString("from"))
        assertEquals(to, decoded.getString("to"))
    }

    @Test fun versionEvent_payload_round_trips_every_json_control_character() {
        val controls = (0x00..0x1f).map(Int::toChar).joinToString("")
        val json = AppVersionEvent.payloadJson(from = controls, to = "ordinary", schemaVersion = 30)

        assertEquals(
            """{"from":"\u0000\u0001\u0002\u0003\u0004\u0005\u0006\u0007\b\t\n\u000b\f\r\u000e\u000f\u0010\u0011\u0012\u0013\u0014\u0015\u0016\u0017\u0018\u0019\u001a\u001b\u001c\u001d\u001e\u001f","schemaVersion":30,"to":"ordinary"}""",
            json,
        )
        assertTrue("JSON must not contain raw control characters", json.none { it.code in 0x00..0x1f })
        assertEquals(controls, JSONObject(json).getString("from"))
    }

    @Test fun shouldRecord_only_on_a_real_transition() {
        assertFalse("first launch — no prior", AppVersionEvent.shouldRecord(lastSeen = null, current = "10.1.1"))
        assertFalse("blank prior", AppVersionEvent.shouldRecord(lastSeen = "", current = "10.1.1"))
        assertFalse("unchanged", AppVersionEvent.shouldRecord(lastSeen = "10.1.1", current = "10.1.1"))
        assertTrue("transition", AppVersionEvent.shouldRecord(lastSeen = "10.1.0", current = "10.1.1"))
    }
}
