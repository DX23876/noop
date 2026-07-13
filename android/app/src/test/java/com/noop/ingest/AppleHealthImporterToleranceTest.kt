package com.noop.ingest

import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.xmlpull.v1.XmlPullParser
import java.io.ByteArrayInputStream

/**
 * Pins the #100 fix on Android: an Apple Health `export.xml` carrying an XML-1.0-illegal byte (or
 * broken UTF-8) mid-file must NOT abort the whole import. The streaming [SanitizingInputStream]
 * scrubs the bad bytes so records BEFORE and AFTER survive, and the dropped span is surfaced (never
 * hidden). Mirrors `AppleHealthImporterTests` on macOS.
 *
 * Runs on the plain JVM: `android.util.Xml` is a throwing stub there, so we swap a real kXML2
 * parser into `AppleHealthImporter.newPullParser` and drive the parse through the test seam
 * `parseStreamForTest` (no Context / Uri / Room).
 */
class AppleHealthImporterToleranceTest {

    @Before
    fun installRealParser() {
        // Construct kXML2's KXmlParser directly (the testImplementation dep). We avoid
        // XmlPullParserFactory.newInstance() because android.jar also ships a *stub*
        // org.xmlpull.v1.XmlPullParserFactory whose newInstance() throws "Stub!" on the JVM
        // unit-test classpath; instantiating the concrete parser dodges that collision.
        AppleHealthImporter.newPullParser = {
            Class.forName("org.kxml2.io.KXmlParser").getDeclaredConstructor().newInstance() as XmlPullParser
        }
    }

    @After
    fun restoreParser() {
        // Leave the object in its default state for any other test in the module.
        AppleHealthImporter.newPullParser = { android.util.Xml.newPullParser() }
    }

    /**
     * NUL (0x00) and a lone 0x1F planted between two valid records. The sanitizer drops them, the
     * parse runs to EOF, and BOTH heart-rate days survive. The scrubbed run is reported.
     */
    @Test
    fun illegalByteMidFileIsSanitizedAndBothSidesSurvive() {
        val head = """
            <?xml version="1.0" encoding="UTF-8"?>
            <HealthData>
             <Record type="HKQuantityTypeIdentifierHeartRate" sourceName="W" unit="count/min" startDate="2024-01-02 08:00:00 +0000" endDate="2024-01-02 08:00:00 +0000" value="61"/>

        """.trimIndent().toByteArray(Charsets.UTF_8)
        val bad = byteArrayOf(0x00, 0x1F)
        val tail = """

             <Record type="HKQuantityTypeIdentifierHeartRate" sourceName="W" unit="count/min" startDate="2024-01-03 08:00:00 +0000" endDate="2024-01-03 08:00:00 +0000" value="72"/>
            </HealthData>
        """.trimIndent().toByteArray(Charsets.UTF_8)

        val probe = AppleHealthImporter.parseStreamForTest(ByteArrayInputStream(head + bad + tail))

        // Two distinct local days, each with one HeartRate sample → both survive the bad byte.
        val avgByDay = probe.days.associate { it.day to it.avgHr }
        assertEquals(61.0, avgByDay["2024-01-02"]!!, 1e-9)
        assertEquals(72.0, avgByDay["2024-01-03"]!!, 1e-9)
        assertTrue("scrubbed illegal-byte run must be surfaced", probe.skippedSpans >= 1)
    }

    /**
     * Invalid UTF-8 (lone 0xFF/0xFE) inside an attribute value is repaired to U+FFFD, not fatal.
     * Both surrounding records survive.
     */
    @Test
    fun invalidUtf8IsRepairedNotFatal() {
        val head = """
            <?xml version="1.0" encoding="UTF-8"?>
            <HealthData>
             <Record type="HKQuantityTypeIdentifierHeartRate" sourceName="
        """.trimIndent().toByteArray(Charsets.UTF_8)
        val bad = byteArrayOf(0xFF.toByte(), 0xFE.toByte())
        val tail = """
            W" unit="count/min" startDate="2024-01-02 08:00:00 +0000" endDate="2024-01-02 08:00:00 +0000" value="61"/>
             <Record type="HKQuantityTypeIdentifierHeartRate" sourceName="W2" unit="count/min" startDate="2024-01-03 08:00:00 +0000" endDate="2024-01-03 08:00:00 +0000" value="72"/>
            </HealthData>
        """.trimIndent().toByteArray(Charsets.UTF_8)

        val probe = AppleHealthImporter.parseStreamForTest(ByteArrayInputStream(head + bad + tail))

        val avgByDay = probe.days.associate { it.day to it.avgHr }
        assertEquals(61.0, avgByDay["2024-01-02"]!!, 1e-9)
        assertEquals(72.0, avgByDay["2024-01-03"]!!, 1e-9)
        assertTrue(probe.skippedSpans >= 1)
    }

