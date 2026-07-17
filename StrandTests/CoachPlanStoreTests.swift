import XCTest
@testable import Strand
import StrandAnalytics

/// The plan state machine and the consequence maths.
///
/// The property this file exists to defend: **the model cannot make a plan active.** It can only ever
/// propose; every path to `accepted` runs through a user action. A coach that quietly writes down what
/// it decided for you isn't a coach.
@MainActor
final class CoachPlanStoreTests: XCTestCase {

    private func makeStore() -> CoachPlanStore {
        // `loading: false` skips the on-disk read, so tests never touch the real plan file.
        CoachPlanStore(loading: false)
    }

    private func proposal(day: String = "2026-07-16",
                          sport: String = "Zone 2 ride",
                          intent: PlanProposal.Intent = .easy) -> PlanProposal {
        PlanProposal(day: day, sport: sport, intent: intent)
    }

    // MARK: - Nothing becomes active on its own

    /// The heart of it: a coach suggestion lands as a proposal and STAYS there.
    func testProposedSessionIsNotACommitment() {
        let store = makeStore()
        store.propose(proposal())

        XCTAssertEqual(store.proposals.first?.status, .proposed)
        XCTAssertFalse(store.proposals.first?.status.isCommitment ?? true,
                       "a proposal the user hasn't answered must never count as a commitment")
        XCTAssertEqual(store.pending.count, 1)
        XCTAssertTrue(store.commitments(fromDay: "2026-01-01").isEmpty)
    }

    /// `propose` cannot be talked into creating an accepted plan, whatever status it's handed — this is
    /// the one entry point the model can reach, so it force-resets the status.
    func testProposeForcesProposedStatusEvenIfHandedAnother() {
        let store = makeStore()
        var sneaky = proposal()
        sneaky.status = .accepted
        store.propose(sneaky)

        XCTAssertEqual(store.proposals.first?.status, .proposed,
                       "the model must not be able to pre-accept its own suggestion")
    }

    func testAcceptIsWhatMakesItACommitment() {
        let store = makeStore()
        store.propose(proposal())
        let id = store.proposals[0].id

        store.accept(id)
        XCTAssertEqual(store.proposals[0].status, .accepted)
        XCTAssertTrue(store.proposals[0].status.isCommitment)
        XCTAssertNotNil(store.proposals[0].decidedAt)
        XCTAssertTrue(store.pending.isEmpty)
    }

    /// `clearTime` undoes a set time without touching status — the counterpart PlanTimeSheet's "Set"
    /// was missing (B3). It must not decide anything else about the session.
    func testClearTimeRemovesOnlyTheTimeNotTheDecision() {
        let store = makeStore()
        store.propose(proposal())
        let id = store.proposals[0].id
        store.accept(id, at: Date().addingTimeInterval(3600))
        XCTAssertNotNil(store.proposals[0].time)

        store.clearTime(id)

        XCTAssertNil(store.proposals[0].time)
        XCTAssertEqual(store.proposals[0].status, .accepted, "clearing the time is not un-accepting")
    }

    /// A user planning their own session doesn't need to approve their own idea.
    func testUserCreatedSessionIsAcceptedImmediately() {
        let store = makeStore()
        store.addUserSession(day: "2026-07-16", time: nil, sport: "CrossFit", intent: .hard)

        XCTAssertEqual(store.proposals[0].status, .accepted)
        XCTAssertEqual(store.proposals[0].source, .userCreated)
    }

    // MARK: - Decline / skip carry information

    /// A decline is kept, not deleted — the filter-bubble floor needs to know it happened.
    func testDeclineIsRecordedNotDiscarded() {
        let store = makeStore()
        store.propose(proposal())
        store.decline(store.proposals[0].id)

        XCTAssertEqual(store.proposals.count, 1)
        XCTAssertEqual(store.proposals[0].status, .declined)
        XCTAssertFalse(store.proposals[0].status.isCommitment)
    }

    /// Without a floor, a run of "not today"s would train the coach into never asking for anything
    /// again — which feels supportive and is actually abandonment.
    func testDeclineStreakCountsConsecutiveDeclines() {
        let store = makeStore()
        for i in 0..<3 {
            store.propose(proposal(day: "2026-07-1\(i)"))
            store.decline(store.proposals[0].id)
        }
        XCTAssertGreaterThanOrEqual(store.declineStreak, CoachPlanStore.declineStreakFloor)
    }

