import XCTest
@testable import StrandAnalytics

final class WhoopEnergyModelTests: XCTestCase {
    private let profile = UserProfile(weightKg: 80, heightCm: 180, age: 35, sex: "male")

    func testEvidenceSecondsAndEnergyArePartitionedWithoutDoubleCounting() throws {
        let rows = [
            WhoopEnergyBucket(start: 0, averageHR: 145, isWorkout: true),
            WhoopEnergyBucket(start: 300, steps: 500, distanceM: 420),
            WhoopEnergyBucket(start: 600),
            WhoopEnergyBucket(start: 900, averageHR: 130, isOffWrist: true),
        ]
        let value = try XCTUnwrap(WhoopEnergyModel.estimate(
            buckets: rows, profile: profile, restingHR: 55, maxHR: 185))
        XCTAssertEqual(value.observedSeconds, 300)
        XCTAssertEqual(value.inferredSeconds, 300)
        XCTAssertEqual(value.modeledSeconds, 600)
        XCTAssertEqual(value.buckets.count, 4)
        XCTAssertEqual(value.totalKcal, value.buckets.reduce(0) { $0 + $1.kcal }, accuracy: 0.001)
        XCTAssertEqual(value.coverageFraction, 0.25, accuracy: 0.001)
    }

    func testSleepAndOffWristNeverUseElevatedHR() throws {
        let sleeping = WhoopEnergyBucket(start: 0, averageHR: 180, isSleep: true)
        let ordinary = WhoopEnergyBucket(start: 300, averageHR: 180, isWorkout: true)
        let result = try XCTUnwrap(WhoopEnergyModel.estimate(
            buckets: [sleeping, ordinary], profile: profile, restingHR: 55, maxHR: 185))
        XCTAssertEqual(result.buckets[0].evidence, .modeled)
        XCTAssertEqual(result.buckets[1].evidence, .observed)
        XCTAssertGreaterThan(result.buckets[1].kcal, result.buckets[0].kcal)
    }

    // MARK: - MET curve unification (two independently-tuned tables disagreeing by up to 2.7 MET)

    /// Isolates the pure movement path: no `averageHR`, so evidence is `.inferred` and the whole
    /// figure comes from `movementMET`. Subtracts the bucket's own basal share to read the MET curve
    /// back out of the reported kcal.
    private func inferredActive(_ bucket: WhoopEnergyBucket, seconds: Int = 300) throws -> Double {
        let result = try XCTUnwrap(WhoopEnergyModel.estimate(
            buckets: [bucket], profile: profile, restingHR: 55, maxHR: 185))
        XCTAssertEqual(result.buckets[0].evidence, .inferred)
        let basal = try XCTUnwrap(Calories.bmrKcalPerDay(profile: profile)) / 86_400 * Double(seconds)
        return result.totalKcal - basal
    }

    /// The regression this fix exists for: 130 steps/min sits at ~5.85 km/h (assuming the 0.75 m
    /// population-average stride), which the Compendium curve puts at ~4.5 MET — the OLD cadence
    /// table said 7.0, the OLD distance table said 4.3 for the same real pace. Pinned as a concrete
    /// margin under the old value, not just "still positive".
    func testCadenceOneThirtyIsNoLongerReadAsSevenMET() throws {
        let active = try inferredActive(.init(start: 0, steps: 650))   // 650/5min = 130/min
        let oldValueAtMET7 = (7.0 - 1) * 3.5 * profile.weightKg / 200 * 5   // 42.0 kcal
        XCTAssertLessThan(active, oldValueAtMET7 * 0.7,
                          "130 steps/min must no longer cost anywhere near the old 7.0-MET reading")
        XCTAssertEqual(active, 24.6, accuracy: 1.5)
    }

    /// The actual defect: cadence and GPS distance are two ways of measuring the SAME thing (speed),
    /// and used to disagree by up to 2.7 MET at equal pace because each had its own hand-tuned table.
    /// Constructing a cadence bucket and a distance bucket for the identical implied speed must now
    /// yield the identical energy — the direct proof the two branches share one curve.
    func testCadenceAndDistanceAgreeAtTheSameImpliedSpeed() throws {
        // 130 steps/min @ 0.75 m stride == 5.85 km/h == 487.5 m over a 5-minute bucket.
        let byCadence = try inferredActive(.init(start: 0, steps: 650))
        let byDistance = try inferredActive(.init(start: 0, distanceM: 487.5))
        XCTAssertEqual(byCadence, byDistance, accuracy: 0.05)
    }

