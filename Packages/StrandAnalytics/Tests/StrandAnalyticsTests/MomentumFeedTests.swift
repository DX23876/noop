import XCTest
@testable import StrandAnalytics

/// The ordering behind the Today "Momentum" card: which single thing is worth saying now, and in what
/// order the rest follow onto the Momentum page. All of it is pure, so it is pinned here rather than
/// argued about against a live screen.
final class MomentumFeedTests: XCTestCase {

    private func msg(_ kind: MomentumKind, tone: MomentumTone = .neutral) -> MomentumMessage {
        MomentumMessage(kind: kind, tone: tone, headline: kind.rawValue, detail: "d")
    }

    /// 09:00 — a morning hour, so the morning nudge is the one in play unless a test says otherwise.
    private let morning = 9
    private let afternoon = 14
    private let evening = 20

    // MARK: - Tiers

    func testTierOrderBeatsEveryTimeOfDayNudge() {
        // A positive insight is favoured by the evening nudge; a time-critical goal is not. The goal
        // must still win — the nudge may only reorder WITHIN a tier.
        let out = MomentumFeed.rank([msg(.streak), msg(.planDeviation)], hour: evening)
        XCTAssertEqual(out.map(\.kind), [.planDeviation, .streak])
    }

    func testExplicitUserStatusOutranksEverything() {
        let out = MomentumFeed.rank([msg(.hrvTrend), msg(.stepGoal), msg(.statusOverride)], hour: afternoon)
        XCTAssertEqual(out.first?.kind, .statusOverride)
    }

    /// Every kind must declare a tier inside the documented range, or the nudge could leak across tiers.
    func testEveryKindHasATierInsideTheDocumentedRange() {
        for kind in MomentumKind.allCases {
            XCTAssertTrue((0...5).contains(kind.tier), "\(kind) sits outside the 0...5 tier ladder")
        }
    }

    // MARK: - Time of day

    /// THE POINT of the feature: the SAME candidate set reads differently at three times of day.
    func testSameCandidatesReorderAcrossTheDay() {
        let pool = [msg(.recoveryRead), msg(.stepGoal), msg(.sleepCatchUp)]
        XCTAssertEqual(MomentumFeed.rank(pool, hour: morning).first?.kind, .recoveryRead)
        XCTAssertEqual(MomentumFeed.rank(pool, hour: afternoon).first?.kind, .stepGoal)
        XCTAssertEqual(MomentumFeed.rank(pool, hour: evening).first?.kind, .sleepCatchUp)
    }

    /// The nudge may lift a message past the tier directly above it — that is what makes the afternoon
    /// step read able to beat the recovery read at all — but never past TWO tiers.
    func testNudgeCanCrossOneTierButNeverTwo() {
        for kind in MomentumKind.allCases {
            for hour in 0..<24 {
                let bonus = MomentumFeed.timeBonus(kind, hour: hour)
                XCTAssertTrue((0...MomentumFeed.maxBonus).contains(bonus),
                              "\(kind) at \(hour)h nudges by \(bonus), outside 0...maxBonus")
            }
        }
        XCTAssertLessThan(MomentumFeed.maxBonus, 2 * MomentumFeed.tierWeight,
                          "a nudge that crosses two tiers would let an insight outrank an urgent message")
    }

    /// The consequence that actually matters: at EVERY hour, an urgent (tier 0) or time-critical
    /// (tier 1) message still leads, however strongly the hour favours something else.
    func testUrgentAndTimeCriticalMessagesLeadAtEveryHour() {
        let distractions = MomentumKind.allCases.filter { $0.tier >= 2 }.map { msg($0) }
        for hour in 0..<24 {
            XCTAssertEqual(MomentumFeed.rank(distractions + [msg(.statusOverride)], hour: hour).first?.kind,
                           .statusOverride, "an explicit user status must lead at \(hour)h")
            XCTAssertEqual(MomentumFeed.rank(distractions + [msg(.planDeviation)], hour: hour).first?.kind,
                           .planDeviation, "a missed planned workout must lead at \(hour)h")
        }
    }