    /// An acceptance breaks the streak — the coach shouldn't still be apologising after you said yes.
    func testAcceptingBreaksTheDeclineStreak() {
        let store = makeStore()
        store.propose(proposal(day: "2026-07-10"))
        store.decline(store.proposals[0].id)
        store.propose(proposal(day: "2026-07-11"))
        store.accept(store.proposals[0].id)

        XCTAssertEqual(store.declineStreak, 0)
    }

    /// Pain and illness are the body talking; the coach doesn't get to argue with that.
    func testPainAndIllnessTriggerCaution() {
        XCTAssertTrue(PlanProposal.SkipReason.pain.triggersCaution)
        XCTAssertTrue(PlanProposal.SkipReason.ill.triggersCaution)
        XCTAssertFalse(PlanProposal.SkipReason.noTime.triggersCaution)
        XCTAssertFalse(PlanProposal.SkipReason.notFeelingIt.triggersCaution)
    }

    func testRecentPainSkipIsSurfacedAsCaution() {
        let store = makeStore()
        store.propose(proposal())
        store.skip(store.proposals[0].id, reason: .pain)

        XCTAssertNotNil(store.recentCautionSkip(), "a recent pain skip must be visible to the coach")
        XCTAssertEqual(store.recentCautionSkip()?.skipReason, .pain)
    }

    /// "No time" is a calendar problem, not a body one — it must not gate training.
    func testNoTimeSkipIsNotACaution() {
        let store = makeStore()
        store.propose(proposal())
        store.skip(store.proposals[0].id, reason: .noTime)
        XCTAssertNil(store.recentCautionSkip())
    }

    func testOldCautionSkipFallsOutOfTheWindow() {
        let store = makeStore()
        store.propose(proposal())
        store.skip(store.proposals[0].id, reason: .pain)
        // A skip from a fortnight ago shouldn't still be suppressing training today.
        let future = Date().addingTimeInterval(14 * 24 * 3600)
        XCTAssertNil(store.recentCautionSkip(withinDays: 7, now: future))
    }

    // MARK: - Swap

    func testSwapRemembersWhatItReplaced() {
        let store = makeStore()
        store.propose(proposal(sport: "Zone 2 ride"))
        store.swap(store.proposals[0].id, toSport: "CrossFit", intent: .hard)

        XCTAssertEqual(store.proposals[0].sport, "CrossFit")
        XCTAssertEqual(store.proposals[0].swappedFrom, "Zone 2 ride")
        XCTAssertEqual(store.proposals[0].intent, .hard)
        XCTAssertEqual(store.proposals[0].status, .modifiedByUser)
        XCTAssertTrue(store.proposals[0].status.isCommitment,
                      "changing a session is still agreeing to train")
    }

    /// Swapping twice must keep the ORIGINAL, not the intermediate — otherwise the story of what the
    /// coach actually suggested is lost.
    func testSwappingTwiceKeepsTheOriginalSport() {
        let store = makeStore()
        store.propose(proposal(sport: "Zone 2 ride"))
        let id = store.proposals[0].id
        store.swap(id, toSport: "CrossFit")
        store.swap(id, toSport: "Swim")

        XCTAssertEqual(store.proposals[0].sport, "Swim")
        XCTAssertEqual(store.proposals[0].swappedFrom, "Zone 2 ride")
    }

    // MARK: - Consequence maths

    /// The swap moment: the app tells you what your OWN history says each option costs, then stops.
    func testOutlookReportsCostFromTheUsersOwnHistory() {
        var inputs = PlanConsequence.Inputs()
        // 10 rest days at ~70, and 6 CrossFit days each followed by a ~50 morning.
        var recovery: [String: Double] = [:]
        for i in 1...10 { recovery[String(format: "2026-05-%02d", i)] = 70 }
        var crossfitDays: Set<String> = []
        for i in 0..<6 {
            let day = String(format: "2026-06-%02d", 1 + i * 3)
            let next = String(format: "2026-06-%02d", 2 + i * 3)
            crossfitDays.insert(day)
            recovery[day] = 68
            recovery[next] = 50
        }
        inputs.recoveryByDay = recovery
        inputs.activityDaysBySport = ["CrossFit": crossfitDays]

        let outlook = PlanConsequence.outlook(sport: "CrossFit", plannedEffort: nil, inputs: inputs)
        XCTAssertNotNil(outlook.chargeCost, "with 6 tagged sessions there's enough to report a cost")
        XCTAssertGreaterThan(outlook.chargeCost ?? 0, 0, "a session followed by a worse morning costs you")
        XCTAssertEqual(outlook.sampleCount, 6)
        XCTAssertTrue(outlook.sentence().contains("CrossFit"))
    }

