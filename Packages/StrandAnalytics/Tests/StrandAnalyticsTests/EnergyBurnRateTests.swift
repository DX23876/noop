import XCTest
@testable import StrandAnalytics

final class EnergyBurnRateTests: XCTestCase {

    private func slice(_ startMinutes: Double, _ durationMinutes: Double,
                       basal: Double, active: Double) -> EnergyBurnRate.Slice {
        .init(startSeconds: startMinutes * 60, durationSeconds: durationMinutes * 60,
              basalKcal: basal, activeKcal: active)
    }

    // MARK: - The measured day

    func testTheRateIsTotalEnergyPerMinuteOfTheSliceItCameFrom() {
        // A five-minute bucket holding 7.5 kcal is 1.5 kcal/min — basal and active together,
        // because the total printed above the chart is also both.
        let points = EnergyBurnRate.measured(slices: [slice(0, 5, basal: 6, active: 1.5)])
        XCTAssertEqual(points.count, 1)
        XCTAssertEqual(points[0].kcalPerMinute, 1.5, accuracy: 0.0001)
        XCTAssertEqual(points[0].startSeconds, 0)
        XCTAssertEqual(points[0].durationSeconds, 300)
    }

    func testABucketOfADifferentLengthIsPricedPerMinuteAllTheSame() {
        // Buckets are nominally 300 s but a day's last one is short. Reading kcal straight off the
        // bucket would draw that one as a dip that never happened.
        let points = EnergyBurnRate.measured(slices: [
            slice(0, 5, basal: 5, active: 5),      // 10 kcal / 5 min  = 2.0
            slice(5, 1, basal: 1, active: 1),      //  2 kcal / 1 min  = 2.0
        ])
        XCTAssertEqual(points.map(\.kcalPerMinute), [2.0, 2.0])
    }

    func testAnUnmeasuredStretchStaysAHoleRatherThanABasalLine() {
        // 09:00–12:00 off the wrist. Nothing may be synthesized to close the line: a drawn line
        // through unmeasured time is a claim about that time.
        let points = EnergyBurnRate.measured(slices: [
            slice(8 * 60, 5, basal: 6, active: 0),
            slice(12 * 60, 5, basal: 6, active: 0),
        ])
        XCTAssertEqual(points.count, 2)
        XCTAssertEqual(points[0].startSeconds, 8 * 3_600)
        XCTAssertEqual(points[1].startSeconds, 12 * 3_600)
    }

    func testPointsComeOutInTimeOrderAndRubbishIsDroppedNotZeroed() {
        let points = EnergyBurnRate.measured(slices: [
            slice(60, 5, basal: 6, active: 0),
            slice(0, 0, basal: 6, active: 1),                       // zero duration
            .init(startSeconds: -300, durationSeconds: 300, basalKcal: 1, activeKcal: 1),
            .init(startSeconds: 120 * 60, durationSeconds: 300,
                  basalKcal: .nan, activeKcal: 3),                  // NaN basal, real active
            slice(30, 5, basal: 6, active: 0),
        ])
        XCTAssertEqual(points.map(\.startSeconds), [30 * 60, 60 * 60, 120 * 60])
        // The NaN was treated as absent, not as a reason to drop a measured active figure.
        XCTAssertEqual(points[2].kcalPerMinute, 0.6, accuracy: 0.0001)
    }

    // MARK: - The reference curve

    private func day(_ name: String, hourly: Double) -> EnergyBurnRate.DayHours {
        .init(day: name, activeKcalByHour: Array(repeating: hourly, count: 24))
    }

    func testTheReferenceIsAMedianSoOneExtraordinaryDayCannotMoveIt() {
        // Four ordinary days and one marathon. A mean would report ~48 kcal/h; the median reports
        // the day this person actually has.
        let days = [day("d1", hourly: 10), day("d2", hourly: 10), day("d3", hourly: 12),
                    day("d4", hourly: 14), day("d5", hourly: 200)]
        let reference = EnergyBurnRate.reference(days: days, windowDays: 7, basalKcalPerDay: nil)
        XCTAssertNotNil(reference)
        XCTAssertEqual(reference?.points.count, 24)
        // Median of [10, 10, 12, 14, 200] is 12 kcal in the hour → 0.2 kcal/min.
        XCTAssertEqual(reference?.points[0].kcalPerMinute ?? 0, 12.0 / 60, accuracy: 0.0001)
    }

    func testBasalIsAddedAsAFlatSockelSoBothCurvesMeasureTheSameQuantity() {
        let reference = EnergyBurnRate.reference(days: [day("d1", hourly: 6), day("d2", hourly: 6),
                                                        day("d3", hourly: 6)],
                                                 windowDays: 7, basalKcalPerDay: 2_400)
        // 6 kcal active + 100 kcal basal in the hour = 106/60 kcal/min, in every hour.
        XCTAssertEqual(reference?.points.map(\.kcalPerMinute).min() ?? 0, 106.0 / 60, accuracy: 0.0001)
        XCTAssertEqual(reference?.points.map(\.kcalPerMinute).max() ?? 0, 106.0 / 60, accuracy: 0.0001)
    }

    func testTooFewDaysProducesNoCurveAtAllRatherThanAThinOne() {
        let two = [day("d1", hourly: 10), day("d2", hourly: 10)]
        XCTAssertNil(EnergyBurnRate.reference(days: two, windowDays: 7, basalKcalPerDay: nil))
        XCTAssertNotNil(EnergyBurnRate.reference(days: two + [day("d3", hourly: 10)],
                                                 windowDays: 7, basalKcalPerDay: nil))
    }

