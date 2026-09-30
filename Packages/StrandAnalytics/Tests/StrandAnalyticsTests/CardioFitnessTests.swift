import XCTest
@testable import StrandAnalytics

final class CardioFitnessTests: XCTestCase {

    private func jurcaVO2(sex: String, age: Double, weightKg: Double, heightCm: Double,
                          restingHR: Double, level: JurcaFitness.ActivityLevel) throws -> Double {
        try XCTUnwrap(JurcaFitness.estimateMET(sex: sex, age: age, weightKg: weightKg, heightCm: heightCm,
                                               restingHR: restingHR, activityLevel: level)) * 3.5
    }

    // MARK: - Jurca 2005

    /// The worksheet's own arithmetic, term by term, so a transcription slip in one coefficient fails here
    /// rather than moving everyone's energy quietly.
    func testCoefficientsAreTheWorksheets() throws {
        // BMI exactly 25: 1.8 m, 81 kg.
        let met = try XCTUnwrap(JurcaFitness.estimateMET(sex: "male", age: 40, weightKg: 81, heightCm: 180,
                                                         restingHR: 60, activityLevel: .level4))
        let body: Double = 0.10 * 40 + 0.17 * 25 + 0.03 * 60
        let expected: Double = 18.07 + 2.77 + 1.76 - body
        XCTAssertEqual(met, expected, accuracy: 1e-9)
        let scores = JurcaFitness.ActivityLevel.allCases.map(\.score)
        XCTAssertEqual(scores, [0, 0.32, 1.06, 1.76, 3.03])
    }

    func testSexTermsAndNonbinaryMidpoint() throws {
        func met(_ sex: String) throws -> Double {
            try XCTUnwrap(JurcaFitness.estimateMET(sex: sex, age: 40, weightKg: 81, heightCm: 180,
                                                   restingHR: 60, activityLevel: .level1))
        }
        XCTAssertEqual(try met("male") - met("female"), 2.77, accuracy: 1e-9)
        XCTAssertEqual(try met("nonbinary"), (try met("male") + met("female")) / 2, accuracy: 1e-9)
    }

    /// Five bodies the formula has to serve. Ranges are the published norms for each, not the formula's
    /// own output, so the test says whether it is plausible rather than whether it is unchanged.
    func testPersonasLandInPlausibleRanges() throws {
        let athlete = try jurcaVO2(sex: "female", age: 30, weightKg: 60, heightCm: 168, restingHR: 48,
                                   level: .level5)
        XCTAssertTrue((40...55).contains(athlete), "\(athlete)")
        let muscular = try jurcaVO2(sex: "male", age: 30, weightKg: 100, heightCm: 180, restingHR: 55,
                                    level: .level4)
        XCTAssertTrue((40...55).contains(muscular), "\(muscular)")
        let untrained = try jurcaVO2(sex: "male", age: 40, weightKg: 75, heightCm: 178, restingHR: 72,
                                     level: .level1)
        XCTAssertTrue((30...40).contains(untrained), "\(untrained)")
        for level in [JurcaFitness.ActivityLevel.level2, .level3, .level4, .level5] {
            let heavy = try jurcaVO2(sex: "male", age: 35, weightKg: 212, heightCm: 196, restingHR: 63,
                                     level: level)
            XCTAssertTrue((18...32).contains(heavy), "\(level) \(heavy)")
        }
        let older = try jurcaVO2(sex: "female", age: 70, weightKg: 65, heightCm: 162, restingHR: 70,
                                 level: .level2)
        XCTAssertTrue((15...24).contains(older), "\(older)")
    }

    /// The failure this replaces: Uth reads a 212 kg wearer as fit as a club runner.
    func testTheHeavyWearerIsFarBelowWhatUthSaid() throws {
        let uth = try XCTUnwrap(Calories.vo2maxFor(hrmax: 195, restingHR: 63))
        let jurca = try jurcaVO2(sex: "male", age: 35, weightKg: 212, heightCm: 196, restingHR: 63,
                                 level: .level3)
        XCTAssertGreaterThan(uth, 45)
        XCTAssertLessThan(jurca, uth * 0.6)
    }