    /// The piecewise curve must be monotonic across its whole span, not just at the four points the
    /// old tables happened to define — walking through running, spanning every table breakpoint.
    func testSpeedToEnergyIsMonotonicAcrossTheWholeCurve() throws {
        let speedsKmh: [Double] = [1, 2, 3.5, 4.5, 5.5, 6.5, 7.5, 9, 11, 13, 15, 17]
        let values = try speedsKmh.map { kmh -> Double in
            try inferredActive(.init(start: 0, distanceM: kmh * 300 / 3.6))
        }
        for (a, b) in zip(values, values.dropFirst()) {
            XCTAssertLessThan(a, b, "energy must strictly increase with speed across the whole table")
        }
    }

    /// Above the table's fastest reference point (16.1 km/h, elite 10-mph running), the curve now
    /// clamps at the Compendium's own 14.5 MET rather than the old hand-picked ceiling of 12 — an
    /// intended change (elite-pace running is genuinely undercounted at 12), pinned explicitly.
    func testVeryHighSpeedClampsAtTheCompendiumCeilingNotTheOldOne() throws {
        let active = try inferredActive(.init(start: 0, distanceM: 20 * 300 / 3.6))   // 20 km/h
        let oldCeilingActive = (12.0 - 1) * 3.5 * profile.weightKg / 200 * 5   // 77.0 kcal
        XCTAssertGreaterThan(active, oldCeilingActive,
                             "elite-pace running must cost more than the old 12-MET cap allowed")
        XCTAssertEqual(active, 94.5, accuracy: 1.5)
    }

    // MARK: - Movement corroboration (the "walk was worth exactly zero" defect)

    /// The regression this whole change exists for. A half-hour walk sits near 37% HR reserve, which
    /// is BELOW the 50% gate both energy paths used, so it produced no active energy at all. Pinned
    /// as a real margin over the same bucket without a movement signal, not merely "> 0".
    func testWalkAtLowHrReserveIsNoLongerWorthZeroActiveEnergy() throws {
        // ~37% reserve: 55 + 0.37 * (185 - 55) ≈ 103 bpm.
        let hrOnly = WhoopEnergyBucket(start: 0, averageHR: 103)
        // The same bucket, with the strap ALSO reporting a walking cadence (~110 steps/min).
        let walking = WhoopEnergyBucket(start: 0, averageHR: 103, steps: 550, activityClass: 1)

        let flat = try XCTUnwrap(WhoopEnergyModel.estimate(
            buckets: [hrOnly], profile: profile, restingHR: 55, maxHR: 185))
        let corroborated = try XCTUnwrap(WhoopEnergyModel.estimate(
            buckets: [walking], profile: profile, restingHR: 55, maxHR: 185))

        // Both saw a heart rate, so both stay `.observed` — movement corroborates, never substitutes.
        XCTAssertEqual(flat.buckets[0].evidence, .observed)
        XCTAssertEqual(corroborated.buckets[0].evidence, .observed)

        let basal = try XCTUnwrap(Calories.bmrKcalPerDay(profile: profile)) / 86_400 * 300
        let flatActive = flat.totalKcal - basal
        let walkActive = corroborated.totalKcal - basal
        // The HR-only reading is the old, near-invisible number; corroborated walking is worth
        // multiples of it. A 5-minute brisk walk at ~4 MET on an 80 kg adult is ~21 kcal above rest.
        XCTAssertGreaterThan(walkActive, flatActive * 2)
        XCTAssertEqual(walkActive, 21, accuracy: 6)
    }

    /// "Prove the method tracks a varying input" (CLAUDE.md). Four separated intensities must come
    /// back strictly ordered — one matching value would prove nothing.
    func testRecoversMultipleInjectedIntensitiesMonotonically() throws {
        func active(_ bucket: WhoopEnergyBucket) throws -> Double {
            let value = try XCTUnwrap(WhoopEnergyModel.estimate(
                buckets: [bucket], profile: profile, restingHR: 55, maxHR: 185))
            return value.totalKcal - (try XCTUnwrap(Calories.bmrKcalPerDay(profile: profile)) / 86_400 * 300)
        }
        let still = try active(.init(start: 0, averageHR: 60))
        let strolling = try active(.init(start: 0, averageHR: 92, steps: 320, activityClass: 1))
        let brisk = try active(.init(start: 0, averageHR: 110, steps: 600, distanceM: 480, activityClass: 1))
        let running = try active(.init(start: 0, averageHR: 155, steps: 850, distanceM: 1_100,
                                       activityClass: 2, isWorkout: true))

        XCTAssertLessThan(still, strolling)
        XCTAssertLessThan(strolling, brisk)
        XCTAssertLessThan(brisk, running)
        // And the spread is physiological, not a rounding wobble: a run outruns a stroll several-fold.
        XCTAssertGreaterThan(running, strolling * 3)
    }

