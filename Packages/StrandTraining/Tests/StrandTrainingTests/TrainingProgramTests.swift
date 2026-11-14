import XCTest
@testable import StrandTraining

/// The rule for what may be followed at once, and where a plan stands in its block.
///
/// Both are single resolvers on purpose: every screen asks them instead of counting for itself, so
/// what they answer here is what the whole app says.
final class TrainingProgramTests: XCTestCase {

    private func program(_ title: String, kind: TrainingProgramKind = .strength,
                         active: Bool = false, block: TrainingProgramBlock? = nil,
                         at ts: Int = 1_000) -> TrainingProgram {
        TrainingProgram(title: title, kind: kind, block: block, isActive: active,
                        createdAt: ts, updatedAt: ts)
    }

    // MARK: Activation

    func testActivatingAStrengthPlanStandsDownTheOtherStrengthPlanOnly() {
        let first = program("Push Pull", active: true)
        let second = program("Full body")
        let cardio = program("Base", kind: .conditioning, active: true)
        let changed = TrainingProgramActivation.activate(second.id, in: [first, second, cardio],
                                                         day: "2026-11-14", now: 2_000)
        XCTAssertEqual(Set(changed.map(\.id)), [first.id, second.id])
        XCTAssertEqual(changed.first { $0.id == second.id }?.isActive, true)
        XCTAssertEqual(changed.first { $0.id == first.id }?.isActive, false)
        // The conditioning plan is a different kind and is not touched at all.
        XCTAssertFalse(changed.contains { $0.id == cardio.id })
    }

    func testActivatingStampsTheBlockStartAndStandingDownClearsIt() {
        let plan = program("Eight weeks", block: TrainingProgramBlock(weeks: 8))
        let taken = TrainingProgramActivation.activate(plan.id, in: [plan],
                                                       day: "2026-11-14", now: 2_000)
        XCTAssertEqual(taken.first?.block?.startedOn, "2026-11-14")

        let running = taken[0]
        let dropped = TrainingProgramActivation.deactivate(running.id, in: [running], now: 3_000)
        XCTAssertEqual(dropped.first?.isActive, false)
        XCTAssertNil(dropped.first?.block?.startedOn)
    }

    /// Pressing activate on the plan already being followed must not restart its block, or every
    /// visit to the button would quietly put the wearer back in week one.
    func testActivatingAnAlreadyActivePlanChangesNothing() {
        var plan = program("Eight weeks", active: true,
                           block: TrainingProgramBlock(weeks: 8, startedOn: "2026-10-01"))
        plan.isActive = true
        let changed = TrainingProgramActivation.activate(plan.id, in: [plan],
                                                         day: "2026-11-14", now: 2_000)
        XCTAssertTrue(changed.isEmpty)
    }

    /// Stored data that somehow holds two active plans of one kind must still read as one, so no
    /// screen can ever show two plans being followed at the same time.
    func testTwoActivePlansOfOneKindResolveToTheMostRecentlyUpdated() {
        let older = program("Older", active: true, at: 1_000)
        let newer = program("Newer", active: true, at: 2_000)
        XCTAssertEqual(TrainingProgramActivation.active(.strength, in: [older, newer])?.id, newer.id)
        XCTAssertEqual(TrainingProgramActivation.activePlans(in: [older, newer]).count, 1)
    }

    func testActivePlansHoldsOnePlanPerKind() {
        let strength = program("Lift", active: true)
        let cardio = program("Run", kind: .conditioning, active: true)
        let resting = program("Later")
        let active = TrainingProgramActivation.activePlans(in: [strength, cardio, resting])
        XCTAssertEqual(Set(active.map(\.id)), [strength.id, cardio.id])
    }

    func testTargetsOrderAWindowGivenTheWrongWayRound() {
        let targets = TrainingProgramTargets(effortLow: 16, effortHigh: 8)
        XCTAssertEqual(targets.effortLow, 8)
        XCTAssertEqual(targets.effortHigh, 16)
    }