    /**
     * #589: overlapping step samples from DIFFERENT sources (an iPhone AND an Apple Watch both count the
     * same walk) must NOT be summed across sources — that double-counts ~2x and poisons steps calibration.
     * We sum WITHIN a source but take the MAX source per day, mirroring Apple Health and the macOS
     * aggregator. Parity with `AppleHealthAggregatorTests.testStepsDoNotDoubleCountAcrossSources`.
     */
    @Test
    fun stepsDoNotDoubleCountAcrossSources() {
        val xml = """
            <?xml version="1.0" encoding="UTF-8"?>
            <HealthData>
             <Record type="HKQuantityTypeIdentifierStepCount" sourceName="iPhone" unit="count" startDate="2024-03-08 10:00:00 +0000" endDate="2024-03-08 10:00:00 +0000" value="4000"/>
             <Record type="HKQuantityTypeIdentifierStepCount" sourceName="iPhone" unit="count" startDate="2024-03-08 11:00:00 +0000" endDate="2024-03-08 11:00:00 +0000" value="3000"/>
             <Record type="HKQuantityTypeIdentifierStepCount" sourceName="Apple Watch" unit="count" startDate="2024-03-08 10:00:00 +0000" endDate="2024-03-08 10:00:00 +0000" value="6500"/>
             <Record type="HKQuantityTypeIdentifierStepCount" sourceName="Apple Watch" unit="count" startDate="2024-03-08 11:00:00 +0000" endDate="2024-03-08 11:00:00 +0000" value="1000"/>
            </HealthData>
        """.trimIndent().toByteArray(Charsets.UTF_8)

        val probe = AppleHealthImporter.parseStreamForTest(ByteArrayInputStream(xml))
        // iPhone day total 7000, Watch day total 7500 → MAX 7500, NOT 14500 (the cross-source sum).
        assertEquals(7500.0, probe.days.single { it.day == "2024-03-08" }.steps!!, 1e-9)
    }

    /** A clean export reports zero skipped spans (no false positives from the sanitizer). */
    @Test
    fun cleanFileReportsNoSkippedSpans() {
        val xml = """
            <?xml version="1.0" encoding="UTF-8"?>
            <HealthData>
             <Record type="HKQuantityTypeIdentifierHeartRate" sourceName="W" unit="count/min" startDate="2024-01-02 08:00:00 +0000" endDate="2024-01-02 08:00:00 +0000" value="61"/>
            </HealthData>
        """.trimIndent().toByteArray(Charsets.UTF_8)

        val probe = AppleHealthImporter.parseStreamForTest(ByteArrayInputStream(xml))
        assertEquals(0, probe.skippedSpans)
        assertEquals(61.0, probe.days.single().avgHr!!, 1e-9)
    }

    /**
     * TOLERANT PARSE: a hard, structural XML error (a broken tag the sanitizer can't fix) AFTER at
     * least one record keeps the partial result and reports the truncated tail as a skipped span.
     */
    @Test
    fun hardParseErrorAfterRecordsKeepsPartialResult() {
        val xml = """
            <?xml version="1.0" encoding="UTF-8"?>
            <HealthData>
             <Record type="HKQuantityTypeIdentifierHeartRate" sourceName="W" unit="count/min" startDate="2024-01-02 08:00:00 +0000" endDate="2024-01-02 08:00:00 +0000" value="61"/>
             <Record type="HKQuantityTypeIdentifierHeartRate" sourceName="W2" unit="count/min" startDate="2024-01-03 08:00:00 +0000" endDate="2024-01-03 08:00:00 +0000" value="72"/>
             <Record type="HKQuantityTypeIdentifierHeartRate" startDate=
        """.trimIndent().toByteArray(Charsets.UTF_8) // truncated, malformed tail

        val probe = AppleHealthImporter.parseStreamForTest(ByteArrayInputStream(xml))
        // The two well-formed records before the break survive.
        assertEquals(2, probe.days.size)
        assertTrue("truncated tail must be surfaced", probe.skippedSpans >= 1)
    }

