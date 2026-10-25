package com.noop.ui.forge

import com.noop.core.CoreRead
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import java.time.LocalDate

class ForgeLogicTest {
    @Test fun theSceneSlotsMatchTheSwiftTable() {
        // DayCycleScene.slot(hour:) in StrandDesign, hour by hour.
        val swift = listOf(1, 1, 1, 1, 1, 2, 3, 6, 7, 7, 8, 8, 10, 10, 10, 10, 10, 9, 9, 5, 5, 4, 4, 4)
        assertEquals(swift, (0..23).map(DayCycleScene::slot))
        assertEquals(1, DayCycleScene.slot(24))
        assertEquals(4, DayCycleScene.slot(-1))
    }

    @Test fun chargeBandsSplitWhereTheSwiftBandsDo() {
        assertEquals(ChargeBand.Depleted, ChargeBand.of(24.9))
        assertEquals(ChargeBand.Low, ChargeBand.of(25.0))
        assertEquals(ChargeBand.Moderate, ChargeBand.of(50.0))
        assertEquals(ChargeBand.Primed, ChargeBand.of(70.0))
        assertEquals(ChargeBand.Peak, ChargeBand.of(88.0))
    }

    @Test fun aNightSumsItsStagesAndCountsWakeAsNotAsleep() {
        val night = CoreRead.Night(0, 8 * 3600, 0.9, 50, 70.0, false, listOf(
            CoreRead.Night.Stage("wake", 0, 600), CoreRead.Night.Stage("light", 600, 3600),
            CoreRead.Night.Stage("deep", 3600, 7200), CoreRead.Night.Stage("rem", 7200, 8 * 3600)))
        val s = SleepSummary.of(night)
        assertEquals(480, s.inBedMin)
        assertEquals(470, s.asleepMin)
        assertEquals(60 + 360, s.restorativeMin)
    }

    @Test fun aNightWithoutStagesIsAsleepThroughout() {
        val s = SleepSummary.of(CoreRead.Night(0, 3600, null, null, null, false, emptyList()))
        assertEquals(60, s.asleepMin)
    }

    @Test fun aTrendComparesTheWindowWithTheOneBefore() {
        val today = LocalDate.parse("2026-10-14")
        val points = (0 until 14).map { CoreRead.Point(today.minusDays(it.toLong()).toString(), if (it < 7) 60.0 else 50.0) }
        val t = TrendStats.of(points, 7, today)
        assertEquals(7, t.current.size)
        assertEquals(60.0, t.average!!, 0.0)
        assertEquals(50.0, t.previousAverage!!, 0.0)
        assertEquals(20, t.change)
    }

    @Test fun aTrendWithoutAnEarlierWindowHasNoChange() {
        val today = LocalDate.parse("2026-10-14")
        assertNull(TrendStats.of(listOf(CoreRead.Point("2026-10-14", 5.0)), 7, today).change)
    }
}
