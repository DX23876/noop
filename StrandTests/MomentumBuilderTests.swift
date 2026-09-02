import XCTest
import StrandAnalytics
import StrandDesign
import WhoopStore
@testable import Strand

/// What the Momentum card is allowed to SAY. `MomentumFeed` decides the order; this decides whether
/// there is anything true to say at all, which is where the honesty rules live.
final class MomentumBuilderTests: XCTestCase {

    private func day(_ key: String, recovery: Double? = nil, strain: Double? = nil,
                     steps: Int? = nil, hrv: Double? = nil, sleepMin: Double? = nil) -> DailyMetric {
        DailyMetric(day: key, totalSleepMin: sleepMin, efficiency: nil, deepMin: nil, remMin: nil,
                    lightMin: nil, disturbances: nil, restingHr: nil, avgHrv: hrv, recovery: recovery,
                    strain: strain, exerciseCount: nil, spo2Pct: nil, skinTempDevC: nil,
                    respRateBpm: nil, steps: steps, activeKcalEst: nil)
    }

    private func kinds(_ i: MomentumBuilder.Inputs) -> Set<MomentumKind> {
        Set(MomentumBuilder.candidates(i).map(\.kind))
    }

    // MARK: - The honesty rules

    func testEmptyInputSaysNothing() {
        XCTAssertTrue(MomentumBuilder.candidates(MomentumBuilder.Inputs()).isEmpty,
                      "with no data the card must fall silent, not invent a message")
    }

    /// A remaining-step count off an unvalidated strap ESTIMATE would be a fabricated number. The
    /// qualitative read is still allowed; the countdown is not.
    func testEstimatedStepsNeverProduceARemainingCount() {
        var i = MomentumBuilder.Inputs()
        i.measuredSteps = 4_000
        i.stepsAreEstimated = true
        i.stepGoal = 10_000
        i.typicalSteps = 9_000
        let out = MomentumBuilder.candidates(i)
        XCTAssertFalse(out.contains { $0.kind == .stepGoal },
                       "a remaining count must not be quoted off an estimate")
        XCTAssertTrue(out.contains { $0.kind == .stepsBelowUsual })
        XCTAssertNil(out.first { $0.kind == .stepsBelowUsual }?.progress,
                     "an estimate carries no progress bar either")
    }

    func testNoStepGoalMeansNoStepGoalMessage() {
        var i = MomentumBuilder.Inputs()
        i.measuredSteps = 4_000
        XCTAssertFalse(kinds(i).contains(.stepGoal))
    }

    /// The user's own example: "2,340 steps to your goal", with the walking estimate beside it.
    func testMeasuredStepsProduceTheCountdown() {
        var i = MomentumBuilder.Inputs()
        i.measuredSteps = 7_660
        i.stepGoal = 10_000
        guard let m = MomentumBuilder.candidates(i).first(where: { $0.kind == .stepGoal }) else {
            return XCTFail("expected a step-goal message")
        }
        XCTAssertTrue(m.headline.contains("2340") || m.headline.contains("2,340"),
                      "headline should name the remaining steps, got: \(m.headline)")
        XCTAssertEqual(m.progress?.label, "7660 / 10000")
        XCTAssertEqual(m.progress?.fraction ?? 0, 0.766, accuracy: 0.001)
    }

    func testReachedGoalReadsPositiveRatherThanANegativeRemainder() {
        var i = MomentumBuilder.Inputs()
        i.measuredSteps = 11_000
        i.stepGoal = 10_000
        let m = MomentumBuilder.candidates(i).first { $0.kind == .stepGoal }
        XCTAssertEqual(m?.tone, .positive)
        XCTAssertEqual(m?.progress?.fraction, 1)
    }

    /// A past day must never be told to go for a walk. (The feed filters too; the builder simply does
    /// not manufacture the candidate in the first place.)
    func testPastDayProducesNoActivityMessages() {
        var i = MomentumBuilder.Inputs()
        i.isToday = false
        i.measuredSteps = 4_000
        i.stepGoal = 10_000
        i.sleepNeedHours = 8
        i.weekSleepHours = [5, 5, 5, 5, 5, 5, 5]
        let out = kinds(i)
        XCTAssertFalse(out.contains(.stepGoal))
        XCTAssertFalse(out.contains(.sleepCatchUp))
    }

