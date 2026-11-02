import XCTest
@testable import StrandAnalytics

final class CycleTrainingPatternTests: XCTestCase {

    private typealias P = CycleTrainingPattern

    /// Day key `offset` days after 2026-01-01.
    private func day(_ offset: Int) -> String {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        let d = c.date(byAdding: .day, value: offset, to: c.date(from: DateComponents(year: 2026, month: 1, day: 1))!)!
        let comps = c.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", comps.year!, comps.month!, comps.day!)
    }

    /// `n` 28-day cycles with the rise on cycle day 15.
    private func cycles(_ n: Int, shift: Bool = true) -> [P.Cycle] {
        (0..<n).map { P.Cycle(start: day($0 * 28), shift: shift ? day($0 * 28 + 14) : nil) }
    }

    /// Two sessions per phase per cycle: follicular on days 7 and 10, luteal on days 19 and 23.
    private func sessions(cycles n: Int, follicularRPE: Double, lutealRPE: Double,
                          follicularKg: Double = 10_000, lutealKg: Double = 10_000) -> [P.Session] {
        (0..<n).flatMap { c -> [P.Session] in
            let base = c * 28
            return [P.Session(day: day(base + 6), rpe: follicularRPE, volumeKg: follicularKg, kind: "Legs"),
                    P.Session(day: day(base + 9), rpe: follicularRPE, volumeKg: follicularKg, kind: "Legs"),
                    P.Session(day: day(base + 18), rpe: lutealRPE, volumeKg: lutealKg, kind: "Legs"),
                    P.Session(day: day(base + 22), rpe: lutealRPE, volumeKg: lutealKg, kind: "Legs")]
        }
    }

    func testPhaseOfDay() {
        let cs = cycles(2)
        XCTAssertEqual(P.phase(of: day(0), cycles: cs), .period)
        XCTAssertEqual(P.phase(of: day(4), cycles: cs), .period)
        XCTAssertEqual(P.phase(of: day(8), cycles: cs), .follicular)
        XCTAssertNil(P.phase(of: day(14), cycles: cs), "the days around the rise belong to neither half")
        XCTAssertEqual(P.phase(of: day(20), cycles: cs), .luteal)
        XCTAssertEqual(P.phase(of: day(28), cycles: cs), .period, "the next logged start begins a new cycle")
        XCTAssertNil(P.phase(of: day(-1), cycles: cs))
    }

    func testCycleWithoutRiseIsNotGuessed() {
        let cs = cycles(1, shift: false)
        XCTAssertEqual(P.phase(of: day(2), cycles: cs), .period)
        XCTAssertNil(P.phase(of: day(20), cycles: cs))
    }

    func testLearningUntilThreeCycles() {
        let r = P.analyse(sessions: sessions(cycles: 2, follicularRPE: 6, lutealRPE: 8), cycles: cycles(2))
        XCTAssertEqual(r.cyclesUsed, 2)
        XCTAssertEqual(r.verdict(for: .luteal), .learning)
    }

    func testHarderLutealFromRPE() {
        let r = P.analyse(sessions: sessions(cycles: 3, follicularRPE: 6, lutealRPE: 7.5), cycles: cycles(3))
        XCTAssertEqual(r.cyclesUsed, 3)
        guard case .harder(let delta, _) = r.verdict(for: .luteal) else { return XCTFail("expected harder") }
        XCTAssertEqual(delta ?? 0, 1.5, accuracy: 1e-9)
        guard case .easier = r.verdict(for: .follicular) else { return XCTFail("the other half reads easier") }
    }

    func testHarderLutealFromVolumeAlone() {
        let r = P.analyse(sessions: sessions(cycles: 3, follicularRPE: 7, lutealRPE: 7, lutealKg: 8_500), cycles: cycles(3))
        guard case .harder(let delta, let drop) = r.verdict(for: .luteal) else { return XCTFail("expected harder") }
        XCTAssertEqual(delta ?? 1, 0, accuracy: 1e-9)
        XCTAssertGreaterThan(drop ?? 0, 0.10)
    }

    func testNoDifference() {
        let r = P.analyse(sessions: sessions(cycles: 4, follicularRPE: 7, lutealRPE: 7.3), cycles: cycles(4))
        XCTAssertEqual(r.verdict(for: .luteal), .noDifference)
    }

    func testRecoversMultipleInjectedDifferences() {
        // The method tracks the size of the input, not one lucky match.
        for (luteal, expectHarder) in [(6.2, false), (6.8, true), (8.0, true), (5.0, false)] {
            let r = P.analyse(sessions: sessions(cycles: 3, follicularRPE: 6, lutealRPE: luteal), cycles: cycles(3))
            if case .harder(let d, _) = r.verdict(for: .luteal) {
                XCTAssertTrue(expectHarder, "luteal \(luteal)")
                XCTAssertEqual(d ?? 0, luteal - 6, accuracy: 1e-9)
            } else {
                XCTAssertFalse(expectHarder, "luteal \(luteal)")
            }
        }
    }
}
