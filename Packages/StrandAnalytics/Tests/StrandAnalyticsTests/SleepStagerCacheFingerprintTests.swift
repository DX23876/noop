import XCTest
@testable import StrandAnalytics
import WhoopProtocol

/// Regression coverage for gravity streams that have identical per-sample axis sums but different motion.
final class SleepStagerCacheFingerprintTests: XCTestCase {
    /// 2025-06-10 00:00:00 UTC, shared with the existing native stager fixtures.
    private let base = 1_749_513_600

    private func gravity(start: Int, duration: Int, flippingAxes: Bool) -> [GravitySample] {
        (0..<duration).map { i in
            if flippingAxes && i.isMultiple(of: 2) {
                return GravitySample(ts: start + i, x: 1, y: 0, z: 0)
            }
            return GravitySample(ts: start + i, x: 0, y: 0, z: 1)
        }
    }

    private func heartRate(start: Int, duration: Int) -> [HRSample] {
        (0..<duration).map { HRSample(ts: start + $0, bpm: 50 + (($0 / 60) % 3)) }
    }

    private func rr(start: Int, duration: Int) -> [RRInterval] {
        let wave = [0, 40, 0, -40]
        return (0..<duration).map { RRInterval(ts: start + $0, rrMs: 1_000 + wave[$0 % wave.count]) }
    }

    private func shifted(_ samples: [GravitySample], by delta: Int) -> [GravitySample] {
        samples.map { GravitySample(ts: $0.ts + delta, x: $0.x, y: $0.y, z: $0.z) }
    }

    private func shifted(_ samples: [HRSample], by delta: Int) -> [HRSample] {
        samples.map { HRSample(ts: $0.ts + delta, bpm: $0.bpm) }
    }

    private func shape(_ segments: [StageSegment], relativeTo start: Int) -> [String] {
        segments.map { "\($0.start - start):\($0.end - start):\($0.stage)" }
    }

    func testDetectSleepSameSumAxesDoNotAliasMemo() {
        let start = base + 2 * 3_600
        let duration = 90 * 60
        let still = gravity(start: start, duration: duration, flippingAxes: false)
        let moving = gravity(start: start, duration: duration, flippingAxes: true)
        let hr = heartRate(start: start, duration: duration)

        // A trace sink bypasses detectSleep's memo and supplies real-path controls.
        let controlA = SleepStager.detectSleep(hr: hr, gravity: still, traceSink: { _ in })
        let controlB = SleepStager.detectSleep(hr: hr, gravity: moving, traceSink: { _ in })
        XCTAssertFalse(controlA.isEmpty, "control A must be a detected still night")
        XCTAssertTrue(controlB.isEmpty, "control B must be motion, not sleep")

        let cachedA = SleepStager.detectSleep(hr: hr, gravity: still)
        let cachedB = SleepStager.detectSleep(hr: hr, gravity: moving)
        let cachedAAgain = SleepStager.detectSleep(hr: hr, gravity: still)
        XCTAssertEqual(cachedA, controlA)
        XCTAssertEqual(cachedB, controlB, "same-sum axis changes must invalidate the detect memo")
        XCTAssertEqual(cachedAAgain, controlA, "A→B→A must not poison the original cache entry")
    }

    func testV1StageSameSumAxesDoNotAliasMemo() {
        let start = base + 100_000
        let duration = 20 * 60
        let still = gravity(start: start, duration: duration, flippingAxes: false)
        let moving = gravity(start: start, duration: duration, flippingAxes: true)
        let hr = heartRate(start: start, duration: duration)
        let controlShift = 200_000

        // Shifted windows create uncached controls without adding a production reset hook.
        let controlA = SleepStager.stageSession(
            start: start + controlShift, end: start + controlShift + duration,
            grav: shifted(still, by: controlShift), hr: shifted(hr, by: controlShift), rr: [], resp: [])
        let controlB = SleepStager.stageSession(
            start: start + 2 * controlShift, end: start + 2 * controlShift + duration,
            grav: shifted(moving, by: 2 * controlShift), hr: shifted(hr, by: 2 * controlShift), rr: [], resp: [])
        XCTAssertNotEqual(shape(controlA, relativeTo: start + controlShift),
                          shape(controlB, relativeTo: start + 2 * controlShift),
                          "controls must exercise observably different staging")

        let a = SleepStager.stageSession(start: start, end: start + duration,
                                         grav: still, hr: hr, rr: [], resp: [])
        let b = SleepStager.stageSession(start: start, end: start + duration,
                                         grav: moving, hr: hr, rr: [], resp: [])
        let aAgain = SleepStager.stageSession(start: start, end: start + duration,
                                              grav: still, hr: hr, rr: [], resp: [])
        XCTAssertEqual(shape(a, relativeTo: start), shape(controlA, relativeTo: start + controlShift))
        XCTAssertEqual(shape(b, relativeTo: start), shape(controlB, relativeTo: start + 2 * controlShift),
                       "same-sum axis changes must invalidate the V1 stage memo")
        XCTAssertEqual(shape(aAgain, relativeTo: start), shape(controlA, relativeTo: start + controlShift))
    }

    func testV2StageSameSumAxesDoNotAliasMemo() {
        let start = base + 1_000_000
        let duration = 30 * 60
        let still = gravity(start: start, duration: duration, flippingAxes: false)
        let moving = (0..<duration).map { i in
            i % 30 == 15
                ? GravitySample(ts: start + i, x: 1, y: 1, z: -1)
                : GravitySample(ts: start + i, x: 0, y: 0, z: 1)
        }
        let hr = heartRate(start: start, duration: duration)
        let beats = rr(start: start, duration: duration)
        var stillControl = still
        stillControl.insert(still[0], at: 1)
        var movingControl = moving
        movingControl.insert(moving[0], at: 1)
        movingControl.insert(moving[0], at: 2)

        // Duplicate identical rows change the old key's count without changing per-second inputs.
        let controlA = SleepStagerV2.stageSession(
            start: start, end: start + duration, grav: stillControl, hr: hr, rr: beats, resp: [])
        let controlB = SleepStagerV2.stageSession(
            start: start, end: start + duration, grav: movingControl, hr: hr, rr: beats, resp: [])
        XCTAssertNotEqual(shape(controlA, relativeTo: start), shape(controlB, relativeTo: start),
                          "controls must exercise observably different staging")

        let a = SleepStagerV2.stageSession(start: start, end: start + duration,
                                           grav: still, hr: hr, rr: beats, resp: [])
        let b = SleepStagerV2.stageSession(start: start, end: start + duration,
                                           grav: moving, hr: hr, rr: beats, resp: [])
        let aAgain = SleepStagerV2.stageSession(start: start, end: start + duration,
                                                grav: still, hr: hr, rr: beats, resp: [])
        XCTAssertEqual(shape(a, relativeTo: start), shape(controlA, relativeTo: start))
        XCTAssertEqual(shape(b, relativeTo: start), shape(controlB, relativeTo: start),
                       "same-sum axis changes must invalidate the V2 stage memo")
        XCTAssertEqual(shape(aAgain, relativeTo: start), shape(controlA, relativeTo: start))
    }
}
