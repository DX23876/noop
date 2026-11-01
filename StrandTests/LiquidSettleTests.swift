import XCTest
@testable import Strand

/// Pins the idle stand-down that keeps the liquid Today cheap. Adopted from gdorgian/noop (d50c5c566).
///
/// `LiquidVessel` / `LiquidTube` pause their `TimelineView` once `LiquidSim.settled` goes true. That is
/// the whole optimization: before it, three Canvas fluid sims held 60fps on the main thread forever and
/// Today felt heavy to scroll. The risk it carries is not a crash — it is silence in either direction:
///
///   • if the sim stops settling (a raised energy floor, a nudge that fires sooner, a damping change),
///     the clock never stands down and the cost quietly comes back with nothing to see;
///   • if it settles too eagerly, a gauge freezes mid-pour and looks broken.
///
/// Neither shows up in a build, so they are pinned here instead. The sim is pure value maths in a
/// reference type — no Canvas, no timer, no device — so stepping it by hand is the real thing.
final class LiquidSettleTests: XCTestCase {

    /// One frame at the hero vessels' 60fps clock.
    private let dt = 1.0 / 60.0

    /// Step `sim` forward with a still phone until it settles, up to `limit` seconds.
    /// Returns the time it took, or nil if it never came to rest.
    @discardableResult
    private func timeToSettle(_ sim: LiquidSim, target: Double, limit: Double = 30) -> Double? {
        var t = 0.0
        while t < limit {
            t += dt
            sim.step(now: t, tilt: 0, target: target)
            if sim.settled { return t }
        }
        return nil
    }

    // MARK: - It settles at all

    /// The load-bearing assertion. `energy` decays exponentially but is floored at 0.025 while motion is
    /// allowed, and a random `nudge` re-injects velocity every 3.5–8.5s — so "does it ever satisfy
    /// `settled`?" is a genuine question about the interaction of three constants, not a formality.
    func testAStillVesselComesToRest() throws {
        let sim = LiquidSim(target: 0)
        let settled = try XCTUnwrap(timeToSettle(sim, target: 0.72),
                                    "never settled — the clock would run at 60fps forever")
        // Generous ceiling: the point is that it rests, not exactly when. It has to outlast at least one
        // nudge window (up to 8.5s) to prove a nudge doesn't keep it awake indefinitely.
        XCTAssertLessThan(settled, 20)
    }

    /// Settling must not mean "gave up before arriving" — the fill has to actually reach the value the
    /// caller asked for, or a paused gauge is showing the wrong number.
    func testItRestsAtTheRequestedFillNotShortOfIt() throws {
        for target in [0.0, 0.15, 0.5, 0.93, 1.0] {
            let sim = LiquidSim(target: 0)
            XCTAssertNotNil(timeToSettle(sim, target: target), "target \(target) never settled")
            XCTAssertEqual(sim.level, target, accuracy: 0.001,
                           "settled at \(sim.level) but was asked for \(target)")
        }
    }

    /// A vessel is built with `energy = 0.5`, so it must NOT report settled on its first frames — that
    /// is the pour-in animation, and pausing through it would freeze the gauge mid-fill.
    func testItDoesNotSettleDuringThePourIn() {
        let sim = LiquidSim(target: 0)
        var t = 0.0
        for _ in 0..<12 {                    // ~200ms
            t += dt
            sim.step(now: t, tilt: 0, target: 0.8)
            XCTAssertFalse(sim.settled, "settled \(t)s in, while still filling")
        }
    }

    // MARK: - Everything that must wake it again

    /// A tap splashes. That has to break the rest state, or the tap would look ignored.
    func testASplashUnsettlesARestingVessel() throws {
        let sim = LiquidSim(target: 0)
        XCTAssertNotNil(timeToSettle(sim, target: 0.5))
        sim.splash(12)
        XCTAssertFalse(sim.settled, "a splash left the sim settled — the tap would render nothing")
    }

    /// A new value has to break it too. The view also clears its pause flag on `value` changing, but the
    /// sim must agree: if it still reported settled, it would stand down again on the very next frame and
    /// the fill would jump instead of flowing.
    func testANewTargetUnsettlesARestingVessel() throws {
        let sim = LiquidSim(target: 0)
        XCTAssertNotNil(timeToSettle(sim, target: 0.30))
        var t = 100.0
        t += dt
        sim.step(now: t, tilt: 0, target: 0.85)
        XCTAssertFalse(sim.settled, "a 0.30 → 0.85 change left the sim settled — the fill would jump")
    }

    /// Tilting the phone has to break it. This is the case the view cannot see on its own — a paused
    /// vessel runs no clock, which is why `LiquidWake` exists to re-arm it from the sensor callback.
    func testTiltUnsettlesARestingVessel() throws {
        let sim = LiquidSim(target: 0)
        XCTAssertNotNil(timeToSettle(sim, target: 0.5))
        var t = 100.0
        t += dt
        sim.step(now: t, tilt: 0.35, target: 0.5)
        XCTAssertFalse(sim.settled, "a tilt left the sim settled — the liquid would ignore the phone")
    }

    /// The wake threshold has to be small enough that a deliberate lean actually crosses it, and the
    /// sim has to react to a tilt of that size. A threshold the physics can't feel would strand a
    /// paused vessel.
    func testTheSmallestAnnouncedTiltStillMovesTheLiquid() throws {
        let sim = LiquidSim(target: 0)
        XCTAssertNotNil(timeToSettle(sim, target: 0.5))
        var t = 100.0
        t += dt
        sim.step(now: t, tilt: LiquidMotion.tiltWakeThreshold * 1.5, target: 0.5)
        XCTAssertFalse(sim.settled,
                       "the smallest tilt LiquidWake announces doesn't disturb the sim — a vessel could "
                       + "wake, re-settle on the same frame, and appear stuck")
    }

    // MARK: - The posed path

    /// The small gauges render once from `posed` and never step. It must report settled immediately —
    /// it is the definition of a still picture — and sit exactly at its fill.
    func testPosedIsAlreadyAtRest() {
        for target in [0.0, 0.42, 1.0] {
            let sim = LiquidSim.posed(target)
            XCTAssertTrue(sim.settled, "posed(\(target)) was not at rest")
            XCTAssertEqual(sim.level, target, accuracy: 0.0001)
        }
    }

    /// `posed` clamps out-of-range input rather than drawing a fill outside the vessel.
    func testPosedClampsOutOfRangeFill() {
        XCTAssertEqual(LiquidSim.posed(1.8).level, 1.0, accuracy: 0.0001)
        XCTAssertEqual(LiquidSim.posed(-0.4).level, 0.0, accuracy: 0.0001)
    }
}
