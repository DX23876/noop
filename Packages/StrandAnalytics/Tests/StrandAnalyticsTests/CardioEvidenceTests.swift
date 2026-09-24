import XCTest
@testable import StrandAnalytics

/// Pins which VO₂max the screens show and what counts as cardio performance evidence.
final class CardioEvidenceTests: XCTestCase {
    private let today = "2026-09-24"

    private func reading(_ back: Int, _ value: Double, _ segment: String) -> VO2maxReading {
        VO2maxReading(day: WeeklyDigestEngine.addDays(today, -back), value: value, segment: segment)
    }

    /// Weekly Apple readings, the latest `latestBack` days ago.
    private func apple(latestBack: Int, count: Int = 6, step: Double = 0.6) -> [VO2maxReading] {
        (0..<count).map { index in
            reading(latestBack + (count - 1 - index) * 7, 40 + Double(index) * step, "apple-health")
        }
    }

    private func session(_ back: Int, avgHr: Int, sport: String = "Running",
                         modality: CardioModality = .foot) -> CardioSessionMetrics {
        let day = WeeklyDigestEngine.addDays(today, -back)
        let start = StrengthSession.daysBetween("1970-01-01", and: day) * 86_400 + 43_200
        // 50 minutes over 10 km: beats per km = 5 × average HR.
        return CardioSessionMetrics(startTs: start, endTs: start + 3_000, day: day, sport: sport,
                                    source: "apple-health", modality: modality, durationS: 3_000,
                                    distanceM: 10_000, avgHr: avgHr, maxHr: nil, energyKcal: nil,
                                    strain: nil, steps: nil)
    }

    /// Eight weekly runs whose average HR moves by `hrStep` per week, oldest first.
    private func runs(startHr: Int, hrStep: Int, sport: String = "Running") -> [CardioSessionMetrics] {
        (0..<8).map { index in session((7 - index) * 7 + 1, avgHr: startHr + index * hrStep, sport: sport) }
    }

    // MARK: - Display

    /// NOOP's estimate is the headline; an Apple reading from weeks ago stays visible with its date
    /// instead of passing as today's value.
    func testTheEstimateIsTheHeadlineAndAppleKeepsItsDate() {
        let estimates = [reading(10, 51, "uth"), reading(3, 52, "uth")]
        let display = CardioEvidence.display(estimates: estimates, apple: apple(latestBack: 35), through: today)
        XCTAssertEqual(display.primary?.value, 52)
        XCTAssertEqual(display.primary?.segment, "uth")
        XCTAssertEqual(display.appleLatest?.day, WeeklyDigestEngine.addDays(today, -35))
    }

    func testWithoutAnEstimateAppleIsTheHeadline() {
        let display = CardioEvidence.display(estimates: [], apple: apple(latestBack: 2), through: today)
        XCTAssertEqual(display.primary?.segment, "apple-health")
        XCTAssertNil(display.appleLatest)
    }

    // MARK: - Freshness

    func testAppleCountsOnlyWhileItIsWorn() {
        XCTAssertTrue(CardioEvidence.appleIsFresh(apple(latestBack: 10), through: today))
        XCTAssertTrue(CardioEvidence.appleIsFresh(apple(latestBack: 14), through: today))
        XCTAssertFalse(CardioEvidence.appleIsFresh(apple(latestBack: 15), through: today),
                       "a watch set aside two weeks ago no longer speaks for today")
        XCTAssertFalse(CardioEvidence.appleIsFresh(apple(latestBack: 2, count: 3), through: today),
                       "three readings are not a line")
    }

    // MARK: - The evidence chain

    func testFreshAppleIsTheEvidence() {
        let evidence = CardioEvidence.reading(apple: apple(latestBack: 3, step: 0.6),
                                              sessions: runs(startHr: 150, hrStep: 0), through: today)
        XCTAssertEqual(evidence.source, .appleVO2max)
        XCTAssertEqual(evidence.evidence, .rising)
    }

    /// With the watch set aside, the lane falls back to its own sessions rather than to a stale line.
    func testStaleAppleFallsBackToHeartRateEfficiency() {
        let evidence = CardioEvidence.reading(apple: apple(latestBack: 30, step: -0.6),
                                              sessions: runs(startHr: 150, hrStep: -2), through: today)
        XCTAssertEqual(evidence.source, .heartRateEfficiency)
        XCTAssertEqual(evidence.evidence, .rising, "fewer beats per kilometre is improving fitness")
        XCTAssertEqual(evidence.efficiency?.sport, "Running")
    }

    func testNothingUsableIsNoEvidence() {
        let evidence = CardioEvidence.reading(apple: [], sessions: [], through: today)
        XCTAssertEqual(evidence.source, .none)
        XCTAssertEqual(evidence.evidence, .none)
        XCTAssertEqual(TrainingStatusModel.cardiovascularAdaptation(evidence).state, .notEnoughData)
    }

    // MARK: - Heart-rate efficiency

    func testEfficiencyDirections() {
        XCTAssertEqual(CardioEvidence.heartRateEfficiency(runs(startHr: 150, hrStep: -2), through: today)?.direction,
                       .improving)
        XCTAssertEqual(CardioEvidence.heartRateEfficiency(runs(startHr: 140, hrStep: 2), through: today)?.direction,
                       .worsening)
    }

    /// Eight weeks drifting by under 3 % describe heat, hills and pace, not the athlete: a steady fall of
    /// one beat per minute across the whole window is 0.7 %.
    func testASmallDriftIsUnclear() {
        let drifting = (0..<8).map { index in session((7 - index) * 7 + 1, avgHr: index < 4 ? 150 : 149) }
        let efficiency = CardioEvidence.heartRateEfficiency(drifting, through: today)
        XCTAssertEqual(efficiency?.direction, .unclear)
        XCTAssertLessThan(abs(efficiency?.changePercent ?? 0), 3)
    }

    /// Only the main sport's exact label is read, and strength sessions never enter.
    func testOnlyTheMainEnduranceSportIsRead() {
        let running = runs(startHr: 150, hrStep: -2)
        let treadmill = (0..<3).map { session($0 * 7 + 2, avgHr: 175, sport: "Treadmill run") }
        let lifting = (0..<6).map { session($0 * 5 + 3, avgHr: 120, sport: "Strength", modality: .strength) }
        let efficiency = CardioEvidence.heartRateEfficiency(running + treadmill + lifting, through: today)
        XCTAssertEqual(efficiency?.sport, "Running")
        XCTAssertEqual(efficiency?.sessions, 8)
        XCTAssertEqual(efficiency?.direction, .improving)
    }

    func testTooFewSessionsHaveNoDirection() {
        let efficiency = CardioEvidence.heartRateEfficiency(Array(runs(startHr: 150, hrStep: -2).prefix(3)),
                                                            through: today)
        XCTAssertEqual(efficiency?.direction, .unknown)
        XCTAssertNil(CardioEvidence.heartRateEfficiency([], through: today))
    }
}
