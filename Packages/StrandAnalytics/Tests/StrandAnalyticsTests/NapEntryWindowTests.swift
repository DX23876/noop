import XCTest
@testable import StrandAnalytics

/// What the nap-entry sheet suggests, and what it says a chosen window will become (#49).
///
/// The sheet exists because a nap the strap missed can only come from the wearer. It is worth pinning
/// because the first version of it suggested wake + 1 h, which the selector folds back into the night all
/// morning: the entry was stored, the day's figures moved, and the nap card then reported no nap on that
/// day — the app contradicting the person who had just told it otherwise.
final class NapEntryWindowTests: XCTestCase {

    /// 2026-11-17 00:00 UTC, so a local hour is the UTC hour plus the offset under test.
    private let day = 1_763_337_600
    private let utc = 0

    // MARK: - The verdict

    /// The whole point of the look-ahead: a window an hour behind a morning wake does NOT stand as a nap,
    /// it is bridged into the night (gap 60 min, onset inside the overnight band [20:00, 11:00)).
    func testAnHourAfterAMorningWakeIsNotANap() {
        let wake = day + 7 * 3_600
        XCTAssertEqual(SleepStageTotals.napEntryVerdict(start: wake + 3_600, nightEnd: wake, offsetSec: utc),
                       .foldedIntoTheNight)
    }

    /// Two hours clears both bridge windows, which is what the suggestion leans on.
    func testTwoHoursAfterTheWakeStandsAsItsOwnNap() {
        let wake = day + 7 * 3_600
        XCTAssertEqual(SleepStageTotals.napEntryVerdict(start: wake + 2 * 3_600, nightEnd: wake, offsetSec: utc),
                       .standsAsNap)
    }

    /// The wider bridge is the overnight one: the SAME 80-minute gap folds in before 11:00 and stands
    /// after it. Both directions, because this is the asymmetry the old suggestion fell into.
    func testTheWiderBridgeOnlyHoldsInsideTheOvernightBand() {
        let earlyWake = day + 9 * 3_600            // 09:00, nap would start 10:20 — overnight band
        XCTAssertEqual(SleepStageTotals.napEntryVerdict(start: earlyWake + 80 * 60, nightEnd: earlyWake,
                                                        offsetSec: utc), .foldedIntoTheNight)
        let lateWake = day + 11 * 3_600            // 11:00, nap would start 12:20 — daytime
        XCTAssertEqual(SleepStageTotals.napEntryVerdict(start: lateWake + 80 * 60, nightEnd: lateWake,
                                                        offsetSec: utc), .standsAsNap)
    }

    /// A window that starts before the night's wake is a correction of that night, not a nap — a third
    /// legitimate outcome, so the sheet must be able to name it rather than call it a nap.
    func testAWindowInsideTheNightIsNamedAsSuch() {
        let wake = day + 7 * 3_600
        XCTAssertEqual(SleepStageTotals.napEntryVerdict(start: wake - 1_800, nightEnd: wake, offsetSec: utc),
                       .insideTheNight)
    }

    /// The verdict reads the same rule the grouping pass reads. Asserted through the pass itself, so this
    /// fails if the two ever stop agreeing — the point of having one function.
    func testTheVerdictAgreesWithTheGroupingItPredicts() {
        let wake = day + 7 * 3_600
        for gapMin in [0, 30, 59, 60, 89, 90, 120, 300] {
            let start = wake + gapMin * 60
            let blocks = [SleepStageTotals.NightBlock(start: day - 3 * 3_600, end: wake),
                          SleepStageTotals.NightBlock(start: start, end: start + 1_800)]
            let groups = SleepStageTotals.bridgedNightGroups(blocks, offsetSec: utc)
            let merged = groups.count == 1
            let verdict = SleepStageTotals.napEntryVerdict(start: start, nightEnd: wake, offsetSec: utc)
            XCTAssertEqual(merged, verdict == .foldedIntoTheNight, "gap \(gapMin) min")
        }
    }

    // MARK: - The suggestion

    /// The ordinary morning: woken at 07:00, it is now the evening, so the sheet opens on the early
    /// afternoon — a nap-shaped hour, and far clear of the night.
    func testAnOrdinaryDaySuggestsTheEarlyAfternoon() {
        let wake = day + 7 * 3_600
        let seed = SleepStageTotals.napEntrySeed(nightEnd: wake, offsetSec: utc, now: day + 20 * 3_600)
        XCTAssertEqual(seed.start, day + 14 * 3_600)
        XCTAssertEqual(seed.end - seed.start, SleepStageTotals.napSeedMinutes * 60)
        XCTAssertEqual(SleepStageTotals.napEntryVerdict(start: seed.start, nightEnd: wake, offsetSec: utc),
                       .standsAsNap)
    }