    /// Sport names come from the user's own history, so "crossfit" and "CrossFit" are the same session.
    func testOutlookMatchesSportCaseInsensitively() {
        var inputs = PlanConsequence.Inputs()
        var recovery: [String: Double] = [:]
        for i in 1...10 { recovery[String(format: "2026-05-%02d", i)] = 70 }
        var days: Set<String> = []
        for i in 0..<6 {
            let day = String(format: "2026-06-%02d", 1 + i * 3)
            days.insert(day)
            recovery[day] = 68
            recovery[String(format: "2026-06-%02d", 2 + i * 3)] = 50
        }
        inputs.recoveryByDay = recovery
        inputs.activityDaysBySport = ["CrossFit": days]

        XCTAssertNotNil(PlanConsequence.outlook(sport: "crossfit", plannedEffort: nil, inputs: inputs).chargeCost)
    }

    /// Thin evidence must say so rather than produce a confident number.
    func testOutlookWithoutHistorySaysSoInsteadOfGuessing() {
        let outlook = PlanConsequence.outlook(sport: "Padel", plannedEffort: nil,
                                              inputs: PlanConsequence.Inputs())
        XCTAssertNil(outlook.chargeCost)
        XCTAssertNil(outlook.sampleCount)
        XCTAssertTrue(outlook.sentence().contains("don't have enough"),
                      "no evidence must read as 'I can't say', not as a number")
    }

    /// The comparison must always hand the decision back — it informs, it never overrules.
    func testSwapComparisonHandsTheDecisionBack() {
        let c = PlanConsequence.compare(from: "Zone 2 ride", fromEffort: 40,
                                        to: "CrossFit", toEffort: 80,
                                        inputs: PlanConsequence.Inputs())
        XCTAssertTrue(c.sentence().contains("Your call"))
    }

    /// The simulator is the point of the forecast: a real projection from real history.
    func testSimulateProjectsFromEnoughHistory() {
        var inputs = PlanConsequence.Inputs()
        inputs.recentCharge = Array(repeating: 65, count: 14)
        inputs.recentEffort = Array(repeating: 50, count: 14)
        inputs.typicalSleepHours = 7.5
        inputs.sleepNights = 14

        let result = PlanConsequence.simulate(todayEffort: 80, plannedSleepHours: 7, inputs: inputs)
        XCTAssertNotNil(result)
        XCTAssertTrue(result?.contains("projects around") ?? false)
    }

    /// Cold start returns nothing rather than a fabricated projection.
    func testSimulateReturnsNilOnColdStart() {
        var inputs = PlanConsequence.Inputs()
        inputs.recentCharge = [65, 66]   // below minBaselineNights
        XCTAssertNil(PlanConsequence.simulate(todayEffort: 50, plannedSleepHours: 8, inputs: inputs))
    }

    /// More sleep should never project a worse tomorrow — a basic sanity check on the wiring.
    func testMoreSleepDoesNotProjectWorse() {
        var inputs = PlanConsequence.Inputs()
        inputs.recentCharge = Array(repeating: 60, count: 14)
        inputs.recentEffort = Array(repeating: 50, count: 14)
        inputs.typicalSleepHours = 8
        inputs.sleepNights = 14

        let short = PlanConsequence.outlook(sport: "Run", plannedEffort: 50,
                                            plannedSleepHours: 5, inputs: inputs)
        let long = PlanConsequence.outlook(sport: "Run", plannedEffort: 50,
                                           plannedSleepHours: 8, inputs: inputs)
        XCTAssertNotNil(short.forecastCharge)
        XCTAssertNotNil(long.forecastCharge)
        XCTAssertGreaterThanOrEqual(long.forecastCharge ?? 0, short.forecastCharge ?? 0)
    }
}