    // MARK: - Urgency is "is there a candidate"

    /// The rule that keeps the daily rotation alive: a weekly goal is time-critical only when the week
    /// is actually running out. Emitted every day, it would sit at the top of the card all week.
    func testWeeklyGoalOnlySpeaksWhenTheWeekIsRunningOut() {
        var i = MomentumBuilder.Inputs()
        i.weekSessionsPlanned = 3
        i.weekSessionsDone = 1
        i.daysLeftInWeek = 5
        XCTAssertFalse(kinds(i).contains(.weeklyTrainingGoal), "not urgent with five days left")

        i.daysLeftInWeek = 2
        XCTAssertTrue(kinds(i).contains(.weeklyTrainingGoal))
    }

    func testCompletedWeekSaysNothing() {
        var i = MomentumBuilder.Inputs()
        i.weekSessionsPlanned = 3
        i.weekSessionsDone = 3
        i.daysLeftInWeek = 1
        XCTAssertFalse(kinds(i).contains(.weeklyTrainingGoal))
    }

    func testLastDayOfTheWeekReadsAsCaution() {
        var i = MomentumBuilder.Inputs()
        i.weekSessionsPlanned = 3
        i.weekSessionsDone = 2
        i.daysLeftInWeek = 1
        let m = MomentumBuilder.candidates(i).first { $0.kind == .weeklyTrainingGoal }
        XCTAssertEqual(m?.tone, .caution)
        XCTAssertEqual(m?.progress?.label, "2 / 3")
    }

    // MARK: - Tone comes from the same band as the ring

    func testRecoveryToneFollowsTheChargeBand() {
        XCTAssertEqual(MomentumBuilder.tone(forCharge: 20), .critical)
        XCTAssertEqual(MomentumBuilder.tone(forCharge: 40), .caution)
        XCTAssertEqual(MomentumBuilder.tone(forCharge: 62), .neutral)
        XCTAssertEqual(MomentumBuilder.tone(forCharge: 75), .positive)
        XCTAssertEqual(MomentumBuilder.tone(forCharge: 95), .positive)
    }

    /// A bad recovery must read red and a good one green — the user's own example of what the card
    /// should do, and the reason tone exists at all.
    func testRecoveryReadCarriesItsBandTone() {
        var i = MomentumBuilder.Inputs()
        i.recoveryRead = (headline: "h", detail: "d")
        i.day = day("2026-08-30", recovery: 91)
        XCTAssertEqual(MomentumBuilder.candidates(i).first?.tone, .positive)
        i.day = day("2026-08-30", recovery: 18)
        XCTAssertEqual(MomentumBuilder.candidates(i).first?.tone, .critical)
    }

    // MARK: - Multi-day reads

    func testStrainingRunIsCountedFromTheMostRecentDayBackwards() {
        let days = [day("2026-08-25", strain: 80), day("2026-08-26", strain: 20),
                    day("2026-08-27", strain: 75), day("2026-08-28", strain: 70),
                    day("2026-08-29", strain: 65)]
        XCTAssertEqual(MomentumBuilder.strainingRun(days), 3, "the run breaks at the easy day, not before it")
    }

    func testStrainingRunOfThreeReadsCritical() {
        var i = MomentumBuilder.Inputs()
        i.strainingDaysInARow = 3
        let m = MomentumBuilder.candidates(i).first { $0.kind == .restDayNeeded }
        XCTAssertEqual(m?.tone, .critical, "this is the one read that must be able to interrupt")
    }

    func testTwoHardDaysAreNotYetWorthSaying() {
        var i = MomentumBuilder.Inputs()
        i.strainingDaysInARow = 2
        XCTAssertFalse(kinds(i).contains(.restDayNeeded))
    }

    func testHrvRunNeedsEnoughHistoryBeforeItClaimsATrend() {
        var i = MomentumBuilder.Inputs()
        i.recentDays = (0..<5).map { day("d\($0)", hrv: 60) }
        XCTAssertNil(MomentumBuilder.hrvRun(i), "five nights is not a trend")
    }

