import XCTest
@testable import StrandAnalytics

final class MuscleMetricTests: XCTestCase {
    func testBalanceExcludesWarmupsAndStabilizersAndReportsUnmappedWork() {
        let now = 2_000_000_000
        let sets = [
            set(session: "work", exercise: "press", ts: now - 60,
                stimulus: 1, primary: ["chest"], secondary: ["triceps"],
                stabilizers: ["serratus"]),
            set(session: "warmup", exercise: "press", ts: now - 120,
                warmup: true, stimulus: 10, primary: ["chest"]),
            set(session: "unknown", exercise: "custom", ts: now - 180,
                stimulus: 1, primary: [])
        ]

        let result = MuscleBalanceMetric.calculate(sets: sets, now: now)

        XCTAssertEqual(result.coverage.workingSetCount, 2)
        XCTAssertEqual(result.coverage.mappedSetCount, 1)
        XCTAssertEqual(result.readings.first(where: { $0.muscleId == "chest" })?.effectiveSets, 1)
        XCTAssertEqual(result.readings.first(where: { $0.muscleId == "triceps" })?.effectiveSets, 0.5)
        XCTAssertNil(result.readings.first(where: { $0.muscleId == "serratus" }))
        XCTAssertTrue(result.readings.allSatisfy { $0.state == .baselineGrowing })
    }

    func testBalanceUsesEightPriorCompleteWeeksAsPersonalDistribution() {
        let now = 2_000_000_000
        var sets = [set(session: "current", exercise: "press", ts: now - 86_400,
                        stimulus: 8, primary: ["chest"])]
        let currentStart = now - MuscleBalanceMetric.currentWindowDays * 86_400
        for week in 0..<MuscleBalanceMetric.baselineWeeks {
            let ts = currentStart - week * 7 * 86_400 - 86_400
            sets.append(set(session: "base-\(week)", exercise: "press", ts: ts,
                            stimulus: 1, primary: ["chest"]))
            sets.append(set(session: "base-leg-\(week)", exercise: "squat", ts: ts,
                            stimulus: 3, primary: ["quadriceps"]))
        }

        let baselineStart = currentStart - MuscleBalanceMetric.baselineWeeks * 7 * 86_400
        let result = MuscleBalanceMetric.calculate(
            sets: sets, now: now, historyAvailableFrom: baselineStart)

        XCTAssertTrue(result.hasPersonalBaseline)
        let chest = try! XCTUnwrap(result.readings.first { $0.muscleId == "chest" })
        XCTAssertEqual(chest.usualShare ?? 0, 0.25, accuracy: 0.0001)
        XCTAssertEqual(chest.state, .aboveUsual)
    }

    func testFatigueUsesDecayAndKeepsSecondaryAtHalfCredit() {
        let now = 2_000_000_000
        let tau = 48.0 * 3_600
        let result = MuscleFatigueMetric.calculate(
            sets: [set(session: "one", exercise: "press", ts: now - Int(tau),
                       stimulus: 2, primary: ["chest"], secondary: ["triceps"], rated: true)],
            now: now, tauByMuscle: ["chest": tau, "triceps": tau],
            personallyFittedMuscles: ["chest"])

        let chest = try! XCTUnwrap(result.readings.first { $0.muscleId == "chest" })
        let triceps = try! XCTUnwrap(result.readings.first { $0.muscleId == "triceps" })
        XCTAssertEqual(chest.residualStimulus, 2 * exp(-1), accuracy: 0.0001)
        XCTAssertEqual(triceps.residualStimulus, exp(-1), accuracy: 0.0001)
        XCTAssertTrue(chest.usesPersonalTau)
        XCTAssertFalse(triceps.usesPersonalTau)
        XCTAssertEqual(result.coverage.ratedSetCount, 1)
    }

    func testEvidenceCombinesSetsFromTheSameExerciseAndDoesNotDoubleCreditDuplicates() {
        let now = 2_000_000_000
        let duplicated = set(session: "one", exercise: "press", ts: now - 60,
                             stimulus: 1, primary: ["chest"], secondary: ["chest"])
        let result = MuscleBalanceMetric.calculate(sets: [duplicated, duplicated], now: now)
        let chest = try! XCTUnwrap(result.readings.first { $0.muscleId == "chest" })

        XCTAssertEqual(chest.effectiveSets, 2, accuracy: 0.0001)
        XCTAssertEqual(chest.evidence.count, 1)
        XCTAssertEqual(chest.evidence[0].value, 2, accuracy: 0.0001)
    }

