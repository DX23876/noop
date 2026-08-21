package com.noop.ingest

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pins LiftingImporter.parse: a Hevy CSV export and a Liftosaur JSON export both fold into one
 * Strength session per workout, with a TRANSPARENT volume load = Σ(weight × reps). Warm-up sets are
 * excluded from the working volume, lb columns / units convert to kg, and the note never claims a
 * strain. Kotlin twin of the macOS LiftingImporterTests — same arithmetic, same labels.
 */
class LiftingImporterTest {

    private fun hevy(csv: String) =
        LiftingImporter.parseHevy(CsvTable.fromData(csv.trimIndent().toByteArray()))

    private fun liftosaur(json: String) = LiftingImporter.parseLiftosaur(json.trimIndent())

    // MARK: - Hevy CSV

    @Test
    fun hevyGroupsSetsIntoOneSessionWithVolumeLoad() {
        // Volume = 100×5 + 100×5 + 100×5 (bench) + 60×8 (curl) = 1980 kg; warm-up 40×10 excluded.
        val r = hevy(
            """
            title,start_time,end_time,exercise_title,set_index,set_type,weight_kg,reps
            Push Day,2026-06-01 18:00:00,2026-06-01 19:00:00,Bench Press,0,warmup,40,10
            Push Day,2026-06-01 18:00:00,2026-06-01 19:00:00,Bench Press,1,normal,100,5
            Push Day,2026-06-01 18:00:00,2026-06-01 19:00:00,Bench Press,2,normal,100,5
            Push Day,2026-06-01 18:00:00,2026-06-01 19:00:00,Bench Press,3,normal,100,5
            Push Day,2026-06-01 18:00:00,2026-06-01 19:00:00,Bicep Curl,0,normal,60,8
            """
        )
        assertEquals(1, r.sessions.size)
        assertEquals(0, r.skipped)
        val s = r.sessions[0]
        assertEquals(1980.0, s.volumeLoadKg, 1e-6)
        assertEquals(4, s.setCount)        // warm-up not counted
        assertEquals(2, s.exerciseCount)
        assertEquals(23, s.totalReps)
        assertEquals(100.0, s.topSetKg!!, 1e-9)
        assertEquals(3600.0, s.durationS!!, 1e-9)
        assertEquals("Push Day", s.title)
    }

    @Test
    fun hevySplitsDistinctWorkoutsAndConvertsPounds() {
        val r = hevy(
            """
            title,start_time,exercise_title,set_type,weight_lb,reps
            A,2026-06-01 10:00:00,Squat,normal,135,5
            B,2026-06-02 10:00:00,Deadlift,normal,225,3
            """
        )
        assertEquals(2, r.sessions.size)
        assertEquals(135 * 0.45359237 * 5, r.sessions[0].volumeLoadKg, 1e-4)
        assertEquals(225 * 0.45359237 * 3, r.sessions[1].volumeLoadKg, 1e-4)
        assertTrue(r.sessions[0].startTs < r.sessions[1].startTs) // oldest first
    }

    @Test
    fun hevySkipsRowsWithNoUsableDate() {
        val r = hevy(
            """
            title,start_time,exercise_title,set_type,weight_kg,reps
            Good,2026-06-01 10:00:00,Squat,normal,100,5
            Bad,,Squat,normal,100,5
            """
        )
        assertEquals(1, r.sessions.size)
        assertEquals(1, r.skipped)
    }

    @Test
    fun hevyBodyweightSetCountsButAddsNoVolume() {
        val r = hevy(
            """
            title,start_time,exercise_title,set_type,reps
            Pull,2026-06-01 10:00:00,Pull Up,normal,12
            """
        )
        assertEquals(1, r.sessions[0].setCount)
        assertEquals(0.0, r.sessions[0].volumeLoadKg, 1e-9)
        assertEquals(12, r.sessions[0].totalReps)
        assertNull(r.sessions[0].topSetKg)
    }

