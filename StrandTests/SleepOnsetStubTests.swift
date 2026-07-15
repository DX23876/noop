import XCTest
@testable import Strand

/// #736: the Sleep tab showed the WRONG bedtime (the earliest pre-sleep fragment, e.g. 21:41) while the
/// pencil edit targeted the night's MAIN block — so the displayed onset and the edit target were different
/// fragments and editing couldn't move the shown bedtime. The fix aligns the displayed onset to the same
/// fragment the edit targets by skipping a leading SPURIOUS pre-onset awake stub (BRIEF + essentially
/// sleepless). These golden tests pin that rule on the pure helpers so a regression can't slip past the
/// view internals. The Android twin lives in SleepScreen's isPreOnsetAwakeStub.
final class SleepOnsetStubTests: XCTestCase {

    // MARK: - isPreOnsetAwakeStub (the per-fragment rule)

    /// A brief, all-awake leading block (15 min, 0 asleep) IS a spurious pre-onset stub.
    func testBriefAllAwakeIsStub() {
        XCTAssertTrue(SleepView.isPreOnsetAwakeStub(spanMin: 15, asleepMin: 0))
    }

    /// A short block that already holds real sleep (12 min span, 8 asleep) is NOT a stub — it's sleep.
    func testShortButAsleepIsNotStub() {
        XCTAssertFalse(SleepView.isPreOnsetAwakeStub(spanMin: 12, asleepMin: 8))
    }

    /// THE #736 SHAPE: a LONG all-awake pre-sleep block (the reporter's 21:41 → 00:27, ~2h45m, 0 asleep) IS a
    /// spurious stub — a multi-hour lie-in before sleep is not part of the night, so it must drop off the
    /// displayed bedtime. The tight old cap missed this; the sleepless test is what keeps it safe.
    func testLongAllAwakePreSleepBlockIsStub() {
        XCTAssertTrue(SleepView.isPreOnsetAwakeStub(spanMin: 165, asleepMin: 0))
    }

    /// A truly absurd all-day awake block (> cap) is NOT silently swallowed — the cap is the only guard left.
    func testBeyondCapIsNotStub() {
        XCTAssertFalse(SleepView.isPreOnsetAwakeStub(spanMin: SleepView.preOnsetStubMaxMin + 1, asleepMin: 0))
    }

    /// Boundary: exactly at both thresholds (cap span, 3 asleep) still counts as a stub (inclusive <=).
    func testAtThresholdsIsStub() {
        XCTAssertTrue(SleepView.isPreOnsetAwakeStub(spanMin: SleepView.preOnsetStubMaxMin,
                                                    asleepMin: SleepView.preOnsetStubAsleepMaxMin))
    }

    /// Just over the asleep threshold (4 min asleep) is real sleep, not a stub.
    func testJustOverAsleepThresholdIsNotStub() {
        XCTAssertFalse(SleepView.isPreOnsetAwakeStub(spanMin: 10,
                                                     asleepMin: SleepView.preOnsetStubAsleepMaxMin + 1))
    }

    /// #259: a leading fragment carrying SOME sleep (over the 3-min sleepless cap) but MINOR relative to the
    /// main block (below the fraction of the group's largest asleep span) is a spurious lead and IS a stub.
    /// Without a reference (default 0) the relative test is OFF, so the same fragment is NOT a stub — existing
    /// callers stay byte-identical.
    func testMinorRelativeLeadingFragmentIsStub() {
        // 30 min span, 10 asleep; main block asleep 400 -> 10 < 0.15*400 = 60 -> spurious.
        XCTAssertTrue(SleepView.isPreOnsetAwakeStub(spanMin: 30, asleepMin: 10, refAsleepMin: 400))
        XCTAssertFalse(SleepView.isPreOnsetAwakeStub(spanMin: 30, asleepMin: 10))
    }

    /// #259 guard: a substantial earlier sleep (comparable to the main block) is a genuine biphasic first
    /// sleep and is NEVER dropped, even with a reference size.
    func testSubstantialBiphasicFragmentIsNotStubEvenWithRef() {
        // 90 asleep vs main block 240 -> 90 >= 0.15*240 = 36 -> kept.
        XCTAssertFalse(SleepView.isPreOnsetAwakeStub(spanMin: 100, asleepMin: 90, refAsleepMin: 240))
    }

    /// #259 GOLDEN at the walk level: a minor leading SLEEP fragment (10 asleep, over the old 3-min cap but
    /// tiny next to the 400-asleep main block) is now skipped, so the displayed onset comes from the main
    /// block (index 1) instead of jumping to the stray 1am lead. Before this rule it returned 0.
    func testMinorLeadingSleepFragmentSkippedByOnsetIndex() {
        XCTAssertEqual(SleepView.nightOnsetIndex(spansMin: [30, 420], asleepsMin: [10, 400]), 1)
    }

