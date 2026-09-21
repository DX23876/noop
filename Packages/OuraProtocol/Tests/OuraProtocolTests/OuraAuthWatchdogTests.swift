import XCTest
@testable import OuraProtocol

/// `OuraAuthWatchdog.step` — the escalation table for an unanswered `get_nonce` (#2304) — and the
/// driver's `authNonceRetryCommand`, the only way the transport may re-send the nonce request.
///
/// The policy is a pure function precisely so it can be tested: the transports own a
/// `CBCentralManager` / `BluetoothGatt` and cannot be built in a unit test, so without this split the
/// decision would have zero coverage. These tests pin the table and the driver gate only; that the
/// escalation clears the watchdog on a healthy connect (no expiry line across a night of reconnects) is
/// a strap claim and is called out as owed in the PR body.
final class OuraAuthWatchdogTests: XCTestCase {
    private let key: [UInt8] = Array(0..<16)

    // MARK: - The table

    func testWaitsInsideTheTimeoutWhateverTheAttempt() {
        // Healthy handshakes answer within 1 s (one 5 s outlier over ~270); nothing inside the timeout
        // is an escalation, however many steps were already taken.
        for seconds in [0.0, 0.5, 1, 5, 9.99] {
            for attempt in 0...3 {
                XCTAssertEqual(OuraAuthWatchdog.step(secondsSinceNonceRequest: seconds, attempt: attempt), .wait,
                               "\(seconds)s / attempt \(attempt) is inside the timeout")
            }
        }
    }

    func testEscalatesInOrderThenDrops() {
        // The bounded sequence: re-send once, toggle once, then drop the link. Every later attempt is a
        // drop too — there is no fourth step and no wrap-around.
        XCTAssertEqual(OuraAuthWatchdog.step(secondsSinceNonceRequest: 10, attempt: 0), .resendNonce)
        XCTAssertEqual(OuraAuthWatchdog.step(secondsSinceNonceRequest: 10, attempt: 1), .toggleNotify)
        XCTAssertEqual(OuraAuthWatchdog.step(secondsSinceNonceRequest: 10, attempt: 2), .dropLink)
        for attempt in 3...10 {
            XCTAssertEqual(OuraAuthWatchdog.step(secondsSinceNonceRequest: 10, attempt: attempt), .dropLink)
        }
    }

    func testTimeoutBoundaryIsInclusive() {
        XCTAssertEqual(OuraAuthWatchdog.step(secondsSinceNonceRequest: 9.999, attempt: 0), .wait)
        XCTAssertEqual(OuraAuthWatchdog.step(secondsSinceNonceRequest: 10.0, attempt: 0), .resendNonce)
    }

    func testALateTimerStillEscalates() {
        // iOS may hold a suspended app's timer for minutes; when it finally fires the wait is far past
        // the timeout and must still take the next step, not a fresh `.wait`.
        XCTAssertEqual(OuraAuthWatchdog.step(secondsSinceNonceRequest: 3_120, attempt: 0), .resendNonce)
        XCTAssertEqual(OuraAuthWatchdog.step(secondsSinceNonceRequest: 3_120, attempt: 2), .dropLink)
    }

    func testNegativeAttemptCountsAsNone() {
        // A defensive reading of an underflowed counter: treat it as "no escalation yet".
        XCTAssertEqual(OuraAuthWatchdog.step(secondsSinceNonceRequest: 10, attempt: -1), .resendNonce)
    }

    // MARK: - The driver gate

    func testRetryCommandIsTheReadyStepsGetNonce() {
        let d = OuraDriver(ringGen: .gen3, authKey: key)
        let onReady = d.nextStep(after: .ready)
        XCTAssertEqual(d.phase, .authenticating)
        let retry = d.authNonceRetryCommand()
        XCTAssertNotNil(retry)
        XCTAssertEqual(retry?.label, "get_nonce")
        XCTAssertEqual(retry?.bytes, onReady[1].bytes, "the retry is byte-identical to the first request")
        XCTAssertEqual(d.phase, .authenticating, "asking for the retry never moves the phase")
    }

    func testRetryCommandIsNilOutsideAuthenticating() {
        // Idle: nothing has been requested yet.
        let idle = OuraDriver(ringGen: .gen3, authKey: key)
        XCTAssertNil(idle.authNonceRetryCommand())

        // No key: `.ready` goes to needsKeyInstall, and there is no handshake to retry.
        let keyless = OuraDriver(ringGen: .gen3, authKey: nil)
        _ = keyless.nextStep(after: .ready)
        XCTAssertEqual(keyless.phase, .needsKeyInstall)
        XCTAssertNil(keyless.authNonceRetryCommand())

        // Past auth: a session that reached the enable triplet / streaming must never be re-opened.
        let past = OuraDriver(ringGen: .gen3, authKey: key)
        _ = past.nextStep(after: .ready)
        _ = past.nextStep(after: .authCompleted(.success))
        XCTAssertEqual(past.phase, .enablingLiveHR)
        XCTAssertNil(past.authNonceRetryCommand())

        // A rejected handshake is a verdict, not silence.
        let failed = OuraDriver(ringGen: .gen3, authKey: key)
        _ = failed.nextStep(after: .ready)
        _ = failed.nextStep(after: .authCompleted(.authError))
        XCTAssertEqual(failed.phase, .authFailed(.authError))
        XCTAssertNil(failed.authNonceRetryCommand())

        // Stopped.
        let stopped = OuraDriver(ringGen: .gen3, authKey: key)
        _ = stopped.nextStep(after: .ready)
        stopped.stop()
        XCTAssertNil(stopped.authNonceRetryCommand())
    }

    func testWatchdogNeverReachesAuthFailed() {
        // The bench reproduction from the issue: drive the driver to `.authenticating`, walk the whole
        // escalation with no nonce, and assert the driver is never told anything — it stays
        // `.authenticating` and never becomes `.authFailed`. (The transport's drop is a link event; the
        // driver only ever sees a nonce or an auth status.)
        let d = OuraDriver(ringGen: .gen3, authKey: key)
        _ = d.nextStep(after: .ready)
        var attempt = 0
        var steps: [OuraAuthWatchdog.Step] = []
        while attempt < 3 {
            let step = OuraAuthWatchdog.step(secondsSinceNonceRequest: OuraAuthWatchdog.nonceTimeout, attempt: attempt)
            steps.append(step)
            if step == .resendNonce || step == .toggleNotify {
                XCTAssertNotNil(d.authNonceRetryCommand())
            }
            attempt += 1
        }
        XCTAssertEqual(steps, [.resendNonce, .toggleNotify, .dropLink])
        XCTAssertEqual(d.phase, .authenticating)
        if case .authFailed = d.phase { XCTFail("silence must never become an auth verdict") }
    }
}
