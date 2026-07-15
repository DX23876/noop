import XCTest
@testable import StrandAnalytics
import WhoopProtocol

/// Pins `WakeMotionRefinement` (#364 "Proposal 2" follow-up; density-gate precedent #345) against
/// SYNTHETIC fixtures only — no real user data. Every fixture is built from `buildNight`, which lays down
/// a dense, still, non-ambulatory baseline (4 gravity samples/min at one fixed orientation, 1 step record/
/// min with a flat counter and `activityClass = 0`) and overrides specific minutes to inject either a
/// posture "burst" (a turn-over) or real walking cadence. Apple twin of the Android
/// `WakeMotionRefinementTest`.
final class WakeMotionRefinementTests: XCTestCase {

    /// Minute-aligned so every assertion below can reason in whole minutes.
    private let start = 1_700_000_000 / 60 * 60

    // MARK: - Fixture builder

    /// One night's gravity + step streams over minutes `[0, totalMinutes)` relative to `start`.
    /// - `burstMinutes`: these minutes get a gravity vector that swings between two orientations
    ///   within the minute (posture variance well above `stablePostureVarianceG2`); every other minute
    ///   is a fixed, motionless orientation (variance 0).
    /// - `walkMinutes`: these minutes accrue `ticksPerWalkMinute` walk-class (`activityClass = 1`)
    ///   step-counter ticks; every other minute accrues 0 ticks at `activityClass = 0` (still).
    /// - `sparse`: when true, mimics a WHOOP 4.0 night instead — gravity only every 5th minute, no step
    ///   samples at all — so the density self-gate declines regardless of the burst/walk pattern.
    private func buildNight(totalMinutes: Int, burstMinutes: Set<Int> = [], walkMinutes: Set<Int> = [],
                            ticksPerWalkMinute: Int = 25,
                            sparse: Bool = false) -> (grav: [GravitySample], steps: [StepSample]) {
        var grav: [GravitySample] = []
        var steps: [StepSample] = []
        var counter = 0
        for m in 0..<totalMinutes {
            let minuteStart = start + m * 60
            if sparse {
                if m % 5 == 0 { grav.append(GravitySample(ts: minuteStart, x: 0, y: 0, z: 1.0)) }
                continue   // no step samples at all on the sparse fixture
            }
            if burstMinutes.contains(m) {
                for k in 0..<4 {
                    let swing = k % 2 == 0
                    grav.append(GravitySample(ts: minuteStart + k * 15, x: swing ? 0 : 1.0, y: 0, z: swing ? 1.0 : 0))
                }
            } else {
                for k in 0..<4 {
                    grav.append(GravitySample(ts: minuteStart + k * 15, x: 0, y: 0, z: 1.0))
                }
            }
            let walking = walkMinutes.contains(m)
            counter += walking ? ticksPerWalkMinute : 0
            steps.append(StepSample(ts: minuteStart, counter: counter & 0xFFFF, activityClass: walking ? 1 : 0))
        }
        return (grav, steps)
    }

    private func wakeSegment(minutes: Int) -> StageSegment {
        StageSegment(start: start, end: start + minutes * 60, stage: "wake")
    }

    // MARK: (a) hot-but-still night, one turn-over burst every 90 min -> the still spans are reclaimed

    func testHotButStillNightReclaimsTheStillSpansAroundIsolatedBursts() {
        let seg = wakeSegment(minutes: 180)
        let (grav, steps) = buildNight(totalMinutes: 180, burstMinutes: [45, 135])

        let result = WakeMotionRefinement.refine([seg], grav: grav, steps: steps)

        let expected: [StageSegment] = [
            StageSegment(start: start, end: start + 44 * 60, stage: "light"),
            StageSegment(start: start + 44 * 60, end: start + 47 * 60, stage: "wake"),
            StageSegment(start: start + 47 * 60, end: start + 134 * 60, stage: "light"),
            StageSegment(start: start + 134 * 60, end: start + 137 * 60, stage: "wake"),
            StageSegment(start: start + 137 * 60, end: start + 180 * 60, stage: "light"),
        ]
        XCTAssertEqual(result, expected,
            "only the two burst minutes (+/-1 min pad) should survive as wake; the motionless stretches "
            + "between them (the hot-but-atonic REM misread) should reclaim to light")

        let totalDuration = result.reduce(0) { $0 + ($1.end - $1.start) }
        XCTAssertEqual(totalDuration, 180 * 60, "the refinement must never change total session duration")
        let wakeDuration = result.filter { $0.stage == "wake" }.reduce(0) { $0 + ($1.end - $1.start) }
        XCTAssertEqual(wakeDuration, 6 * 60, "wake should shrink from 180 min to the 2 burst blocks (3 min each)")
    }

    // MARK: (b) a real get-up (3 consecutive minutes of 25 ticks/min) stays wake

    func testRealGetUpStaysWake() {
        let seg = wakeSegment(minutes: 30)
        let (grav, steps) = buildNight(totalMinutes: 30, walkMinutes: [10, 11, 12], ticksPerWalkMinute: 25)

        let result = WakeMotionRefinement.refine([seg], grav: grav, steps: steps)

        XCTAssertEqual(result, [seg],
            "3 consecutive minutes at 25 ticks/min clears the sustained-walk locomotion gate (>=2 "
            + "consecutive minutes >=10 ticks), so the whole segment must be left untouched")
    }

    // MARK: (c) sparse-motion night -> the density self-gate declines to act

