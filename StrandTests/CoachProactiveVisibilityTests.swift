import XCTest
@testable import Strand

/// Batch D: making the coach's own initiative visible, and closing the plan/goal loops that ended in
/// silence.
@MainActor
final class CoachProactiveVisibilityTests: XCTestCase {

    // MARK: - A message the user never asked for should say so

    func testOnlyRepliesAreNotCoachInitiated() {
        XCTAssertFalse(ChatMessage.Origin.reply.isCoachInitiated)
        for origin: ChatMessage.Origin in [.brief, .checkIn, .nudge, .weeklyReview] {
            XCTAssertTrue(origin.isCoachInitiated, "\(origin) arrives unprompted")
        }
    }

    /// Every stored transcript predates this field. Decoding those as anything but `.reply` would
    /// retroactively label a year of ordinary answers as unprompted messages.
    func testMessagesSavedBeforeOriginExistedDecodeAsReplies() throws {
        let legacy = """
        {"id":"\(UUID().uuidString)","role":"assistant","text":"Hallo","date":700000000}
        """.data(using: .utf8)!
        XCTAssertEqual(try JSONDecoder().decode(ChatMessage.self, from: legacy).origin, .reply)
    }

    func testOriginSurvivesARoundTrip() throws {
        let message = ChatMessage(role: .assistant, text: "Today's brief", origin: .brief)
        let decoded = try JSONDecoder().decode(
            ChatMessage.self, from: try JSONEncoder().encode(message))
        XCTAssertEqual(decoded.origin, .brief)
    }

    // MARK: - The badge

    private func makeEngine() -> AICoachEngine {
        UserDefaults.standard.removeObject(forKey: "coach.lastSeenCoachMessageAt")
        let engine = AICoachEngine(repo: Repository(deviceId: "test-proactive-\(UUID().uuidString)"))
        engine.newConversation()
        return engine
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "coach.lastSeenCoachMessageAt")
        super.tearDown()
    }

    func testAnUnseenBriefRaisesTheBadge() {
        let engine = makeEngine()
        engine.messages = [ChatMessage(role: .assistant, text: "Today's brief", origin: .brief)]

        XCTAssertTrue(engine.hasUnseenCoachMessage,
                      "without this the coach reaches out into an interface that gives no sign "
                      + "anything arrived")
    }

    func testAnOrdinaryReplyDoesNotRaiseTheBadge() {
        let engine = makeEngine()
        engine.messages = [ChatMessage(role: .user, text: "Frage"),
                           ChatMessage(role: .assistant, text: "Antwort")]
        XCTAssertFalse(engine.hasUnseenCoachMessage, "an answer to a question is not news")
    }

    func testOpeningTheChatClearsTheBadge() {
        let engine = makeEngine()
        engine.messages = [ChatMessage(role: .assistant, text: "Today's brief",
                                       date: Date().addingTimeInterval(-60), origin: .brief)]
        XCTAssertTrue(engine.hasUnseenCoachMessage)

        engine.markCoachMessagesSeen()

        XCTAssertFalse(engine.hasUnseenCoachMessage)
    }

    func testAMessageArrivingAfterTheLastVisitRaisesItAgain() {
        let engine = makeEngine()
        engine.markCoachMessagesSeen()
        engine.messages = [ChatMessage(role: .assistant, text: "A nudge",
                                       date: Date().addingTimeInterval(60), origin: .nudge)]

        XCTAssertTrue(engine.hasUnseenCoachMessage, "seen-ness is per message, not once and for all")
    }

    // MARK: - Skip reasons the coach never saw

    private func skipped(_ reason: PlanProposal.SkipReason) -> PlanProposal {
        PlanProposal(day: "2026-07-20", sport: "Zone 2", intent: .easy,
                     status: .skipped, skipReason: reason)
    }

    func testADominantEverydayReasonBecomesAStatedPattern() {
        let line = AICoachEngine.skipPatternLine([skipped(.noTime), skipped(.noTime), skipped(.noTime)])
        XCTAssertNotNil(line)
        XCTAssertTrue(line?.contains("No time") ?? false)
    }

    func testBelowTheThresholdNothingIsClaimed() {
        XCTAssertNil(AICoachEngine.skipPatternLine([skipped(.noTime), skipped(.tired)]),
                     "two scattered skips are not a pattern")
    }

    /// Pain and illness already reach the coach as a CAUTION with the weight they deserve. Restating
    /// them here would turn a health signal into a scheduling habit.
    func testPainAndIllnessAreNotFoldedIntoTheHabitPattern() {
        XCTAssertNil(AICoachEngine.skipPatternLine([skipped(.pain), skipped(.ill), skipped(.pain)]))
    }

    /// The line must not tell the model to stop suggesting that kind of session — that is the filter
    /// bubble `declineStreakFloor` exists to prevent.
    func testThePatternAsksRatherThanSuppresses() {
        let line = AICoachEngine.skipPatternLine([skipped(.tired), skipped(.tired), skipped(.tired)]) ?? ""
        XCTAssertTrue(line.contains("ask what would actually fit"))
        XCTAssertTrue(line.contains("do not quietly stop suggesting"))
    }

    func testNoSkipsMeansNoLine() {
        XCTAssertNil(AICoachEngine.skipPatternLine([]))
    }

    // MARK: - A goal whose date has passed

    private func goal(daysPastTarget: Int?, status: CoachGoal.Status = .active) -> CoachGoal {
        CoachGoal(title: "Half marathon",
                  targetDate: daysPastTarget.map {
                      Calendar.current.date(byAdding: .day, value: -$0, to: Date())!
                  },
                  status: status)
    }

    func testAPassedTargetDateIsSurfaced() {
        XCTAssertNotNil(ProactiveCoach.expiredGoalNeedingReview([goal(daysPastTarget: 3)]),
                        "a date going by with nothing said reads as not having noticed")
    }

    /// A target date is a target, not a stopwatch — pouncing the next morning would be graceless.
    func testTheSameDayAndTheDayAfterAreLeftAlone() {
        XCTAssertNil(ProactiveCoach.expiredGoalNeedingReview([goal(daysPastTarget: 0)]))
    }

    func testAFutureGoalIsNotReviewed() {
        let future = CoachGoal(title: "Marathon",
                               targetDate: Calendar.current.date(byAdding: .day, value: 30, to: Date()))
        XCTAssertNil(ProactiveCoach.expiredGoalNeedingReview([future]))
    }

    func testAnAlreadyClosedGoalIsNotReopened() {
        for status: CoachGoal.Status in [.achieved, .abandoned, .archived, .paused] {
            XCTAssertNil(ProactiveCoach.expiredGoalNeedingReview([goal(daysPastTarget: 5, status: status)]),
                         "\(status) has already been dealt with")
        }
    }

    func testAGoalWithNoTargetDateNeverExpires() {
        XCTAssertNil(ProactiveCoach.expiredGoalNeedingReview([goal(daysPastTarget: nil)]))
    }

    /// The review must not congratulate or commiserate on a number it hasn't checked — a missed date can
    /// mean illness, travel, or a target that was never realistic, and the app cannot tell which.
    func testTheReviewInstructionForbidsAnUnverifiedVerdict() {
        let text = AICoachEngine.goalReviewInstruction(for: goal(daysPastTarget: 2))
        XCTAssertTrue(text.contains("can't be judged"), "an honest non-answer must be allowed")
        XCTAssertTrue(text.contains("Do NOT congratulate or commiserate on a number you haven't verified"))
        XCTAssertTrue(text.contains("Half marathon"), "it should name the goal it's reviewing")
    }
}