    @Test
    fun hevyTimestampUsesDeviceTimezoneNotUtc() {
        // #649: Hevy writes zoneless local wall-clock times. "12 Jun 2026, 18:30" must land at 18:30
        // in the device zone, not 18:30 UTC. The "d MMM yyyy, HH:mm" form contains a comma, so it is a
        // quoted CSV field (as Hevy exports). At UTC+2, 18:30 local == 16:30 UTC.
        val zone = java.time.ZoneId.of("UTC+02:00")
        val csv =
            """
            title,start_time,exercise_title,set_type,weight_kg,reps
            Evening,"12 Jun 2026, 18:30",Squat,normal,100,5
            """.trimIndent()
        val r = LiftingImporter.parseHevy(CsvTable.fromData(csv.toByteArray()), zone)
        assertEquals(1, r.sessions.size)
        val expected = java.time.LocalDateTime.of(2026, 6, 12, 18, 30)
            .atZone(zone).toEpochSecond()
        assertEquals(expected, r.sessions[0].startTs)
        // Same wall-clock parsed at UTC would be 7200 s later — confirm we are NOT doing that.
        val asUtc = java.time.LocalDateTime.of(2026, 6, 12, 18, 30)
            .toEpochSecond(java.time.ZoneOffset.UTC)
        assertEquals(7200L, asUtc - r.sessions[0].startTs)
    }

    @Test
    fun hevyPlainTimestampHonoursDeviceTimezone() {
        // The "yyyy-MM-dd HH:mm:ss" Hevy form is equally zoneless → device-zone, not UTC.
        val zone = java.time.ZoneId.of("UTC-05:00")
        val csv =
            """
            title,start_time,exercise_title,set_type,weight_kg,reps
            Morning,2026-06-01 09:00:00,Bench,normal,80,5
            """.trimIndent()
        val r = LiftingImporter.parseHevy(CsvTable.fromData(csv.toByteArray()), zone)
        // 09:00 at UTC-5 == 14:00 UTC.
        val expected = java.time.OffsetDateTime.parse("2026-06-01T14:00:00Z").toEpochSecond()
        assertEquals(expected, r.sessions[0].startTs)
    }

    @Test
    fun hevyTimestampWithExplicitOffsetIgnoresDeviceTimezone() {
        // A timestamp that already carries an offset is authoritative — the device zone must NOT shift
        // it. "...+01:00" at 12:00 is 11:00 UTC regardless of the passed zone.
        val csv =
            """
            title,start_time,exercise_title,set_type,weight_kg,reps
            Zoned,2026-06-01T12:00:00+01:00,Row,normal,70,5
            """.trimIndent()
        val r = LiftingImporter.parseHevy(CsvTable.fromData(csv.toByteArray()), java.time.ZoneId.of("UTC+09:00"))
        val expected = java.time.OffsetDateTime.parse("2026-06-01T11:00:00Z").toEpochSecond()
        assertEquals(expected, r.sessions[0].startTs)
    }

    // MARK: - Liftosaur JSON

    @Test
    fun liftosaurParsesHistoryRecords() {
        // startTime is epoch ms. Volume = 80×5 + 80×5 + 100×3 = 1100 kg.
        val r = liftosaur(
            """
            { "history": [
              { "startTime": 1748772000000, "endTime": 1748775600000, "dayName": "Day 1",
                "entries": [
                  { "sets": [ { "weight": 80, "completedReps": 5 }, { "weight": 80, "completedReps": 5 } ] },
                  { "sets": [ { "weight": { "value": 100, "unit": "kg" }, "completedReps": 3 } ] }
                ] }
            ] }
            """
        )
        assertEquals(1, r.sessions.size)
        val s = r.sessions[0]
        assertEquals(1100.0, s.volumeLoadKg, 1e-6)
        assertEquals(3, s.setCount)
        assertEquals(2, s.exerciseCount)
        assertEquals(13, s.totalReps)
        assertEquals(1748772000L, s.startTs)
        assertEquals(3600.0, s.durationS!!, 1e-9)
    }

