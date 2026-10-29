package com.noop.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * The stored reads back from the shared core parse the Swift rows into Room's shapes, and answer null for the core's
 * `null` (a failed store read) or a malformed row, so the repository falls back to Room instead of showing nothing.
 */
class CoreStoredReadsTest {
    @Test fun storedInputsParseSwiftRows() {
        val series = CoreStoredInputs.parseSeries("""[{"day":"2026-10-01","key":"weight","value":92.5}]""", "apple-health")!!
        assertEquals("apple-health", series[0].deviceId)
        assertEquals(92.5, series[0].value, 0.0)
        assertEquals(listOf("a", "b"), CoreStoredInputs.parseKeys("""["b","a"]"""))
        assertEquals(7, CoreStoredInputs.parseCount("""{"count":7}"""))
        val days = CoreStoredInputs.parseAppleDaily("""[{"day":"2026-10-02","steps":8100,"vo2max":41.2}]""", "health-connect")!!
        assertEquals(8100, days[0].steps)
        assertNull(days[0].activeKcal)
        assertEquals("health-connect", days[0].deviceId)
        assertEquals(emptyList<Any>(), CoreStoredInputs.parseSeries("[]", "x"))
    }

    @Test fun failedOrMalformedReadsFallBack() {
        assertNull(CoreStoredInputs.parseSeries("null", "x"))
        assertNull(CoreStoredInputs.parseKeys("null"))
        assertNull(CoreStoredInputs.parseCount("null"))
        assertNull(CoreStoredInputs.parseAppleDaily("null", "x"))
        assertNull(CoreDailyRows.parse("null", "x"))
        assertNull(CoreLabMarkers.parse("null"))
        assertNull(CoreResolvedSeries.parse("null"))
        assertNull(CoreWorkoutRows.parse("null"))
        // A row without a field the parser needs is not half a list.
        assertNull(CoreStoredInputs.parseSeries("""[{"day":"2026-10-01","value":1}]""", "x"))
        assertNull(CoreLabMarkers.parse("""[{"id":"1"}]"""))
        assertNull(CoreWorkoutRows.parse("""[{"startTs":1}]"""))
    }

    @Test fun labMarkersAndResolvedSeriesParse() {
        val markers = CoreLabMarkers.parse("""[{"id":"m1","deviceId":"lab","markerKey":"ldl","category":"lipids","day":"2026-09-30",
            "takenAt":1790000000,"value":2.4,"unit":"mmol/L","source":"manual"},
            {"id":"m2","deviceId":"lab","markerKey":"note","category":"lipids","day":"2026-09-30","takenAt":1790000001,
            "valueText":"fasting","unit":"","source":"manual","referenceText":"<3.0"}]""")!!
        assertEquals(2.4, markers[0].value!!, 0.0)
        assertNull(markers[1].value)
        assertEquals("fasting", markers[1].valueText)
        assertEquals("<3.0", markers[1].referenceText)

        val r = CoreResolvedSeries.parse("""{"requestedSource":"my-whoop","candidates":[{"source":"my-whoop","key":"hrv"}],
            "points":[{"day":"2026-10-01","value":61,"source":"my-whoop","sourceKey":"hrv"}]}""")!!
        assertEquals("my-whoop", r.requestedSource)
        assertEquals(61.0, r.points[0].value, 0.0)
        assertEquals("hrv", r.candidates[0].key)
    }
}
