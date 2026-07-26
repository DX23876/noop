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

    // MARK: - mainNightWakeMinutes (main-night selection feeding the learner)

    /// Fixed UTC offset for deterministic day-bucketing/local-minute math, independent of the machine's
    /// system timezone.
    private static let utc: (Int) -> Int = { _ in 0 }
    private static let dayStartUtc = 1_700_000_000 - (1_700_000_000 % 86_400)   // a stable UTC midnight

    private func dayStart(_ daysAgo: Int) -> Int { Self.dayStartUtc - daysAgo * 86_400 }

    /// A day with an overnight block AND an afternoon nap must resolve to the NIGHT's wake time, not the
    /// nap's — the exact bug the old code had (no nap filter at all).
    func testNapOnTheSameDayDoesNotContributeItsOwnWakeTime() {
        let day = dayStart(0)
        let night = (start: day - 6 * 3600, end: day + 7 * 3600)          // 18:00 prev day → 07:00
        let nap = (start: day + 14 * 3600, end: day + 15 * 3600)          // 14:00 → 15:00 nap
        let wakes = CoachCheckIn.mainNightWakeMinutes(
            blocks: [night, nap], nights: 5, habitualMidsleepSec: nil, offsetSec: Self.utc)
        XCTAssertEqual(wakes, [7 * 60], "the nap must not appear as its own wake time")
    }

    /// A night briefly split by a short wake (bridgeable gap) must resolve to ONE wake time — the later
    /// fragment's end — not two competing entries.
    func testSplitSleepNightResolvesToOneWakeTime() {
        let day = dayStart(0)
        let first = (start: day - 6 * 3600, end: day + 2 * 3600)          // 18:00 → 02:00
        let second = (start: day + 2 * 3600 + 300, end: day + 7 * 3600)   // 02:05 → 07:00 (5-min gap, bridges)
        let wakes = CoachCheckIn.mainNightWakeMinutes(
            blocks: [first, second], nights: 5, habitualMidsleepSec: nil, offsetSec: Self.utc)
        XCTAssertEqual(wakes, [7 * 60], "a bridged split night must yield exactly one wake time")
    }

    /// More distinct nights of data than `nights` requested must keep the NEWEST ones — the regression
    /// check for the old `ORDER BY startTs ASC LIMIT ?` bug, which silently dropped the newest nights
    /// instead of the oldest once a window held more rows than the limit.
    func testMoreNightsThanRequestedKeepsTheNewestOnes() {
        let blocks = (0..<10).map { i -> (start: Int, end: Int) in
            let day = dayStart(9 - i)   // i=0 → oldest (9 days ago), i=9 → newest (today)
            return (start: day - 6 * 3600, end: day + (7 + i) * 3600)   // wake minute varies so nights differ
        }
        let wakes = CoachCheckIn.mainNightWakeMinutes(
            blocks: blocks, nights: 3, habitualMidsleepSec: nil, offsetSec: Self.utc)
        // The newest 3 nights (i = 7, 8, 9) wake at 14:00, 15:00, 16:00 respectively.
        XCTAssertEqual(wakes, [14 * 60, 15 * 60, 16 * 60])
    }

    /// Empty input yields no wake times at all (not a crash / not a fallback default).
    func testEmptyBlocksYieldNoWakeTimes() {
        XCTAssertEqual(CoachCheckIn.mainNightWakeMinutes(
            blocks: [], nights: 14, habitualMidsleepSec: nil, offsetSec: Self.utc), [])
    }

    /// A window spanning a DST-style offset change must map each wake to ITS OWN local minute, not one
    /// offset applied uniformly across the whole window.
    func testEachNightUsesItsOwnOffsetAcrossAnOffsetChange() {
        let day0 = dayStart(1), day1 = dayStart(0)
        // day0 wakes under UTC+1 (offset 3600), day1 wakes under UTC+2 (offset 7200) — simulating a
        // spring-forward mid-window. Both blocks end at the same UTC instant-of-day (07:00 UTC), but
        // should map to DIFFERENT local minutes because the offset changed.
        let older = (start: day0 - 6 * 3600, end: day0 + 7 * 3600)
        let newer = (start: day1 - 6 * 3600, end: day1 + 7 * 3600)
        let offsetSec: (Int) -> Int = { ts in ts < day1 ? 3600 : 7200 }
        let wakes = CoachCheckIn.mainNightWakeMinutes(
            blocks: [older, newer], nights: 5, habitualMidsleepSec: nil, offsetSec: offsetSec)
        XCTAssertEqual(wakes.count, 2)
        XCTAssertEqual(wakes[0], 8 * 60, "older night: 07:00 UTC + 1h offset = 08:00 local")
        XCTAssertEqual(wakes[1], 9 * 60, "newer night: 07:00 UTC + 2h offset = 09:00 local")
    }
}
