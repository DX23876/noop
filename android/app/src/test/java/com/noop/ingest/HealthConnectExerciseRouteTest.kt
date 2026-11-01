package com.noop.ingest

import androidx.health.connect.client.records.ExerciseSessionRecord
import com.noop.data.WorkoutRow
import com.noop.location.RoutePoint
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * A recorded GPS workout carries its route into Health Connect, so an app that reads the session there
 * (a Strava bridge, say) gets the track with real times and heights. Health Connect rejects a location
 * outside the session or out of time order, which would fail the whole insert.
 */
class HealthConnectExerciseRouteTest {

    private val row = WorkoutRow(
        deviceId = "my-whoop", startTs = 1_723_000_000, endTs = 1_723_001_800,
        sport = "Running", source = "manual", routePolyline = "x",
    )

    private fun point(offsetS: Long, alt: Double? = 400.0) =
        RoutePoint(lat = 50.0 + offsetS / 1e5, lon = 8.0, tMs = (row.startTs + offsetS) * 1000, altitudeM = alt)

    @Test
    fun keepsOnlyLocationsInsideTheSessionInTimeOrder() {
        val route = HealthConnectWriter.exerciseRoute(
            row, listOf(point(-5), point(10), point(10), point(5), point(20, null), point(1_800)),
        )!!
        assertEquals(listOf(5L, 10L, 20L), route.route.map { it.time.epochSecond - row.startTs })
        assertEquals(400.0, route.route.first().altitude!!.inMeters, 1e-9)
        assertNull(route.route.last().altitude)
    }

    @Test
    fun fewerThanTwoLocationsIsNoRoute() {
        assertNull(HealthConnectWriter.exerciseRoute(row, listOf(point(5))))
    }

    @Test
    fun theRouteRidesOnTheSession() {
        val route = HealthConnectWriter.exerciseRoute(row, listOf(point(5), point(10)))
        val session = HealthConnectWriter.buildExerciseRecords(row, 56, route).first() as ExerciseSessionRecord
        assertEquals(route, (session.exerciseRouteResult as androidx.health.connect.client.records.ExerciseRouteResult.Data).exerciseRoute)
    }
}
