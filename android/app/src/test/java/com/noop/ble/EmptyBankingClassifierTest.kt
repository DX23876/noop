package com.noop.ble

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pins [WhoopBleClient.classifyCompletedOffload] — the pure classification exitBackfilling runs on a
 * COMPLETED (HISTORY_COMPLETE) offload. The #214 fix is the `rowsPersisted == 0` arm: before it, the
 * empty-banking signal had ONE shape (console-only across ≥3 diagnostic chunks), so a NEAR-EMPTY
 * metadata-only completion (zero rows persisted, fewer than 3 console frames) slipped through to the
 * silent branch and surfaced no "charge to 100% and reconnect" guidance. Kotlin twin of the macOS
 * EmptyBankingClassifierTests. Banner firing still requires a SUSTAINED streak (EmptySyncTracker, #126).
 */
class EmptyBankingClassifierTest {

    @Test
    fun decodedChunksAreBanking() {
        val (banked, nothing) = WhoopBleClient.classifyCompletedOffload(
            decodedChunks = 5, consoleChunks = 0, rowsPersisted = 120,
        )
        assertTrue(banked)
        assertFalse(nothing)
    }

    @Test
    fun consoleOnlyAcrossManyChunksIsBankedNothing() {
        val (banked, nothing) = WhoopBleClient.classifyCompletedOffload(
            decodedChunks = 0, consoleChunks = 4, rowsPersisted = 0,
        )
        assertFalse(banked)
        assertTrue(nothing)
    }

    // #214 regression case: metadata-only completion — zero rows, FEWER than 3 console frames.
    @Test
    fun metadataOnlyZeroRowsIsBankedNothing() {
        val (banked, nothing) = WhoopBleClient.classifyCompletedOffload(
            decodedChunks = 0, consoleChunks = 0, rowsPersisted = 0,
        )
        assertFalse(banked)
        assertTrue("#214: a metadata-only completion that persisted 0 rows banks nothing", nothing)
    }

    @Test
    fun fewConsoleFramesZeroRowsIsBankedNothing() {
        val (_, nothing) = WhoopBleClient.classifyCompletedOffload(
            decodedChunks = 0, consoleChunks = 2, rowsPersisted = 0,
        )
        assertTrue("#214: < 3 console frames no longer hides a zero-row completion", nothing)
    }

    // Rows persisted (but nothing decoded this pass) is NOT "banked nothing".
    @Test
    fun rowsPersistedIsNotBankedNothing() {
        val (banked, nothing) = WhoopBleClient.classifyCompletedOffload(
            decodedChunks = 0, consoleChunks = 0, rowsPersisted = 40,
        )
        assertTrue(banked)
        assertFalse("rows were persisted — the strap is banking", nothing)
    }

    // The new signal still feeds the SUSTAINED-streak gate: 3 consecutive metadata-only completions are
    // required before the banner trips (the #126 guard is unchanged); a banking cycle clears the streak.
    @Test
    fun metadataOnlyTripsBannerOnlyWhenSustained() {
        val tracker = EmptySyncTracker()   // default threshold 3
        fun recordMetadataOnly(): Boolean {
            val (banked, nothing) = WhoopBleClient.classifyCompletedOffload(0, 0, 0)
            return tracker.recordCompletedSync(bankedSensorRecords = banked, consoleOnly = nothing)
        }
        assertFalse(recordMetadataOnly())
        assertFalse(recordMetadataOnly())
        assertTrue("#214 + #126: three consecutive metadata-only completions trip the guidance",
            recordMetadataOnly())
    }

    // #324/#928 future-dated strap banner — Kotlin twin of the macOS futureDatedStrapBanner tests.

    @Test
    fun futureDatedNewestSurfacesBanner() {
        val now = 1_783_843_824L                    // ~2026-07-12, the reporter's wall clock
        val newest = now + 26_445L * 3600L          // 26445 h ahead — the #324 log's banked frontier
        val banner = WhoopBleClient.futureDatedStrapBanner(newest, now)
        assertNotNull(banner)
        assertTrue(banner!!.contains("set in the future"))
        assertTrue(banner.contains("power-cycle"))
    }

    @Test
    fun currentStrapNoFutureBanner() {
        val now = 1_783_843_824L
        assertEquals(null, WhoopBleClient.futureDatedStrapBanner(now - 3600L, now))
        assertEquals(null, WhoopBleClient.futureDatedStrapBanner(now, now))
    }

    @Test
    fun withinSkewAllowanceNoFutureBanner() {
        val now = 1_783_843_824L
        assertEquals("24 h ahead is within the 48 h allowance — not flagged",
            null, WhoopBleClient.futureDatedStrapBanner(now + 24L * 3600L, now))
        assertTrue("just past 48 h is future-dated",
            WhoopBleClient.futureDatedStrapBanner(now + 49L * 3600L, now) != null)
    }

    @Test
    fun nilNewestNoFutureBanner() {
        assertEquals(null, WhoopBleClient.futureDatedStrapBanner(null, 1_783_843_824L))
    }

    @Test
    fun bankingCycleResetsTheMetadataOnlyStreak() {
        val tracker = EmptySyncTracker()
        val empty = WhoopBleClient.classifyCompletedOffload(0, 0, 0)
        val banking = WhoopBleClient.classifyCompletedOffload(decodedChunks = 3, consoleChunks = 0, rowsPersisted = 90)
        tracker.recordCompletedSync(bankedSensorRecords = empty.first, consoleOnly = empty.second)
        tracker.recordCompletedSync(bankedSensorRecords = empty.first, consoleOnly = empty.second)
        tracker.recordCompletedSync(bankedSensorRecords = banking.first, consoleOnly = banking.second)
        assertEquals(0, tracker.consecutiveEmptySyncs)
    }
}