    func testHrvRunReportsTheCurrentSideAndItsLength() {
        var i = MomentumBuilder.Inputs()
        // Seven low nights then four clearly high ones: the run is the four, above the mean.
        i.recentDays = (0..<7).map { day("lo\($0)", hrv: 50) } + (0..<4).map { day("hi\($0)", hrv: 90) }
        let run = MomentumBuilder.hrvRun(i)
        XCTAssertEqual(run?.days, 4)
        XCTAssertEqual(run?.above, true)
    }

    // MARK: - Sleep

    func testSleepOwedNeedsANeedToMeasureAgainst() {
        var i = MomentumBuilder.Inputs()
        i.weekSleepHours = [6, 6, 6]
        XCTAssertNil(MomentumBuilder.sleepOwedMinutes(i), "no personal need means no debt claim")
    }

    func testSleepOwedSumsOnlyTheShortfall() {
        var i = MomentumBuilder.Inputs()
        i.sleepNeedHours = 8
        i.weekSleepHours = [7, 9, 7.5]   // 1h + 0 + 0.5h short — the long night must not pay off the debt
        XCTAssertEqual(MomentumBuilder.sleepOwedMinutes(i), 90)
    }

    /// A week's debt in raw minutes ("About 339 min behind") is arithmetically right and useless to
    /// read. Anything past an hour reads in hours.
    func testDurationTextIsReadablePastAnHour() {
        XCTAssertEqual(MomentumBuilder.durationText(45), "45 min")
        XCTAssertEqual(MomentumBuilder.durationText(120), "2 h")
        XCTAssertEqual(MomentumBuilder.durationText(339), "5 h 39 min")
    }

    /// The advice must stay doable: chasing a whole week's debt in one night is not something anyone does.
    func testBedtimeShiftIsCappedAndRounded() {
        XCTAssertEqual(MomentumBuilder.bedtimeShiftMinutes(90), 30)
        XCTAssertEqual(MomentumBuilder.bedtimeShiftMinutes(20), 15, "never advises a pointless nudge")
        XCTAssertLessThanOrEqual(MomentumBuilder.bedtimeShiftMinutes(600), 60, "never advises the impossible")
    }

    // MARK: - Plan and training suggestion

    func testOpenPlannedSessionSpeaksOnlyToday() {
        var i = MomentumBuilder.Inputs()
        i.openPlannedSessionToday = "Run"
        XCTAssertTrue(kinds(i).contains(.planDeviation))
        i.isToday = false
        XCTAssertFalse(kinds(i).contains(.planDeviation), "a past day cannot still have an open session")
    }

    /// The suggestion needs BOTH halves. Recovery alone would tell someone to push in the middle of an
    /// already-heavy week, which is how a training app talks people into digging a hole.
    func testTrainingSuggestionNeedsHighRecoveryAndAModerateWeek() {
        var i = MomentumBuilder.Inputs()
        i.day = day("2026-08-30", recovery: 90)
        i.weekLoadRatio = 1.4
        XCTAssertFalse(kinds(i).contains(.trainingSuggestion), "not during a heavy week")

        i.weekLoadRatio = 0.8
        XCTAssertTrue(kinds(i).contains(.trainingSuggestion))

        i.day = day("2026-08-30", recovery: 55)
        XCTAssertFalse(kinds(i).contains(.trainingSuggestion), "not on a middling recovery")
    }

    /// The screen must never advise a hard session and a rest day at the same time.
    func testTrainingSuggestionStaysQuietWhileARestDayIsUrged() {
        var i = MomentumBuilder.Inputs()
        i.day = day("2026-08-30", recovery: 92)
        i.weekLoadRatio = 0.7
        i.strainingDaysInARow = 3
        let out = kinds(i)
        XCTAssertTrue(out.contains(.restDayNeeded))
        XCTAssertFalse(out.contains(.trainingSuggestion),
                       "advising a push and a rest day at once would contradict itself")
    }