    func testTheCurveReportsHowManyDaysItActuallyHadAndHowManyWereAskedFor() {
        // "7d avg" built from 5 days must be able to say 5 — the count is what makes the label honest.
        let days = (1...5).map { day("d\($0)", hourly: 10) }
        let reference = EnergyBurnRate.reference(days: days, windowDays: 7, basalKcalPerDay: nil)
        XCTAssertEqual(reference?.sampleDays, 5)
        XCTAssertEqual(reference?.windowDays, 7)
    }

    func testAShortHourRowIsDroppedRatherThanPaddedWithIdleHours() {
        let broken = EnergyBurnRate.DayHours(day: "d4", activeKcalByHour: Array(repeating: 10, count: 20))
        let days = [day("d1", hourly: 10), day("d2", hourly: 10), broken]
        XCTAssertNil(EnergyBurnRate.reference(days: days, windowDays: 7, basalKcalPerDay: nil))
    }

    // MARK: - Which days may describe a norm

    func testADayQualifiesOnlyOnTheCurrentModelAndSolidCoverage() {
        let current = WhoopDailyEnergyEstimate.modelVersion
        let solid = Int(86_400 * EnergyEngine.solidCoverage)
        XCTAssertTrue(EnergyBurnRate.dayQualifies(modelVersion: current, representedSeconds: solid))
        XCTAssertTrue(EnergyBurnRate.dayQualifies(modelVersion: current, representedSeconds: 86_400))
        XCTAssertFalse(EnergyBurnRate.dayQualifies(modelVersion: current, representedSeconds: solid - 1))
        // An older model's kcal are not comparable with today's at all, however well covered.
        XCTAssertFalse(EnergyBurnRate.dayQualifies(modelVersion: "whoop-bucket-v1",
                                                   representedSeconds: 86_400))
    }

    // MARK: - Training vs the rest of the day

    private func window(_ startMinutes: Double, _ endMinutes: Double) -> EnergyBurnRate.Window {
        .init(startSeconds: startMinutes * 60, endSeconds: endMinutes * 60)
    }

    func testEnergyInsideASessionIsTrainingAndEverythingElseIsMovement() {
        let slices = [slice(0, 5, basal: 6, active: 2),        // before
                      slice(60, 5, basal: 6, active: 30),      // inside
                      slice(120, 5, basal: 6, active: 3)]      // after
        let split = EnergyBurnRate.activeSplit(slices: slices, training: [window(55, 70)])
        XCTAssertEqual(split.training, 30, accuracy: 0.0001)
        XCTAssertEqual(split.movement, 5, accuracy: 0.0001)
    }

    func testTheTwoHalvesAlwaysAddUpToActiveEnergy() {
        // The card prints both as percentages of the day's total; if they stopped summing to active,
        // the four figures on it would stop summing to the total.
        let slices = [slice(0, 5, basal: 6, active: 2), slice(58, 5, basal: 6, active: 40),
                      slice(63, 5, basal: 6, active: 25), slice(200, 5, basal: 6, active: 4)]
        let split = EnergyBurnRate.activeSplit(slices: slices, training: [window(60, 64)])
        XCTAssertEqual(split.training + split.movement, 71, accuracy: 0.0001)
    }

    func testASessionThatCoversPartOfABucketIsChargedThatPart() {
        // A five-minute bucket, two minutes of it inside the session: 40 % of its active energy.
        let split = EnergyBurnRate.activeSplit(slices: [slice(60, 5, basal: 6, active: 50)],
                                               training: [window(63, 65)])
        XCTAssertEqual(split.training, 20, accuracy: 0.0001)
        XCTAssertEqual(split.movement, 30, accuracy: 0.0001)
    }

    func testTwoOverlappingSessionsCannotChargeTheSameSecondsTwice() {
        // Cross-source dedup is not perfect, and a strap session with an imported twin must not
        // invent energy by covering the bucket 200 %.
        let split = EnergyBurnRate.activeSplit(
            slices: [slice(60, 5, basal: 6, active: 50)],
            training: [window(60, 65), window(61, 64), window(59, 66)])
        XCTAssertEqual(split.training, 50, accuracy: 0.0001)
        XCTAssertEqual(split.movement, 0, accuracy: 0.0001)
    }

    func testASessionRunningPastMidnightOnlyClaimsTheSecondsInsideTheDay() {
        // 23:40 to 00:20 the next day, clipped by the caller to the day edge: only the 20 minutes
        // before midnight belong to this day's training figure.
        let slices = [slice(23 * 60 + 40, 5, basal: 6, active: 10),
                      slice(23 * 60 + 55, 5, basal: 6, active: 10)]
        let split = EnergyBurnRate.activeSplit(slices: slices, training: [window(23 * 60 + 40, 24 * 60)])
        XCTAssertEqual(split.training, 20, accuracy: 0.0001)
        XCTAssertEqual(split.movement, 0, accuracy: 0.0001)
    }

    func testNoSessionsMeansEveryActiveKcalIsDailyMovement() {
        let slices = [slice(0, 5, basal: 6, active: 2), slice(60, 5, basal: 6, active: 8)]
        let split = EnergyBurnRate.activeSplit(slices: slices, training: [])
        XCTAssertEqual(split.training, 0)
        XCTAssertEqual(split.movement, 10, accuracy: 0.0001)
    }

    func testBasalEnergyIsNotMovedIntoTrainingByASession() {
        // Resting energy during a workout is still resting energy. Only `activeKcal` is split.
        let split = EnergyBurnRate.activeSplit(slices: [slice(60, 5, basal: 600, active: 10)],
                                               training: [window(60, 65)])
        XCTAssertEqual(split.training, 10, accuracy: 0.0001)
        XCTAssertEqual(split.movement, 0, accuracy: 0.0001)
    }
}
