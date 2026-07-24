import XCTest
import StrandAnalytics
@testable import Strand

/// Pins docs/feature-spec.md §2: the Basiskarte shows the real `ReadinessEngine` statement while
/// `ActivityStatus` is `.active`, and a fixed statement for the three exception states — Basiskarte and
/// coach must never disagree, so `.active` must pass the readiness text through unmodified.
final class BaseCardStatementTests: XCTestCase {

    /// A readiness fixture with an intentionally distinctive headline/summary so a test can prove an
    /// exception-state override actually replaced the text, rather than accidentally falling through.
    private func fixtureReadiness() -> ReadinessEngine.Readiness {
        ReadinessEngine.Readiness(
            level: .primed,
            headline: "Primed",
            summary: "Your signals are aligned and your load is supported.",
            signals: [],
            acwr: nil,
            monotony: nil)
    }

    func testActiveStatusPassesReadinessThroughVerbatim() {
        let readiness = fixtureReadiness()
        let statement = BaseCardStatement.current(status: .active, readiness: readiness)
        XCTAssertEqual(statement.headline, readiness.headline)
        XCTAssertEqual(statement.summary, readiness.summary)
        XCTAssertFalse(statement.isOverride)
    }

    func testExceptionStatesOverrideWithFixedNonEmptyText() {
        let readiness = fixtureReadiness()
        for state: ActivityStatus.State in [.sick, .injured, .onBreak] {
            let status = ActivityStatus(state: state, validUntil: nil, setAt: Date())
            let statement = BaseCardStatement.current(status: status, readiness: readiness)

            XCTAssertTrue(statement.isOverride, "\(state) should be an override")
            XCTAssertFalse(statement.headline.isEmpty, "\(state) headline should not be empty")
            XCTAssertFalse(statement.summary.isEmpty, "\(state) summary should not be empty")

            // Prove the computed readiness text was actually replaced, not passed through.
            XCTAssertNotEqual(statement.headline, readiness.headline, "\(state) must not leak the computed headline")
            XCTAssertNotEqual(statement.summary, readiness.summary, "\(state) must not leak the computed summary")
        }
    }

    func testExceptionStatesHaveDistinctHeadlines() {
        let readiness = fixtureReadiness()
        let headlines = [ActivityStatus.State.sick, .injured, .onBreak].map {
            BaseCardStatement.current(status: ActivityStatus(state: $0, validUntil: nil, setAt: Date()), readiness: readiness).headline
        }
        XCTAssertEqual(Set(headlines).count, headlines.count, "each exception state should show its own headline")
    }
}
