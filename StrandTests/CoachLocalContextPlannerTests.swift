import XCTest
@testable import Strand

final class CoachLocalContextPlannerTests: XCTestCase {
    func testOrdinaryQuestionGetsOnlyTheCompactSafeBaseline() {
        XCTAssertEqual(CoachLocalContextPlanner.sections(for: "How are things?"), [.compactBiometrics])
    }

    func testTrainingQuestionRequestsOnlyRelevantTrainingSections() {
        let sections = CoachLocalContextPlanner.sections(for: "Should I run today or rest?")
        XCTAssertTrue(sections.contains(.compactBiometrics))
        XCTAssertTrue(sections.contains(.readiness))
        XCTAssertTrue(sections.contains(.workouts))
        XCTAssertTrue(sections.contains(.planning))
        XCTAssertTrue(sections.contains(.trainingPreferences))
        XCTAssertFalse(sections.contains(.stress))
        XCTAssertFalse(sections.contains(.patterns))
    }

    func testLongHistoryDoesNotPullTheRecentDailyTable() {
        XCTAssertEqual(CoachLocalContextPlanner.sections(for: "How has my weight changed over 3 years?"),
                       [.compactBiometrics])
    }

    func testPastConversationQuestionRequestsOnlyItsMemoryCategory() {
        let sections = CoachLocalContextPlanner.sections(for: "What did I ask you yesterday?")
        XCTAssertTrue(sections.contains(.conversationMemory))
        XCTAssertFalse(sections.contains(.workouts))
    }
}
