import XCTest
@testable import StrandAnalytics
import WhoopProtocol

final class WorkoutEnergyEstimateTests: XCTestCase {
    private let profile = UserProfile(weightKg: 80, heightCm: 180, age: 30, sex: "male")

    private func resolve(recorded: Double? = nil, sport: String = "Strength Training",
                         seconds: Double = 4_620, avgHR: Int? = nil)
        -> WorkoutEnergyEstimate.Resolved? {
        WorkoutEnergyEstimate.resolve(recordedKcal: recorded, sport: sport, durationSeconds: seconds,
                                      averageHR: avgHR, profile: profile, hrMax: 190, restingHR: 55,
                                      peakMET: 10)
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

    func testTheTableCarriesASessionWithNoHeartRateAtAll() throws {
        // A Hevy import or a hand-entered bout: no samples, no average, still an hour of lifting. The
        // table MET is taken above the wearer's own basal rate, as the day model's table branch does,
        // not as a multiple of the 3.5 ml/kg/min population resting rate.
        let resolved = resolve(sport: "Strength", seconds: 3_600, avgHR: nil)
        XCTAssertEqual(resolved?.provenance, .metTable)
        let basal = try XCTUnwrap(Calories.bmrKcalPerDay(profile: profile)) / 24
        let active: Double = (ActivityMETCatalog.met(forSport: "Strength") - 1) * 3.5 * 80 / 200 * 60
        XCTAssertEqual(resolved?.kcal ?? 0, basal + active, accuracy: 0.001)
    }

    /// A walk with a measured distance is priced by its pace, whatever its heart rate was, on the curve
    /// the day model prices every walk with. Without a distance it falls back to heart rate.
    func testAWalkWithADistanceIsPricedByPace() throws {
        let walk = try XCTUnwrap(WorkoutEnergyEstimate.resolve(
            recordedKcal: nil, sport: "Walking", durationSeconds: 3_600, averageHR: 150,
            profile: profile, hrMax: 190, restingHR: 55, peakMET: 10, distanceM: 4_800))
        XCTAssertEqual(walk.provenance, .pace)
        let basal = try XCTUnwrap(Calories.bmrKcalPerDay(profile: profile)) / 24
        let active: Double = (WhoopEnergyModel.metForSpeed(4.8) - 1) * 3.5 * 80 / 200 * 60
        XCTAssertEqual(walk.kcal, basal + active, accuracy: 1e-6)
        let noDistance = WorkoutEnergyEstimate.resolve(
            recordedKcal: nil, sport: "Walking", durationSeconds: 3_600, averageHR: 150,
            profile: profile, hrMax: 190, restingHR: 55, peakMET: 10)
        XCTAssertEqual(noDistance?.provenance, .heartRate)
        // A distance no walk could have (GPS lost: 7 m in an hour) is a failed recording, not a pace.
        let lostGPS = WorkoutEnergyEstimate.resolve(
            recordedKcal: nil, sport: "Walking", durationSeconds: 3_600, averageHR: 150,
            profile: profile, hrMax: 190, restingHR: 55, peakMET: 10, distanceM: 7)
        XCTAssertEqual(lostGPS?.provenance, .heartRate)
        // Distance on a sport that is not on foot is not a pace.
        let ride = WorkoutEnergyEstimate.resolve(
            recordedKcal: nil, sport: "Indoor cycle", durationSeconds: 3_600, averageHR: 150,
            profile: profile, hrMax: 190, restingHR: 55, peakMET: 10, distanceM: 20_000)
        XCTAssertEqual(ride?.provenance, .heartRate)
    }

    func testTheActiveShareRemovesTheWindowsBasal() throws {
        let basal = try XCTUnwrap(Calories.bmrKcalPerDay(profile: profile)) / 24
        XCTAssertEqual(try XCTUnwrap(WorkoutEnergyEstimate.activeShare(
            grossKcal: 600, seconds: 3_600, profile: profile)), 600 - basal, accuracy: 1e-9)
        XCTAssertEqual(WorkoutEnergyEstimate.activeShare(grossKcal: 10, seconds: 3_600, profile: profile), 0)
        XCTAssertNil(WorkoutEnergyEstimate.activeShare(
            grossKcal: 600, seconds: 3_600, profile: UserProfile(weightKg: 0, heightCm: 180, age: 30)))
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
            profile: profile, hrMax: 190, restingHR: 60, peakMET: 10))
        XCTAssertEqual(resolved.provenance, .heartRate)
        let met = WhoopEnergyModel.exerciseMET(hr: 108, resting: 60, maximum: 190, kind: .resistance,
                                               peakMET: 10)
        let expected = try XCTUnwrap(Calories.bmrKcalPerDay(profile: profile)) / 86_400 * seconds
            + WhoopEnergyModel.activeKcal(met: met, seconds: seconds, weightKg: 80)
        XCTAssertEqual(resolved.kcal, expected, accuracy: 1e-6)
        let keytel = try XCTUnwrap(Calories.estimateBoutCalories(
            averageHR: 108, durationSeconds: seconds, profile: profile, hrmax: 190, restingHR: 60))
        XCTAssertLessThan(resolved.kcal, keytel)