    /// "A lot of load" only means something relative to what this person usually does, and that needs
    /// history. A new user's first quiet week must not read as a licence to push.
    func testWeekLoadRatioNeedsHistory() {
        let short = (0..<20).map { day("d\($0)", strain: 50) }
        XCTAssertNil(MomentumBuilder.weekLoadRatio(short))

        let heavyWeek = (0..<28).map { day("p\($0)", strain: 40) } + (0..<7).map { day("w\($0)", strain: 80) }
        guard let ratio = MomentumBuilder.weekLoadRatio(heavyWeek) else { return XCTFail("expected a ratio") }
        XCTAssertGreaterThan(ratio, 1.5, "a week at double the usual load must read as heavy")
    }

    // MARK: - Dashboard grouping

    /// The dashboard groups by the SAME ladder the feed ranks by, so the page's sections and the card's
    /// ordering cannot drift apart. Every kind must land in exactly one group.
    func testEveryKindLandsInExactlyOneDashboardTier() {
        for kind in MomentumKind.allCases {
            let matches = MomentumTier.allCases.filter { $0.contains(kind) }
            XCTAssertEqual(matches.count, 1, "\(kind) matched \(matches.count) dashboard groups")
        }
    }

    func testEveryKindHasItsOwnSymbol() {
        let symbols = MomentumKind.allCases.map(MomentumSymbol.name(for:))
        XCTAssertFalse(symbols.contains(""), "every kind needs a symbol")
        XCTAssertEqual(Set(symbols).count, symbols.count,
                       "two kinds sharing a symbol would be indistinguishable on the dashboard")
    }

    // MARK: - The memo key

    /// The feed is resolved in a `.task(id:)` instead of the view body, because the body recomposes
    /// with live heart rate. `hour` is the load-bearing member of that key: the time-of-day weighting is
    /// the only input that moves without new data, so a key without it would freeze the card on whatever
    /// it said at launch — the optimisation would switch off the feature it optimises.
    func testMemoKeyChangesWithTheHour() {
        let nine = key(hour: 9)
        XCTAssertNotEqual(nine, key(hour: 14), "the card must be able to rotate through the day")
        XCTAssertEqual(nine, key(hour: 9), "the same hour must not churn the feed")
    }

    func testMemoKeyChangesForEveryInputThatCanChangeTheFeed() {
        let base = key()
        XCTAssertNotEqual(base, key(refreshSeq: 2), "new data")
        XCTAssertNotEqual(base, key(dayOffset: -1), "a navigated day")
        XCTAssertNotEqual(base, key(lastShownKind: "stepGoal"), "the dwell bookkeeping")
        XCTAssertNotEqual(base, key(snoozed: "2026-08-30|streak"), "a snooze")
        XCTAssertNotEqual(base, key(statusState: "sick"), "an explicit user status")
        XCTAssertNotEqual(base, key(goalsUpdatedAt: Date(timeIntervalSince1970: 99)), "goal progress")
    }

    /// And the point of the whole thing: an ordinary body pass changes nothing, so nothing is rebuilt.
    func testMemoKeyIsStableAcrossAnOrdinaryBodyPass() {
        XCTAssertEqual(key(), key())
    }

    private func key(refreshSeq: Int = 1, dayOffset: Int = 0, hour: Int = 9,
                     lastShownKind: String = "recoveryRead", snoozed: String = "",
                     goalsUpdatedAt: Date? = Date(timeIntervalSince1970: 0),
                     statusState: String = "active") -> TodayView.MomentumKey {
        TodayView.MomentumKey(refreshSeq: refreshSeq, dayOffset: dayOffset, hour: hour,
                              lastShownKind: lastShownKind, snoozed: snoozed,
                              goalsUpdatedAt: goalsUpdatedAt, statusState: statusState)
    }

    // MARK: - One row for the whole recovery read

    /// The headline used to be resolved from the carried last-scored day while the delta and the tone
    /// came from the DISPLAYED day — so a carried read showed a "% over baseline" headline with no chip,
    /// and a carried BAD recovery rendered neutral. Everything must come from one row.
    func testCarriedRecoveryUsesOneRowForHeadlineDeltaAndTone() {
        let carried = day("2026-08-15", recovery: 18, hrv: 90)
        let history = (0..<20).map { day("h\($0)", recovery: 60, hrv: 50) }

        let subject = MomentumCopy.subjectRow(displayed: nil, lastScored: carried)
        XCTAssertEqual(subject?.day, carried.day)

        let delta = MomentumCopy.baselineDeltaPct(row: subject, allDays: history + [carried],
                                                  fallbackDayKey: "2026-08-30")
        XCTAssertNotNil(delta, "the delta must resolve from the same row the headline used")

        var i = MomentumBuilder.Inputs()
        i.day = subject
        i.recoveryRead = (headline: "h", detail: "d")
        XCTAssertEqual(MomentumBuilder.candidates(i).first?.tone, .critical,
                       "a carried bad recovery must not read neutral")
    }