    /// `max(hrMET, movementMET)` must never REDUCE a high-HR bucket that happens to have a quiet
    /// wrist — cycling and lifting are exactly that shape, and a `min`/average would under-report them.
    func testHighHeartRateWithQuietWristKeepsTheHeartRateCurve() throws {
        let cycling = WhoopEnergyBucket(start: 0, averageHR: 160, motionIntensity: 0.04,
                                        isWorkout: true)
        let bare = WhoopEnergyBucket(start: 0, averageHR: 160, isWorkout: true)
        let withMotion = try XCTUnwrap(WhoopEnergyModel.estimate(
            buckets: [cycling], profile: profile, restingHR: 55, maxHR: 185))
        let without = try XCTUnwrap(WhoopEnergyModel.estimate(
            buckets: [bare], profile: profile, restingHR: 55, maxHR: 185))
        XCTAssertEqual(withMotion.totalKcal, without.totalKcal, accuracy: 0.001)
    }

    /// The guard that keeps the change conservative: `movementMET` floors at 1.5, so calling it for a
    /// bucket with NO movement signal would invent half a MET on every still, awake, measured second.
    func testStillMeasuredBucketGainsNothingFromTheMovementPath() throws {
        let resting = WhoopEnergyBucket(start: 0, averageHR: 58, motionIntensity: 0.0,
                                        activityClass: 0)
        let value = try XCTUnwrap(WhoopEnergyModel.estimate(
            buckets: [resting], profile: profile, restingHR: 55, maxHR: 185))
        let basal = try XCTUnwrap(Calories.bmrKcalPerDay(profile: profile)) / 86_400 * 300
        // At 2% reserve the HR curve gives ~1.05 MET; the 1.5-MET movement floor must not apply.
        XCTAssertEqual(value.totalKcal - basal, 0, accuracy: 1.0)
    }

    /// The strap's own class raises a floor but must not overrule a FASTER reading from distance —
    /// a run misreported as a walk keeps the run's energy.
    func testActivityClassRaisesAFloorWithoutCappingAFasterSignal() throws {
        let mislabelled = WhoopEnergyBucket(start: 0, averageHR: 150, steps: 900,
                                            distanceM: 1_200, activityClass: 1)
        let value = try XCTUnwrap(WhoopEnergyModel.estimate(
            buckets: [mislabelled], profile: profile, restingHR: 55, maxHR: 185))
        let basal = try XCTUnwrap(Calories.bmrKcalPerDay(profile: profile)) / 86_400 * 300
        // 1.2 km in 5 min = 14.4 km/h → far above the 3.0-MET walk floor.
        XCTAssertGreaterThan(value.totalKcal - basal, 60)
    }

    /// Guards the invalidation contract: `Repository.energySummaries` filters `whoopDailyEnergy` rows
    /// to this exact string, so a silent revert would resurrect pre-movement-corroboration (v1) rows
    /// into a chart that should only ever show one model generation at a time.
    func testModelVersionIsTheMovementCorroborationGeneration() {
        XCTAssertEqual(WhoopDailyEnergyEstimate.modelVersion, "whoop-bucket-v3")
    }

    func testInvalidBucketsAndProfileDoNotInventEnergy() {
        XCTAssertNil(WhoopEnergyModel.estimate(
            buckets: [.init(start: 0)],
            profile: .init(weightKg: 0, heightCm: 0, age: 0), restingHR: nil, maxHR: nil))
        XCTAssertNil(WhoopEnergyModel.estimate(
            buckets: [.init(start: 0, durationSeconds: 0)],
            profile: profile, restingHR: nil, maxHR: nil))
    }

    func testCausalWeightNeverReadsFutureAndManualWinsSameDay() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let day = 2_000_000_000
        let observations = [
            CausalWeightObservation(timestamp: day, weightKg: 80, source: .health),
            CausalWeightObservation(timestamp: day + 60, weightKg: 79, source: .manual),
            CausalWeightObservation(timestamp: day + 86_400, weightKg: 60, source: .manual),
        ]
        let sameDay = CausalWeightResolver.weight(
            at: day + 3_600, observations: observations, calendar: calendar)
        XCTAssertEqual(try XCTUnwrap(sameDay), 79, accuracy: 0.001)
    }

    func testCausalWeightExpiresAfterNinetyDays() {
        let row = CausalWeightObservation(timestamp: 1_000_000, weightKg: 80, source: .manual)
        XCTAssertNil(CausalWeightResolver.weight(
            at: 1_000_000 + 91 * 86_400, observations: [row]))
    }
}
