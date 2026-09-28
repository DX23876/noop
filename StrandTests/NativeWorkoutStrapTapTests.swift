import XCTest
import StrandTraining
@testable import Strand

/// The pure decisions behind the strap during a strength session: when a tap is a knock, and when the rest
/// and timed-set buzzes fire. Which set a tap completes, and whether it may, is `NativeWorkoutEngine`'s and
/// tested with the StrandTraining package (`WorkoutSetFlowTests`).
@MainActor
final class NativeWorkoutStrapTapTests: XCTestCase {
    func testATapUnderFiveSecondsAfterTheLastIsAKnock() {
        XCTAssertTrue(NativeWorkoutSessionModel.isKnock(secondsSinceLastStep: 0))
        XCTAssertTrue(NativeWorkoutSessionModel.isKnock(secondsSinceLastStep: 4))
        XCTAssertFalse(NativeWorkoutSessionModel.isKnock(secondsSinceLastStep: 5))
        XCTAssertFalse(NativeWorkoutSessionModel.isKnock(secondsSinceLastStep: 90))
        // A clock that went backwards is not a reason to swallow a tap.
        XCTAssertFalse(NativeWorkoutSessionModel.isKnock(secondsSinceLastStep: -3))
    }

    func testARestWarnsFiveSecondsBeforeItsEndWithThreePulses() {
        let now = 2_000_000
        let rest = WorkoutTimerState(kind: .rest, startedAtTs: now, endsAtTs: now + 120)
        XCTAssertEqual(NativeWorkoutSessionModel.strapCue(for: rest, now: now),
                       .init(at: now + 115, endsAt: now + 120, loops: 3))
        // Already inside the window: a second from now, clear of the confirming buzz the same tap sent.
        let short = WorkoutTimerState(kind: .restPause, startedAtTs: now, endsAtTs: now + 3)
        XCTAssertEqual(NativeWorkoutSessionModel.strapCue(for: short, now: now)?.at, now + 1)
    }

    func testATimedSetBuzzesTwiceAtItsEnd() {
        let now = 2_000_000
        let plank = WorkoutTimerState(kind: .timedSet, startedAtTs: now, endsAtTs: now + 60)
        XCTAssertEqual(NativeWorkoutSessionModel.strapCue(for: plank, now: now),
                       .init(at: now + 60, endsAt: now + 60, loops: 2))
        XCTAssertNil(NativeWorkoutSessionModel.strapCue(for: plank, now: now + 60))
    }

    func testAPausedOrLongFinishedTimerEarnsNoBuzz() {
        let now = 2_000_000
        let paused = WorkoutTimerState(kind: .rest, startedAtTs: now, endsAtTs: now + 120,
                                       pausedRemainingSeconds: 80)
        XCTAssertNil(NativeWorkoutSessionModel.strapCue(for: paused, now: now))
        let over = WorkoutTimerState(kind: .rest, startedAtTs: now - 200, endsAtTs: now - 11)
        XCTAssertNil(NativeWorkoutSessionModel.strapCue(for: over, now: now))
        XCTAssertFalse(NativeWorkoutSessionModel.isStaleCue(endsAt: now - 10, now: now))
        XCTAssertTrue(NativeWorkoutSessionModel.isStaleCue(endsAt: now - 11, now: now))
    }
}