    /// The shipped card said "Latest sleep · 15 Aug..", because the caption already ends in a period and
    /// the detail appended another.
    func testCarriedDetailEndsInExactlyOnePeriod() {
        let row = day("2026-08-15", recovery: 62, sleepMin: 400)
        let detail = MomentumCopy.detail(row: row, allDays: [row], fallbackDayKey: "2026-08-30",
                                         carriedCaption: "Latest sleep · 15 Aug.")
        XCTAssertTrue(detail.hasSuffix("Aug."), "got: \(detail)")
        XCTAssertFalse(detail.hasSuffix(".."), "the caption's own period must not be doubled")
    }

    func testDetailWithoutACarriedCaptionIsUnchanged() {
        let row = day("2026-08-30", recovery: 62, sleepMin: 400)
        let plain = MomentumCopy.detail(row: row, allDays: [row], fallbackDayKey: "2026-08-30",
                                        carriedCaption: nil)
        XCTAssertFalse(plain.isEmpty)
        XCTAssertFalse(plain.contains("·"))
    }

    /// A caption that does NOT already end in a period still gets one.
    func testCaptionWithoutAPeriodStillGetsOne() {
        let row = day("2026-08-15", recovery: 62)
        let detail = MomentumCopy.detail(row: row, allDays: [row], fallbackDayKey: "2026-08-30",
                                         carriedCaption: "Last night · 15 August")
        XCTAssertTrue(detail.hasSuffix("August."), "got: \(detail)")
    }

    // MARK: - Tone routes through the ONE tone-to-colour mapping

    /// `MomentumTint` used to run its own switch, and `.neutral` fell to the CHROME accent (brand mint)
    /// instead of a data colour — a neutral message rendered in a third green beside Charge's real
    /// value-coloured green. It now maps onto `StrandTone`, the same vocabulary `StatePill` and the
    /// Goals tile already use, so Momentum can never disagree with the rest of the app about what a
    /// tone looks like. A `CaseIterable` sweep so a tone added later cannot fall through unmapped.
    func testEveryMomentumToneMapsToAStrandTone() {
        let expected: [MomentumTone: StrandTone] = [
            .positive: .positive, .neutral: .neutral, .caution: .warning, .critical: .critical,
        ]
        for tone in MomentumTone.allCases {
            XCTAssertEqual(MomentumTint.strandTone(for: tone), expected[tone],
                           "\(tone) must map to \(String(describing: expected[tone]))")
        }
    }

    /// The regression itself: neutral must NOT resolve to the chrome accent. `StrandTone.neutral` is
    /// `StrandPalette.textSecondary`, a muted grey — this pins the STATUS-TOKEN choice (comparable,
    /// unlike two `Color` reads) rather than asserting on `Color` equality.
    func testNeutralIsNotTheChromeAccent() {
        XCTAssertEqual(MomentumTint.strandTone(for: .neutral), .neutral)
        XCTAssertNotEqual(MomentumTint.strandTone(for: .neutral), .accent)
    }

    // MARK: - Layout key must survive the rename

    /// The card is now called "Momentum", but `TodaySection.synthesis`'s rawValue is the PERSISTED key in
    /// `today.sectionOrder`, and unknown tokens are dropped on load. Renaming the case would silently
    /// reset the saved layout of every user who ever reordered Today.
    func testSynthesisSectionKeepsItsPersistedKeyAfterTheRename() {
        XCTAssertEqual(TodaySection.synthesis.rawValue, "synthesis")
        let restored = TodayLayoutPrefs.decodeOrder("hero,synthesis,keyMetrics")
        XCTAssertTrue(restored.contains(.synthesis),
                      "a saved order written before the rename must still resolve")
    }
}
