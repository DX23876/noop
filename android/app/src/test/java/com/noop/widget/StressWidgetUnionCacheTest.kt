package com.noop.widget

import com.noop.data.HrSample
import com.noop.data.PairedDeviceRow
import com.noop.data.WhoopDao
import com.noop.data.WhoopRepository
import java.lang.reflect.Proxy
import java.time.Instant
import java.time.ZoneId
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/** Exercises the producer's actual memo gate with an in-memory DAO, without Room or a strap. */
class StressWidgetUnionCacheTest {
    private val now = Instant.parse("2026-10-01T12:00:00Z").epochSecond
    private val active = "whoop-active"

    @Before fun reset() = StressWidgetProducer.resetForTest()

    private class Data {
        val rows = mutableMapOf<String, List<HrSample>>()
        val registered = mutableListOf<String>()
        val rowReads = mutableListOf<String>()

        private fun device(id: String) = PairedDeviceRow(
            id = id, brand = "WHOOP", model = "4.0", nickname = null,
            sourceKind = "strap", capabilities = "hr", status = "archived",
            addedAt = 0L, lastSeenAt = 0L,
        )

        val repo: WhoopRepository = WhoopRepository(
            Proxy.newProxyInstance(
                WhoopDao::class.java.classLoader, arrayOf(WhoopDao::class.java),
            ) { _, method, args ->
                when (method.name) {
                    "pairedDevices" -> registered.map(::device)
                    "countHrInWindow", "maxHrTsInWindow", "hrSamples" -> {
                        val id = args[0] as String
                        val from = args[1] as Long
                        val to = args[2] as Long
                        val samples = rows[id].orEmpty().filter { it.ts in from..to }
                        when (method.name) {
                            "countHrInWindow" -> samples.size
                            "maxHrTsInWindow" -> samples.maxOfOrNull { it.ts } ?: 0L
                            else -> { rowReads += id; samples }
                        }
                    }
                    else -> throw UnsupportedOperationException("producer touched ${method.name}")
                }
            } as WhoopDao,
        )
    }

    // Below the scoring minimum deliberately: these tests measure whether a day's streams are read,
    // not analytics outputs. A genuine empty curve is cached too and must invalidate on new HR.
    private fun curve(data: Data, id: String = active, personal: Boolean = false) = runBlocking {
        StressWidgetProducer.todayCurve(data.repo, id, personal, now, ZoneId.of("UTC"))
    }

    @Test fun unchangedUnionReusesTheCurveWithoutFetchingRows() {
        val data = Data()
        assertNotNull(curve(data))
        val reads = data.rowReads.toList()
        assertTrue(reads.isNotEmpty())
        assertNotNull(curve(data))
        assertEquals(reads, data.rowReads)
    }

    @Test fun canonicalImportInvalidatesAnIdleActiveStrapsCurve() {
        val data = Data()
        assertNotNull(curve(data))
        data.rowReads.clear()
        data.rows["my-whoop"] = listOf(HrSample("my-whoop", now - 60, 65))
        assertNotNull(curve(data))
        assertEquals(listOf(active, "my-whoop"), data.rowReads)
        data.rowReads.clear()
        assertNotNull(curve(data))
        assertTrue("the refreshed curve must be memoized", data.rowReads.isEmpty())
    }

    @Test fun archivedSourceBackfillInvalidatesEvenWhenNewestTimestampDoesNotMove() {
        val data = Data()
        val alias = "whoop-archived"
        data.registered += alias
        data.rows[alias] = listOf(HrSample(alias, now - 60, 65))
        assertNotNull(curve(data))
        data.rowReads.clear()
        data.rows[alias] = data.rows.getValue(alias) + HrSample(alias, now - 120, 64)
        assertNotNull(curve(data))
        assertEquals(listOf(active, alias, "my-whoop"), data.rowReads)
    }

    @Test fun newlyRegisteredSourceInvalidatesThePreviouslyEmptyCurve() {
        val data = Data()
        assertNotNull(curve(data))
        data.rowReads.clear()
        data.registered += "whoop-restored"
        data.rows["whoop-restored"] = listOf(HrSample("whoop-restored", now - 60, 65))
        assertNotNull(curve(data))
        assertEquals(listOf(active, "whoop-restored", "my-whoop"), data.rowReads)
    }

    @Test fun switchingActiveSourcesWithEqualCountsStillReloads() {
        val data = Data()
        assertNotNull(curve(data))
        data.rowReads.clear()
        assertNotNull(curve(data, id = "whoop-other"))
        assertEquals(listOf("whoop-other", "my-whoop"), data.rowReads)
    }

    @Test fun bothLensesKeepTheirOwnWarmUnionGate() {
        val data = Data()
        assertNotNull(curve(data))
        assertNotNull(curve(data, personal = true))
        data.rowReads.clear()
        assertNotNull(curve(data))
        assertNotNull(curve(data, personal = true))
        assertTrue(data.rowReads.isEmpty())
        data.rows["my-whoop"] = listOf(HrSample("my-whoop", now - 60, 65))
        assertNotNull(curve(data))
        assertNotNull(curve(data, personal = true))
        assertEquals(listOf(active, "my-whoop", active, "my-whoop"), data.rowReads)
    }
}
