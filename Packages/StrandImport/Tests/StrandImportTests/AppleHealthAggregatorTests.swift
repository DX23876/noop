import XCTest
@testable import StrandImport

final class AppleHealthAggregatorTests: XCTestCase {
    func testEnergyChoosesAppleWatchWithoutCrossSourceDoubleCounting() {
        XCTAssertEqual(AppleHealthAggregator.preferredEnergyTotal([
            "Jane’s Apple Watch": 540,
            "Jane’s iPhone": 430,
            "NOOP": 600,
        ]), 540)
        XCTAssertEqual(AppleHealthAggregator.preferredEnergyTotal([
            "Phone": 400, "Other tracker": 350,
        ]), 400)
        XCTAssertNil(AppleHealthAggregator.preferredEnergyTotal(["NOOP": 500]))
    }

    // MARK: - Helpers

    /// Build a quantity HealthSample at a given UTC instant + offset.
    private func sample(
        _ type: String,
        _ value: Double?,
        at utc: Date,
        end: Date? = nil,
        offset: Int = 0
    ) -> HealthSample {
        HealthSample(
            type: type,
            value: value,
            valueString: value.map { String($0) },
            unit: nil,
            start: utc,
            end: end ?? utc,
            tzOffsetMin: offset,
            sourceName: "Test"
        )
    }

    /// Build a quantity HealthSample with an explicit unit string (for the
    /// body-composition kg/lb handling tests). `end` defaults to `utc` so the
    /// daily-latest tie-break works off the sample's end time.
    private func sample(
        _ type: String,
        _ value: Double?,
        at utc: Date,
        unit: String?,
        end: Date? = nil,
        offset: Int = 0
    ) -> HealthSample {
        HealthSample(
            type: type,
            value: value,
            valueString: value.map { String($0) },
            unit: unit,
            start: utc,
            end: end ?? utc,
            tzOffsetMin: offset,
            sourceName: "Test"
        )
    }

    private func sleep(
        _ stage: SleepStage,
        from start: Date,
        to end: Date,
        offset: Int = 0
    ) -> SleepStageInterval {
        SleepStageInterval(stage: stage, start: start, end: end, tzOffsetMin: offset, sourceName: "Test")
    }

    private func agg(_ daily: [AppleDailyAggregate], _ day: String) -> AppleDailyAggregate? {
        daily.first { $0.day == day }
    }

    // MARK: - Mean rules (resting, hrv, resp, walking)

    func testDailyMeansPerType() {
        let d1 = Fixtures.utc(2024, 3, 1, 8, 0, 0)
        let d1b = Fixtures.utc(2024, 3, 1, 20, 0, 0)
        let samples = [
            sample("RestingHeartRate", 50, at: d1),
            sample("RestingHeartRate", 60, at: d1b),
            sample("HeartRateVariabilitySDNN", 40, at: d1),
            sample("HeartRateVariabilitySDNN", 60, at: d1b),
            sample("RespiratoryRate", 14, at: d1),
            sample("RespiratoryRate", 16, at: d1b),
            sample("WalkingHeartRateAverage", 90, at: d1),
            sample("WalkingHeartRateAverage", 110, at: d1b),
        ]
        let daily = AppleHealthAggregator.daily(samples: samples)
        let a = try! XCTUnwrap(agg(daily, "2024-03-01"))
        XCTAssertEqual(a.restingHr!, 55, accuracy: 1e-9)
        XCTAssertEqual(a.hrvSDNN!, 50, accuracy: 1e-9)
        XCTAssertEqual(a.respRate!, 15, accuracy: 1e-9)
        XCTAssertEqual(a.walkingHr!, 100, accuracy: 1e-9)
    }

    // MARK: - HeartRate mean + max

    func testHeartRateMeanAndMax() {
        let day = Fixtures.utc(2024, 3, 2, 9, 0, 0)
        let samples = [
            sample("HeartRate", 60, at: day),
            sample("HeartRate", 80, at: day),
            sample("HeartRate", 130, at: day),
        ]
        let daily = AppleHealthAggregator.daily(samples: samples)
        let a = try! XCTUnwrap(agg(daily, "2024-03-02"))
        XCTAssertEqual(a.avgHr!, 90, accuracy: 1e-9)
        XCTAssertEqual(a.maxHr!, 130, accuracy: 1e-9)
    }

