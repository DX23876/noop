package com.noop.ui

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * Unit tests for [zoneCoachBuzzLoops], the pure HR-zone coaching buzz decision behind
 * AppViewModel.coachZone. Mirrors macOS AppModel.coachZone: a triple-buzz on climbing into Zone 5,
 * a single buzz on recovering to Zone 1 (when enabled), and nothing otherwise.
 * Reimplemented from @cbarrado's PR #350.
 */
class ZoneCoachTest {

    @Test fun firstObservationNeverBuzzes() {
        // previousZone == -1 means we've only just started watching: record, don't buzz.
        assertEquals(0, zoneCoachBuzzLoops(previousZone = -1, zone = 5, recoveryEnabled = true))
        assertEquals(0, zoneCoachBuzzLoops(previousZone = -1, zone = 1, recoveryEnabled = true))
    }

    @Test fun sameZoneDoesNotBuzz() {
        assertEquals(0, zoneCoachBuzzLoops(previousZone = 5, zone = 5, recoveryEnabled = true))
        assertEquals(0, zoneCoachBuzzLoops(previousZone = 3, zone = 3, recoveryEnabled = true))
    }

    @Test fun enteringTopZoneTripleBuzzes() {
        assertEquals(3, zoneCoachBuzzLoops(previousZone = 4, zone = 5, recoveryEnabled = true))
        // Recovery flag is irrelevant to the top-zone buzz.
        assertEquals(3, zoneCoachBuzzLoops(previousZone = 2, zone = 5, recoveryEnabled = false))
    }

    @Test fun recoveringToZone1BuzzesOnceWhenEnabled() {
        assertEquals(1, zoneCoachBuzzLoops(previousZone = 3, zone = 1, recoveryEnabled = true))
        // Below Zone 1 (zoneNumber returns 0) still counts as recovered.
        assertEquals(1, zoneCoachBuzzLoops(previousZone = 4, zone = 0, recoveryEnabled = true))
    }

    @Test fun recoveryBuzzSuppressedWhenDisabled() {
        assertEquals(0, zoneCoachBuzzLoops(previousZone = 3, zone = 1, recoveryEnabled = false))
        assertEquals(0, zoneCoachBuzzLoops(previousZone = 4, zone = 0, recoveryEnabled = false))
    }

    @Test fun midZoneChangesDoNotBuzz() {
        // Dropping out of the top zone but not to recovery, or climbing without reaching Zone 5.
        assertEquals(0, zoneCoachBuzzLoops(previousZone = 5, zone = 4, recoveryEnabled = true))
        assertEquals(0, zoneCoachBuzzLoops(previousZone = 2, zone = 3, recoveryEnabled = true))
        assertEquals(0, zoneCoachBuzzLoops(previousZone = 3, zone = 2, recoveryEnabled = true))
    }

    @Test fun shufflingWithinRecoveryDoesNotRebuzz() {
        // Already at/under Zone 1 (previous <= 1) → no fresh recovery buzz on the 1↔0 wobble.
        assertEquals(0, zoneCoachBuzzLoops(previousZone = 1, zone = 0, recoveryEnabled = true))
        assertEquals(0, zoneCoachBuzzLoops(previousZone = 0, zone = 1, recoveryEnabled = true))
    }
}
