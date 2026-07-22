import XCTest
@testable import Strand

/// Pins T6 of Etappe T: the check-in is its OWN act, not a re-run of the morning brief.
/// `checkInInstruction` looks BACK (what happened, what was logged), opens on the T5 read tools, keeps
/// the skip-reason tone ("never laziness"), and stops at one adjustment. `appendTrailingUserTurn` keeps
/// the history-carrying wire role-alternating (the Anthropic client maps pairs 1:1, no coalescing).
@MainActor
final class CoachCheckInTests: XCTestCase {

    // MARK: - checkInInstruction

    /// Tool path: opens on the read tools a check-in turns on (get_plan_adherence + get_my_logs, the T5
    /// tool), carries the skip-as-information tone, and caps at a single adjustment.
    func testCheckInToolPathOpensOnTheReadToolsAndCapsAtOneAdjustment() {
        let instruction = AICoachEngine.checkInInstruction(toolsActive: true)
        XCTAssertTrue(instruction.contains("get_plan_adherence"))
        XCTAssertTrue(instruction.contains("get_my_logs"))
        XCTAssertTrue(instruction.contains("check-in, not a fresh brief"))
        XCTAssertTrue(instruction.contains("NEVER as laziness"))
        XCTAssertTrue(instruction.contains("AT MOST ONE"))
    }

    /// Non-tool path works off the data already in context ("above") and names no tool to call, but
    /// keeps the same look-back framing, skip tone and single-adjustment cap.
    func testCheckInNonToolPathReflectsOnDataAboveWithoutNamingToolsToCall() {
        let instruction = AICoachEngine.checkInInstruction(toolsActive: false)
        XCTAssertTrue(instruction.contains("plan-adherence and logs above"))
        XCTAssertFalse(instruction.contains("get_plan_adherence"),
                       "the non-tool path cannot call a tool, so it must not name one")
        XCTAssertTrue(instruction.contains("check-in, not a fresh brief"))
        XCTAssertTrue(instruction.contains("NEVER as laziness"))
        XCTAssertTrue(instruction.contains("AT MOST ONE"))
    }

    /// The check-in is a DIFFERENT instruction from the brief — the whole point of T6 (the old check-in
    /// just re-ran the brief).
    func testCheckInIsNotTheBriefInstruction() {
        XCTAssertNotEqual(AICoachEngine.checkInInstruction(toolsActive: true),
                          AICoachEngine.briefInstruction(toolsActive: true))
        XCTAssertNotEqual(AICoachEngine.checkInInstruction(toolsActive: false),
                          AICoachEngine.briefInstruction(toolsActive: false))
    }

    // MARK: - appendTrailingUserTurn (role alternation)

    /// History ending on an ASSISTANT turn (the normal case) gets the check-in as a new trailing user
    /// turn — a clean [.., assistant, user] alternation.
    func testAppendsANewUserTurnAfterAnAssistantTurn() {
        let history: [(role: ChatMessage.Role, content: String)] = [
            (.user, "morning"), (.assistant, "Today's brief\n\n…")
        ]
        let wire = AICoachEngine.appendTrailingUserTurn(history, content: "CHECKIN")
        XCTAssertEqual(wire.map(\.role), [.user, .assistant, .user])
        XCTAssertEqual(wire.last?.content, "CHECKIN")
    }

    /// History ending on a USER turn (an errored send with no reply) must NOT produce two consecutive
    /// user turns — the check-in folds into that trailing turn instead.
    func testFoldsIntoATrailingUserTurnToAvoidConsecutiveUsers() {
        let history: [(role: ChatMessage.Role, content: String)] = [
            (.assistant, "hi"), (.user, "unanswered question")
        ]
        let wire = AICoachEngine.appendTrailingUserTurn(history, content: "CHECKIN")
        XCTAssertEqual(wire.map(\.role), [.assistant, .user], "must stay alternating, not add a 2nd user")
        XCTAssertTrue(wire.last!.content.contains("unanswered question"))
        XCTAssertTrue(wire.last!.content.contains("CHECKIN"))
    }

    /// Empty history → the check-in is the sole (valid, user-first) turn.
    func testEmptyHistoryYieldsASoleUserTurn() {
        let wire = AICoachEngine.appendTrailingUserTurn([], content: "CHECKIN")
        XCTAssertEqual(wire.count, 1)
        XCTAssertEqual(wire[0].role, .user)
        XCTAssertEqual(wire[0].content, "CHECKIN")
    }

    // MARK: - habitualWakeMinutes (the .afterWake wake-time learner)

    /// Below the minimum nights there is no habit to rely on yet — must be nil so `.afterWake` keeps
    /// falling back to the fixed time rather than firing off one or two nights.
    func testWakeTimeIsNilBelowMinimumNights() {
        XCTAssertNil(CoachCheckIn.habitualWakeMinutes(fromLocalMinutes: []))
        XCTAssertNil(CoachCheckIn.habitualWakeMinutes(fromLocalMinutes: [7 * 60, 7 * 60]))
    }

    /// Odd count → the middle value. Three ordinary mornings around 07:00 resolve to 07:00.
    func testWakeTimeIsMedianForOddCount() {
        let minutes = [6 * 60 + 45, 7 * 60, 7 * 60 + 15]
        XCTAssertEqual(CoachCheckIn.habitualWakeMinutes(fromLocalMinutes: minutes), 7 * 60)
    }

    /// Even count → the mean of the two middle values.
    func testWakeTimeAveragesTheTwoMiddleValuesForEvenCount() {
        let minutes = [6 * 60 + 40, 7 * 60, 7 * 60 + 20, 8 * 60]
        // sorted middles are 07:00 (420) and 07:20 (440) → 430 = 07:10
        XCTAssertEqual(CoachCheckIn.habitualWakeMinutes(fromLocalMinutes: minutes), 430)
    }

    /// The median must shrug off a single outlier — one 04:00 alarm among steady 07:00 mornings must not
    /// drag the learned time earlier the way a mean would.
    func testWakeTimeMedianIgnoresASingleOutlier() {
        let minutes = [4 * 60, 7 * 60, 7 * 60 + 5, 7 * 60 + 10, 6 * 60 + 55]
        XCTAssertEqual(CoachCheckIn.habitualWakeMinutes(fromLocalMinutes: minutes), 7 * 60)
    }

    /// Garbage minute-of-day values (out of the 0..<1440 range) are dropped before the median, and if too
    /// few valid nights remain the result is nil rather than a number computed off nonsense.
    func testWakeTimeDropsOutOfRangeValuesAndReNilsIfTooFewRemain() {
        let minutes = [-5, 5000, 7 * 60]   // only one valid value survives
        XCTAssertNil(CoachCheckIn.habitualWakeMinutes(fromLocalMinutes: minutes))
    }
}