    func testSparseMotionNightDeclinesToAct() {
        let seg = wakeSegment(minutes: 180)
        // Same burst pattern as the dense test above (which DOES reclassify) so the only variable here
        // is density -- proving the decline is the gate, not the burst pattern being ineligible.
        let (grav, steps) = buildNight(totalMinutes: 180, burstMinutes: [45, 135], sparse: true)

        let result = WakeMotionRefinement.refine([seg], grav: grav, steps: steps)

        XCTAssertEqual(result, [seg],
            "a WHOOP-4.0-shaped stream (sparse gravity, no step samples) must fail the density self-gate "
            + "and leave the incumbent wake call untouched, per #345")
    }

    // MARK: (d) toggle off -> byte-identical output

    func testToggleOffIsByteIdenticalPassthrough() {
        let seg = wakeSegment(minutes: 180)
        let (grav, steps) = buildNight(totalMinutes: 180, burstMinutes: [45, 135])

        let off = WakeMotionRefinement.apply([seg], grav: grav, steps: steps, enabled: false)
        XCTAssertEqual(off, [seg], "enabled=false must be a guaranteed byte-identical passthrough")

        // Sanity: the SAME fixture actually changes when enabled, so the assertion above isn't vacuous.
        let on = WakeMotionRefinement.apply([seg], grav: grav, steps: steps, enabled: true)
        XCTAssertNotEqual(on, [seg], "fixture sanity check: this fixture must be live when enabled")
    }

    // MARK: (e) tracks VARYING inputs -- multiple patterns, each with a different injected reclaim
    // amount, each recovered (repo hard rule for a derived physiological signal: prove the method tracks
    // varying input, not a single lucky match).

    func testRecoversDifferentInjectedReclaimAmountsAcrossPatterns() {
        struct Scenario { let name: String; let totalMinutes: Int; let burstMinutes: Set<Int> }
        let scenarios: [Scenario] = [
            Scenario(name: "single burst", totalMinutes: 40, burstMinutes: [20]),
            Scenario(name: "two well-separated bursts", totalMinutes: 120, burstMinutes: [20, 80]),
            Scenario(name: "three well-separated bursts", totalMinutes: 90, burstMinutes: [10, 40, 70]),
            Scenario(name: "two adjacent bursts (padding overlaps)", totalMinutes: 60, burstMinutes: [5, 6]),
            Scenario(name: "burst at the segment's own edge (padding clamps)", totalMinutes: 50, burstMinutes: [0, 49]),
        ]

        for s in scenarios {
            let seg = wakeSegment(minutes: s.totalMinutes)
            let (grav, steps) = buildNight(totalMinutes: s.totalMinutes, burstMinutes: s.burstMinutes)
            let result = WakeMotionRefinement.refine([seg], grav: grav, steps: steps)

            // Expected kept-as-wake minutes = union of each burst minute +/-1, clamped to the segment.
            var expectedKept: Set<Int> = []
            for m in s.burstMinutes {
                let lo = max(0, m - 1), hi = min(s.totalMinutes - 1, m + 1)
                if lo <= hi { expectedKept.formUnion(lo...hi) }
            }
            let expectedReclaimedMin = s.totalMinutes - expectedKept.count

            let totalDuration = result.reduce(0) { $0 + ($1.end - $1.start) }
            XCTAssertEqual(totalDuration, s.totalMinutes * 60, "[\(s.name)] duration must be conserved")

            let actualWakeMin = result.filter { $0.stage == "wake" }.reduce(0) { $0 + ($1.end - $1.start) } / 60
            let actualReclaimedMin = s.totalMinutes - actualWakeMin
            XCTAssertEqual(actualReclaimedMin, expectedReclaimedMin,
                "[\(s.name)] expected \(expectedReclaimedMin) min reclaimed to light, got \(actualReclaimedMin)")

            // Every distinct injected pattern above yields a DIFFERENT reclaim amount -- this loop only
            // proves the method tracks varying input if that's actually true of the fixtures.
        }

        // Belt-and-suspenders on the point of the test: the scenarios really do inject different amounts.
        let distinctReclaimAmounts = Set(scenarios.map { s -> Int in
            var kept: Set<Int> = []
            for m in s.burstMinutes {
                let lo = max(0, m - 1), hi = min(s.totalMinutes - 1, m + 1)
                if lo <= hi { kept.formUnion(lo...hi) }
            }
            return s.totalMinutes - kept.count
        })
        XCTAssertGreaterThan(distinctReclaimAmounts.count, 1,
            "fixture sanity: scenarios must inject genuinely different reclaim amounts")
    }

    // MARK: - Session-level convenience (efficiency recompute)

    func testSessionLevelRefineRecomputesEfficiency() {
        let session = SleepSession(start: start, end: start + 180 * 60, efficiency: 0.0,
                                   stages: [wakeSegment(minutes: 180)], restingHR: 52, avgHRV: 40.0)
        let (grav, steps) = buildNight(totalMinutes: 180, burstMinutes: [45, 135])

        let refined = WakeMotionRefinement.refine(session, grav: grav, steps: steps)

        XCTAssertGreaterThan(refined.efficiency, session.efficiency,
            "reclassifying 174 of 180 wake minutes to light must raise efficiency")
        XCTAssertEqual(refined.efficiency, SleepStager.efficiency(start: session.start, end: session.end,
                                                                  stages: refined.stages),
            "efficiency must be recomputed from the REFINED stages, not left stale")
        XCTAssertEqual(refined.restingHR, session.restingHR, "restingHR is stage-independent, must be carried over")
        XCTAssertEqual(refined.avgHRV, session.avgHRV, "avgHRV is stage-independent, must be carried over")
    }
}