    /**
     * A multi-byte UTF-8 character split across the sanitizer's chunk boundary must NOT be
     * misclassified as invalid. Force a tiny chunk so "é" (0xC3 0xA9) straddles two refills.
     */
    @Test
    fun multiByteUtf8AcrossChunkBoundaryIsPreserved() {
        val xml = """
            <?xml version="1.0" encoding="UTF-8"?>
            <HealthData>
             <Record type="HKQuantityTypeIdentifierHeartRate" sourceName="cafémeter" unit="count/min" startDate="2024-01-02 08:00:00 +0000" endDate="2024-01-02 08:00:00 +0000" value="61"/>
            </HealthData>
        """.trimIndent().toByteArray(Charsets.UTF_8)

        // Drive the sanitizer directly with an 8-byte chunk so the multi-byte char is cut across reads.
        val san = SanitizingInputStream(ByteArrayInputStream(xml), chunkSize = 8)
        val out = san.readBytes()
        assertEquals("a valid multi-byte char must not be scrubbed", 0, san.scrubbedRunCount)
        // The sanitized bytes round-trip to the original (no corruption of the split character).
        assertEquals(String(xml, Charsets.UTF_8), String(out, Charsets.UTF_8))
    }

    /**
     * iOS 16+ shape: per-workout energy/distance/HR live in nested <WorkoutStatistics> children, NOT
     * as <Workout> attributes. The importer must read them, or every modern-export workout imports as
     * a bare shell (no energy/distance/HR) and de-dups noisily. MetadataEntry child confirms the
     * sub-tree walk skips non-stats children. Mirrors the macOS AppleHealthImporterTests twin.
     */
    @Test
    fun modernWorkoutStatisticsRecoversEnergyDistanceAndHr() {
        val xml = """
            <?xml version="1.0" encoding="UTF-8"?>
            <HealthData>
             <Workout workoutActivityType="HKWorkoutActivityTypeRunning" duration="45" durationUnit="min" sourceName="Watch" startDate="2024-01-02 16:00:00 +0000" endDate="2024-01-02 16:45:00 +0000">
              <WorkoutStatistics type="HKQuantityTypeIdentifierActiveEnergyBurned" startDate="2024-01-02 16:00:00 +0000" endDate="2024-01-02 16:45:00 +0000" sum="540" unit="Cal"/>
              <WorkoutStatistics type="HKQuantityTypeIdentifierDistanceWalkingRunning" startDate="2024-01-02 16:00:00 +0000" endDate="2024-01-02 16:45:00 +0000" sum="8.05" unit="km"/>
              <WorkoutStatistics type="HKQuantityTypeIdentifierHeartRate" startDate="2024-01-02 16:00:00 +0000" endDate="2024-01-02 16:45:00 +0000" average="150" minimum="98" maximum="176" unit="count/min"/>
              <MetadataEntry key="HKIndoorWorkout" value="0"/>
             </Workout>
            </HealthData>
        """.trimIndent().toByteArray(Charsets.UTF_8)

        val probe = AppleHealthImporter.parseStreamForTest(ByteArrayInputStream(xml))

        assertEquals(1, probe.workouts.size)
        val w = probe.workouts.single()
        assertEquals("Running", w.sport)
        assertEquals(2700.0, w.durationS!!, 1e-9)          // 45 min -> seconds
        assertEquals(540.0, w.energyKcal!!, 1e-9)          // sum, Cal == kcal
        assertEquals(8050.0, w.distanceM!!, 0.5)           // 8.05 km -> ~8050 m
        assertEquals(150, w.avgHr)                          // WorkoutStatistics HeartRate average
        assertEquals(176, w.maxHr)                          // WorkoutStatistics HeartRate maximum
        assertEquals(0, probe.skippedSpans)
    }

    /**
     * Regression guard: the legacy iOS <=15 shape (totals as <Workout> attributes) must keep parsing.
     * HR was never an attribute in that shape, so avg/max stay null.
     */
    @Test
    fun legacyWorkoutAttributesStillParse() {
        val xml = """
            <?xml version="1.0" encoding="UTF-8"?>
            <HealthData>
             <Workout workoutActivityType="HKWorkoutActivityTypeCycling" duration="30" durationUnit="min" totalDistance="10.0" totalDistanceUnit="km" totalEnergyBurned="250" totalEnergyBurnedUnit="kcal" startDate="2024-01-02 16:00:00 +0000" endDate="2024-01-02 16:30:00 +0000"/>
            </HealthData>
        """.trimIndent().toByteArray(Charsets.UTF_8)

        val probe = AppleHealthImporter.parseStreamForTest(ByteArrayInputStream(xml))

        assertEquals(1, probe.workouts.size)
        val w = probe.workouts.single()
        assertEquals("Cycling", w.sport)
        assertEquals(250.0, w.energyKcal!!, 1e-9)
        assertEquals(10000.0, w.distanceM!!, 0.5)
        assertEquals(null, w.avgHr)
        assertEquals(null, w.maxHr)
    }
}
