import XCTest
@testable import StrandImport

final class AppleHealthImporterTests: XCTestCase {

    private let fixtureName = "sample_health_data.xml"

    private func parsed() throws -> AppleHealthImportResult {
        let data = Fixtures.data(fixtureName)
        XCTAssertFalse(data.isEmpty, "\(fixtureName) fixture missing")
        return try AppleHealthImporter().importXML(data: data)
    }

    // MARK: - Type filtering

    func testOnlyRelevantTypesIngested() throws {
        let r = try parsed()
        let types = Set(r.samples.map { $0.type })
        // BodyMass is now a relevant (body-composition) type -> included.
        XCTAssertTrue(types.contains("BodyMass"))
        XCTAssertTrue(types.contains("HeartRate"))
        XCTAssertTrue(types.contains("RestingHeartRate"))
        XCTAssertTrue(types.contains("OxygenSaturation"))
        XCTAssertTrue(types.contains("RespiratoryRate"))
        XCTAssertTrue(types.contains("StepCount"))
        XCTAssertTrue(types.contains("SleepAnalysis"))
        // An irrelevant type stays excluded.
        XCTAssertFalse(types.contains("DietaryWater"))
    }

    // MARK: - OxygenSaturation ×100

    func testOxygenSaturationFractionScaledToPercent() throws {
        let r = try parsed()
        let spo2 = r.samples.first { $0.type == "OxygenSaturation" }
        XCTAssertNotNil(spo2)
        // Raw value 0.97 -> 97.0
        XCTAssertEqual(try XCTUnwrap(spo2?.value), 97.0, accuracy: 1e-9)
        XCTAssertEqual(spo2?.valueString, "0.97")
    }

    // MARK: - Dates -> UTC

    func testDatesNormalizedToUTC() throws {
        let r = try parsed()
        let hr = r.samples.first { $0.type == "HeartRate" }
        XCTAssertNotNil(hr)
        // 2024-01-02 08:00:00 +0100 -> 07:00:00 UTC.
        XCTAssertEqual(hr?.start, Fixtures.utc(2024, 1, 2, 7, 0, 0))
        XCTAssertEqual(hr?.end, Fixtures.utc(2024, 1, 2, 7, 0, 0))
        XCTAssertEqual(hr?.tzOffsetMin, 60)
        XCTAssertEqual(hr?.value, 61)
        XCTAssertEqual(hr?.unit, "count/min")
        XCTAssertEqual(hr?.sourceName, "Apple Watch")
    }

