package com.noop.analytics

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Boundary tests for [Baselines.deviceEraEpoch] (#459): the recalibration epoch at the latest
 * device-era boundary in a source-tagged nightly history, so a baseline never mixes two brands'
 * incompatible HRV scales (Oura RMSSD ~120-155 ms vs WHOOP ~72-112 ms across a switch). Mirrors the
 * Swift DeviceEraEpochTests so both platforms compute the SAME epoch for the same history.
 */
class DeviceEraEpochTest {

    private fun epochOfDayUTC(day: String): Double =
        java.time.LocalDate.parse(day)
            .atStartOfDay(java.time.ZoneOffset.UTC).toEpochSecond().toDouble()

    // ── single brand → no epoch (byte-identical fold for every single-device user) ──────────────

    @Test fun emptyHistoryIsZero() {
        assertEquals(0.0, Baselines.deviceEraEpoch(emptyList()), 0.0)
    }

    @Test fun oneWhoopBrandAcrossManyIdsIsZero() {
        // The canonical import, the active strap, and the "-noop" computed sibling ALL bucket to
        // "whoop", so a normal WHOOP user (whose nights span all three ids) gets no epoch → unchanged.
        val days = listOf(
            "2026-01-01" to "my-whoop",
            "2026-01-02" to "my-whoop-noop",
            "2026-01-03" to "whoop-EA:DC:0C:67:20:04",
            "2026-01-04" to "my-whoop",
        )
        assertEquals(0.0, Baselines.deviceEraEpoch(days), 0.0)
    }

    @Test fun oneWearableBrandOnlyIsZero() {
        // A pure Oura importer (never paired a WHOOP) has one brand → no boundary.
        val days = (1..40).map { "2026-01-%02d".format(it) to "oura-import" }
        assertEquals(0.0, Baselines.deviceEraEpoch(days), 0.0)
    }

    // ── the reported case: Oura era then WHOOP era, no overlap ──────────────────────────────────

    @Test fun ouraThenWhoopReturnsFirstWhoopDay() {
        val days = buildList {
            for (d in 1..15) add("2026-01-%02d".format(d) to "oura-import")
            for (d in 16..31) add("2026-01-%02d".format(d) to "my-whoop")
        }
        // Epoch = start of the first WHOOP night, so foldHistory drops every Oura night before it.
        assertEquals(epochOfDayUTC("2026-01-16"), Baselines.deviceEraEpoch(days), 0.0)
    }

    @Test fun unsortedInputIsSortedInternally() {
        val days = listOf(
            "2026-01-16" to "my-whoop",
            "2026-01-02" to "oura-import",
            "2026-01-31" to "my-whoop",
            "2026-01-01" to "oura-import",
            "2026-01-20" to "my-whoop",
        )
        assertEquals(epochOfDayUTC("2026-01-16"), Baselines.deviceEraEpoch(days), 0.0)
    }

    @Test fun whoopThenOuraReturnsFirstOuraDay() {
        // Symmetry: whichever brand is NEWEST defines the current era; the epoch opens that era.
        val days = buildList {
            for (d in 1..10) add("2026-02-%02d".format(d) to "my-whoop")
            for (d in 11..20) add("2026-02-%02d".format(d) to "oura-import")
        }
        assertEquals(epochOfDayUTC("2026-02-11"), Baselines.deviceEraEpoch(days), 0.0)
    }

    @Test fun onlyTheLatestBoundaryMatters_ouraWhoopOura() {
        // Two switches: the epoch is the LATEST era's start (the second Oura run), not the first.
        val days = buildList {
            for (d in 1..5) add("2026-03-%02d".format(d) to "oura-import")
            for (d in 6..10) add("2026-03-%02d".format(d) to "my-whoop")
            for (d in 11..15) add("2026-03-%02d".format(d) to "oura-import")
        }
        assertEquals(epochOfDayUTC("2026-03-11"), Baselines.deviceEraEpoch(days), 0.0)
    }

    @Test fun fitbitAndGarminAreDistinctBrands() {
        val days = buildList {
            for (d in 1..5) add("2026-04-%02d".format(d) to "garmin-import")
            for (d in 6..10) add("2026-04-%02d".format(d) to "fitbit-import")
        }
        assertEquals(epochOfDayUTC("2026-04-06"), Baselines.deviceEraEpoch(days), 0.0)
    }

    @Test fun sameDayMixedBrandTieBreaksDeterministically() {
        // An overlap night carrying BOTH an Oura and a WHOOP row on the same day: the (day, sourceId)
        // total order must resolve the tie identically to the Swift twin, so the epoch never diverges by
        // platform. "my-whoop" < "oura-import" lexically, so on the last day the WHOOP row sorts last and
        // defines the current brand; the boundary lands where the last pure-Oura day gives way.
        val days = listOf(
            "2026-06-01" to "oura-import",
            "2026-06-02" to "oura-import",
            "2026-06-03" to "my-whoop",   // overlap day: both brands present
            "2026-06-03" to "oura-import",
            "2026-06-04" to "my-whoop",
        )
        // After the (day, sourceId) total sort the overlap day orders my-whoop < oura-import, so the LAST
        // row on 2026-06-03 is oura-import. The current-brand (whoop) suffix walk therefore breaks at that
        // 06-03 oura row, and the era opens at 2026-06-04 — the same result the Swift twin computes.
        assertEquals(epochOfDayUTC("2026-06-04"), Baselines.deviceEraEpoch(days), 0.0)
    }

    // ── brand bucketing ────────────────────────────────────────────────────────────────────────

    @Test fun brandBucketCollapsesWhoopIdsAndSeparatesWearables() {
        assertEquals("whoop", Baselines.brandBucket("my-whoop"))
        assertEquals("whoop", Baselines.brandBucket("my-whoop-noop"))
        assertEquals("whoop", Baselines.brandBucket("whoop-AA:BB:CC:DD:EE:FF"))
        assertEquals("whoop", Baselines.brandBucket("apple-health"))   // rides the strap scale
        assertEquals("oura", Baselines.brandBucket("oura-import"))
        assertEquals("fitbit", Baselines.brandBucket("fitbit-import"))
        assertEquals("garmin", Baselines.brandBucket("garmin-import"))
    }

    // ── the epoch actually re-seeds foldHistory across the scale jump ────────────────────────────

    @Test fun epochDropsPreSwitchNightsFromTheFold() {
        // 15 Oura nights at ~135 ms then 6 WHOOP nights at ~90 ms. Folding the WHOLE history anchors
        // the baseline high (Oura-inflated); applying the era epoch drops the Oura nights so the
        // baseline re-learns from the WHOOP era and no longer reads the WHOOP nights as suppressed.
        val ouraVals = (1..15).map { 135.0 }
        val whoopVals = (1..6).map { 90.0 }
        val values: List<Double?> = ouraVals + whoopVals
        val dayKeys = buildList {
            for (d in 1..15) add("2026-05-%02d".format(d))
            for (d in 16..21) add("2026-05-%02d".format(d))
        }
        val sourceDays = buildList {
            for (d in 1..15) add("2026-05-%02d".format(d) to "oura-import")
            for (d in 16..21) add("2026-05-%02d".format(d) to "my-whoop")
        }
        val eraEpoch = Baselines.deviceEraEpoch(sourceDays)
        val mixed = Baselines.foldHistory(values, dayKeys, Baselines.hrvCfg, 0.0)
        val gated = Baselines.foldHistory(values, dayKeys, Baselines.hrvCfg, eraEpoch)
        assertTrue("era-gated baseline sits near the WHOOP era, not the Oura-inflated mean",
            gated.baseline < mixed.baseline)
        assertTrue("era-gated baseline is close to the WHOOP nightly level", gated.baseline <= 100.0)
        // The final WHOOP night reads far LESS suppressed against the era baseline than the mixed one.
        assertTrue(
            "z of a 90 ms WHOOP night is higher (less negative) against the era baseline",
            Baselines.deviation(90.0, gated).z > Baselines.deviation(90.0, mixed).z,
        )
    }
}
