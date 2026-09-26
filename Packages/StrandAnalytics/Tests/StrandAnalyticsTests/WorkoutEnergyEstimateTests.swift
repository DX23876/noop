import XCTest
@testable import StrandAnalytics

final class WorkoutEnergyEstimateTests: XCTestCase {
    private let profile = UserProfile(weightKg: 80, heightCm: 180, age: 30, sex: "male")

    private func resolve(recorded: Double? = nil, sport: String = "Strength Training",
                         seconds: Double = 4_620, avgHR: Int? = nil)
        -> WorkoutEnergyEstimate.Resolved? {
        WorkoutEnergyEstimate.resolve(recordedKcal: recorded, sport: sport, durationSeconds: seconds,
                                      averageHR: avgHR, profile: profile, hrMax: 190, restingHR: 55)
    }

    func testARecordedFigureWinsAndIsNotMarkedAsAnEstimate() {
        let resolved = resolve(recorded: 512, avgHR: 103)
        XCTAssertEqual(resolved?.kcal, 512)
        XCTAssertEqual(resolved?.provenance, .recorded)
        XCTAssertEqual(resolved?.isEstimated, false)
    }

    func testAnAverageHeartRateBeatsTheTable() {
        // The reported session: 1 h 17 m at 103 bpm, nothing recorded. Heart rate is evidence about
        // the person who did it; the table is an average over everyone who ever did the activity.
        let resolved = resolve(avgHR: 103)
        XCTAssertEqual(resolved?.provenance, .heartRate)
        XCTAssertEqual(resolved?.isEstimated, true)
        XCTAssertGreaterThan(resolved?.kcal ?? 0, 0)

        let table = resolve()
        XCTAssertEqual(table?.provenance, .metTable)
        XCTAssertNotEqual(resolved?.kcal, table?.kcal, "the two branches must not coincide by accident")
    }

    func testTheTableCarriesASessionWithNoHeartRateAtAll() {
        // A Hevy import or a hand-entered bout: no samples, no average, still an hour of lifting.
        let resolved = resolve(sport: "Strength", seconds: 3_600, avgHR: nil)
        XCTAssertEqual(resolved?.provenance, .metTable)
        XCTAssertEqual(resolved?.kcal ?? 0,
                       ActivityMETCatalog.grossKcal(sport: "Strength", seconds: 3_600, weightKg: 80) ?? 0,
                       accuracy: 0.001)
    }

    func testAZeroHeartRateIsNotEvidenceAndFallsThrough() {
        XCTAssertEqual(resolve(avgHR: 0)?.provenance, .metTable)
    }

    func testARecordedZeroIsNotARecording() {
        // Several importers write 0 rather than omitting the field. Treating that as "measured, and
        // it cost nothing" is how a lifting session ends up reading as free.
        XCTAssertEqual(resolve(recorded: 0, avgHR: 103)?.provenance, .heartRate)
    }

    func testASessionNobodyCanPriceIsNilRatherThanZero() {
        XCTAssertNil(resolve(seconds: 0, avgHR: 103))
        XCTAssertNil(WorkoutEnergyEstimate.resolve(
            recordedKcal: nil, sport: "Strength", durationSeconds: 3_600, averageHR: nil,
            profile: UserProfile(weightKg: 0, heightCm: 180, age: 30, sex: "male"),
            hrMax: nil, restingHR: nil))
    }

    func testAnUnknownSportStillCostsSomething() {
        // Free text is allowed everywhere a sport is entered, and an unrecognised name must not make
        // the session free — `ActivityMETCatalog` has a deliberately conservative default for it.
        let resolved = resolve(sport: "Underwater basket weaving", seconds: 3_600)
        XCTAssertEqual(resolved?.provenance, .metTable)
        XCTAssertGreaterThan(resolved?.kcal ?? 0, 0)
    }

    /// Without strap coverage a lifting session's average heart rate is priced on the strap model's
    /// resistance curve plus basal — not Keytel, which reads the pressor response as oxygen uptake.
    func testALiftingSessionsHeartRateIsPricedOnTheResistanceCurve() throws {
        let seconds = 5_400.0
        let resolved = try XCTUnwrap(WorkoutEnergyEstimate.resolve(
            recordedKcal: nil, sport: "Strength Training", durationSeconds: seconds, averageHR: 108,
            profile: profile, hrMax: 190, restingHR: 60))
        XCTAssertEqual(resolved.provenance, .heartRate)
        let met = WhoopEnergyModel.exerciseMET(hr: 108, resting: 60, maximum: 190, kind: .resistance)
        let expected = try XCTUnwrap(Calories.bmrKcalPerDay(profile: profile)) / 86_400 * seconds
            + WhoopEnergyModel.activeKcal(met: met, seconds: seconds, weightKg: 80)
        XCTAssertEqual(resolved.kcal, expected, accuracy: 1e-6)
        let keytel = try XCTUnwrap(Calories.estimateBoutCalories(
            averageHR: 108, durationSeconds: seconds, profile: profile, hrmax: 190, restingHR: 60))
        XCTAssertLessThan(resolved.kcal, keytel)

        // An endurance session keeps Keytel.
        let run = try XCTUnwrap(WorkoutEnergyEstimate.resolve(
            recordedKcal: nil, sport: "Running", durationSeconds: 3_600, averageHR: 150,
            profile: profile, hrMax: 190, restingHR: 60))
        XCTAssertEqual(run.kcal, Calories.estimateBoutCalories(
            averageHR: 150, durationSeconds: 3_600, profile: profile, hrmax: 190, restingHR: 60) ?? 0,
            accuracy: 1e-6)
    }

