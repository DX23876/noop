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

    // MARK: - Dedup: a re-proposal replaces, it doesn't stack (W3)

    /// The daily brief could fire propose_plan for the same session repeatedly; without dedup that's N
    /// identical cards. A re-proposal of the same (day, sport) updates the pending row in place.
    func testReProposingTheSameSessionReplacesRatherThanDuplicates() {
        let store = makeStore()
        store.propose(proposal(sport: "Zone 2 ride"))
        let firstId = store.proposals[0].id
        let firstCreatedAt = store.proposals[0].createdAt

        var second = proposal(sport: "Zone 2 ride")
        second.rationale = "Recovery is up — a longer easy ride today."
        store.propose(second)

        XCTAssertEqual(store.pending.count, 1, "the same session must not stack a second card")
        XCTAssertEqual(store.proposals[0].id, firstId, "the row keeps its id so the card can't flicker")
        XCTAssertEqual(store.proposals[0].createdAt, firstCreatedAt)
        XCTAssertEqual(store.proposals[0].rationale, "Recovery is up — a longer easy ride today.",
                       "the newer rationale wins")
    }

    func testADifferentSportOnTheSameDayIsKeptSeparately() {
        let store = makeStore()
        store.propose(proposal(day: "2026-07-16", sport: "Zone 2 ride"))
        store.propose(proposal(day: "2026-07-16", sport: "Mobility"))
        XCTAssertEqual(store.pending.count, 2, "an AM ride and PM mobility are two real sessions")
    }

    func testDedupIgnoresSportCaseAndSurroundingWhitespace() {
        let store = makeStore()
        store.propose(proposal(sport: "Zone 2 ride"))
        store.propose(proposal(sport: "  zone 2 RIDE "))
        XCTAssertEqual(store.pending.count, 1)
    }

    /// The load-bearing scope: dedup must never reach a DECIDED proposal. Re-proposing an identical
    /// session after it was accepted must not silently rewrite the commitment.
    /// Re-proposing a session the user already committed to is now REFUSED entirely (#P7 10.5): the
    /// coach must not re-pitch what's already on the table as a fresh idea. The commitment stays
    /// untouched either way — that invariant is the load-bearing one — but there's also no duplicate
    /// pending card anymore.
    func testReProposingAnAlreadyCommittedSessionIsRefused() {
        let store = makeStore()
        store.propose(proposal(sport: "Zone 2 ride"))
        let acceptedId = store.proposals[0].id
        store.accept(acceptedId)

        let created = store.propose(proposal(sport: "Zone 2 ride"))

        XCTAssertFalse(created, "propose must report it declined to duplicate an existing commitment")
        XCTAssertEqual(store.proposals.count, 1, "no fresh proposal next to the commitment")
        XCTAssertEqual(store.proposals.first(where: { $0.id == acceptedId })?.status, .accepted,
                       "the accepted commitment must be untouched")
        XCTAssertTrue(store.pending.isEmpty)
    }

    /// The guard is scoped to COMMITMENTS: a DECLINED session is not a commitment, so re-proposing it
    /// still creates a fresh pending row (the decline survives — the filter-bubble floor needs it).
    func testReProposingADeclinedSessionStillCreatesAFreshProposal() {
        let store = makeStore()
        store.propose(proposal(sport: "Zone 2 ride"))
        let declinedId = store.proposals[0].id
        store.decline(declinedId)

        let created = store.propose(proposal(sport: "Zone 2 ride"))
        XCTAssertTrue(created, "a declined session isn't a commitment — it can be offered again")
        XCTAssertEqual(store.pending.count, 1)
    }

    /// A decline must survive a re-proposal, or the filter-bubble floor (`declineStreak`) is defeated.
    func testDedupCannotResurrectADeclinedProposal() {
        let store = makeStore()
        store.propose(proposal(sport: "Zone 2 ride"))
        let declinedId = store.proposals[0].id
        store.decline(declinedId)
        XCTAssertEqual(store.declineStreak, 1)

        store.propose(proposal(sport: "Zone 2 ride"))

        XCTAssertEqual(store.proposals.first(where: { $0.id == declinedId })?.status, .declined,
                       "the decline is information the coach needs — it must not be erased")
        XCTAssertEqual(store.declineStreak, 1, "the streak must still count the surviving decline")
        XCTAssertEqual(store.pending.count, 1, "the re-proposal is a new pending row")
    }

    func testDedupKeyIsPureAndDayScoped() {
        XCTAssertEqual(CoachPlanStore.dedupKey(day: "2026-07-16", sport: "Zone 2 ride"),
                       CoachPlanStore.dedupKey(day: "2026-07-16", sport: "  zone 2 RIDE "))
        XCTAssertNotEqual(CoachPlanStore.dedupKey(day: "2026-07-16", sport: "Zone 2 ride"),
                          CoachPlanStore.dedupKey(day: "2026-07-17", sport: "Zone 2 ride"),
                          "the same sport on two days is two distinct sessions")
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

    // MARK: - Reschedule (#P7 9.7): moved, not missed

    /// Moving a committed session to another day marks it `.rescheduled` (still a commitment), keeps its
    /// origin day in `rescheduledFrom`, and lands it on the new day — so adherence reads a move as a move,
    /// not a skip.
    func testRescheduleMovesTheSessionAndRecordsWhereItCameFrom() {
        let store = makeStore()
        store.propose(proposal(day: "2026-07-16", sport: "Zone 2 ride"))
        let id = store.proposals[0].id
        store.accept(id)

        store.reschedule(id, toDay: "2026-07-17")

        XCTAssertEqual(store.proposals[0].status, .rescheduled)
        XCTAssertTrue(store.proposals[0].status.isCommitment, "a moved session is still intended")
        XCTAssertEqual(store.proposals[0].day, "2026-07-17")
        XCTAssertEqual(store.proposals[0].rescheduledFrom, "2026-07-16")
        XCTAssertNotNil(store.proposals[0].decidedAt)
    }

    /// Rescheduling twice keeps the ORIGINAL day, mirroring how a double-swap keeps the original sport.
    func testReschedulingTwiceKeepsTheOriginalDay() {
        let store = makeStore()
        store.propose(proposal(day: "2026-07-16", sport: "Zone 2 ride"))
        let id = store.proposals[0].id
        store.accept(id)
        store.reschedule(id, toDay: "2026-07-17")
        store.reschedule(id, toDay: "2026-07-18")

        XCTAssertEqual(store.proposals[0].day, "2026-07-18")
        XCTAssertEqual(store.proposals[0].rescheduledFrom, "2026-07-16", "the story starts where it started")
    }

    /// A rescheduled session shows up as a commitment on its NEW day, not the old one.
    func testRescheduledSessionIsACommitmentOnItsNewDay() {
        let store = makeStore()
        store.propose(proposal(day: "2026-07-16", sport: "Zone 2 ride"))
        let id = store.proposals[0].id
        store.accept(id)
        store.reschedule(id, toDay: "2026-07-20")

        XCTAssertEqual(store.commitments(fromDay: "2026-07-18").count, 1,
                       "the moved session counts from its new day")
    }

    // MARK: - Round-trip: rescheduledFrom survives persistence

    func testRescheduledFromSurvivesEncodingRoundTrip() throws {
        var p = PlanProposal(day: "2026-07-17", sport: "Zone 2 ride", intent: .easy,
                             status: .rescheduled, rescheduledFrom: "2026-07-16")
        p.decidedAt = Date()
        let data = try JSONEncoder().encode(p)
        let back = try JSONDecoder().decode(PlanProposal.self, from: data)
        XCTAssertEqual(back.status, .rescheduled)
        XCTAssertEqual(back.rescheduledFrom, "2026-07-16")
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
