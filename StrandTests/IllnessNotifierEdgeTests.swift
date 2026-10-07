import XCTest
@testable import Strand

/// The illness notification fires on a clear-to-raised edge kept in persisted state, at most once a
/// day. Same cases as Android `IllnessAlertPolicyTest` (upstream d1bee8bd7, #2586).
final class IllnessNotifierEdgeTests: XCTestCase {

    func testAFreshTransitionNotifies() {
        XCTAssertTrue(IllnessNotifier.shouldNotify(raised: true, previouslyRaised: false,
                                                   lastNotifiedDay: nil, today: "2026-10-07"))
    }

    func testAClearEvaluationNeverNotifies() {
        XCTAssertFalse(IllnessNotifier.shouldNotify(raised: false, previouslyRaised: false,
                                                    lastNotifiedDay: nil, today: "2026-10-07"))
    }

    /// The #2586 case: the alert is still raised from yesterday and the app was cold-started. The
    /// day gate alone would allow it; the persisted edge does not.
    func testAStillRaisedAlertAfterARestartDoesNotNotifyAgain() {
        XCTAssertFalse(IllnessNotifier.shouldNotify(raised: true, previouslyRaised: true,
                                                    lastNotifiedDay: "2026-10-06", today: "2026-10-07"))
    }

    func testTheDayGateStillDedupesSameDayTransitions() {
        XCTAssertFalse(IllnessNotifier.shouldNotify(raised: true, previouslyRaised: false,
                                                    lastNotifiedDay: "2026-10-07", today: "2026-10-07"))
    }

    /// Clear evaluations are recorded, so a genuine new decline later is told.
    func testAGenuineNewDeclineAfterRecoveryNotifies() {
        XCTAssertTrue(IllnessNotifier.shouldNotify(raised: true, previouslyRaised: false,
                                                   lastNotifiedDay: "2026-09-01", today: "2026-10-07"))
    }
}
