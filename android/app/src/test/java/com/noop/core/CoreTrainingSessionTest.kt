package com.noop.core

import org.junit.Assert.*
import org.junit.Test

/** Synthetic documents emitted by Swift pin the session transcript and physiology contract. */
class CoreTrainingSessionTest {
    private fun fixture(name: String) = javaClass.getResource("/training/$name.json")!!.readText()

    @Test fun theTranscriptKeepsWarmupsSupersetsAndVolumeCoverage() {
        val s = CoreTrainingSession.parse(fixture("session-strength"))!!
        assertEquals("strength", s.kind)
        assertEquals("hevy_csv", s.source)
        assertEquals(1, s.groups.size)
        assertEquals(2, s.groups.single().size)
        assertEquals(listOf(false, true), s.groups[0][0].sets.map { it.isWorking })
        assertEquals(2, s.summary!!.workingSets)
        assertEquals(1, s.summary!!.volumeSets)
        assertEquals(640.0, s.summary!!.volumeKg, 0.0)
        assertEquals(800.0, s.summary!!.bodyweightVolumeKg, 0.0)
        assertNull(s.summary!!.densityKgPerMinute)
        assertEquals(106.66666666666666, s.groups[0][0].sets[1].e1rmKg!!, 1e-10)
        assertNull(s.groups[0][1].sets[0].e1rmKg)
    }

    @Test fun measuredPhysiologyStaysApartFromTheUnratedWholeSession() {
        val s = CoreTrainingSession.parse(fixture("session-strength"))!!
        assertEquals(60, s.heartRate.size)
        assertEquals(setOf(130.0, 140.0), s.heartRate.map { it.bpm }.toSet())
        assertEquals(listOf(0.0, 30.0, 30.0, 0.0, 0.0), s.zoneMinutes)
        assertEquals(8.0, s.summary!!.meanRPE!!, 0.0)
        assertNull(s.rating)
        assertEquals(30, s.bucketSeconds)
    }

    @Test fun aDeliberateRatingCarriesItsCoreLoadAndTiming() {
        val s = CoreTrainingSession.parse(fixture("session-rated"))!!
        val rating = s.rating!!
        assertEquals(9.0, rating.rpe, 0.0)
        assertEquals(540.0, rating.loadAU!!, 0.0)
        assertEquals(60.0, rating.durationMinutes!!, 0.0)
        assertEquals("later", rating.timing)
        assertNotNull(s.canonicalId)
        assertEquals(8.0, s.summary!!.meanRPE!!, 0.0)
    }

    @Test fun nativeSidesDurationAndDistanceSurviveTheDetailBoundary() {
        val s = CoreTrainingSession.parse(fixture("session-native"))!!
        val sets = s.groups.flatten().flatMap { it.sets }
        assertEquals(10, sets[0].leftReps)
        assertEquals(12, sets[0].rightReps)
        assertEquals(75.0, sets[1].durationS!!, 0.0)
        assertEquals(120.0, sets[1].distanceM!!, 0.0)
        assertTrue(s.heartRate.isEmpty())
        assertNull(s.zoneMinutes)
    }

    @Test fun cardioAverageDoesNotSupplyACurveOrZoneSplit() {
        val s = CoreTrainingSession.parse(fixture("session-cardio"))!!
        assertEquals("endurance", s.kind)
        assertEquals(140, s.avgHr)
        assertEquals(5_000.0, s.distanceM!!, 0.0)
        assertTrue(s.groups.isEmpty())
        assertNull(s.summary)
        assertTrue(s.heartRate.isEmpty())
        assertNull(s.zoneMinutes)
        val report = CoreTrainingReports.parseCardio(fixture("cardio"))!!
        assertTrue(report.sessions.all { it.id.isNotEmpty() })
    }

    @Test fun unavailableAndMalformedDocumentsDoNotBecomeAnEmptySession() {
        listOf("null", "{}", "bad", "{\"error\":\"storeUnavailable\"}").forEach {
            assertNull(CoreTrainingSession.parse(it))
        }
    }
}