    // MARK: - Sum rules (steps, active, basal)

    func testDailySums() {
        let day = Fixtures.utc(2024, 3, 3, 10, 0, 0)
        let samples = [
            sample("StepCount", 1000, at: day),
            sample("StepCount", 2500, at: day),
            sample("ActiveEnergyBurned", 100, at: day),
            sample("ActiveEnergyBurned", 50, at: day),
            sample("BasalEnergyBurned", 700, at: day),
            sample("BasalEnergyBurned", 800, at: day),
        ]
        let daily = AppleHealthAggregator.daily(samples: samples)
        let a = try! XCTUnwrap(agg(daily, "2024-03-03"))
        XCTAssertEqual(a.steps!, 3500, accuracy: 1e-9)
        XCTAssertEqual(a.activeKcal!, 150, accuracy: 1e-9)
        XCTAssertEqual(a.basalKcal!, 1500, accuracy: 1e-9)
    }

    /// #589: overlapping step samples from DIFFERENT sources (an iPhone AND an Apple Watch both count the
    /// same walk) must NOT be summed across sources — that double-counts ~2x and poisons the steps
    /// calibration. We sum WITHIN a source but take the MAX source per day, the de-overlap Apple Health
    /// itself shows. Same-source samples still sum (see testDailySums).
    func testStepsDoNotDoubleCountAcrossSources() {
        let day = Fixtures.utc(2024, 3, 8, 10, 0, 0)
        func step(_ v: Double, _ src: String) -> HealthSample {
            HealthSample(type: "StepCount", value: v, valueString: String(Int(v)), unit: "count",
                         start: day, end: day, tzOffsetMin: 0, sourceName: src)
        }
        // iPhone logs 4000 + 3000 = 7000 across the day; the Watch logs 6500 + 1000 = 7500 the SAME day.
        let samples = [
            step(4000, "iPhone"), step(3000, "iPhone"),
            step(6500, "Apple Watch"), step(1000, "Apple Watch"),
        ]
        let a = try! XCTUnwrap(agg(AppleHealthAggregator.daily(samples: samples), "2024-03-08"))
        // NOT 14500 (the naive cross-source sum). MAX source = 7500.
        XCTAssertEqual(a.steps!, 7500, accuracy: 1e-9)
    }

    // MARK: - VO2Max latest

    func testVO2MaxLatestWins() {
        let early = Fixtures.utc(2024, 3, 4, 8, 0, 0)
        let late = Fixtures.utc(2024, 3, 4, 18, 0, 0)
        let samples = [
            sample("VO2Max", 42.0, at: early, end: early),
            sample("VO2Max", 45.0, at: late, end: late),
        ]
        let daily = AppleHealthAggregator.daily(samples: samples)
        let a = try! XCTUnwrap(agg(daily, "2024-03-04"))
        XCTAssertEqual(a.vo2max!, 45.0, accuracy: 1e-9)
    }

    // MARK: - SpO2 fraction → percent

    func testSpo2FractionDetectedAndScaled() {
        let day = Fixtures.utc(2024, 3, 5, 7, 0, 0)
        // Fractional values 0.97 / 0.95 should become 97 / 95 -> mean 96.
        let frac = [
            sample("OxygenSaturation", 0.97, at: day),
            sample("OxygenSaturation", 0.95, at: day),
        ]
        let a = try! XCTUnwrap(agg(AppleHealthAggregator.daily(samples: frac), "2024-03-05"))
        XCTAssertEqual(a.spo2Pct!, 96, accuracy: 1e-9)

        // Already-percent values (the importer pre-scales) stay as-is.
        let pct = [
            sample("OxygenSaturation", 97, at: day),
            sample("OxygenSaturation", 95, at: day),
        ]
        let b = try! XCTUnwrap(agg(AppleHealthAggregator.daily(samples: pct), "2024-03-05"))
        XCTAssertEqual(b.spo2Pct!, 96, accuracy: 1e-9)
    }

    // MARK: - Full HK identifier strings also map

    func testFullHKIdentifiersMap() {
        let day = Fixtures.utc(2024, 3, 6, 9, 0, 0)
        let samples = [
            sample("HKQuantityTypeIdentifierRestingHeartRate", 55, at: day),
            sample("HKQuantityTypeIdentifierStepCount", 1234, at: day),
        ]
        let a = try! XCTUnwrap(agg(AppleHealthAggregator.daily(samples: samples), "2024-03-06"))
        XCTAssertEqual(a.restingHr!, 55, accuracy: 1e-9)
        XCTAssertEqual(a.steps!, 1234, accuracy: 1e-9)
    }

