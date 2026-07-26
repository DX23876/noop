import XCTest
@testable import Strand

/// `JourneyMilestones` is deliberately NOT a streak counter or a gamification meter — every case here
/// checks that a milestone states a fact about what happened rather than rewarding a habit loop, and
/// that an empty result (a brand-new goal with nothing done yet) is treated as normal, not a failure.
final class JourneyMilestonesTests: XCTestCase {

    func testBrandNewGoalHasNoMilestonesYet() {
        let achieved = JourneyMilestones.achieved(.init())
        XCTAssertTrue(achieved.isEmpty, "nothing achieved is a normal, honest state for a new goal")
    }

    func testBrandNewGoalGetsAnInvitationNotAGap() {
        let suggestion = JourneyMilestones.nextSuggestion(.init())
        XCTAssertTrue(suggestion.lowercased().contains("first session"))
    }

    func testFirstWeekRequiresBothTimeAndACompletedSession() {
        // Time passed, but nothing completed: no "first week" claim.
        let timeOnly = JourneyMilestones.achieved(.init(daysSinceGoalCreated: 10, completedSessionCount: 0))
        XCTAssertFalse(timeOnly.contains { $0.id == "first_week" })

        // Completed something, but not a week old yet: still no claim.
        let sessionOnly = JourneyMilestones.achieved(.init(daysSinceGoalCreated: 2, completedSessionCount: 3))
        XCTAssertFalse(sessionOnly.contains { $0.id == "first_week" })

        // Both true: the milestone appears.
        let both = JourneyMilestones.achieved(.init(daysSinceGoalCreated: 8, completedSessionCount: 1))
        XCTAssertTrue(both.contains { $0.id == "first_week" })
    }

    func testSessionCountMilestoneUsesCorrectSingularPlural() {
        let one = JourneyMilestones.achieved(.init(completedSessionCount: 1))
        XCTAssertEqual(one.first { $0.id == "sessions" }?.title, "1 session completed")

        let many = JourneyMilestones.achieved(.init(completedSessionCount: 5))
        XCTAssertEqual(many.first { $0.id == "sessions" }?.title, "5 sessions completed")
    }

    func testLongestRunOnlyAppearsWithARealPositiveValue() {
        XCTAssertFalse(JourneyMilestones.achieved(.init(longestRunKm: nil)).contains { $0.id == "longest_run" })
        XCTAssertFalse(JourneyMilestones.achieved(.init(longestRunKm: 0)).contains { $0.id == "longest_run" })
        XCTAssertTrue(JourneyMilestones.achieved(.init(longestRunKm: 4.2)).contains { $0.id == "longest_run" })
    }

    /// "Pain-free" must never be claimed alongside a recent pain/illness skip, and needs a real minimum
    /// of completed sessions — a single session says nothing about a pattern.
    func testPainFreeRequiresNoRecentCautionSkipAndEnoughSessions() {
        let withCaution = JourneyMilestones.achieved(
            .init(completedSessionCount: 5, hasRecentCautionSkip: true))
        XCTAssertFalse(withCaution.contains { $0.id == "pain_free" })

        let tooFew = JourneyMilestones.achieved(
            .init(completedSessionCount: 1, hasRecentCautionSkip: false))
        XCTAssertFalse(tooFew.contains { $0.id == "pain_free" })

        let clean = JourneyMilestones.achieved(
            .init(completedSessionCount: 4, hasRecentCautionSkip: false))
        XCTAssertTrue(clean.contains { $0.id == "pain_free" })
    }

    /// Small week-to-week noise must NOT read as a milestone — only a rise clearing the threshold does.
    func testRecoveryTrendNeedsToClearTheThreshold() {
        let noise = JourneyMilestones.achieved(.init(recentAvgCharge: 61, priorAvgCharge: 60))
        XCTAssertFalse(noise.contains { $0.id == "recovery_up" })

        let realRise = JourneyMilestones.achieved(.init(recentAvgCharge: 70, priorAvgCharge: 60))
        XCTAssertTrue(realRise.contains { $0.id == "recovery_up" })
    }

    func testRecoveryTrendDoesNotClaimADrop() {
        let drop = JourneyMilestones.achieved(.init(recentAvgCharge: 50, priorAvgCharge: 65))
        XCTAssertFalse(drop.contains { $0.id == "recovery_up" })
    }

    // MARK: - Next suggestion is always forward-looking, never a countdown

    func testNextSuggestionEncouragesTheFirstWeekWhenStillEarly() {
        let s = JourneyMilestones.nextSuggestion(.init(daysSinceGoalCreated: 3, completedSessionCount: 2))
        XCTAssertTrue(s.lowercased().contains("first week"))
    }

    func testNextSuggestionReferencesTheLongestRunWhenAvailable() {
        let s = JourneyMilestones.nextSuggestion(
            .init(daysSinceGoalCreated: 30, completedSessionCount: 10, longestRunKm: 5.0))
        XCTAssertTrue(s.contains("5.0"))
    }

    func testNextSuggestionFallsBackToConsistency() {
        let s = JourneyMilestones.nextSuggestion(
            .init(daysSinceGoalCreated: 30, completedSessionCount: 10, longestRunKm: nil))
        XCTAssertTrue(s.lowercased().contains("consistency") || s.lowercased().contains("showing up"))
    }
}
