package com.noop.protocol

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * FIX #72: a grossly-stale strap RTC (the strap sat unused for months, so its clock is months behind)
 * misdates offloaded history. The extractor now corrects type-47/EVENT timestamps by the (wall - device)
 * clock offset when grossly stale, SNAPPED to a 5-min grid so re-syncs dedupe, and is a no-op for a normal
 * clock. Uses the same real worn v18 frame (unix=1780916150) as Whoop5HistoricalDecodeTest. Mirrors the
 * macOS Whoop4HistoricalV24HardwareTests #72 cases.
 */
class HistoricalStreamsClockCorrectionTest {
    private fun bytes(s: String): ByteArray =
        s.chunked(2).map { it.toInt(16).toByte() }.toByteArray()

    private val wornV18 =
        "aa01740001003fb12f1280733d8401b69f266a66460066025a0265020000000000007b0a8d656463ff0012163cf6a439bf2924fd3ed763fe3e3200aa000000000000000000f7000901f10b0007010c020c00000000000000000000000000000000000000000000000100656f1e1e0000009d61a7c00000003e862817"

    @Test fun zeroedStrapRtcKeepsRealUnixInsteadOfFutureDating() {
        // FIELD BUG (#471): a fully-drained strap whose RTC reset to ~epoch reports a near-zero device
        // clock while its frames still carry the true-unix rawTs. clockOffset is then ~decades and the
        // naive correction hurled every sample to year 2081 — silently killing sleep & recovery. The
        // guard must keep the already-correct rawTs rather than date it into the future.
        val rawTs = 1_780_916_150L
        val wall = rawTs + 7 * 86_400                            // offloaded a week later
        val st = extractHistoricalStreams(listOf(bytes(wornV18)), 31_500_000, wall.toInt(), DeviceFamily.WHOOP5) // RTC ~1971
        assertEquals(rawTs, st.hr.first().ts)                   // kept; not rawTs + ~55 years
    }

    @Test fun staleClockShiftsHistoricalTimestampForwardAndSnaps() {
        // device >= rawTs keeps the record in the strap's past (corrected <= wall), so the
        // never-date-into-the-future guard leaves this genuine stale-clock correction unchanged.
        val device = 1_780_920_000
        val wall = device + 60 * 86_400 + 137                    // ~60 days ahead, +137s exercises snapping
        val st = extractHistoricalStreams(listOf(bytes(wornV18)), device, wall, DeviceFamily.WHOOP5)
        val rawTs = 1_780_916_150L
        val snapped = ((wall - device) + 150) / 300 * 300        // round-half-up; offset > 0
        assertEquals(rawTs + snapped, st.hr.first().ts)
        assertEquals(0L, (st.hr.first().ts - rawTs) % 300)       // landed on the 5-min grid
    }

    @Test fun staleClockCorrectionIsDedupStableAcrossResync() {
        // Realistic re-sync jitter (~seconds, same 5-min bucket) → identical corrected ts → dedupes.
        val device = 1_780_920_000
        val a = extractHistoricalStreams(listOf(bytes(wornV18)), device, device + 60 * 86_400 + 10, DeviceFamily.WHOOP5)
        val b = extractHistoricalStreams(listOf(bytes(wornV18)), device, device + 60 * 86_400 + 13, DeviceFamily.WHOOP5)
        assertEquals(a.hr.first().ts, b.hr.first().ts)
    }

    @Test fun normalClockLeavesHistoricalTimestampUnchanged() {
        val identity = extractHistoricalStreams(listOf(bytes(wornV18)), 0, 0, DeviceFamily.WHOOP5)
        assertEquals(1_780_916_150L, identity.hr.first().ts)
        val drift = extractHistoricalStreams(listOf(bytes(wornV18)), 1_780_000_000, 1_780_003_600, DeviceFamily.WHOOP5) // 1h
        assertEquals(1_780_916_150L, drift.hr.first().ts)
    }

    // ── #547 ingest gate ────────────────────────────────────────────────────────────────────────────
    // A bad strap clock/flash (pikapik) emits records whose `unix` decodes to scattered garbage — far-past
    // (year 2024/2019/…), a 2027 spike (1_827_642_881), and even a FUTURE date — which entered the DB
    // verbatim and polluted the day-windowed analytics. The gate now drops any record whose final ts is
    // < MIN_PLAUSIBLE_UNIX (2023-11) or > now + FUTURE_MARGIN (1 day), keeping a normal recent ts identical.