    // MARK: - Day bucketing by tz offset

    func testDayBucketingByTimezoneOffset() {
        // 2024-03-07 23:30 +0100 == 22:30 UTC, local day is the 7th.
        let utcInstant = Fixtures.utc(2024, 3, 7, 22, 30, 0)
        let s1 = sample("HeartRate", 70, at: utcInstant, offset: 60)
        // Same UTC instant but offset 0 -> still the 7th at 22:30 UTC.
        let s2 = sample("HeartRate", 80, at: utcInstant, offset: 0)
        let daily = AppleHealthAggregator.daily(samples: [s1, s2])
        // Both fall on 2024-03-07 in their own offsets -> one bucket.
        XCTAssertEqual(daily.count, 1)
        XCTAssertEqual(daily[0].day, "2024-03-07")

        // Now a sample at 2024-03-07 23:30 UTC with +0100 -> local 2024-03-08 00:30.
        let lateUTC = Fixtures.utc(2024, 3, 7, 23, 30, 0)
        let s3 = sample("HeartRate", 65, at: lateUTC, offset: 60)
        let d2 = AppleHealthAggregator.daily(samples: [s3])
        XCTAssertEqual(d2[0].day, "2024-03-08")
    }

    func testNegativeOffsetBucketing() {
        // 2024-03-08 02:00 UTC with -0500 -> local 2024-03-07 21:00.
        let utcInstant = Fixtures.utc(2024, 3, 8, 2, 0, 0)
        let s = sample("StepCount", 500, at: utcInstant, offset: -300)
        let daily = AppleHealthAggregator.daily(samples: [s])
        XCTAssertEqual(daily[0].day, "2024-03-07")
    }

    // MARK: - Multi-day separation

    func testMultiDaySeparationAndSortOrder() {
        let day2 = Fixtures.utc(2024, 3, 2, 10, 0, 0)
        let day1 = Fixtures.utc(2024, 3, 1, 10, 0, 0)
        let day3 = Fixtures.utc(2024, 3, 3, 10, 0, 0)
        let samples = [
            sample("StepCount", 100, at: day2),
            sample("StepCount", 200, at: day1),
            sample("StepCount", 300, at: day3),
        ]
        let daily = AppleHealthAggregator.daily(samples: samples)
        XCTAssertEqual(daily.map { $0.day }, ["2024-03-01", "2024-03-02", "2024-03-03"])
        XCTAssertEqual(agg(daily, "2024-03-01")!.steps!, 200, accuracy: 1e-9)
        XCTAssertEqual(agg(daily, "2024-03-02")!.steps!, 100, accuracy: 1e-9)
        XCTAssertEqual(agg(daily, "2024-03-03")!.steps!, 300, accuracy: 1e-9)
    }

    // MARK: - Sleep stage minute sums

    func testSleepStageMinuteSums() {
        // A night ending on 2024-03-10 (wake day).
        let coreStart = Fixtures.utc(2024, 3, 9, 23, 0, 0)
        let coreEnd = Fixtures.utc(2024, 3, 10, 0, 0, 0)   // 60 min core
        let deepEnd = Fixtures.utc(2024, 3, 10, 0, 30, 0)  // 30 min deep
        let remEnd = Fixtures.utc(2024, 3, 10, 1, 15, 0)   // 45 min rem
        let awakeEnd = Fixtures.utc(2024, 3, 10, 1, 20, 0) // 5 min awake
        let inBedEnd = Fixtures.utc(2024, 3, 10, 1, 30, 0) // 10 min in bed (separate)

        let intervals = [
            sleep(.asleepCore, from: coreStart, to: coreEnd),
            sleep(.asleepDeep, from: coreEnd, to: deepEnd),
            sleep(.asleepREM, from: deepEnd, to: remEnd),
            sleep(.awake, from: remEnd, to: awakeEnd),
            sleep(.inBed, from: awakeEnd, to: inBedEnd),
        ]
        let m = AppleHealthAggregator.sleepDaily(intervals)
        let night = try! XCTUnwrap(m["2024-03-10"])
        XCTAssertEqual(night.core, 60, accuracy: 1e-9)
        XCTAssertEqual(night.deep, 30, accuracy: 1e-9)
        XCTAssertEqual(night.rem, 45, accuracy: 1e-9)
        XCTAssertEqual(night.awake, 5, accuracy: 1e-9)
        XCTAssertEqual(night.inBed, 10, accuracy: 1e-9)
        // asleep = core + deep + rem (awake/inBed excluded).
        XCTAssertEqual(night.asleep, 135, accuracy: 1e-9)
    }

