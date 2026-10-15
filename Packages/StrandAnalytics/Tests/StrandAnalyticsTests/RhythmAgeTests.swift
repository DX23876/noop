import XCTest
@testable import StrandAnalytics

/// The daily-rhythm readout built on CosinorAge: the WHOOP 5/MG `@41` → ENMO conversion, the comparison with
/// the published cohort and the weekly gate. Probe values for the conversion come from the isotonic fit in
/// `Tools/cosinor_calib.py` over the 2026-10-08…15 MG week (9018 minutes, thinned to 32 knots).
final class RhythmAgeTests: XCTestCase {

    // MARK: Conversion

    func testConversionMatchesTheFittedTableAtProbePoints() {
        XCTAssertEqual(RhythmAge.enmo(fromDyn41Mg: 0), 0.606115, accuracy: 1e-4)
        XCTAssertEqual(RhythmAge.enmo(fromDyn41Mg: 10), 1.423576, accuracy: 1e-4)
        XCTAssertEqual(RhythmAge.enmo(fromDyn41Mg: 20), 3.439115, accuracy: 1e-4)
        XCTAssertEqual(RhythmAge.enmo(fromDyn41Mg: 50), 9.616241, accuracy: 1e-4)
        XCTAssertEqual(RhythmAge.enmo(fromDyn41Mg: 100), 32.573714, accuracy: 1e-4)
        XCTAssertEqual(RhythmAge.enmo(fromDyn41Mg: 400), 114.769473, accuracy: 1e-4)
    }

    func testConversionHoldsItsEndValueBeyondTheMeasuredRange() {
        XCTAssertEqual(RhythmAge.enmo(fromDyn41Mg: 5_000), RhythmAge.enmo(fromDyn41Mg: 654.4341), accuracy: 1e-9)
    }

    func testConversionNeverDecreases() {
        var previous = -Double.infinity
        for x in stride(from: 0.0, through: 1_000.0, by: 0.5) {
            let y = RhythmAge.enmo(fromDyn41Mg: x)
            XCTAssertGreaterThanOrEqual(y, previous, "at \(x) mg")
            previous = y
        }
    }

    // MARK: Minute series

    func testMinuteWithEnoughSecondsIsConvertedFromItsMean() {
        let start = 1_791_590_400   // 2026-10-09 00:00 UTC
        let samples = (0..<60).map { CosinorAgeEngine.ActivitySample(ts: start + $0, g: 0.020) }
        let days = RhythmAge.daySeries(dyn41: samples, tzOffsetSeconds: 0)
        XCTAssertEqual(days.count, 1)
        XCTAssertEqual(days[0].minutes[0]!, RhythmAge.enmo(fromDyn41Mg: 20), accuracy: 1e-9)
        XCTAssertEqual(days[0].validMinutes, 1)
    }

    func testMinuteWithTooFewSecondsIsLeftEmpty() {
        let start = 1_791_590_400
        let thin = (0..<49).map { CosinorAgeEngine.ActivitySample(ts: start + $0, g: 0.020) }
        let full = (0..<60).map { CosinorAgeEngine.ActivitySample(ts: start + 60 + $0, g: 0.020) }
        let days = RhythmAge.daySeries(dyn41: thin + full, tzOffsetSeconds: 0)
        XCTAssertNil(days[0].minutes[0])
        XCTAssertNotNil(days[0].minutes[1])
    }

    // MARK: Cohort comparison (Shim et al. 2024, Table 1, UK Biobank training set, quartiles)

    func testMovementIsComparedWithTheCohortQuartiles() {
        XCTAssertEqual(RhythmAge.movementLevel(mesorMg: 16), .below)
        XCTAssertEqual(RhythmAge.movementLevel(mesorMg: 28), .typical)
        XCTAssertEqual(RhythmAge.movementLevel(mesorMg: 40), .above)
    }

    func testDayNightContrastIsComparedWithTheCohortQuartiles() {
        XCTAssertEqual(RhythmAge.contrastLevel(amplitudeMg: 9.8), .below)
        XCTAssertEqual(RhythmAge.contrastLevel(amplitudeMg: 23.5), .typical)
        XCTAssertEqual(RhythmAge.contrastLevel(amplitudeMg: 31), .above)
    }

    func testPeakTimeIsComparedWithTheCohortQuartiles() {
        XCTAssertEqual(RhythmAge.peakLevel(hour: 12.8), .below)
        XCTAssertEqual(RhythmAge.peakLevel(hour: 14.0), .typical)
        XCTAssertEqual(RhythmAge.peakLevel(hour: 15.5), .above)
    }

    // MARK: Weekly outcome

    /// Seven local days of per-second `@41`, every second present, following a day-night cosine.
    private func week(days: Int = 7, hoursPerDay: Int = 24, start: Int = 1_791_590_400) -> [CosinorAgeEngine.ActivitySample] {
        var out: [CosinorAgeEngine.ActivitySample] = []
        for d in 0..<days {
            for s in stride(from: 0, to: hoursPerDay * 3600, by: 1) {
                let hour = Double(s) / 3600
                let mg = 40 + 35 * cos(2 * Double.pi * (hour - 14) / 24)
                out.append(.init(ts: start + d * 86_400 + s, g: mg / 1000))
            }
        }
        return out
    }

