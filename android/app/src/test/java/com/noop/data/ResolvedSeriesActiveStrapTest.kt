package com.noop.data

import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.lang.reflect.Proxy

/**
 * #172 / #175 regression — resolvedSeries() must honour a caller-threaded ACTIVE strap id.
 *
 * After a strap remove+re-add the IntelligenceEngine banks computed scores under
 * "<activeStrapId>-noop", not the canonical "my-whoop-noop". resolvedSeries() defaults
 * strapDeviceId to the canonical "my-whoop", and before #175 no UI caller overrode it, so
 * [WhoopRepository.sourceCandidates] probed only the canonical pair: the Today Rest ring fell
 * back to "Calibrating — needs a tracked night" and the Key Metrics Rest card showed no data
 * while the Sleep tab (already on the #814 union spine) showed fully scored nights.
 *
 * These tests pin the BEHAVIOUR either side of that seam, complementing [ResolverUnionTest]
 * (which pins the candidate LIST shape, #1008) and the call-site census in
 * [com.noop.ui.ResolvedSeriesCallSiteAuditTest]:
 *
 *   • threading the active id resolves scores banked under its computed sibling (the #175 fix);
 *   • the legacy canonical default MISSES those same scores (the #172 symptom, kept as a
 *     documented failure shape so the default is never mistaken for re-add-safe);
 *   • a single-strap install (active == canonical) resolves byte-identically threaded or not;
 *   • the #1008 union still holds through the threaded read: active wins its day, canonical
 *     fills the days banked before the re-add.
 *
 * Driven through a Proxy-stub [WhoopDao] (no Room): the resolver only touches metricSeries +
 * dailyMetricsRange, answered from a fixture list; everything else throws.
 */
class ResolvedSeriesActiveStrapTest {

    private val canonical = "my-whoop"
    private val reAdded = "whoop-ABC123" // the id a re-added strap gets (whoop-<uuid>)

    // The wide-open window every Today/Trends caller passes.
    private val from = "0000-00-00"
    private val to = "9999-99-99"

    /** Build a repository whose metricSeries answers from [rows] (filtered like the real query:
     *  by deviceId + key + day window, ascending) and whose dailyMetricsRange is empty. Every
     *  other dao call throws, proof the resolver reached past its contract. */
    private fun repo(rows: List<MetricSeriesRow>): WhoopRepository {
        val dao = Proxy.newProxyInstance(
            WhoopDao::class.java.classLoader,
            arrayOf(WhoopDao::class.java),
        ) { _, method, args ->
            when (method.name) {
                "metricSeries" -> {
                    val a = args!!
                    val deviceId = a[0] as String
                    val key = a[1] as String
                    val lo = a[2] as String
                    val hi = a[3] as String
                    rows.filter { it.deviceId == deviceId && it.key == key && it.day >= lo && it.day <= hi }
                        .sortedBy { it.day }
                }
                "dailyMetricsRange" -> emptyList<DailyMetric>()
                else -> throw UnsupportedOperationException("resolver must not call ${method.name}")
            }
        } as WhoopDao
        return WhoopRepository(dao)
    }

    private fun row(source: String, day: String, value: Double) =
        MetricSeriesRow(deviceId = source, day = day, key = "sleep_performance", value = value)

    // --- the #175 fix: threading the active id reaches the re-added strap's banked scores ---

    @Test
    fun reAddedStrap_threadedActiveId_resolvesScoresBankedUnderItsComputedSibling() = runBlocking {
        val repo = repo(
            listOf(
                row("$reAdded-noop", "2026-07-08", 91.0),
                row("$reAdded-noop", "2026-07-09", 84.0),
            ),
        )

        val resolved = repo.resolvedSeries(
            "sleep_performance", canonical, from, to,
            strapDeviceId = reAdded,
        )

        assertEquals(
            listOf("2026-07-08" to 91.0, "2026-07-09" to 84.0),
            resolved.values,
        )
        assertEquals(listOf("$reAdded-noop"), resolved.usedSources)
    }

    /** The #172 symptom, pinned: the legacy canonical DEFAULT cannot see scores banked under the
     *  re-added strap's computed sibling — exactly why the Rest ring read "Calibrating" while the
     *  Sleep tab showed scored nights. If this test ever starts passing, the default grew re-add
     *  awareness and the eight #175 call-site overrides can be reconsidered. */
    @Test
    fun reAddedStrap_legacyCanonicalDefault_missesTheBankedScores() = runBlocking {
        val repo = repo(
            listOf(
                row("$reAdded-noop", "2026-07-08", 91.0),
                row("$reAdded-noop", "2026-07-09", 84.0),
            ),
        )

        // No strapDeviceId: the pre-#175 caller shape.
        val resolved = repo.resolvedSeries("sleep_performance", canonical, from, to)

        assertTrue(
            "canonical-default read must not see \"$reAdded-noop\" rows (got ${resolved.values})",
            resolved.values.isEmpty(),
        )
    }

    // --- the #175 "byte-identical" claim for single-strap installs ---

    @Test
    fun singleStrapInstall_threadedAndDefaultReadsAreIdentical() = runBlocking {
        val repo = repo(
            listOf(
                row("$canonical-noop", "2026-07-08", 77.0),
                row("$canonical-noop", "2026-07-09", 82.0),
            ),
        )

        val threaded = repo.resolvedSeries(
            "sleep_performance", canonical, from, to,
            strapDeviceId = canonical, // activeStrapId resolves to the canonical id
        )
        val default = repo.resolvedSeries("sleep_performance", canonical, from, to)

        assertEquals(default.candidates, threaded.candidates)
        assertEquals(default.values, threaded.values)
        assertEquals(listOf("2026-07-08" to 77.0, "2026-07-09" to 82.0), threaded.values)
    }

    // --- the #1008 union, exercised through the threaded read ---

    @Test
    fun threadedRead_activeWinsItsDay_canonicalFillsHistoryBankedBeforeReAdd() = runBlocking {
        val repo = repo(
            listOf(
                // History banked under the canonical pair BEFORE the re-add…
                row("$canonical-noop", "2026-07-01", 70.0),
                row("$canonical-noop", "2026-07-08", 80.0),
                // …and the re-added strap's own scored night for the 8th.
                row("$reAdded-noop", "2026-07-08", 91.0),
            ),
        )

        val resolved = repo.resolvedSeries(
            "sleep_performance", canonical, from, to,
            strapDeviceId = reAdded,
        )

        // Active pair wins the day it covers; canonical fills the pre-re-add day. Nothing dropped.
        assertEquals(
            listOf("2026-07-01" to 70.0, "2026-07-08" to 91.0),
            resolved.values,
        )
        assertEquals(listOf("$canonical-noop", "$reAdded-noop"), resolved.usedSources.sorted())
    }
}