    func testSleepKeyedByWakeDayAcrossMidnight() {
        // An interval that starts before midnight but ends after -> wake day.
        let start = Fixtures.utc(2024, 3, 11, 23, 30, 0)
        let end = Fixtures.utc(2024, 3, 12, 0, 30, 0) // 60 min, wakes on the 12th
        let m = AppleHealthAggregator.sleepDaily([sleep(.asleepCore, from: start, to: end)])
        XCTAssertNil(m["2024-03-11"])
        XCTAssertEqual(m["2024-03-12"]!.core, 60, accuracy: 1e-9)
    }

    func testLegacyAsleepUnspecifiedCountsAsAsleep() {
        let start = Fixtures.utc(2024, 3, 13, 1, 0, 0)
        let end = Fixtures.utc(2024, 3, 13, 1, 30, 0) // 30 min
        let m = AppleHealthAggregator.sleepDaily([sleep(.asleepUnspecified, from: start, to: end)])
        let n = try! XCTUnwrap(m["2024-03-13"])
        XCTAssertEqual(n.asleep, 30, accuracy: 1e-9)
        // Not attributed to a specific stage bucket.
        XCTAssertEqual(n.core, 0, accuracy: 1e-9)
        XCTAssertEqual(n.deep, 0, accuracy: 1e-9)
        XCTAssertEqual(n.rem, 0, accuracy: 1e-9)
    }

    func testUnknownSleepStageIgnored() {
        let start = Fixtures.utc(2024, 3, 14, 1, 0, 0)
        let end = Fixtures.utc(2024, 3, 14, 2, 0, 0)
        let m = AppleHealthAggregator.sleepDaily([sleep(.unknown, from: start, to: end)])
        let n = try! XCTUnwrap(m["2024-03-14"])
        XCTAssertEqual(n.asleep, 0, accuracy: 1e-9)
        XCTAssertEqual(n.awake, 0, accuracy: 1e-9)
        XCTAssertEqual(n.inBed, 0, accuracy: 1e-9)
    }

    // MARK: - Full merge

    func testAggregateMergesSamplesAndSleep() {
        let day = Fixtures.utc(2024, 3, 20, 9, 0, 0)
        let samples = [
            sample("RestingHeartRate", 52, at: day),
            sample("StepCount", 8000, at: day),
        ]
        // Sleep night that wakes on the same day.
        let sStart = Fixtures.utc(2024, 3, 20, 2, 0, 0)
        let sEnd = Fixtures.utc(2024, 3, 20, 3, 0, 0) // 60 min deep
        let intervals = [sleep(.asleepDeep, from: sStart, to: sEnd)]

        let summary = ImportSummary(
            sourceKind: .appleHealth, recordCount: samples.count,
            earliest: day, latest: day, countsByCategory: [:]
        )
        let result = AppleHealthImportResult(
            samples: samples, workouts: [], sleepIntervals: intervals, summary: summary
        )
        let merged = AppleHealthAggregator.aggregate(result)
        let a = try! XCTUnwrap(agg(merged, "2024-03-20"))
        XCTAssertEqual(a.restingHr!, 52, accuracy: 1e-9)
        XCTAssertEqual(a.steps!, 8000, accuracy: 1e-9)
        XCTAssertEqual(a.deepMin!, 60, accuracy: 1e-9)
        XCTAssertEqual(a.asleepMin!, 60, accuracy: 1e-9)
    }