    func testAFullWeekGivesAReadingThatEqualsTheEngineOnTheConvertedMinutes() {
        let samples = week()
        guard case .reading(let r) = RhythmAge.evaluate(dyn41: samples, age: 40, sex: .unknown, tzOffsetSeconds: 0) else {
            return XCTFail("a fully worn week must give a reading")
        }
        let expected = CosinorAgeEngine.compute(days: RhythmAge.daySeries(dyn41: samples, tzOffsetSeconds: 0),
                                                age: 40, sex: .unknown)!
        XCTAssertEqual(r.result.cosinorAge, expected.cosinorAge, accuracy: 1e-9)
        XCTAssertEqual(r.peakHour, 14, accuracy: 0.3)
    }

    func testTooFewHoursAreReportedAsCollectingWithTheHoursSoFar() {
        let samples = week(days: 2)
        guard case .collecting(let hours) = RhythmAge.evaluate(dyn41: samples, age: 40, sex: .unknown, tzOffsetSeconds: 0) else {
            return XCTFail("48 h is below the study's 72 h bar")
        }
        XCTAssertEqual(hours, 48, accuracy: 0.1)
    }

    func testDaytimeOnlyWearIsCollectingNotAReading() {
        let samples = week(days: 7, hoursPerDay: 16)
        guard case .collecting = RhythmAge.evaluate(dyn41: samples, age: 40, sex: .unknown, tzOffsetSeconds: 0) else {
            return XCTFail("an unobserved night must not be scored")
        }
    }

    func testNoMotionSamplesMeansNoData() {
        XCTAssertEqual(RhythmAge.evaluate(dyn41: [], age: 40, sex: .unknown, tzOffsetSeconds: 0), .noData)
    }

    func testFittedActivityPeaksAtThePeakHourAndNeverGoesNegative() {
        XCTAssertEqual(RhythmAge.fittedActivity(hour: 13, mesor: 16, amplitude: 10, peakHour: 13), 26, accuracy: 1e-9)
        XCTAssertEqual(RhythmAge.fittedActivity(hour: 1, mesor: 16, amplitude: 10, peakHour: 13), 6, accuracy: 1e-9)
        XCTAssertEqual(RhythmAge.fittedActivity(hour: 1, mesor: 5, amplitude: 10, peakHour: 13), 0)
    }

    // MARK: Hour of day

    /// The wearer's real week (2026-10-08…15), converted activity per clock hour.
    private let realWeek: [Double?] = [8.8, 4.6, 2.8, 1.8, 2.8, 3.1, 14.4, 21.3, 17.9, 37.4, 39.8, 34.7,
                                       20.4, 25.9, 14.6, 17.4, 14.5, 11.0, 19.2, 31.3, 11.2, 12.3, 13.4, 10.7]

    func testHourlyProfileAveragesEveryMinuteOfAClockHourAcrossDays() {
        var a = [Double?](repeating: nil, count: 1440), b = [Double?](repeating: nil, count: 1440)
        a[9 * 60] = 10; a[9 * 60 + 1] = 20; b[9 * 60 + 30] = 60
        let profile = RhythmAge.hourlyProfile([.init(minutes: a, validMinutes: 2), .init(minutes: b, validMinutes: 1)])
        XCTAssertEqual(profile.count, 24)
        XCTAssertEqual(profile[9]!, 30, accuracy: 1e-9)
        XCTAssertNil(profile[10])
    }

    func testTheTypicalDayPeaksInTheAfternoonAndIsLowAtNight() {
        XCTAssertEqual(RhythmAge.typicalDay.count, 24)
        XCTAssertEqual(RhythmAge.typicalDay.firstIndex(of: RhythmAge.typicalDay.max()!), 13)
        XCTAssertLessThan(RhythmAge.typicalDay[2], 10)
    }

    func testPartsOfTheDayAreComparedWithTheTypicalDay() {
        let parts = RhythmAge.partLevels(realWeek)
        XCTAssertEqual(parts[.morning], .typical)
        XCTAssertEqual(parts[.afternoon], .below)
        XCTAssertEqual(parts[.evening], .typical)
    }

    func testAPartWithoutDataHasNoLevel() {
        var profile = realWeek
        for h in 18..<22 { profile[h] = nil }
        XCTAssertNil(RhythmAge.partLevels(profile)[.evening])
    }

    func testTheBusiestThreeHoursAreFoundInTheRealWeek() {
        XCTAssertEqual(RhythmAge.busiestWindowStart(realWeek), 9)
    }

    func testNoDaytimeDataHasNoBusiestWindow() {
        XCTAssertNil(RhythmAge.busiestWindowStart([Double?](repeating: nil, count: 24)))
    }

    func testAReadingCarriesTheHourlyProfile() {
        guard case .reading(let r) = RhythmAge.evaluate(dyn41: week(), age: 40, sex: .unknown, tzOffsetSeconds: 0) else {
            return XCTFail("a fully worn week must give a reading")
        }
        XCTAssertEqual(r.hourly.count, 24)
        // A cosine peaking at 14:00 makes 12–15 and 13–16 equally busy.
        XCTAssertTrue([12, 13].contains(RhythmAge.busiestWindowStart(r.hourly) ?? -1))
    }

    func testProfileSexStringsMapToTheModelVariants() {
        XCTAssertEqual(RhythmAge.sex(profileValue: "Male"), .male)
        XCTAssertEqual(RhythmAge.sex(profileValue: "female"), .female)
        XCTAssertEqual(RhythmAge.sex(profileValue: ""), .unknown)
    }
}