    /// A bound given on its own stays on its own side. An upper bound stored as a lower one says the
    /// opposite of what was asked for: "up to 8" would become "from 8".
    func testALoneBoundKeepsTheSideItWasGiven() {
        let ceiling = TrainingProgramTargets(effortHigh: 8)
        XCTAssertNil(ceiling.effortLow)
        XCTAssertEqual(ceiling.effortHigh, 8)

        let floor = TrainingProgramTargets(effortLow: 8)
        XCTAssertEqual(floor.effortLow, 8)
        XCTAssertNil(floor.effortHigh)
    }

    // MARK: Block state

    func testBlockWeeksCountFromTheDayThePlanWasTakenUp() {
        let block = TrainingProgramBlock(weeks: 8, startedOn: "2026-11-02")
        // The start day itself is week one, and so is every day up to the seventh.
        XCTAssertEqual(TrainingBlockState.resolve(block: block, today: "2026-11-02")?.week, 1)
        XCTAssertEqual(TrainingBlockState.resolve(block: block, today: "2026-11-08")?.week, 1)
        XCTAssertEqual(TrainingBlockState.resolve(block: block, today: "2026-11-09")?.week, 2)
        XCTAssertEqual(TrainingBlockState.resolve(block: block, today: "2026-12-14")?.week, 7)
    }

    func testTheFinalWeekIsLighterAndTheWeekAfterItIsTheEnd() {
        let block = TrainingProgramBlock(weeks: 4, deloadInFinalWeek: true,
                                          deloadFactor: 0.8, startedOn: "2026-11-02")
        let third = TrainingBlockState.resolve(block: block, today: "2026-11-16")
        XCTAssertEqual(third?.week, 3)
        XCTAssertEqual(third?.isDeload, false)
        XCTAssertEqual(third?.loadFactor, 1)

        let fourth = TrainingBlockState.resolve(block: block, today: "2026-11-23")
        XCTAssertEqual(fourth?.isDeload, true)
        XCTAssertEqual(fourth?.loadFactor, 0.8)
        XCTAssertEqual(fourth?.weeksRemaining, 1)

        let after = TrainingBlockState.resolve(block: block, today: "2026-11-30")
        XCTAssertEqual(after?.isFinished, true)
        XCTAssertEqual(after?.isDeload, false)
        XCTAssertEqual(after?.weeksRemaining, 0)
    }

    func testALighterWeekCanAlsoFallAtAFixedInterval() {
        let block = TrainingProgramBlock(weeks: 12, deloadInFinalWeek: false,
                                          deloadEveryWeeks: 4, startedOn: "2026-11-02")
        XCTAssertEqual(TrainingBlockState.resolve(block: block, today: "2026-11-23")?.isDeload, true)
        XCTAssertEqual(TrainingBlockState.resolve(block: block, today: "2026-11-30")?.isDeload, false)
        XCTAssertEqual(TrainingBlockState.resolve(block: block, today: "2026-12-21")?.isDeload, true)
    }

    /// A plan that is resting has no week to report, and saying so is the honest answer. "Week 1 of 8"
    /// for a plan nobody is following would be a promise the plan is not making.
    func testAPlanWithoutABlockOrWithoutAStartReportsNothing() {
        XCTAssertNil(TrainingBlockState.resolve(block: nil, today: "2026-11-14"))
        XCTAssertNil(TrainingBlockState.resolve(block: TrainingProgramBlock(weeks: 8),
                                                 today: "2026-11-14"))
    }

    /// A clock that steps back, or a start day stamped in a different time zone, must not produce a
    /// week zero or a negative one.
    func testADayBeforeTheStartStillReadsAsTheFirstWeek() {
        let block = TrainingProgramBlock(weeks: 8, startedOn: "2026-11-02")
        XCTAssertEqual(TrainingBlockState.resolve(block: block, today: "2026-11-01")?.week, 1)
    }

    func testDayDifferenceCountsWholeDaysAcrossAClockChange() {
        // Europe switches off summer time on 2026-10-25; counted on a fixed calendar in UTC, the
        // week either side of it is still seven days.
        XCTAssertEqual(TrainingBlockState.dayDifference(from: "2026-10-22", to: "2026-10-29"), 7)
        XCTAssertNil(TrainingBlockState.dayDifference(from: "not a day", to: "2026-10-29"))
    }
}