    /** Overwrite the v18 record's unix (u32 LE @15) and recompute the WHOOP5 CRC32 trailer so the frame
     *  still passes the integrity gate. Header CRC16 covers only frame[0..6) (not the unix), so only the
     *  payload CRC32 (over frame[8..total-4), stored LE at total-4) needs rebuilding. */
    private fun wornV18WithUnix(unix: Long): ByteArray {
        val f = bytes(wornV18)
        val declaredLength = (f[2].toInt() and 0xFF) or ((f[3].toInt() and 0xFF) shl 8)
        val total = declaredLength + 8
        for (i in 0 until 4) f[15 + i] = ((unix shr (8 * i)) and 0xFF).toByte()
        val payload = f.copyOfRange(8, total - 4)
        val crc = Crc.crc32(payload)
        for (i in 0 until 4) f[total - 4 + i] = ((crc shr (8 * i)) and 0xFF).toByte()
        return f
    }

    @Test fun gateDropsFutureDatedRecord() {
        // The worn frame's real unix is 1_780_916_150. Set "now" ten days BEFORE it, so the record is
        // > now + 1 day in the future — a bad-clock artefact the gate must reject (no rows, drop counted).
        val rawTs = 1_780_916_150L
        val now = rawTs - 10 * 86_400
        val st = extractHistoricalStreams(
            listOf(bytes(wornV18)), 0, 0, DeviceFamily.WHOOP5, wallNow = now,
        )
        assertTrue("future-dated record must produce no rows", st.hr.isEmpty())
        assertEquals(1, st.droppedImplausibleTs)
    }

    @Test fun gateKeepsRecordWithinOneDayFuture() {
        // Boundary: a record exactly within the +1-day margin is NOT future-dated — kept, byte-identical.
        val rawTs = 1_780_916_150L
        val now = rawTs - 86_400 + 10           // record is +1 day - 10s ahead → inside the margin
        val st = extractHistoricalStreams(
            listOf(bytes(wornV18)), 0, 0, DeviceFamily.WHOOP5, wallNow = now,
        )
        assertEquals(rawTs, st.hr.first().ts)
        assertEquals(0, st.droppedImplausibleTs)
    }

    @Test fun gateDropsFarPastRecord() {
        // A record whose unix decodes below the 1.7B floor (here 2019) is garbage from a reset RTC — drop.
        val farPast = 1_550_000_000L            // 2019-02, < MIN_PLAUSIBLE_UNIX (1_700_000_000)
        val st = extractHistoricalStreams(
            listOf(wornV18WithUnix(farPast)), 0, 0, DeviceFamily.WHOOP5, wallNow = 1_780_916_150L,
        )
        assertTrue("far-past record must produce no rows", st.hr.isEmpty())
        assertEquals(1, st.droppedImplausibleTs)
    }

    @Test fun gateKeepsNormalRecentTimestampByteIdentical() {
        // The control: a plausible recent ts (re-CRC'd to a value just inside the floor + comfortably in
        // the past) is admitted UNCHANGED — the gate is a garbage filter, never a transform.
        val recent = 1_780_916_150L
        val st = extractHistoricalStreams(
            listOf(wornV18WithUnix(recent)), 0, 0, DeviceFamily.WHOOP5, wallNow = recent + 3_600,
        )
        assertEquals(recent, st.hr.first().ts)   // byte-identical pass-through
        assertEquals(0, st.droppedImplausibleTs)

        // And the floor boundary: exactly MIN_PLAUSIBLE_UNIX is kept (inclusive).
        val floor = MIN_PLAUSIBLE_UNIX
        val atFloor = extractHistoricalStreams(
            listOf(wornV18WithUnix(floor)), 0, 0, DeviceFamily.WHOOP5, wallNow = 1_780_916_150L,
        )
        assertEquals(floor, atFloor.hr.first().ts)
        assertEquals(0, atFloor.droppedImplausibleTs)
    }

    // ── #547 SESSION-RELATIVE gate (re-pollution by a wandering clock) ────────────────────────────────
    // A wandering-clock strap re-sends records whose `unix` clears the absolute 2023-11 floor but is months
    // OUTSIDE the strap's own GET_DATA_RANGE [oldest, newest] window for THIS sync (e.g. 2024-12-25 against a
    // 2026 strap). Those are dropped session-relatively; a legitimately-old record WITHIN the window is kept.
    // Mirrors the Swift HistoricalTimestampGateTests session-relative cases 1:1 (same SESSION_RANGE_MARGIN).

    @Test fun sessionRelativeBoundsMatchSwift() {
        assertEquals(7L * 86_400L, SESSION_RANGE_MARGIN)
    }