    @Test
    fun liftosaurConvertsPoundUnitAndSkipsUncompletedSets() {
        val r = liftosaur(
            """
            { "history": [
              { "startTime": 1748772000000, "entries": [
                  { "unit": "lb", "sets": [ { "weight": 100, "completedReps": 5 }, { "weight": 100, "reps": 5 } ] }
              ] }
            ] }
            """
        )
        val s = r.sessions[0]
        assertEquals(1, s.setCount) // template set without completedReps skipped
        assertEquals(100 * 0.45359237 * 5, s.volumeLoadKg, 1e-4)
    }

    @Test
    fun liftosaurAcceptsBareArrayAndStorageWrapper() {
        val bare =
            """[ { "startTime": 1748772000000, "entries": [ { "sets": [ { "weight": 50, "completedReps": 10 } ] } ] } ]"""
        assertEquals(1, LiftingImporter.parseLiftosaur(bare).sessions.size)
        val wrapped =
            """{ "storage": { "history": [ { "startTime": 1748772000000, "entries": [ { "sets": [ { "weight": 50, "completedReps": 10 } ] } ] } ] } }"""
        assertEquals(1, LiftingImporter.parseLiftosaur(wrapped).sessions.size)
    }

    @Test
    fun liftosaurHeterogeneousHistoryCountsEveryRejectedRecord() {
        val json =
            """
            { "history": [
              { "startTime": 1748772000000, "endTime": 1748775600000, "dayName": "Day 1",
                "entries": [ { "sets": [ { "weight": 80, "completedReps": 5 } ] } ] },
              7,
              { "dayName": "Missing timestamp",
                "entries": [ { "sets": [ { "weight": 60, "completedReps": 8 } ] } ] },
              "not a record"
            ] }
            """.trimIndent()

        val r = LiftingImporter.parse(json.toByteArray())

        assertEquals(listOf(1748772000L), r.sessions.map { it.startTs })
        assertEquals(1, r.sessions.size)
        val s = r.sessions[0]
        assertEquals(1748775600L, s.endTs)
        assertEquals(3600.0, s.durationS!!, 1e-9)
        assertEquals(400.0, s.volumeLoadKg, 1e-6)
        assertEquals(1, s.setCount)
        assertEquals(1, s.exerciseCount)
        assertEquals(5, s.totalReps)
        assertEquals(80.0, s.topSetKg!!, 1e-9)
        assertEquals("Day 1", s.title)
        assertEquals("2025-06-01", r.firstDay)
        assertEquals("2025-06-01", r.lastDay)
        assertEquals(3, r.skipped)
    }

    // MARK: - Auto-detection + note

    @Test
    fun detectFormatRoutesByLeadingByte() {
        assertEquals(
            LiftingImporter.Format.LIFTOSAUR_JSON,
            LiftingImporter.detectFormat("  { \"history\": [] }".toByteArray()),
        )
        assertEquals(LiftingImporter.Format.LIFTOSAUR_JSON, LiftingImporter.detectFormat("[]".toByteArray()))
        assertEquals(LiftingImporter.Format.HEVY_CSV, LiftingImporter.detectFormat("title,start_time\n".toByteArray()))
    }

    @Test
    fun volumeLoadNoteMatchesSwiftForTitledAndUntitledSessions() {
        fun session(title: String?) = LiftingImporter.Session(
            startTs = 0, endTs = 0, volumeLoadKg = 12400.0, setCount = 18,
            exerciseCount = 5, totalReps = 120, topSetKg = 140.0, title = title,
        )

        val body = "Strength · volume load 12,400 kg · 18 sets · 5 exercises"
        assertEquals(body, session(null).volumeLoadNote())
        assertEquals(body, session("").volumeLoadNote())
        assertEquals("Leg Day: $body", session("Leg Day").volumeLoadNote())
    }
}
