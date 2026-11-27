import XCTest
@testable import StrandAnalytics
import WhoopProtocol

/// The restless-movement term of `SleepStagerV2` (#59): sustained small movements argue against REM, a calm
/// night stages exactly as without the term, and the memo cache keeps the two apart. That the term is the one
/// scored against sleep-lab truth is pinned separately, label for label, by `Tools/SleepPSG`'s port tests.
final class SleepStagerRestlessTermTests: XCTestCase {

    private let start = 1_749_517_200

    // MARK: - fixtures

    /// Gravity with a constant tiny jitter every second, so the night's quiescent jerk floor is that jitter (a
    /// perfectly still stream has a zero floor, against which every jerk would count). Inside `restless` every
    /// second carries small movement: 11 × the floor, so restless, yet far under the 38 × at which an epoch
    /// counts as moving and the 55 × that opens the wake gate.
    private func gravity(durationS: Int, restless: Range<Int>? = nil) -> [GravitySample] {
        (0..<durationS).map { i -> GravitySample in
            var x = i % 2 == 0 ? 0.001 : -0.001
            if let r = restless, r.contains(i) { x += i % 2 == 0 ? 0.01 : -0.01 }
            return GravitySample(ts: start + i, x: x, y: 0, z: 1.0)
        }
    }

    /// Flat heart rate, except a swinging stretch inside `rem` (raised and variable, the REM signature).
    private func heartRate(durationS: Int, rem: Range<Int>) -> [HRSample] {
        (0..<durationS).map { i -> HRSample in
            guard rem.contains(i) else { return HRSample(ts: start + i, bpm: 52) }
            return HRSample(ts: start + i, bpm: 60 + Int(7.0 * sin(2.0 * Double.pi * Double(i) / 40.0)))
        }
    }

    private func minutes(_ stage: String, _ segs: [StageSegment], in window: Range<Int>) -> Double {
        let lo = start + window.lowerBound, hi = start + window.upperBound
        return segs.filter { $0.stage == stage && $0.end > lo && $0.start < hi }
            .reduce(0.0) { $0 + Double(min($1.end, hi) - max($1.start, lo)) } / 60.0
    }

    private let hour = 3600
    /// The REM-looking hour, two to three hours into a six-hour night.
    private var remStretch: Range<Int> { (2 * hour)..<(3 * hour) }
    /// Fifteen restless minutes inside it.
    private var restlessBlock: Range<Int> { (2 * hour + 20 * 60)..<(2 * hour + 35 * 60) }

    // MARK: - counting

    /// Only runs of five seconds or more count, a trailing run included: a REM twitch lasts 3 s or less.
    func testOnlyRunsLongerThanATwitchCount() {
        let thr = 1.0
        let jerks: [Double] = [2, 2, 2, 2, 2, 2, 0, 2, 2, 2, 2, 0, 0, 2, 2, 2, 2, 2]
        XCTAssertEqual(SleepStagerV2.restlessRunSeconds(jerks, above: thr), 6 + 5)
        XCTAssertEqual(SleepStagerV2.restlessRunSeconds([2, 2, 2, 2, 0, 2, 2, 2, 2], above: thr), 0)
        XCTAssertEqual(SleepStagerV2.restlessRunSeconds([], above: thr), 0)
    }

    // MARK: - staging

    /// A calm night has no restless seconds, so the term adds nothing and every label stays where it was.
    func testACalmNightStagesIdenticallyWithTheTerm() {
        let dur = 6 * hour
        let grav = gravity(durationS: dur)
        let hr = heartRate(durationS: dur, rem: remStretch)
        let without = SleepStagerV2.stageSession(start: start, end: start + dur, grav: grav, hr: hr, rr: [], resp: [])
        let with = SleepStagerV2.stageSession(start: start, end: start + dur, grav: grav, hr: hr, rr: [], resp: [],
                                              restless: .remOnly)
        XCTAssertEqual(with, without)
        XCTAssertGreaterThan(minutes("rem", without, in: remStretch), 20,
                             "the fixture must stage REM in its swinging stretch, or the next test proves nothing")
    }

    /// Sustained small movements inside a REM stretch take REM away there. The REM-only form never argues for
    /// wake, so the wake on this night does not grow.
    func testSustainedRestlessnessTakesREMAwayWithoutAddingWake() {
        let dur = 6 * hour
        let grav = gravity(durationS: dur, restless: restlessBlock)
        let hr = heartRate(durationS: dur, rem: remStretch)
        let without = SleepStagerV2.stageSession(start: start, end: start + dur, grav: grav, hr: hr, rr: [], resp: [])
        let with = SleepStagerV2.stageSession(start: start, end: start + dur, grav: grav, hr: hr, rr: [], resp: [],
                                              restless: .remOnly)
        let remBefore = minutes("rem", without, in: restlessBlock), remAfter = minutes("rem", with, in: restlessBlock)
        XCTAssertGreaterThan(remBefore, 10, "the fixture must stage REM before the term is applied")
        XCTAssertLessThan(remAfter, remBefore - 5, "REM \(remBefore) → \(remAfter) min")
        XCTAssertLessThanOrEqual(minutes("wake", with, in: 0..<dur), minutes("wake", without, in: 0..<dur))
    }

    /// The memo cache keys on the term: a night staged without it, then with it, then without it again gets
    /// three honest answers, not the first one three times.
    func testTheCacheKeepsTheTermApart() {
        let dur = 6 * hour
        let grav = gravity(durationS: dur, restless: restlessBlock)
        let hr = heartRate(durationS: dur, rem: remStretch)
        func stage(_ term: SleepStagerV2.RestlessTerm?) -> [StageSegment] {
            SleepStagerV2.stageSession(start: start, end: start + dur, grav: grav, hr: hr, rr: [], resp: [],
                                       restless: term)
        }
        let first = stage(nil)
        let with = stage(.remOnly)
        let again = stage(nil)
        XCTAssertNotEqual(with, first, "a call with the term was answered from the call without it")
        XCTAssertEqual(again, first)
    }
}