    func testAggregateIncludesSleepOnlyDays() {
        // A day with sleep but no quantity samples still produces a row.
        let sStart = Fixtures.utc(2024, 3, 21, 2, 0, 0)
        let sEnd = Fixtures.utc(2024, 3, 21, 3, 0, 0)
        let intervals = [sleep(.asleepREM, from: sStart, to: sEnd)]
        let summary = ImportSummary(
            sourceKind: .appleHealth, recordCount: 0,
            earliest: sStart, latest: sEnd, countsByCategory: [:]
        )
        let result = AppleHealthImportResult(
            samples: [], workouts: [], sleepIntervals: intervals, summary: summary
        )
        let merged = AppleHealthAggregator.aggregate(result)
        let a = try! XCTUnwrap(agg(merged, "2024-03-21"))
        XCTAssertNil(a.restingHr)
        XCTAssertNil(a.steps)
        XCTAssertEqual(a.remMin!, 60, accuracy: 1e-9)
        XCTAssertEqual(a.asleepMin!, 60, accuracy: 1e-9)
    }

    // MARK: - metricPoints flattening

    func testMetricPointsFlattening() {
        let day = Fixtures.utc(2024, 3, 25, 9, 0, 0)
        let samples = [
            sample("RestingHeartRate", 50, at: day),
            sample("HeartRateVariabilitySDNN", 60, at: day),
            sample("OxygenSaturation", 0.97, at: day),
            sample("RespiratoryRate", 15, at: day),
            sample("HeartRate", 70, at: day),
            sample("HeartRate", 120, at: day),
            sample("StepCount", 5000, at: day),
            sample("ActiveEnergyBurned", 300, at: day),
            sample("BasalEnergyBurned", 1500, at: day),
            sample("WalkingHeartRateAverage", 95, at: day),
            sample("VO2Max", 44, at: day),
        ]
        let sStart = Fixtures.utc(2024, 3, 25, 2, 0, 0)
        let intervals = [
            sleep(.asleepCore, from: sStart, to: Fixtures.utc(2024, 3, 25, 3, 0, 0)),  // 60 core
            sleep(.asleepDeep, from: Fixtures.utc(2024, 3, 25, 3, 0, 0), to: Fixtures.utc(2024, 3, 25, 3, 30, 0)), // 30 deep
            sleep(.asleepREM, from: Fixtures.utc(2024, 3, 25, 3, 30, 0), to: Fixtures.utc(2024, 3, 25, 4, 0, 0)),  // 30 rem
        ]
        let summary = ImportSummary(
            sourceKind: .appleHealth, recordCount: samples.count,
            earliest: day, latest: day, countsByCategory: [:]
        )
        let result = AppleHealthImportResult(
            samples: samples, workouts: [], sleepIntervals: intervals, summary: summary
        )
        let daily = AppleHealthAggregator.aggregate(result)
        let points = AppleHealthAggregator.metricPoints(daily)

        // Build a lookup for the single day.
        var byKey: [String: Double] = [:]
        for p in points where p.day == "2024-03-25" { byKey[p.key] = p.value }

        XCTAssertEqual(byKey["resting_hr"]!, 50, accuracy: 1e-9)
        XCTAssertEqual(byKey["hrv"]!, 60, accuracy: 1e-9)
        XCTAssertEqual(byKey["spo2"]!, 97, accuracy: 1e-9)
        XCTAssertEqual(byKey["resp_rate"]!, 15, accuracy: 1e-9)
        XCTAssertEqual(byKey["avg_hr"]!, 95, accuracy: 1e-9)   // (70+120)/2
        XCTAssertEqual(byKey["max_hr"]!, 120, accuracy: 1e-9)
        XCTAssertEqual(byKey["walking_hr"]!, 95, accuracy: 1e-9)
        XCTAssertEqual(byKey["steps"]!, 5000, accuracy: 1e-9)
        XCTAssertEqual(byKey["active_kcal"]!, 300, accuracy: 1e-9)
        XCTAssertEqual(byKey["basal_kcal"]!, 1500, accuracy: 1e-9)
        XCTAssertEqual(byKey["vo2max"]!, 44, accuracy: 1e-9)
        XCTAssertEqual(byKey["asleep_min"]!, 120, accuracy: 1e-9)
        XCTAssertEqual(byKey["deep_min"]!, 30, accuracy: 1e-9)
        XCTAssertEqual(byKey["rem_min"]!, 30, accuracy: 1e-9)
        XCTAssertEqual(byKey["core_min"]!, 60, accuracy: 1e-9)
    }