        // An endurance session takes the same curve with the full reserve share.
        let run = try XCTUnwrap(WorkoutEnergyEstimate.resolve(
            recordedKcal: nil, sport: "Running", durationSeconds: 3_600, averageHR: 150,
            profile: profile, hrMax: 190, restingHR: 60, peakMET: 10))
        let runMET = WhoopEnergyModel.exerciseMET(hr: 150, resting: 60, maximum: 190, kind: .endurance,
                                                  peakMET: 10)
        let runBasal = try XCTUnwrap(Calories.bmrKcalPerDay(profile: profile)) / 24
        XCTAssertEqual(run.kcal, runBasal + WhoopEnergyModel.activeKcal(met: runMET, seconds: 3_600,
                                                                       weightKg: 80), accuracy: 1e-6)
    }

    /// The resistance curve is scaled to the ceiling the day's bucket model used. With none known the
    /// session takes its table MET rather than a ceiling nobody measured.
    func testALiftingSessionFollowsTheDaysCeilingAndTakesTheTableWithoutOne() throws {
        func kcal(_ peak: Double?) -> Double? {
            WorkoutEnergyEstimate.resolve(
                recordedKcal: nil, sport: "Strength Training", durationSeconds: 3_600, averageHR: 120,
                profile: profile, hrMax: 190, restingHR: 60, peakMET: peak)?.kcal
        }
        XCTAssertLessThan(try XCTUnwrap(kcal(6)), try XCTUnwrap(kcal(12)))
        XCTAssertEqual(WorkoutEnergyEstimate.resolve(
            recordedKcal: nil, sport: "Strength Training", durationSeconds: 3_600, averageHR: 120,
            profile: profile, hrMax: 190, restingHR: 60)?.provenance, .metTable)
        XCTAssertLessThan(try XCTUnwrap(kcal(nil)), try XCTUnwrap(Calories.estimateBoutCalories(
            averageHR: 120, durationSeconds: 3_600, profile: profile, hrmax: 190, restingHR: 60)))
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
            profile: profile, hrMax: 190, restingHR: 60, strapKcal: nil, peakMET: 10)?.provenance, .heartRate)
        XCTAssertEqual(WorkoutEnergyEstimate.resolve(
            recordedKcal: nil, sport: "Strength Training", durationSeconds: 5_400, averageHR: 108,
            profile: profile, hrMax: 190, restingHR: 60, strapKcal: 0, peakMET: 10)?.provenance, .heartRate)
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


final class LegacyWorkoutEnergyTests: XCTestCase {
    private let heavy = UserProfile(weightKg: 212, heightCm: 196, age: 35, sex: "male",
                                    basalFormula: .mifflinStJeor)
    private let walk = (0..<8_040).map { HRSample(ts: $0, bpm: 130 + ($0 / 600) % 40) }

    /// The reported walk: 3,471 kcal stored, and Keytel on the same trace lands beside it.
    func testAKeytelFigureIsRecognisedAndATypedOneIsNot() {
        let keytel = Calories.estimateBoutCalories(walk, profile: heavy, hrmax: 195, restingHR: 63).0
        XCTAssertTrue(LegacyWorkoutEnergy.looksComputed(stored: keytel * 1.1, samples: walk,
                                                        sport: "Walking", profile: heavy,
                                                        hrMax: 195, restingHR: 63))
        XCTAssertFalse(LegacyWorkoutEnergy.looksComputed(stored: 900, samples: walk, sport: "Walking",
                                                         profile: heavy, hrMax: 195, restingHR: 63))
        XCTAssertFalse(LegacyWorkoutEnergy.looksComputed(stored: keytel, samples: [], sport: "Walking",
                                                         profile: heavy, hrMax: 195, restingHR: 63))
    }

    func testLiveGpsSummaryCanRecogniseAStoredKeytelFigureWhenOffloadDiffers() {
        let live = Calories.estimateBoutCalories(averageHR: 147, durationSeconds: 7_794,
                                                profile: heavy, hrmax: 195, restingHR: 58)!
        XCTAssertTrue(LegacyWorkoutEnergy.looksComputed(stored: 2_784, averageHR: 147,
                                                        durationSeconds: 7_794, profile: heavy,
                                                        hrMax: 195, restingHR: 58))
        XCTAssertEqual(live, 2_784, accuracy: 700)
        XCTAssertFalse(LegacyWorkoutEnergy.looksComputed(stored: 900, averageHR: 147,
                                                         durationSeconds: 7_794, profile: heavy,
                                                         hrMax: 195, restingHR: 58))
    }

    /// A lifting session saved under v7 was priced on the resistance curve, not Keytel.
    func testAV7LiftingFigureIsRecognised() throws {
        let lift = (0..<3_600).map { HRSample(ts: $0, bpm: $0 % 180 < 60 ? 125 : 100) }
        let candidates = LegacyWorkoutEnergy.candidates(lift, sport: "Strength Training", profile: heavy,
                                                        hrMax: 195, restingHR: 63)
        XCTAssertEqual(candidates.count, 2)
        XCTAssertTrue(LegacyWorkoutEnergy.looksComputed(stored: candidates[1], samples: lift,
                                                        sport: "Strength Training", profile: heavy,
                                                        hrMax: 195, restingHR: 63))
    }
}
