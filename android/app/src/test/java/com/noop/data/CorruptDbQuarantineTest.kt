package com.noop.data

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * #661: the pure quarantine-planning behind [CorruptionPreservingOpenHelperFactory]'s corruption
 * handler — timestamped `.corrupt.<epoch>` names, keep-newest-N, and never evicting the copy we just
 * wrote. The filesystem move/prune is I/O and not unit-tested here; this pins the decision logic.
 */
class CorruptDbQuarantineTest {

    @Test fun firstQuarantineEvictsNothing() {
        val plan = planCorruptQuarantine("whoop.db", emptyList(), nowMillis = 1000)
        assertEquals("whoop.db.corrupt.1000", plan.quarantineName)
        assertEquals(emptyList<String>(), plan.evict)
    }

    @Test fun underTheCapEvictsNothing() {
        val plan = planCorruptQuarantine(
            "whoop.db", listOf("whoop.db.corrupt.100", "whoop.db.corrupt.200"), nowMillis = 300, keep = 3,
        )
        assertEquals(emptyList<String>(), plan.evict)
    }

    @Test fun keepsNewestNAndEvictsOldest() {
        val existing = listOf(
            "whoop.db.corrupt.100",
            "whoop.db.corrupt.200",
            "whoop.db.corrupt.300",
        )
        val plan = planCorruptQuarantine("whoop.db", existing, nowMillis = 400, keep = 3)
        assertEquals("whoop.db.corrupt.400", plan.quarantineName)
        // Newest 3 kept = 400, 300, 200; only the oldest (100) is evicted.
        assertEquals(listOf("whoop.db.corrupt.100"), plan.evict)
    }

    @Test fun evictionOrderIsOldestFirstAcrossManyCopies() {
        val existing = (10L..14L).map { "whoop.db.corrupt.${it * 100}" } // 1000..1400
        val plan = planCorruptQuarantine("whoop.db", existing, nowMillis = 1500, keep = 3)
        // Kept: 1500, 1400, 1300. Evicted: 1200, 1100, 1000 (any order).
        assertEquals(
            listOf("whoop.db.corrupt.1000", "whoop.db.corrupt.1100", "whoop.db.corrupt.1200").sorted(),
            plan.evict.sorted(),
        )
        assertFalse("whoop.db.corrupt.1500" in plan.evict)
    }

    @Test fun theJustWrittenQuarantineIsNeverEvictedEvenIfOlderThanExistingOrKeepZero() {
        // A clock skew makes the new stamp (50) older than an existing one (100); with keep=0 the plan
        // must still protect the copy we just wrote and evict only the others.
        val plan = planCorruptQuarantine("whoop.db", listOf("whoop.db.corrupt.100"), nowMillis = 50, keep = 0)
        assertEquals("whoop.db.corrupt.50", plan.quarantineName)
        assertTrue("whoop.db.corrupt.100" in plan.evict)
        assertFalse("whoop.db.corrupt.50" in plan.evict)
    }

    @Test fun aReDeliveredExistingStampDoesNotDuplicate() {
        // If the listing already contains the new stamp (re-entrancy), it is not counted twice.
        val plan = planCorruptQuarantine(
            "whoop.db", listOf("whoop.db.corrupt.900", "whoop.db.corrupt.900"), nowMillis = 900, keep = 3,
        )
        assertEquals("whoop.db.corrupt.900", plan.quarantineName)
        assertEquals(emptyList<String>(), plan.evict)
    }
}
