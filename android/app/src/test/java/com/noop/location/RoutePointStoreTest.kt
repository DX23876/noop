package com.noop.location

import org.junit.Assert.assertEquals
import org.junit.Test

class RoutePointStoreTest {

    @Test
    fun pointsSurviveTheFileFormat() {
        val points = listOf(
            RoutePoint(50.123456789, 8.5, 1_723_000_000_123, 401.25),
            RoutePoint(-33.9, 151.2, 1_723_000_002_000, null),
        )
        assertEquals(points, RoutePointStore.decode(RoutePointStore.encode(points)))
    }

    @Test
    fun aBrokenLineIsSkipped() {
        assertEquals(1, RoutePointStore.decode("1,2,3,4\nnonsense\n5,6\n").size)
    }

    @Test
    fun anySportNameMakesASafeFileName() {
        assertEquals("1723000000-treadmillrun.csv", RoutePointStore.fileName(1_723_000_000, "Treadmill/Run"))
    }
}
