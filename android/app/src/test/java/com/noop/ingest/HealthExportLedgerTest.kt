package com.noop.ingest

import androidx.health.connect.client.records.RestingHeartRateRecord
import androidx.health.connect.client.records.metadata.Metadata
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.Instant
import java.time.ZoneOffset

/**
 * The Health Connect export writes only what changed, from the core's ledger. Until 2026-11-26 every pass
 * rewrote about 190 records of its 60-day window.
 */
class HealthExportLedgerTest {
    private fun rhr(day: String, bpm: Long) = HealthExportLedger.entry { v ->
        RestingHeartRateRecord(
            time = Instant.parse("${day}T03:00:00Z"), zoneOffset = ZoneOffset.ofHours(1), beatsPerMinute = bpm,
            metadata = Metadata(clientRecordId = "noop-rhr-$day", clientRecordVersion = v),
        )
    }!!

    @Test fun theFingerprintIgnoresTheVersionAndFollowsTheValue() {
        val a = rhr("2026-11-25", 52)
        assertEquals("noop-rhr-2026-11-25", a.id)
        assertEquals(a.fingerprint, HealthExportLedger.fingerprint(a.build(123)))
        assertNotEquals(a.fingerprint, rhr("2026-11-25", 51).fingerprint)
    }

    @Test fun onlyTheRecordsThePlanMarksAreBuiltAtTheirRevision() {
        val entries = listOf(rhr("2026-11-24", 50), rhr("2026-11-25", 52))
        val plan = listOf(
            HealthExportLedger.Version("noop-rhr-2026-11-24", 7, needsSave = false),
            HealthExportLedger.Version("noop-rhr-2026-11-25", 9, needsSave = true),
        )
        val (records, versions) = HealthExportLedger.changed(entries, fallbackVersion = 1, plan = plan)
        assertEquals(listOf("noop-rhr-2026-11-25"), records.map { it.metadata.clientRecordId })
        assertEquals(9L, records.single().metadata.clientRecordVersion)
        assertEquals(listOf(plan[1]), versions)
    }

    @Test fun aFullWriteSendsEveryRecordAtItsPlannedRevision() {
        val entries = listOf(rhr("2026-11-24", 50), rhr("2026-11-25", 52))
        val plan = listOf(
            HealthExportLedger.Version("noop-rhr-2026-11-24", 7, needsSave = false),
            HealthExportLedger.Version("noop-rhr-2026-11-25", 9, needsSave = true),
        )
        val (records, versions) = HealthExportLedger.changed(entries, fallbackVersion = 1, plan = plan, everything = true)
        assertEquals("a record Health Connect lost is created again", 2, records.size)
        assertEquals("an unchanged one keeps its version, so Health Connect leaves it as it is",
            listOf(7L, 9L), records.map { it.metadata.clientRecordVersion })
        assertEquals(plan, versions)
    }

    @Test fun theFullWriteComesOnceADay() {
        val day = HealthExportLedger.FULL_WRITE_INTERVAL_MS
        assertTrue("never written in full, as on a restored phone", HealthExportLedger.fullWriteDue(0, 1_000))
        assertTrue(!HealthExportLedger.fullWriteDue(1_000, 1_000 + day - 1))
        assertTrue(HealthExportLedger.fullWriteDue(1_000, 1_000 + day))
        assertTrue("a clock that went back", HealthExportLedger.fullWriteDue(5_000, 1_000))
    }

    @Test fun withoutAPlanEverythingIsWrittenAsBefore() {
        val entries = listOf(rhr("2026-11-24", 50), rhr("2026-11-25", 52))
        val (records, versions) = HealthExportLedger.changed(entries, fallbackVersion = 42, plan = null)
        assertEquals(2, records.size)
        assertTrue(records.all { it.metadata.clientRecordVersion == 42L })
        assertTrue("nothing to commit without the ledger", versions.isEmpty())
    }

    @Test fun thePlanIsReadFromTheCoreAndCommitsTheAcceptedRevisions() {
        val calls = mutableListOf<Pair<String, String>>()
        val fake: (String, String) -> String? = { op, args ->
            calls += op to args
            when (op) {
                "health.planExports" -> {
                    val items = JSONObject(args).getJSONArray("items")
                    val out = JSONArray()
                    for (i in 0 until items.length()) {
                        out.put(JSONObject().put("id", items.getJSONObject(i).getString("id")).put("revision", 5 + i)
                            .put("needsSave", i == 0))
                    }
                    JSONObject().put("versions", out).toString()
                }
                else -> """{"ok":true}"""
            }
        }
        val entries = listOf(rhr("2026-11-24", 50), rhr("2026-11-25", 52))
        val plan = assertNotNullAndGet(HealthExportLedger.plan(entries, fake))
        assertEquals(listOf(true, false), plan.map { it.needsSave })
        assertTrue(JSONObject(calls.single().second).getJSONArray("items").getJSONObject(0).getString("fingerprint")
            .startsWith("rhr|"))

        HealthExportLedger.commit(plan.filter { it.needsSave }, fake)
        assertEquals("health.commitExports", calls.last().first)
        assertEquals(5L, JSONObject(calls.last().second).getJSONArray("versions").getJSONObject(0).getLong("revision"))
    }

    @Test fun aCoreThatCannotAnswerGivesNoPlan() {
        val entries = listOf(rhr("2026-11-25", 52))
        assertNull(HealthExportLedger.plan(entries) { _, _ -> null })
        assertNull(HealthExportLedger.plan(entries) { _, _ -> """{"error":"store"}""" })
        assertNull("a plan of another length is not trusted",
            HealthExportLedger.plan(entries) { _, _ -> """{"versions":[]}""" })
    }

    private fun <T> assertNotNullAndGet(value: T?): T { assertNotNull(value); return value!! }
}