    // MARK: - Tone

    /// The regression this rule exists for: an afternoon step read is nudged hard, a rest-day warning is
    /// not — yet "you have had three straining days" is the more important thing to say.
    func testCriticalMessageOutranksAHardNudgedPeer() {
        let out = MomentumFeed.rank([msg(.stepGoal), msg(.restDayNeeded, tone: .critical)], hour: afternoon)
        XCTAssertEqual(out.first?.kind, .restDayNeeded)
    }

    /// Bounded on both sides: a critical message never displaces an explicit user statement, and it
    /// never reaches two tiers up.
    func testCriticalToneIsBounded() {
        XCTAssertLessThan(MomentumFeed.criticalBonus, MomentumFeed.tierWeight)
        for hour in 0..<24 {
            let out = MomentumFeed.rank([msg(.streak, tone: .critical), msg(.statusOverride)], hour: hour)
            XCTAssertEqual(out.first?.kind, .statusOverride,
                           "an explicit user status must still lead at \(hour)h")
        }
    }

    func testHourIsNormalisedSoNoInputTraps() {
        XCTAssertEqual(MomentumFeed.timeBonus(.stepGoal, hour: 14),
                       MomentumFeed.timeBonus(.stepGoal, hour: 38))
        XCTAssertEqual(MomentumFeed.timeBonus(.stepGoal, hour: 14),
                       MomentumFeed.timeBonus(.stepGoal, hour: -10))
    }

    // MARK: - Hysteresis

    func testIncumbentHoldsTheCardDuringItsDwell() {
        let now = Date()
        let last = MomentumLastShown(kind: .stepGoal, at: now.addingTimeInterval(-10 * 60))
        // Morning, so recoveryRead outranks stepGoal by a whole tier — but the dwell has not passed.
        let out = MomentumFeed.rank([msg(.recoveryRead), msg(.stepGoal)],
                                    hour: morning, lastShown: last, now: now)
        XCTAssertEqual(out.first?.kind, .stepGoal, "the card must not change under the reader")
        XCTAssertEqual(out.count, 2, "the challenger is held behind it, not dropped")
    }

    func testChallengerTakesTheCardOnceTheDwellHasPassed() {
        let now = Date()
        let last = MomentumLastShown(kind: .stepGoal,
                                     at: now.addingTimeInterval(-MomentumFeed.minDwellSeconds - 60))
        let out = MomentumFeed.rank([msg(.recoveryRead), msg(.stepGoal)],
                                    hour: morning, lastShown: last, now: now)
        XCTAssertEqual(out.first?.kind, .recoveryRead)
    }

    /// A near-equal rival must NOT take the card even after the dwell, or two candidates inside one tier
    /// trade places every time an input twitches.
    func testNearEqualRivalDoesNotTakeTheCardAfterTheDwell() {
        let now = Date()
        let last = MomentumLastShown(kind: .weightMilestone,
                                     at: now.addingTimeInterval(-MomentumFeed.minDwellSeconds - 60))
        // Both are tier 2 and neither is nudged at this hour, so the margin is 0.
        let out = MomentumFeed.rank([msg(.milestone), msg(.weightMilestone)],
                                    hour: morning, lastShown: last, now: now)
        XCTAssertEqual(out.first?.kind, .weightMilestone)
    }

    /// Something actually wrong interrupts. A dwell timer is not a reason to stay quiet about it.
    func testCriticalMessageBreaksTheDwell() {
        let now = Date()
        let last = MomentumLastShown(kind: .stepGoal, at: now.addingTimeInterval(-60))
        let out = MomentumFeed.rank([msg(.restDayNeeded, tone: .critical), msg(.stepGoal)],
                                    hour: afternoon, lastShown: last, now: now)
        XCTAssertEqual(out.first?.kind, .restDayNeeded)
    }

