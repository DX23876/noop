import XCTest
@testable import Strand

/// Guards `runUnescalated`.
///
/// The helper exists because `await someDetachedTask.value` escalates that task to the waiter's
/// priority, which made the "background" analysis scan run at the UI's quality of service. Awaiting a
/// continuation instead removes the dependency edge the runtime escalates through — and removes the
/// one it propagates CANCELLATION through as well. Re-attaching cancellation by hand is therefore not
/// a nicety: without it a cancelled reanalysis would keep burning the CPU it was cancelled to free,
/// which is a worse version of the problem the helper was written to fix.
final class UnescalatedWorkTests: XCTestCase {

    /// The ordinary path: the value comes back, unwrapped, exactly as a `Task.value` would deliver it.
    func testItReturnsTheWorkResult() async {
        let value = await runUnescalated { 41 + 1 }
        XCTAssertEqual(value, 42)
    }

    /// Non-`Sendable` results must still cross. The analysis scan returns `DayScan`, which is
    /// deliberately not `Sendable`, so a helper that demanded conformance could not be used where it
    /// is needed most. A class is the sharpest version of that case.
    func testANonSendableResultCrosses() async {
        final class Payload { let n: Int; init(n: Int) { self.n = n } }
        let payload = await runUnescalated { Payload(n: 7) }
        XCTAssertEqual(payload.n, 7)
    }

    /// Cancelling the CALLER must cancel the work. This is the property the continuation removed and
    /// the cancellation handler puts back.
    func testCancellingTheCallerCancelsTheWork() async {
        let started = expectation(description: "work started")
        let observed = expectation(description: "work observed the cancellation")

        let caller = Task {
            await runUnescalated {
                started.fulfill()
                // Poll rather than sleep: `Task.sleep` throws on cancellation and would pass this test
                // without the work ever having been cancelled.
                while !Task.isCancelled {
                    await Task.yield()
                }
                observed.fulfill()
            }
        }

        await fulfillment(of: [started], timeout: 5)
        caller.cancel()
        await fulfillment(of: [observed], timeout: 5)
        _ = await caller.value
    }

    /// Cancellation that arrives before the inner task even exists must not be lost. The handler is
    /// installed before the task is created, so this ordering is real, not theoretical.
    func testCancellationArrivingFirstIsNotLost() async {
        let caller = Task {
            // Cancelled before it ever runs, so the box adopts an already-cancelled state.
            await Task.yield()
            return await runUnescalated { Task.isCancelled }
        }
        caller.cancel()
        let sawCancellation = await caller.value
        XCTAssertTrue(sawCancellation, "the work must start already cancelled, not run to completion")
    }

    /// The property the callers actually need: the body runs at the priority it asked for, even though a
    /// main-actor caller is waiting on it.
    @MainActor
    func testUnescalatedWorkKeepsItsDeclaredPriority() async {
        let inside = await runUnescalated(priority: .utility) { Task.currentPriority }
        XCTAssertEqual(inside, .utility,
                       "unprompted work must keep the priority it declared, not the waiter's")
    }

    /// The control, and the reason the helper exists. If this ever stops escalating, the runtime changed
    /// and the helper can go — so this failing is informative rather than a nuisance.
    @MainActor
    func testAwaitingADetachedTaskEscalatesItInstead() async {
        let inside = await Task.detached(priority: .utility) { Task.currentPriority }.value
        XCTAssertNotEqual(inside, .utility,
                          "a plain awaited detached task is expected to be escalated to the waiter's priority")
    }

    /// A suspension point inside the body must not hand the priority back.
    @MainActor
    func testPriorityHoldsAcrossASuspensionInsideTheBody() async {
        let inside = await runUnescalated(priority: .utility) { () async -> TaskPriority in
            try? await Task.sleep(nanoseconds: 1_000_000)
            return Task.currentPriority
        }
        XCTAssertEqual(inside, .utility)
    }

    /// The value comes back intact; the helper is a priority fix, not a behaviour change.
    @MainActor
    func testTheResultIsReturnedUnchanged() async {
        let sum = await runUnescalated { (1...10).reduce(0, +) }
        XCTAssertEqual(sum, 55)
    }
}