    @Test fun sessionRelativeDropsFloorClearingOutOfWindowRecord() {
        // 2024-12-25 record (clears the 2023-11 floor) arriving against a 2026 fortnight strap window.
        val newest = 1_780_916_150L                       // strap's newest banked record
        val oldest = newest - 14 * 86_400                 // strap banked a ~2-week window
        val badYule = 1_735_084_800L                      // 2024-12-25 00:00 UTC — months before `oldest`
        val st = extractHistoricalStreams(
            listOf(wornV18WithUnix(badYule)), 0, 0, DeviceFamily.WHOOP5,
            wallNow = newest, sessionOldestUnix = oldest, sessionNewestUnix = newest,
        )
        assertTrue("a floor-clearing record months before the strap's own window is dropped", st.hr.isEmpty())
        assertEquals(1, st.droppedImplausibleTs)
    }

    @Test fun sessionRelativeKeepsLegitimatelyOldInWindowBackfill() {
        // A real deep-backfill record WITHIN the strap's banked window must be KEPT (session-relative).
        val newest = 1_780_916_150L
        val oldest = newest - 30 * 86_400                 // a month of banked backlog
        val realOld = oldest + 2 * 86_400                 // 2 days into the window — real history
        val st = extractHistoricalStreams(
            listOf(wornV18WithUnix(realOld)), 0, 0, DeviceFamily.WHOOP5,
            wallNow = newest, sessionOldestUnix = oldest, sessionNewestUnix = newest,
        )
        assertEquals(realOld, st.hr.first().ts)
        assertEquals(0, st.droppedImplausibleTs)
    }

    @Test fun sessionRelativeFallsBackToAbsoluteWithoutMarkers() {
        // No range markers → absolute-only gate, unchanged: a 2024-12-25 record SURVIVES (clears the floor).
        val badYule = 1_735_084_800L
        val st = extractHistoricalStreams(
            listOf(wornV18WithUnix(badYule)), 0, 0, DeviceFamily.WHOOP5, wallNow = badYule + 3_600,
        )
        assertEquals(badYule, st.hr.first().ts)
        assertEquals(0, st.droppedImplausibleTs)
    }

    @Test fun sessionRelativeIgnoresMalformedMarkers() {
        // A below-floor (wrong-epoch) oldest marker must NEVER reject real data — fall back to absolute-only.
        val newest = 1_780_916_150L
        val realRecent = newest - 3600
        val st = extractHistoricalStreams(
            listOf(wornV18WithUnix(realRecent)), 0, 0, DeviceFamily.WHOOP5,
            wallNow = newest, sessionOldestUnix = 12_345L, sessionNewestUnix = newest,
        )
        assertEquals(realRecent, st.hr.first().ts)
        assertEquals(0, st.droppedImplausibleTs)
    }

    // ── #324 bad-clock diagnostics: dropped-record epoch span ─────────────────────────────────────────
    // The EVENT-frame RTC-state capture (RTC_LOST / BOOT / SET_RTC → droppedRtcEvents) is exercised by the
    // Swift twin HistoricalTimestampGateTests (ParsedFrame fixtures); here we pin the HISTORICAL_DATA span
    // capture + the pure kind gate, which don't need a synthetic EVENT byte frame.

    @Test fun capturesDroppedEpochSpanForFutureDatedRecords() {
        val now = 1_780_916_150L
        val older = now + 100L * 86_400        // ~100 days ahead — future-dated, dropped
        val newer = now + 300L * 86_400        // ~300 days ahead — future-dated, dropped
        val st = extractHistoricalStreams(
            listOf(wornV18WithUnix(newer), wornV18WithUnix(older)), 0, 0, DeviceFamily.WHOOP5, wallNow = now,
        )
        assertEquals(2, st.droppedImplausibleTs)
        assertEquals(older, st.droppedImplausibleOldestTs)   // span brackets both, regardless of arrival order
        assertEquals(newer, st.droppedImplausibleNewestTs)
        assertTrue(st.droppedRtcEvents.isEmpty())
    }

    @Test fun noDropLeavesSpanNull() {
        val st = extractHistoricalStreams(
            listOf(wornV18WithUnix(1_780_916_150L)), 0, 0, DeviceFamily.WHOOP5, wallNow = 1_780_916_150L + 3_600,
        )
        assertEquals(null, st.droppedImplausibleOldestTs)
        assertEquals(null, st.droppedImplausibleNewestTs)
        assertTrue(st.droppedRtcEvents.isEmpty())
    }

    @Test fun rtcStateKindMatch() {
        assertTrue(DroppedRtcEvent.isRtcStateKind("RTC_LOST(13)"))
        assertTrue(DroppedRtcEvent.isRtcStateKind("SET_RTC(16)"))
        assertTrue(DroppedRtcEvent.isRtcStateKind("BOOT(15)"))
        assertTrue(DroppedRtcEvent.isRtcStateKind("BOOT_REPORT(30)"))
        assertTrue(!DroppedRtcEvent.isRtcStateKind("WRIST_ON(9)"))
        assertTrue(!DroppedRtcEvent.isRtcStateKind("BATTERY_LEVEL(3)"))
    }
}