    func testMissingBodyInputsGiveNoEstimate() {
        XCTAssertNil(JurcaFitness.estimateMET(sex: "male", age: 35, weightKg: 80, heightCm: 0,
                                              restingHR: 60, activityLevel: .level1))
        XCTAssertNil(JurcaFitness.estimateMET(sex: "male", age: 35, weightKg: 80, heightCm: 180,
                                              restingHR: .nan, activityLevel: .level1))
    }

    func testLevelBoundariesFollowTheWorksheet() {
        XCTAssertEqual(JurcaFitness.level(weeklyAerobicMinutes: 181, lightActivityDaysPerWeek: 0), .level5)
        XCTAssertEqual(JurcaFitness.level(weeklyAerobicMinutes: 180, lightActivityDaysPerWeek: 0), .level4)
        XCTAssertEqual(JurcaFitness.level(weeklyAerobicMinutes: 60, lightActivityDaysPerWeek: 0), .level4)
        XCTAssertEqual(JurcaFitness.level(weeklyAerobicMinutes: 59, lightActivityDaysPerWeek: 7), .level3)
        XCTAssertEqual(JurcaFitness.level(weeklyAerobicMinutes: 20, lightActivityDaysPerWeek: 0), .level3)
        XCTAssertEqual(JurcaFitness.level(weeklyAerobicMinutes: 19, lightActivityDaysPerWeek: 5), .level2)
        XCTAssertEqual(JurcaFitness.level(weeklyAerobicMinutes: 19, lightActivityDaysPerWeek: 4.9), .level1)
    }

    // MARK: - Activity category from measured days

    private func evidence(_ day: String, minutes: Int, light: Bool = true) -> DailyActivityEvidence {
        DailyActivityEvidence(day: day, aerobicSeconds: minutes * 60, hadLightActivity: light)
    }

    func testTheCategoryReadsTheFourWeeksEndingOnTheDay() {
        // 28 days of 30 aerobic minutes = 210 a week, level 5. A day after the priced one must not count,
        // nor one 28 days before it.
        var rows = (0..<28).map { evidence(WeeklyDigestEngine.addDays("2026-09-28", -$0), minutes: 30) }
        rows.append(evidence("2026-09-29", minutes: 10_000))
        rows.append(evidence("2026-08-31", minutes: 10_000))
        XCTAssertEqual(PeakMETResolver.activityLevel(for: "2026-09-28", evidence: rows), .level5)
    }

    func testTheRateIsTakenOverObservedDaysOnly() {
        // A strap worn for one week: 70 aerobic minutes in that week is level 4, not a quarter of it.
        let rows = (0..<7).map { evidence(WeeklyDigestEngine.addDays("2026-09-28", -$0), minutes: 10) }
        XCTAssertEqual(PeakMETResolver.activityLevel(for: "2026-09-28", evidence: rows), .level4)
        XCTAssertNil(PeakMETResolver.activityLevel(for: "2026-09-28", evidence: []))
    }

    // MARK: - Resolver

    private let heavy = UserProfile(weightKg: 200, heightCm: 196, age: 35, sex: "male")

    private func resolve(day: String = "2026-09-28", manual: PeakMETResolver.ManualEntry? = nil,
                         apple: [VO2maxReading] = [], restingHR: Double? = 63,
                         level: JurcaFitness.ActivityLevel? = .level3,
                         weights: [String: Double] = [:]) -> PeakMETResolution? {
        PeakMETResolver.resolve(day: day, profile: heavy, restingHR: restingHR, manual: manual,
                                apple: apple, weightOnDay: { weights[$0] }, activityLevel: level)
    }

    private func reading(_ day: String, _ value: Double) -> VO2maxReading {
        VO2maxReading(day: day, value: value, segment: "apple-health")
    }

    func testAnEnteredValueOutranksAppleAndExpiresAfterHalfAYear() throws {
        let manual = PeakMETResolver.ManualEntry(vo2max: 28, day: "2026-06-01", weightKg: 200)
        let apple = [reading("2026-09-20", 19)]
        XCTAssertEqual(resolve(day: "2026-09-28", manual: manual, apple: apple)?.source, .manual)
        XCTAssertEqual(resolve(day: "2026-11-30", manual: manual)?.source, .manual)   // day 182
        XCTAssertEqual(resolve(day: "2026-12-02", manual: manual)?.source, .jurca)    // day 184
        // Entered in the future of the priced day: not yet known.
        XCTAssertEqual(resolve(day: "2026-05-31", manual: manual)?.source, .jurca)
    }