    // MARK: - Strap model over the session window

    private func bucket(_ start: Int, basal: Double = 7, active: Double = 10,
                        context: EnergyContext? = .confirmedWorkout) -> WorkoutEnergyEstimate.StrapBucket {
        .init(start: start, durationSeconds: 300, basalKcal: basal, activeKcal: active, context: context)
    }

    func testTheStrapModelOutranksTheAverageHeartRateButNotARecording() {
        let withStrap = WorkoutEnergyEstimate.resolve(
            recordedKcal: nil, sport: "Strength Training", durationSeconds: 5_400, averageHR: 108,
            profile: profile, hrMax: 190, restingHR: 60, strapKcal: 306)
        XCTAssertEqual(withStrap?.provenance, .strapModel)
        XCTAssertEqual(withStrap?.kcal, 306)
        XCTAssertEqual(withStrap?.isEstimated, true)

        let recorded = WorkoutEnergyEstimate.resolve(
            recordedKcal: 512, sport: "Strength Training", durationSeconds: 5_400, averageHR: 108,
            profile: profile, hrMax: 190, restingHR: 60, strapKcal: 306)
        XCTAssertEqual(recorded?.provenance, .recorded)

        // No strap answer: the heart-rate branch is reached exactly as before.
        XCTAssertEqual(WorkoutEnergyEstimate.resolve(
            recordedKcal: nil, sport: "Strength Training", durationSeconds: 5_400, averageHR: 108,
            profile: profile, hrMax: 190, restingHR: 60, strapKcal: nil)?.provenance, .heartRate)
        XCTAssertEqual(WorkoutEnergyEstimate.resolve(
            recordedKcal: nil, sport: "Strength Training", durationSeconds: 5_400, averageHR: 108,
            profile: profile, hrMax: 190, restingHR: 60, strapKcal: 0)?.provenance, .heartRate)
    }

    func testTheWindowSumsBasalAndActiveOfTheBucketsInsideIt() throws {
        // 30 min = six whole buckets inside the window, one bucket either side outside it.
        let buckets = (-1...6).map { bucket($0 * 300) }
        let kcal = try XCTUnwrap(WorkoutEnergyEstimate.strapWindowKcal(
            buckets: buckets, startTs: 0, endTs: 1_800))
        XCTAssertEqual(kcal, 6 * 17, accuracy: 1e-9)
    }

    func testAPartialBucketIsProratedByItsOverlap() throws {
        let kcal = try XCTUnwrap(WorkoutEnergyEstimate.strapWindowKcal(
            buckets: [bucket(0), bucket(300)], startTs: 150, endTs: 600))
        XCTAssertEqual(kcal, 17 * 0.5 + 17, accuracy: 1e-9)
    }

    func testCalibrationScalesActiveEnergyOnly() throws {
        let kcal = try XCTUnwrap(WorkoutEnergyEstimate.strapWindowKcal(
            buckets: [bucket(0)], startTs: 0, endTs: 300, activeFactor: 1.5))
        XCTAssertEqual(kcal, 7 + 15, accuracy: 1e-9)
    }

    func testBucketsPricedBeforeTheSessionExistedDoNotAnswerForIt() {
        // The reported case: the model ran while the session was invisible to it and charged the
        // lifting as elevated heart rate with no activity. Summing that would present the stale
        // zero-active answer as the strap's verdict on the workout.
        let stale = (0..<18).map { bucket($0 * 300, active: 0, context: .unresolvedElevatedHR) }
        XCTAssertNil(WorkoutEnergyEstimate.strapWindowKcal(buckets: stale, startTs: 0, endTs: 5_400))
    }

    func testAWindowTheStrapBarelyCoveredDoesNotAnswer() {
        // 3 of 6 buckets: half the session unseen.
        XCTAssertNil(WorkoutEnergyEstimate.strapWindowKcal(
            buckets: (0..<3).map { bucket($0 * 300) }, startTs: 0, endTs: 1_800))
        // Off-wrist time is modelled basal, not strap evidence, and does not count as coverage.
        let offWrist = (0..<6).map { bucket($0 * 300, active: 0, context: $0 < 3 ? .offWrist : .confirmedWorkout) }
        XCTAssertNil(WorkoutEnergyEstimate.strapWindowKcal(buckets: offWrist, startTs: 0, endTs: 1_800))
    }

    func testAShortGapIsChargedAtTheCoveredRate() throws {
        // 5 of 6 buckets present (83 % coverage): the missing five minutes cost what the rest did.
        let kcal = try XCTUnwrap(WorkoutEnergyEstimate.strapWindowKcal(
            buckets: [0, 1, 2, 4, 5].map { bucket($0 * 300) }, startTs: 0, endTs: 1_800))
        XCTAssertEqual(kcal, 6 * 17, accuracy: 1e-9)
    }

    func testAnEmptyOrInvertedWindowIsNil() {
        XCTAssertNil(WorkoutEnergyEstimate.strapWindowKcal(buckets: [], startTs: 0, endTs: 1_800))
        XCTAssertNil(WorkoutEnergyEstimate.strapWindowKcal(buckets: [bucket(0)], startTs: 300, endTs: 300))
        XCTAssertNil(WorkoutEnergyEstimate.strapWindowKcal(buckets: [bucket(0)], startTs: 0, endTs: 300,
                                                           activeFactor: .nan))
    }
}