    // MARK: - nightOnsetIndex (which fragment supplies the displayed bedtime)

    /// THE #736 GOLDEN: a two-fragment night where fragment 1 is a brief pre-sleep awake stub. The displayed
    /// onset must come from fragment 2 (the real sleep), the SAME fragment the pencil edits — not fragment 1
    /// (the 21:41 stub) the tab used to show.
    func testTwoFragmentNightWithLeadingAwakeStubPicksSecondFragment() {
        // fragment 0: 14 min, 0 asleep (the spurious stub). fragment 1: 7 hours, ~400 asleep (the real night).
        let onsetIdx = SleepView.nightOnsetIndex(spansMin: [14, 420], asleepsMin: [0, 400])
        XCTAssertEqual(onsetIdx, 1)
    }

    /// A normal single-block night is unchanged: index 0.
    func testSingleBlockNightUnchanged() {
        XCTAssertEqual(SleepView.nightOnsetIndex(spansMin: [430], asleepsMin: [415]), 0)
    }

    /// A genuine biphasic / interrupted night (both fragments are real sleep) keeps fragment 0 as the
    /// onset — we must NOT swallow a real first sleep block as if it were a stub (#555 stays intact).
    func testGenuineBiphasicNightKeepsFirstFragment() {
        // fragment 0: 90 min with 80 asleep (real sleep before a wake), fragment 1: the longer main block.
        XCTAssertEqual(SleepView.nightOnsetIndex(spansMin: [90, 300], asleepsMin: [80, 280]), 0)
    }

    /// Two leading stubs collapse: the onset walks to the first real-sleep fragment (index 2).
    func testTwoLeadingStubsWalkToFirstRealSleep() {
        XCTAssertEqual(SleepView.nightOnsetIndex(spansMin: [8, 12, 400], asleepsMin: [0, 1, 380]), 2)
    }

    /// Degenerate guard: an all-stub group (shouldn't reach the hero, mergeDay gates on asleep > 0) falls
    /// back to index 0 rather than returning an out-of-range value.
    func testAllStubGroupFallsBackToZero() {
        XCTAssertEqual(SleepView.nightOnsetIndex(spansMin: [5, 10], asleepsMin: [0, 0]), 0)
    }

    // MARK: - Real-night regression: a genuine short first sleep is NOT a spurious lead

    /// THE BUG (real 2026-07-14 night): a 67-min first-sleep fragment (12:16 → 1:22, ~34 asleep min) then a
    /// ~6-min walk then the main 1:29 → 7:32 sleep (~340 asleep). The two bridge into ONE night, and the
    /// Health write-back spans 12:16 → 7:32. But the #259 relative "minor lead" test compared 34 asleep min
    /// against 15% of the ~340-min main (≈51 min) and wrongly classified the real first sleep as a spurious
    /// lead, so the displayed onset jumped to the 1:29 main and HID the true 12:16 bedtime. The absolute
    /// asleep floor keeps a real sleep episode as the onset: index 0, the 12:16 fragment.
    func testRealFirstSleepFragmentIsTheDisplayedOnset() {
        // fragment: 66.8 span / 34 asleep. main: 363.6 span / 340 asleep.
        XCTAssertEqual(SleepView.nightOnsetIndex(spansMin: [66.8, 363.6], asleepsMin: [34, 340]), 0)
    }

    /// The per-fragment rule: a real 34-min sleep episode beside a 340-min main is NOT a stub, even though
    /// it is under 15% of the main (the old relative test's flaw for long nights). The floor is what keeps it.
    func testRealFirstSleepFragmentIsNotStub() {
        XCTAssertFalse(SleepView.isPreOnsetAwakeStub(spanMin: 66.8, asleepMin: 34, refAsleepMin: 340))
    }

    /// Floor boundary: a fragment carrying at least `preOnsetStubMinorAsleepFloorMin` asleep minutes is a
    /// real sleep episode and never a spurious lead, whatever the main block's size.
    func testAtMinorAsleepFloorIsNotStub() {
        XCTAssertFalse(SleepView.isPreOnsetAwakeStub(spanMin: 40,
                                                     asleepMin: SleepView.preOnsetStubMinorAsleepFloorMin,
                                                     refAsleepMin: 1000))
    }

    /// The floor does NOT reopen #736/#259: a tiny stray sleep lead (10 asleep, under the floor AND under
    /// 15% of a big main) is still a spurious lead, so those goldens above stay green.
    func testTinyStrayLeadStillStubUnderFloor() {
        XCTAssertTrue(SleepView.isPreOnsetAwakeStub(spanMin: 30, asleepMin: 10, refAsleepMin: 400))
    }
}