    func testFatigueIgnoresNumericallyExhaustedHistory() {
        let now = 2_000_000_000
        let tau = 48.0 * 3_600
        let recent = set(session: "recent", exercise: "press", ts: now - 60,
                         stimulus: 1, primary: ["chest"])
        let expired = set(session: "expired", exercise: "press",
                          ts: now - 9 * 72 * 3_600, stimulus: 100, primary: ["chest"])
        let result = MuscleFatigueMetric.calculate(
            sets: [recent, expired], now: now, tauByMuscle: ["chest": tau])

        let chest = try! XCTUnwrap(result.readings.first { $0.muscleId == "chest" })
        XCTAssertEqual(chest.evidence.map(\.sessionId), ["recent"])
        XCTAssertEqual(result.coverage.workingSetCount, 1)
    }

    func testStrengthNormalizesDifferentExercisesBeforeCombiningMuscles() {
        let week = 7 * 86_400
        var sets: [MuscleMetricSet] = []
        for index in 0..<5 {
            sets.append(set(session: "press-\(index)", exercise: "press", ts: 1_900_000_000 + index * week,
                            stimulus: 1, e1rm: 100 + Double(index * 2), primary: ["chest"] ))
            sets.append(set(session: "fly-\(index)", exercise: "fly", ts: 1_900_000_000 + index * week,
                            stimulus: 1, e1rm: 10 + Double(index), primary: ["chest"] ))
        }

        let result = MuscleStrengthMetric.calculate(sets: sets)
        let chest = try! XCTUnwrap(result.readings.first { $0.muscleId == "chest" })

        XCTAssertEqual(chest.direction, .increasing)
        XCTAssertEqual(chest.exerciseEvidence.count, 2)
        XCTAssertNotNil(chest.normalizedSlopePerWeek)
        XCTAssertLessThan(chest.normalizedSlopePerWeek ?? 1, 0.2)
    }

    func testStrengthNeedsFourSessionPointsAndNeverUsesTimedWork() {
        let week = 7 * 86_400
        let sets = (0..<3).map { index in
            set(session: "row-\(index)", exercise: "row", ts: 1_900_000_000 + index * week,
                stimulus: 1, e1rm: 80 + Double(index), primary: ["upper_back"])
        } + [set(session: "plank", exercise: "plank", ts: 1_900_000_000,
                 stimulus: 1, e1rm: nil, primary: ["abdominals"])]

        let result = MuscleStrengthMetric.calculate(sets: sets)

        XCTAssertEqual(result.readings.first { $0.muscleId == "upper_back" }?.direction,
                       .insufficientEvidence)
        XCTAssertEqual(result.readings.first { $0.muscleId == "abdominals" }?.direction,
                       .insufficientEvidence)
        XCTAssertNil(result.readings.first { $0.muscleId == "abdominals" }?.normalizedSlopePerWeek)
    }

    func testStrengthTrendResistsOneExtremeOutlier() {
        let week = 7 * 86_400
        let values = [100.0, 102, 900, 106, 108]
        let sets = values.enumerated().map { index, value in
            set(session: "press-\(index)", exercise: "press",
                ts: 1_900_000_000 + index * week, stimulus: 1,
                e1rm: value, primary: ["chest"])
        }

        let result = MuscleStrengthMetric.calculate(sets: sets)
        let chest = try! XCTUnwrap(result.readings.first { $0.muscleId == "chest" })

        XCTAssertEqual(chest.direction, .increasing)
        XCTAssertLessThan(chest.normalizedSlopePerWeek ?? 1, 0.05)
    }

    private func set(session: String, exercise: String, ts: Int, warmup: Bool = false,
                     stimulus: Double, e1rm: Double? = nil, primary: [String],
                     secondary: [String] = [], stabilizers: [String] = [],
                     rated: Bool = false) -> MuscleMetricSet {
        .init(sessionId: session, sessionTitle: session, exerciseId: exercise,
              exerciseTitle: exercise, startTs: ts, isWarmup: warmup,
              rpeWasRecorded: rated, stimulus: stimulus, estimatedOneRepMaxKg: e1rm,
              primaryMuscleIds: primary, secondaryMuscleIds: secondary,
              stabilizerMuscleIds: stabilizers)
    }
}
