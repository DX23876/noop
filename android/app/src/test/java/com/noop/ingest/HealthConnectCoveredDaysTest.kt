package com.noop.ingest

import com.noop.data.DailyMetric
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pins the #112 fix: the Health Connect backfill skips any day the strap already covers, where
 * "cover" means EITHER a raw "my-whoop" daily row OR a computed "my-whoop-noop" row (the derived
 * recovery/strain/sleep source IntelligenceEngine writes). For a strap-only WHOOP user there are
 * no raw "my-whoop" rows, so the computed source is the ONLY thing marking their days as owned —
 * unioning the two day-sets is what stops the sparse HC row (recovery/strain/stages = null) from
 * shadowing a computed day and blanking Today / regressing Sleep stages.
 *
 * Covers the pure [HealthConnectImporter.coveredDaySet] mapper + the union semantics the importer
 * applies to it. No Room / Context / Health Connect client needed.
 */
class HealthConnectCoveredDaysTest {

    private fun row(deviceId: String, day: String) = DailyMetric(deviceId = deviceId, day = day)

    @Test
    fun coveredDaySetIsTheDistinctDaysOfTheRows() {
        val rows = listOf(
            row("my-whoop-noop", "2026-06-08"),
            row("my-whoop-noop", "2026-06-09"),
            row("my-whoop-noop", "2026-06-09"), // duplicate day collapses
        )
        assertEquals(setOf("2026-06-08", "2026-06-09"), HealthConnectImporter.coveredDaySet(rows))
    }

    @Test
    fun emptyRowsGiveEmptyCoverage() {
        assertTrue(HealthConnectImporter.coveredDaySet(emptyList()).isEmpty())
    }

    /**
     * The strap-only case that regressed in #112: NO raw "my-whoop" rows, but the computed
     * "my-whoop-noop" source covers today. The union must include today so HC does NOT backfill
     * (and shadow) it — while a day the strap never covered stays open for gap-fill.
     */
    @Test
    fun computedSourceCoversAStrapOnlyUsersDays() {
        val rawDays = HealthConnectImporter.coveredDaySet(emptyList()) // strap-only: no raw rows
        val computedDays = HealthConnectImporter.coveredDaySet(
            listOf(
                row("my-whoop-noop", "2026-06-09"),
                row("my-whoop-noop", "2026-06-10"),
            )
        )
        val covered = rawDays + computedDays

        // Strap-covered days are owned -> HC must skip them.
        assertTrue("2026-06-09 in covered", "2026-06-09" in covered)
        assertTrue("2026-06-10 in covered", "2026-06-10" in covered)
        // A day the strap never covered stays open for HC gap-fill.
        assertFalse("2026-06-07 not in covered", "2026-06-07" in covered)
    }

    /**
     * A real (non-strap-only) WHOOP user has raw "my-whoop" rows too; the union of raw + computed
     * covers both, and any day neither source has is still left open for Health Connect.
     */
    @Test
    fun unionOfRawAndComputedCoversBothAndLeavesGapsOpen() {
        val rawDays = HealthConnectImporter.coveredDaySet(
            listOf(row("my-whoop", "2026-06-05"), row("my-whoop", "2026-06-06"))
        )
        val computedDays = HealthConnectImporter.coveredDaySet(
            listOf(row("my-whoop-noop", "2026-06-06"), row("my-whoop-noop", "2026-06-07"))
        )
        val covered = rawDays + computedDays

        assertEquals(setOf("2026-06-05", "2026-06-06", "2026-06-07"), covered)
        assertFalse("2026-06-08 left open for gap-fill", "2026-06-08" in covered)
    }

    // ---- #112 follow-up: the gate unions EVERY strap-native source id, not just the canonical
    // "my-whoop"/"my-whoop-noop" pair, so an actively paired strap's "whoop-<mac>" days are owned.

    @Test
    fun strapNativeSourceIdsAreRecognised() {
        // Canonical pair.
        assertTrue(HealthConnectImporter.isStrapNativeSourceId("my-whoop"))
        assertTrue(HealthConnectImporter.isStrapNativeSourceId("my-whoop-noop"))
        // Actively paired strap: raw BLE id + its computed twin.
        assertTrue(HealthConnectImporter.isStrapNativeSourceId("whoop-aa:bb:cc:dd:ee:ff"))
        assertTrue(HealthConnectImporter.isStrapNativeSourceId("whoop-aa:bb:cc:dd:ee:ff-noop"))
        // Any other on-device computed source counts as strap coverage.
        assertTrue(HealthConnectImporter.isStrapNativeSourceId("xiaomi-band-noop"))
        // Case-insensitive (ids are stored lowercase, but never rely on it).
        assertTrue(HealthConnectImporter.isStrapNativeSourceId("WHOOP-AA:BB-NOOP"))
    }

    @Test
    fun importerOwnedSourcesAreNotStrapCoverage() {
        assertFalse(HealthConnectImporter.isStrapNativeSourceId("health-connect"))
        assertFalse(HealthConnectImporter.isStrapNativeSourceId("apple-health"))
        assertFalse(HealthConnectImporter.isStrapNativeSourceId("xiaomi-band"))
        assertFalse(HealthConnectImporter.isStrapNativeSourceId("manual"))
        assertFalse(HealthConnectImporter.isStrapNativeSourceId(""))
    }

    /**
     * The re-paired-strap case behind the shadow-row bug: fresh nights live ONLY under the active
     * strap's "whoop-<mac>" / "whoop-<mac>-noop" ids. Filtering the discovered id list through
     * [HealthConnectImporter.isStrapNativeSourceId] and unioning per-id day-sets must own those
     * days too — the old canonical-pair-only read left them open and HC shadowed them.
     */
    @Test
    fun activeStrapIdsCoverTheirDays() {
        val discovered = listOf(
            "my-whoop", "my-whoop-noop",
            "whoop-aa:bb:cc:dd:ee:ff-noop", // active strap, computed nights only
            "health-connect", "apple-health", // importer-owned: must NOT contribute coverage
        )
        val strapIds = discovered.filter { HealthConnectImporter.isStrapNativeSourceId(it) }
        assertEquals(listOf("my-whoop", "my-whoop-noop", "whoop-aa:bb:cc:dd:ee:ff-noop"), strapIds)

        val rowsBySource = mapOf(
            "my-whoop" to listOf(row("my-whoop", "2026-06-01")),
            "my-whoop-noop" to listOf(row("my-whoop-noop", "2026-06-02")),
            "whoop-aa:bb:cc:dd:ee:ff-noop" to listOf(row("whoop-aa:bb:cc:dd:ee:ff-noop", "2026-06-09")),
            "health-connect" to listOf(row("health-connect", "2026-06-10")),
        )
        val covered = strapIds.fold(emptySet<String>()) { acc, id ->
            acc + HealthConnectImporter.coveredDaySet(rowsBySource[id].orEmpty())
        }

        assertEquals(setOf("2026-06-01", "2026-06-02", "2026-06-09"), covered)
        // The HC-owned day is NOT strap coverage — it stays open so HC may rewrite its own rows.
        assertFalse("2026-06-10" in covered)
    }
}