    func testMetricPointsSkipsNilValues() {
        // A day with only steps -> only a steps point, no HR keys.
        let day = Fixtures.utc(2024, 3, 26, 9, 0, 0)
        let daily = AppleHealthAggregator.daily(samples: [sample("StepCount", 100, at: day)])
        let points = AppleHealthAggregator.metricPoints(daily)
        let keys = Set(points.map { $0.key })
        XCTAssertEqual(keys, ["steps"])
        XCTAssertFalse(keys.contains("resting_hr"))
        XCTAssertFalse(keys.contains("avg_hr"))
    }

    // MARK: - Body composition (daily latest)

    func testBodyCompositionDailyLatest() {
        // Two weigh-ins on the same day -> the later (by end time) wins.
        let early = Fixtures.utc(2024, 4, 1, 7, 0, 0)
        let late = Fixtures.utc(2024, 4, 1, 19, 0, 0)
        let samples = [
            sample("BodyMass", 80.0, at: early, end: early),
            sample("BodyMass", 79.5, at: late, end: late),
            sample("LeanBodyMass", 60.0, at: early, end: early),
            sample("LeanBodyMass", 61.0, at: late, end: late),
            sample("BodyMassIndex", 24.0, at: early, end: early),
            sample("BodyMassIndex", 23.8, at: late, end: late),
        ]
        let a = try! XCTUnwrap(agg(AppleHealthAggregator.daily(samples: samples), "2024-04-01"))
        XCTAssertEqual(a.weightKg!, 79.5, accuracy: 1e-9)
        XCTAssertEqual(a.leanMassKg!, 61.0, accuracy: 1e-9)
        XCTAssertEqual(a.bmi!, 23.8, accuracy: 1e-9)
    }

    func testBodyFatFractionDetectedAndScaled() {
        let day = Fixtures.utc(2024, 4, 2, 8, 0, 0)
        // Fraction 0.18 -> 18 percent.
        let frac = [sample("BodyFatPercentage", 0.18, at: day)]
        let a = try! XCTUnwrap(agg(AppleHealthAggregator.daily(samples: frac), "2024-04-02"))
        XCTAssertEqual(a.bodyFatPct!, 18, accuracy: 1e-9)

        // Already-percent value (>1) stays as-is.
        let pct = [sample("BodyFatPercentage", 22.0, at: day)]
        let b = try! XCTUnwrap(agg(AppleHealthAggregator.daily(samples: pct), "2024-04-02"))
        XCTAssertEqual(b.bodyFatPct!, 22, accuracy: 1e-9)
    }

    func testBodyFatLatestWins() {
        let early = Fixtures.utc(2024, 4, 3, 7, 0, 0)
        let late = Fixtures.utc(2024, 4, 3, 18, 0, 0)
        let samples = [
            sample("BodyFatPercentage", 0.20, at: early, end: early),
            sample("BodyFatPercentage", 0.19, at: late, end: late),
        ]
        let a = try! XCTUnwrap(agg(AppleHealthAggregator.daily(samples: samples), "2024-04-03"))
        XCTAssertEqual(a.bodyFatPct!, 19, accuracy: 1e-9)
    }

    func testBodyMassKgAssumedWhenNoUnit() {
        // No unit -> assume kg, value passes through unchanged.
        let day = Fixtures.utc(2024, 4, 4, 9, 0, 0)
        let a = try! XCTUnwrap(agg(AppleHealthAggregator.daily(samples: [sample("BodyMass", 75.0, at: day)]), "2024-04-04"))
        XCTAssertEqual(a.weightKg!, 75.0, accuracy: 1e-9)
    }

    func testBodyMassPoundsConvertedToKg() {
        let day = Fixtures.utc(2024, 4, 5, 9, 0, 0)
        // 200 lb -> 90.7184 kg.
        let lbWeight = sample("BodyMass", 200.0, at: day, unit: "lb")
        let a = try! XCTUnwrap(agg(AppleHealthAggregator.daily(samples: [lbWeight]), "2024-04-05"))
        XCTAssertEqual(a.weightKg!, 200.0 * 0.453592, accuracy: 1e-6)

        // Explicit kg unit -> unchanged.
        let kgWeight = sample("BodyMass", 90.0, at: day, unit: "kg")
        let b = try! XCTUnwrap(agg(AppleHealthAggregator.daily(samples: [kgWeight]), "2024-04-05"))
        XCTAssertEqual(b.weightKg!, 90.0, accuracy: 1e-9)
    }