    func testNegativeOffsetDateParsing() {
        let p = HealthDateParser()
        let result = p.parse("2024-06-01 14:30:00 -0500")
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.0, Fixtures.utc(2024, 6, 1, 19, 30, 0)) // +5h to UTC
        XCTAssertEqual(result?.1, -300)
    }

    // MARK: - Sleep enums

    func testSleepAnalysisStagesMapped() throws {
        let r = try parsed()
        XCTAssertEqual(r.sleepIntervals.count, 3)
        let stages = r.sleepIntervals.map { $0.stage }
        XCTAssertEqual(stages, [.asleepCore, .asleepDeep, .awake])

        let core = r.sleepIntervals[0]
        XCTAssertEqual(core.start, Fixtures.utc(2024, 1, 1, 22, 15, 0)) // 23:15 +0100
        XCTAssertEqual(core.end, Fixtures.utc(2024, 1, 1, 23, 15, 0))
    }

    func testSleepStageMappingTable() {
        XCTAssertEqual(SleepStage.from(rawValue: "HKCategoryValueSleepAnalysisInBed"), .inBed)
        XCTAssertEqual(SleepStage.from(rawValue: "HKCategoryValueSleepAnalysisAsleep"), .asleepUnspecified)
        XCTAssertEqual(SleepStage.from(rawValue: "HKCategoryValueSleepAnalysisAsleepCore"), .asleepCore)
        XCTAssertEqual(SleepStage.from(rawValue: "HKCategoryValueSleepAnalysisAsleepDeep"), .asleepDeep)
        XCTAssertEqual(SleepStage.from(rawValue: "HKCategoryValueSleepAnalysisAsleepREM"), .asleepREM)
        XCTAssertEqual(SleepStage.from(rawValue: "HKCategoryValueSleepAnalysisAwake"), .awake)
        XCTAssertEqual(SleepStage.from(rawValue: "garbage"), .unknown)
    }

    // MARK: - Correlation dedupe

    func testCorrelationChildNotDoubleCounted() throws {
        let r = try parsed()
        // The HeartRate value 61 appears once top-level AND once inside the
        // Correlation; only one should survive.
        let hrCount = r.samples.filter { $0.type == "HeartRate" && $0.value == 61 }.count
        XCTAssertEqual(hrCount, 1, "Correlation-nested record was double-counted")
    }

    func testDedupeOnIdenticalKey() throws {
        // Two identical records at top level should collapse to one.
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <HealthData>
         <Record type="HKQuantityTypeIdentifierHeartRate" sourceName="W" unit="count/min" startDate="2024-01-02 08:00:00 +0000" endDate="2024-01-02 08:00:00 +0000" value="70"/>
         <Record type="HKQuantityTypeIdentifierHeartRate" sourceName="W" unit="count/min" startDate="2024-01-02 08:00:00 +0000" endDate="2024-01-02 08:00:00 +0000" value="70"/>
        </HealthData>
        """
        let r = try AppleHealthImporter().importXML(data: Data(xml.utf8))
        XCTAssertEqual(r.samples.filter { $0.type == "HeartRate" }.count, 1)
    }

    // MARK: - Workouts

    func testWorkoutParsed() throws {
        let r = try parsed()
        XCTAssertEqual(r.workouts.count, 1)
        let w = r.workouts[0]
        XCTAssertEqual(w.activityType, "Running")
        XCTAssertEqual(w.durationS, 45 * 60)              // 45 min -> seconds
        XCTAssertEqual(w.distanceM!, 8050, accuracy: 0.5) // 8.05 km -> ~8050 m
        XCTAssertEqual(w.energyKcal, 540)
        XCTAssertEqual(w.start, Fixtures.utc(2024, 1, 2, 16, 0, 0)) // 17:00 +0100
        XCTAssertEqual(w.tzOffsetMin, 60)
    }

    /// iOS 16+ shape: per-workout energy/distance/HR live in nested <WorkoutStatistics> children, not as
    /// <Workout> attributes. The parser must fold them in, or every modern-export workout imports as a
    /// bare shell (no energy/distance/HR) and de-dups noisily. The MetadataEntry child confirms the
    /// deferred commit ignores non-statistics children. Kotlin twin:
    /// `AppleHealthImporterToleranceTest.modernWorkoutStatisticsRecoversEnergyDistanceAndHr`.
    func testWorkoutStatisticsModernExport() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <HealthData>
         <Workout workoutActivityType="HKWorkoutActivityTypeRunning" duration="45" durationUnit="min" sourceName="Watch" startDate="2024-01-02 16:00:00 +0000" endDate="2024-01-02 16:45:00 +0000">
          <WorkoutStatistics type="HKQuantityTypeIdentifierActiveEnergyBurned" startDate="2024-01-02 16:00:00 +0000" endDate="2024-01-02 16:45:00 +0000" sum="540" unit="Cal"/>
          <WorkoutStatistics type="HKQuantityTypeIdentifierDistanceWalkingRunning" startDate="2024-01-02 16:00:00 +0000" endDate="2024-01-02 16:45:00 +0000" sum="8.05" unit="km"/>
          <WorkoutStatistics type="HKQuantityTypeIdentifierHeartRate" startDate="2024-01-02 16:00:00 +0000" endDate="2024-01-02 16:45:00 +0000" average="150" minimum="98" maximum="176" unit="count/min"/>
          <MetadataEntry key="HKIndoorWorkout" value="0"/>
         </Workout>
        </HealthData>
        """
        let r = try AppleHealthImporter().importXML(data: Data(xml.utf8))
        XCTAssertEqual(r.workouts.count, 1)
        let w = try XCTUnwrap(r.workouts.first)
        XCTAssertEqual(w.activityType, "Running")
        XCTAssertEqual(w.durationS, 45 * 60)
        XCTAssertEqual(try XCTUnwrap(w.energyKcal), 540, accuracy: 1e-9)   // sum, Cal == kcal
        XCTAssertEqual(try XCTUnwrap(w.distanceM), 8050, accuracy: 0.5)    // 8.05 km -> ~8050 m
        XCTAssertEqual(try XCTUnwrap(w.avgHr), 150, accuracy: 1e-9)        // WorkoutStatistics average
        XCTAssertEqual(try XCTUnwrap(w.maxHr), 176, accuracy: 1e-9)        // WorkoutStatistics maximum
    }

    // MARK: - Prefix stripping

    func testStripPrefix() {
        XCTAssertEqual(HealthXMLDelegate.stripPrefix("HKQuantityTypeIdentifierHeartRate"), "HeartRate")
        XCTAssertEqual(HealthXMLDelegate.stripPrefix("HKCategoryTypeIdentifierSleepAnalysis"), "SleepAnalysis")
        XCTAssertEqual(HealthXMLDelegate.stripPrefix("HKWorkoutActivityTypeRunning"), "Running")
        XCTAssertEqual(HealthXMLDelegate.stripPrefix("AlreadyClean"), "AlreadyClean")
    }

    // MARK: - Summary

    func testSummary() throws {
        let r = try parsed()
        XCTAssertEqual(r.summary.sourceKind, .appleHealth)
        XCTAssertGreaterThan(r.summary.recordCount, 0)
        XCTAssertEqual(r.summary.recordCount, r.samples.count + r.workouts.count)
        XCTAssertNotNil(r.summary.earliest)
        XCTAssertNotNil(r.summary.latest)
        XCTAssertLessThanOrEqual(r.summary.earliest!, r.summary.latest!)
        XCTAssertEqual(r.summary.countsByCategory["Workout"], 1)
    }

    // MARK: - Tolerant parse / byte sanitizer (#100)

    /// A 0x00 NUL byte planted mid-file (XML-1.0-illegal control char) must be scrubbed by the
    /// streaming sanitizer so the parse runs to EOF — records BEFORE and AFTER the bad byte both
    /// survive, and the import reports the skipped span rather than aborting the whole file.
    func testIllegalByteMidFileIsSanitizedAndBothSidesSurvive() throws {
        var bytes = Data()
        bytes.append(Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <HealthData>
         <Record type="HKQuantityTypeIdentifierHeartRate" sourceName="W" unit="count/min" startDate="2024-01-02 08:00:00 +0000" endDate="2024-01-02 08:00:00 +0000" value="61"/>

        """.utf8))
        // Illegal control bytes mid-file (NUL + a lone 0x1F), between two valid records.
        bytes.append(contentsOf: [0x00, 0x1F])
        bytes.append(Data("""

         <Record type="HKQuantityTypeIdentifierHeartRate" sourceName="W" unit="count/min" startDate="2024-01-02 09:00:00 +0000" endDate="2024-01-02 09:00:00 +0000" value="72"/>
        </HealthData>
        """.utf8))

        let r = try AppleHealthImporter().importXML(data: bytes)
        let hr = r.samples.filter { $0.type == "HeartRate" }.compactMap { $0.value }.sorted()
        XCTAssertEqual(hr, [61, 72], "both records around the illegal byte must survive")
        XCTAssertGreaterThanOrEqual(r.summary.skippedSpans, 1, "the scrubbed illegal-byte run must be surfaced")
    }

    /// Invalid UTF-8 (a lone 0xFF continuation byte that is not part of any valid sequence) inside a
    /// text node is repaired to U+FFFD and does not abort the import.
    func testInvalidUTF8IsRepairedNotFatal() throws {
        var bytes = Data()
        bytes.append(Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <HealthData>
         <Record type="HKQuantityTypeIdentifierHeartRate" sourceName="
        """.utf8))
        bytes.append(contentsOf: [0xFF, 0xFE]) // invalid UTF-8 in the sourceName attribute value
        bytes.append(Data("""
        W" unit="count/min" startDate="2024-01-02 08:00:00 +0000" endDate="2024-01-02 08:00:00 +0000" value="61"/>
         <Record type="HKQuantityTypeIdentifierHeartRate" sourceName="W2" unit="count/min" startDate="2024-01-02 09:00:00 +0000" endDate="2024-01-02 09:00:00 +0000" value="72"/>
        </HealthData>
        """.utf8))

        let r = try AppleHealthImporter().importXML(data: bytes)
        // Two distinct sourceNames -> two HeartRate samples survive (the dedupe key includes source).
        XCTAssertEqual(r.samples.filter { $0.type == "HeartRate" }.count, 2)
        XCTAssertGreaterThanOrEqual(r.summary.skippedSpans, 1)
    }

    /// TOLERANT PARSE layer: a hard, structural XML error (not a bad byte — the sanitizer can't fix
    /// a broken tag) AFTER at least one record was parsed keeps the partial result instead of
    /// discarding everything, and reports the truncated tail as a skipped span.
    func testHardParseErrorAfterRecordsKeepsPartialResult() throws {
        // Two valid records, then a malformed (never-closed, garbage) tag that libxml2 rejects.
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <HealthData>
         <Record type="HKQuantityTypeIdentifierHeartRate" sourceName="W" unit="count/min" startDate="2024-01-02 08:00:00 +0000" endDate="2024-01-02 08:00:00 +0000" value="61"/>
         <Record type="HKQuantityTypeIdentifierHeartRate" sourceName="W2" unit="count/min" startDate="2024-01-02 09:00:00 +0000" endDate="2024-01-02 09:00:00 +0000" value="72"/>
         <Record type="HKQuantityTypeIdentifierHeartRate" startDate=<<<BROKEN
        """
        let r = try AppleHealthImporter().importXML(data: Data(xml.utf8))
        // The two well-formed records before the break must survive.
        XCTAssertEqual(r.samples.filter { $0.type == "HeartRate" }.count, 2)
        XCTAssertGreaterThanOrEqual(r.summary.skippedSpans, 1, "the truncated tail must be surfaced as a skipped span")
    }

    /// A hard parse error with NO records parsed yet still throws (we don't silently swallow a
    /// completely broken file).
    func testHardParseErrorWithNoRecordsStillThrows() {
        let xml = "<<<not xml at all"
        XCTAssertThrowsError(try AppleHealthImporter().importXML(data: Data(xml.utf8)))
    }

    /// A clean export reports zero skipped spans (no false positives from the sanitizer).
    func testCleanFileReportsNoSkippedSpans() throws {
        let r = try parsed()
        XCTAssertEqual(r.summary.skippedSpans, 0)
    }

    /// A multi-byte UTF-8 character split across the sanitizer's chunk boundary must NOT be
    /// misclassified as invalid. We force a tiny chunk so the 2-byte "é" straddles two reads.
    func testMultiByteUTF8AcrossChunkBoundaryIsPreserved() throws {
        // "é" is U+00E9 = 0xC3 0xA9. Pad the sourceName so the split lands between those two bytes.
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <HealthData>
         <Record type="HKQuantityTypeIdentifierHeartRate" sourceName="caf\u{00E9}meter" unit="count/min" startDate="2024-01-02 08:00:00 +0000" endDate="2024-01-02 08:00:00 +0000" value="61"/>
        </HealthData>
        """
        let data = Data(xml.utf8)

        // Drive the sanitizer directly with an 8-byte chunk so the multi-byte char is guaranteed to
        // be cut across a refill; then parse the sanitized output and confirm the value survived
        // and nothing was scrubbed.
        let san = SanitizingInputStream(source: InputStream(data: data), chunkSize: 8)
        let parser = XMLParser(stream: san)
        let delegate = HealthXMLDelegate()
        parser.delegate = delegate
        XCTAssertTrue(parser.parse(), "well-formed UTF-8 split across chunks must parse cleanly")
        XCTAssertEqual(san.scrubbedRunCount, 0, "a valid multi-byte char must not be scrubbed")
        let result = delegate.makeResult()
        XCTAssertEqual(result.samples.first?.value, 61)
        XCTAssertEqual(result.samples.first?.sourceName, "caf\u{00E9}meter")
    }

    // MARK: - Bounded-memory path (issue #355)

    /// With `retainRawSamples:false` the importer must NOT hold the raw
    /// `[HealthSample]` array, yet its pre-folded `sampleDailies` must equal the
    /// batch fold of the SAME export parsed with retention on. This proves the
    /// incremental (bounded) fold == the batch fold, and that the app path can
    /// safely drop the raw samples.
    func testBoundedPathDropsRawSamplesButMatchesBatchFold() throws {
        let data = Fixtures.data(fixtureName)
        XCTAssertFalse(data.isEmpty, "\(fixtureName) fixture missing")

        // Retain-on: raw samples present, sampleDailies left empty (batch path).
        let retained = try AppleHealthImporter(retainRawSamples: true).importXML(data: data)
        XCTAssertFalse(retained.samples.isEmpty, "retain:true must keep raw samples")

        // Retain-off: raw samples dropped, sampleDailies pre-folded incrementally.
        let bounded = try AppleHealthImporter(retainRawSamples: false).importXML(data: data)
        XCTAssertTrue(bounded.samples.isEmpty, "retain:false must drop raw samples")

        // The incremental fold must equal the batch fold over the same samples.
        let batch = AppleHealthAggregator.daily(samples: retained.samples)
        XCTAssertEqual(bounded.sampleDailies, batch,
                       "incremental fold must match batch daily() exactly")

        // And aggregate() must reach the SAME merged result via either path.
        let aggBounded = AppleHealthAggregator.aggregate(bounded)
        let aggRetained = AppleHealthAggregator.aggregate(retained)
        XCTAssertEqual(aggBounded, aggRetained,
                       "aggregate() must be identical whether or not raw samples were retained")

        // Summary parity: recordCount + date span come from incremental tracking
        // when samples are dropped, and must match the retained run.
        XCTAssertEqual(bounded.summary.recordCount, retained.summary.recordCount)
        XCTAssertEqual(bounded.summary.earliest, retained.summary.earliest)
        XCTAssertEqual(bounded.summary.latest, retained.summary.latest)
        XCTAssertEqual(bounded.summary.countsByCategory, retained.summary.countsByCategory)
        // Workouts/sleep are unaffected by the flag.
        XCTAssertEqual(bounded.workouts, retained.workouts)
        XCTAssertEqual(bounded.sleepIntervals, retained.sleepIntervals)
    }

    /// `hasAnyRecord` (and therefore the tolerant-parse keep-partial decision)
    /// must still fire when raw samples are dropped — a hard error after records
    /// were seen keeps the partial result even on the bounded path.
    func testBoundedPathHardErrorAfterRecordsKeepsPartialResult() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <HealthData>
         <Record type="HKQuantityTypeIdentifierHeartRate" sourceName="W" unit="count/min" startDate="2024-01-02 08:00:00 +0000" endDate="2024-01-02 08:00:00 +0000" value="61"/>
         <Record type="HKQuantityTypeIdentifierHeartRate" startDate=<<<BROKEN
        """
        let r = try AppleHealthImporter(retainRawSamples: false).importXML(data: Data(xml.utf8))
        XCTAssertTrue(r.samples.isEmpty, "bounded path keeps no raw samples")
        // The folded aggregate still carries the one good day, and the tail is
        // surfaced as a skipped span (proves hasAnyRecord used anyRecordSeen).
        XCTAssertEqual(r.sampleDailies.count, 1)
        XCTAssertEqual(r.summary.recordCount, 1)
        XCTAssertGreaterThanOrEqual(r.summary.skippedSpans, 1)
    }

    // MARK: - Unknown elements tolerated

    func testUnknownElementsTolerated() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <HealthData>
         <SomeFutureElement foo="bar"><Nested/></SomeFutureElement>
         <Record type="HKQuantityTypeIdentifierHeartRate" sourceName="W" unit="count/min" startDate="2024-01-02 08:00:00 +0000" endDate="2024-01-02 08:00:00 +0000" value="80">
          <UnknownChild key="x" value="y"/>
         </Record>
        </HealthData>
        """
        let r = try AppleHealthImporter().importXML(data: Data(xml.utf8))
        XCTAssertEqual(r.samples.count, 1)
        XCTAssertEqual(r.samples[0].value, 80)
    }
}