    /// A nap cannot be suggested for a time that has not come yet: at 09:30 the window sits behind the
    /// clock, not at 14:00.
    func testAMorningSuggestionStaysBehindTheClock() {
        let wake = day + 7 * 3_600
        let now = day + 9 * 3_600 + 1_800
        let seed = SleepStageTotals.napEntrySeed(nightEnd: wake, offsetSec: utc, now: now)
        XCTAssertEqual(seed.end, now)
        XCTAssertEqual(SleepStageTotals.napEntryVerdict(start: seed.start, nightEnd: wake, offsetSec: utc),
                       .standsAsNap)
    }

    /// Right after a wake there is no honest window at all: the suggestion stays at the earliest one that
    /// would count as a nap rather than offering a time the night would swallow. The sheet's own guard
    /// then says a sleep cannot end in the future, which is true and is the wearer's cue to pick a time.
    func testRightAfterWakingTheSuggestionStaysClearOfTheNight() {
        let wake = day + 7 * 3_600
        let seed = SleepStageTotals.napEntrySeed(nightEnd: wake, offsetSec: utc, now: wake + 600)
        XCTAssertEqual(seed.start, wake + SleepStageTotals.napSeedMinGapSec)
        XCTAssertEqual(SleepStageTotals.napEntryVerdict(start: seed.start, nightEnd: wake, offsetSec: utc),
                       .standsAsNap)
    }

    /// A night that ran into the afternoon pushes the suggestion past 14:00 instead of behind the wake.
    func testALongNightPushesTheSuggestionPastTheAfternoon() {
        let wake = day + 13 * 3_600 + 1_800        // woke 13:30
        let seed = SleepStageTotals.napEntrySeed(nightEnd: wake, offsetSec: utc, now: day + 22 * 3_600)
        XCTAssertEqual(seed.start, wake + SleepStageTotals.napSeedMinGapSec)
        XCTAssertEqual(SleepStageTotals.napEntryVerdict(start: seed.start, nightEnd: wake, offsetSec: utc),
                       .standsAsNap)
    }

    /// The afternoon is the wearer's afternoon, not UTC's: east of UTC the same wake yields a seed whose
    /// LOCAL hour is still 14.
    func testTheAfternoonIsLocal() {
        let offset = 3_600                          // CET
        let wake = day + 6 * 3_600                  // 07:00 local
        let seed = SleepStageTotals.napEntrySeed(nightEnd: wake, offsetSec: offset, now: day + 20 * 3_600)
        let localHour = ((seed.start + offset) % 86_400) / 3_600
        XCTAssertEqual(localHour, SleepStageTotals.napSeedLocalHour)
    }
}

/// The oracle the Kotlin twin's expected literal is pasted from (`NapEntryWindowParityTest`). Reading the
/// two implementations side by side does not catch a differing rounding or an off-by-one at a band edge;
/// this does, over a spread of gaps, hours and offsets. Printed by the Swift side, asserted on the Kotlin
/// side, per the repository's oracle rule.
final class NapEntryWindowOracleTests: XCTestCase {
    func testPrintTheOracle() {
        let day = 1_763_337_600          // 2026-11-17 00:00 UTC
        var out: [String] = []
        for offset in [0, 3_600, -7 * 3_600] {
            for wakeHour in [5, 7, 9, 11, 13, 19] {
                let wake = day + wakeHour * 3_600
                for gapMin in [-30, 0, 30, 59, 60, 61, 89, 90, 120, 480] {
                    let v = SleepStageTotals.napEntryVerdict(start: wake + gapMin * 60, nightEnd: wake,
                                                             offsetSec: offset)
                    out.append(v.rawValue)
                }
                for nowHour in [8, 10, 16, 23] {
                    let seed = SleepStageTotals.napEntrySeed(nightEnd: wake, offsetSec: offset,
                                                             now: day + nowHour * 3_600)
                    out.append("\(seed.start - day)/\(seed.end - day)")
                }
            }
        }
        print("NAP_ENTRY_ORACLE=" + out.joined(separator: ","))
    }
}