    func testLeanMassPoundsConvertedToKg() {
        let day = Fixtures.utc(2024, 4, 6, 9, 0, 0)
        let lbLean = sample("LeanBodyMass", 150.0, at: day, unit: "lbs")
        let a = try! XCTUnwrap(agg(AppleHealthAggregator.daily(samples: [lbLean]), "2024-04-06"))
        XCTAssertEqual(a.leanMassKg!, 150.0 * 0.453592, accuracy: 1e-6)
    }

    func testBodyCompositionFullHKIdentifiersMap() {
        let day = Fixtures.utc(2024, 4, 7, 9, 0, 0)
        let samples = [
            sample("HKQuantityTypeIdentifierBodyMass", 82.0, at: day),
            sample("HKQuantityTypeIdentifierBodyFatPercentage", 0.21, at: day),
            sample("HKQuantityTypeIdentifierLeanBodyMass", 64.0, at: day),
            sample("HKQuantityTypeIdentifierBodyMassIndex", 25.1, at: day),
        ]
        let a = try! XCTUnwrap(agg(AppleHealthAggregator.daily(samples: samples), "2024-04-07"))
        XCTAssertEqual(a.weightKg!, 82.0, accuracy: 1e-9)
        XCTAssertEqual(a.bodyFatPct!, 21, accuracy: 1e-9)
        XCTAssertEqual(a.leanMassKg!, 64.0, accuracy: 1e-9)
        XCTAssertEqual(a.bmi!, 25.1, accuracy: 1e-9)
    }

    func testBodyOnlyDayStillProducesRowViaAggregate() {
        // A day with only body-composition samples (no cardio/sleep) still
        // surfaces a merged row.
        let day = Fixtures.utc(2024, 4, 8, 9, 0, 0)
        let samples = [sample("BodyMass", 77.0, at: day)]
        let summary = ImportSummary(
            sourceKind: .appleHealth, recordCount: samples.count,
            earliest: day, latest: day, countsByCategory: [:]
        )
        let result = AppleHealthImportResult(
            samples: samples, workouts: [], sleepIntervals: [], summary: summary
        )
        let merged = AppleHealthAggregator.aggregate(result)
        let a = try! XCTUnwrap(agg(merged, "2024-04-08"))
        XCTAssertEqual(a.weightKg!, 77.0, accuracy: 1e-9)
        XCTAssertNil(a.restingHr)
        XCTAssertNil(a.asleepMin)
    }

    func testMetricPointsEmitsBodyCompositionKeys() {
        let day = Fixtures.utc(2024, 4, 9, 9, 0, 0)
        let samples = [
            sample("BodyMass", 78.0, at: day),
            sample("BodyFatPercentage", 0.20, at: day),
            sample("LeanBodyMass", 62.0, at: day),
            sample("BodyMassIndex", 24.5, at: day),
        ]
        let daily = AppleHealthAggregator.daily(samples: samples)
        let points = AppleHealthAggregator.metricPoints(daily)

        var byKey: [String: Double] = [:]
        for p in points where p.day == "2024-04-09" { byKey[p.key] = p.value }

        XCTAssertEqual(byKey["weight"]!, 78.0, accuracy: 1e-9)
        XCTAssertEqual(byKey["body_fat"]!, 20, accuracy: 1e-9)
        XCTAssertEqual(byKey["lean_mass"]!, 62.0, accuracy: 1e-9)
        XCTAssertEqual(byKey["bmi"]!, 24.5, accuracy: 1e-9)
    }

    func testMetricPointsSkipsNilBodyComposition() {
        // A weight-only day emits "weight" but not body_fat / lean_mass / bmi.
        let day = Fixtures.utc(2024, 4, 10, 9, 0, 0)
        let daily = AppleHealthAggregator.daily(samples: [sample("BodyMass", 80.0, at: day)])
        let keys = Set(AppleHealthAggregator.metricPoints(daily).map { $0.key })
        XCTAssertEqual(keys, ["weight"])
        XCTAssertFalse(keys.contains("body_fat"))
        XCTAssertFalse(keys.contains("lean_mass"))
        XCTAssertFalse(keys.contains("bmi"))
    }

    // MARK: - localDay direct

    func testLocalDayDirect() {
        // 23:30 UTC at +0100 -> next day 00:30 local.
        let d = AppleHealthAggregator.localDay(Fixtures.utc(2024, 12, 31, 23, 30, 0), tzOffsetMin: 60)
        XCTAssertEqual(d, "2025-01-01")
    }
}