    /// A critical incumbent is not displaced by another critical message — otherwise two critical
    /// candidates would swap the card on every pass, which is the flicker the dwell exists to stop.
    func testCriticalIncumbentStillHoldsAgainstAnotherCritical() {
        let now = Date()
        let last = MomentumLastShown(kind: .stepGoal, at: now.addingTimeInterval(-60))
        let out = MomentumFeed.rank([msg(.restDayNeeded, tone: .critical), msg(.stepGoal, tone: .critical)],
                                    hour: afternoon, lastShown: last, now: now)
        XCTAssertEqual(out.first?.kind, .stepGoal)
    }

    /// An incumbent whose message no longer applies simply loses the card — it must not be resurrected.
    func testIncumbentThatIsNoLongerACandidateIsNotRestored() {
        let now = Date()
        let last = MomentumLastShown(kind: .stepGoal, at: now.addingTimeInterval(-60))
        let out = MomentumFeed.rank([msg(.recoveryRead)], hour: morning, lastShown: last, now: now)
        XCTAssertEqual(out.map(\.kind), [.recoveryRead])
    }

    // MARK: - Honesty and stability

    func testEmptyInputYieldsNothingRatherThanAFillerMessage() {
        XCTAssertTrue(MomentumFeed.rank([], hour: morning).isEmpty)
    }

    func testPastDayDropsEveryActionableKind() {
        let pool = [msg(.stepGoal), msg(.planDeviation), msg(.recoveryRead), msg(.hrvTrend)]
        let out = MomentumFeed.rank(pool, hour: afternoon, retrospective: true)
        XCTAssertEqual(Set(out.map(\.kind)), [.recoveryRead, .hrvTrend])
        XCTAssertTrue(out.allSatisfy(\.kind.isRetrospective))
    }

    func testPastDayWithOnlyActionableKindsYieldsNothing() {
        let out = MomentumFeed.rank([msg(.stepGoal), msg(.planDeviation)],
                                    hour: afternoon, retrospective: true)
        XCTAssertTrue(out.isEmpty, "a past day must not be told to walk 2,340 more steps")
    }

    /// The Momentum page renders the whole list, so equal-scoring candidates must not shuffle between
    /// two runs over identical input.
    func testEqualScoresKeepTheirInputOrder() {
        let pool = [msg(.milestone), msg(.weightMilestone)]
        for _ in 0..<20 {
            XCTAssertEqual(MomentumFeed.rank(pool, hour: morning).map(\.kind),
                           [.milestone, .weightMilestone])
        }
    }

    func testRankReturnsEveryCandidateNotJustTheWinner() {
        let pool = [msg(.streak), msg(.stepGoal), msg(.recoveryRead), msg(.planDeviation)]
        XCTAssertEqual(MomentumFeed.rank(pool, hour: morning).count, pool.count)
    }

    // MARK: - Progress

    /// The card shows the percentage and the dashboard the counts, so the card's chip cannot repeat
    /// what its own detail line already said.
    func testProgressOffersBothWaysOfSayingIt() {
        let p = MomentumProgress(fraction: 0.766, label: "7,660 / 10,000")
        XCTAssertEqual(p.percentText, "77 %")
        XCTAssertEqual(p.label, "7,660 / 10,000")
    }

    func testProgressFractionIsClamped() {
        XCTAssertEqual(MomentumProgress(fraction: 1.8, label: "x").percentText, "100 %")
        XCTAssertEqual(MomentumProgress(fraction: -0.4, label: "x").percentText, "0 %")
    }

    // MARK: - Imagery

    func testEverySceneLookupResolvesOrHonestlyReturnsNil() {
        for kind in MomentumKind.allCases {
            // Must not trap, and a mapped name must be one of the real day-cycle assets.
            if let name = MomentumScene.assetName(for: kind) {
                XCTAssertTrue(name.hasPrefix("scene"), "\(kind) maps to an unknown asset \(name)")
            }
        }
    }

    func testSceneLookupIsStable() {
        for kind in MomentumKind.allCases {
            XCTAssertEqual(MomentumScene.assetName(for: kind), MomentumScene.assetName(for: kind))
        }
    }
}
