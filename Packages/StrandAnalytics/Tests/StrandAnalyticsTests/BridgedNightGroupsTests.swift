import XCTest
@testable import StrandAnalytics

/// Pins the all-groups bridge (#364): the SAME two-tier gap bridge the main-night selector applies
/// (#561 short-wake + #861 overnight night-tail), returned for EVERY group with each group's
/// inter-fragment wake seams explicit — so the Health write-back and the sleep screens can present
/// a briefly-interrupted night as ONE night without re-deriving (or diverging from) the bridge.
final class BridgedNightGroupsTests: XCTestCase {
    private typealias B = SleepStageTotals.NightBlock
    private typealias Gap = SleepStageTotals.BridgedNightGroup.GapSpan
    /// 2026-01-02 00:00:00 UTC — fixtures read as local clock times with offsetSec 0.
    private let t0 = 1_767_312_000

    func testShortWakeBridgesTwoFragmentsWithOneGap() {
        // The #364 example shape: 23:00→02:00, a 16-minute wake, 02:16→06:00.
        let a = B(start: t0 - 3_600, end: t0 + 2 * 3_600)
        let b = B(start: t0 + 2 * 3_600 + 16 * 60, end: t0 + 6 * 3_600)
        let groups = SleepStageTotals.bridgedNightGroups([a, b], offsetSec: 0)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].indices, [0, 1])
        XCTAssertEqual(groups[0].gaps, [Gap(start: a.end, end: b.start)])
    }

    func testDaytimeNapStaysItsOwnGroup() {
        let night = B(start: t0 - 3_600, end: t0 + 6 * 3_600)          // 23:00→06:00
        let nap = B(start: t0 + 14 * 3_600, end: t0 + 15 * 3_600)      // 14:00→15:00
        let groups = SleepStageTotals.bridgedNightGroups([night, nap], offsetSec: 0)
        XCTAssertEqual(groups.map(\.indices), [[0], [1]])
        XCTAssertTrue(groups.allSatisfy { $0.gaps.isEmpty })
    }

    func testNightTailBridgesOvernightGapOverSixtyMinutes() {
        // 75-min gap with the second fragment's onset at 04:15 local (overnight band): folded in by
        // the #861 night-tail bridge, so a longer real mid-night wake still reads as one night.
        let a = B(start: t0 - 3_600, end: t0 + 3 * 3_600)
        let b = B(start: t0 + 3 * 3_600 + 75 * 60, end: t0 + 7 * 3_600)
        let groups = SleepStageTotals.bridgedNightGroups([a, b], offsetSec: 0)
        XCTAssertEqual(groups.map(\.indices), [[0, 1]])
        XCTAssertEqual(groups[0].gaps, [Gap(start: a.end, end: b.start)])
    }

    func testDaytimeGapOverSixtyMinutesDoesNotBridge() {
        // Same 75-min gap but the second fragment begins at 13:15 local (daytime): the night-tail
        // widening must NOT apply, so the blocks stay separate groups (a real afternoon nap).
        let a = B(start: t0 + 9 * 3_600, end: t0 + 12 * 3_600)
        let b = B(start: t0 + 12 * 3_600 + 75 * 60, end: t0 + 14 * 3_600)
        let groups = SleepStageTotals.bridgedNightGroups([a, b], offsetSec: 0)
        XCTAssertEqual(groups.map(\.indices), [[0], [1]])
    }

    func testThreeFragmentNightYieldsTwoGaps() {
        let a = B(start: t0, end: t0 + 3_600)
        let b = B(start: t0 + 3_600 + 600, end: t0 + 2 * 3_600)
        let c = B(start: t0 + 2 * 3_600 + 900, end: t0 + 3 * 3_600)
        let groups = SleepStageTotals.bridgedNightGroups([a, b, c], offsetSec: 0)
        XCTAssertEqual(groups.map(\.indices), [[0, 1, 2]])
        XCTAssertEqual(groups[0].gaps, [Gap(start: a.end, end: b.start),
                                        Gap(start: b.end, end: c.start)])
    }

    func testOverlappingFragmentStartsItsOwnGroup() {
        // Legacy semantics pinned: a negative gap (fragment starting inside the previous span) does
        // NOT bridge — `mainNightGroupIndices` has always required gap >= 0, and the refactor must
        // not change the pick. No seam is fabricated either.
        let a = B(start: t0, end: t0 + 4 * 3_600)
        let b = B(start: t0 + 3_600, end: t0 + 2 * 3_600)
        let groups = SleepStageTotals.bridgedNightGroups([a, b], offsetSec: 0)
        XCTAssertEqual(groups.map(\.indices), [[0], [1]])
        XCTAssertTrue(groups.allSatisfy { $0.gaps.isEmpty })
    }

    func testZeroGapBridgesWithoutSeam() {
        // Touching fragments (gap == 0) bridge, and no zero-length seam is emitted.
        let a = B(start: t0, end: t0 + 3_600)
        let b = B(start: t0 + 3_600, end: t0 + 2 * 3_600)
        let groups = SleepStageTotals.bridgedNightGroups([a, b], offsetSec: 0)
        XCTAssertEqual(groups.map(\.indices), [[0, 1]])
        XCTAssertTrue(groups[0].gaps.isEmpty)
    }

    func testUnsortedInputIndicesReferToOriginalPositions() {
        // Input order reversed: indices still point into the ORIGINAL array (late = 0, early = 1),
        // returned ascending within the group.
        let late = B(start: t0 + 2 * 3_600 + 16 * 60, end: t0 + 6 * 3_600)
        let early = B(start: t0 - 3_600, end: t0 + 2 * 3_600)
        let groups = SleepStageTotals.bridgedNightGroups([late, early], offsetSec: 0)
        XCTAssertEqual(groups.map(\.indices), [[0, 1]])
        XCTAssertEqual(groups[0].gaps, [Gap(start: early.end, end: late.start)])
    }

    func testEmptyInputYieldsNoGroups() {
        XCTAssertTrue(SleepStageTotals.bridgedNightGroups([], offsetSec: 0).isEmpty)
    }

    /// The refactor guard: the main-night pick over the all-groups pass stays byte-identical for a
    /// biphasic night + nap day (the #561/#861 golden suite pins the rest of the behaviour).
    func testMainNightGroupIndicesUnchangedForBiphasicPlusNap() {
        let a = B(start: t0 - 3_600, end: t0 + 2 * 3_600)
        let b = B(start: t0 + 2 * 3_600 + 16 * 60, end: t0 + 6 * 3_600)
        let nap = B(start: t0 + 14 * 3_600, end: t0 + 15 * 3_600)
        XCTAssertEqual(SleepStageTotals.mainNightGroupIndices([a, b, nap], offsetSec: 0), [0, 1])
    }

    /// REAL NIGHT (2026-07-14, PDT): a 12:16 first-sleep fragment (67 min) then a ~6-min walk then the
    /// main 1:29 → 7:32 sleep, stored as two rows on `my-whoop-noop` with the main's onset user-edited
    /// later via `startTsAdjusted` (so its EFFECTIVE start is 1:29). The 6-min effective gap is far under
    /// `gapBridgeMaxMin`, so the two fragments MUST bridge into ONE group — proving the fragment is NOT
    /// filtered out of grouping. The bug lives downstream (the display onset walk), not here: the group
    /// spans the whole night, exactly as the Health write-back folds it (#364). offsetSec = -25200 (PDT).
    func testRealNightFirstSleepFragmentBridgesIntoMainGroup() {
        let off = -25_200
        let fragment = B(start: 1_784_013_364, end: 1_784_017_375)      // 12:16 → 1:22 (67 min)
        let mainEffective = B(start: 1_784_017_740, end: 1_784_039_558) // 1:29 (edited onset) → 7:32
        let groups = SleepStageTotals.bridgedNightGroups([fragment, mainEffective], offsetSec: off)
        XCTAssertEqual(groups.map(\.indices), [[0, 1]], "the 6-min walk must bridge, not split the night")
        XCTAssertEqual(groups[0].gaps, [Gap(start: fragment.end, end: mainEffective.start)])
        // The whole bridged group is the main night, and its span opens at the 12:16 fragment.
        XCTAssertEqual(SleepStageTotals.mainNightGroupIndices([fragment, mainEffective], offsetSec: off),
                       [0, 1])
        let span = groups[0].indices
        XCTAssertEqual([fragment, mainEffective][span[0]].start, 1_784_013_364,
                       "earliest onset of the bridged night is the 12:16 first-sleep fragment")
    }
}