    /// Half a year, like an entered value: a rarely worn Watch must not hand most days to the formula.
    func testAppleCountsForHalfAYearAndNeverFromTheFuture() {
        XCTAssertEqual(PeakMETResolver.appleFreshnessDays, 183)
        XCTAssertEqual(resolve(day: "2026-09-28", apple: [reading("2026-08-28", 19)])?.source, .appleWatch)
        XCTAssertEqual(resolve(day: "2026-09-28", apple: [reading("2026-03-29", 19)])?.source, .appleWatch)  // day 183
        XCTAssertEqual(resolve(day: "2026-09-28", apple: [reading("2026-03-28", 19)])?.source, .jurca)       // day 184
        XCTAssertEqual(resolve(day: "2026-09-28", apple: [reading("2026-09-29", 19)])?.source, .jurca)
        let newest = resolve(day: "2026-09-28", apple: [reading("2026-09-01", 25), reading("2026-09-20", 19)])
        XCTAssertEqual(newest?.sourceDay, "2026-09-20")
    }

    /// Losing fat leaves absolute uptake roughly where it was: a reading taken at 220 kg describes a
    /// 200 kg body as 10 % fitter per kilogram.
    func testAMeasurementIsRescaledToTodaysWeight() throws {
        let value = try XCTUnwrap(resolve(apple: [reading("2026-09-20", 19)], weights: ["2026-09-20": 220]))
        XCTAssertEqual(value.vo2max, 19 * 220 / 200, accuracy: 1e-9)
        XCTAssertEqual(value.measuredVO2max, 19)
        XCTAssertEqual(value.measuredWeightKg, 220)
        // Unknown weight at the time: taken as it stands, not rescaled against a guess.
        XCTAssertEqual(try XCTUnwrap(resolve(apple: [reading("2026-09-20", 19)])).vo2max, 19, accuracy: 1e-9)
    }

    func testBoundsDifferForAnEstimateAndAMeasurement() throws {
        let athlete = PeakMETResolver.ManualEntry(vo2max: 80, day: "2026-09-01", weightKg: nil)
        XCTAssertEqual(try XCTUnwrap(resolve(manual: athlete)).peakMET, 80 / 3.5, accuracy: 1e-9)
        let absurd = PeakMETResolver.ManualEntry(vo2max: 200, day: "2026-09-01", weightKg: nil)
        XCTAssertEqual(try XCTUnwrap(resolve(manual: absurd)).peakMET, 25)
        let jurca = try XCTUnwrap(resolve())
        XCTAssertTrue(PeakMETResolver.estimateRange.contains(jurca.peakMET))
        XCTAssertEqual(jurca.activityLevel, .level3)
    }

    /// The hint belongs to the formula outside its range, and to nothing else.
    func testMeasurementIsAdvisedOnlyForTheFormulaAboveItsBMIRange() {
        XCTAssertTrue(PeakMETResolver.measurementAdvised(source: .jurca, weightKg: 212, heightCm: 196))   // BMI 55
        XCTAssertFalse(PeakMETResolver.measurementAdvised(source: .jurca, weightKg: 150, heightCm: 196))  // BMI 39
        XCTAssertFalse(PeakMETResolver.measurementAdvised(source: .appleWatch, weightKg: 212, heightCm: 196))
        XCTAssertFalse(PeakMETResolver.measurementAdvised(source: .manual, weightKg: 212, heightCm: 196))
        XCTAssertFalse(PeakMETResolver.measurementAdvised(source: nil, weightKg: 212, heightCm: 196))
        XCTAssertFalse(PeakMETResolver.measurementAdvised(source: .jurca, weightKg: 212, heightCm: 0))
    }

    /// No measurement and no resting HR (the first nights): nothing, so the model prices from the table.
    func testWithoutRestingHeartRateThereIsNoEstimate() {
        XCTAssertNil(resolve(restingHR: nil))
        XCTAssertNil(resolve(level: nil))
    }
}
