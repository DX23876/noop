import XCTest
import WhoopProtocol
import WhoopStore
@testable import StrandAnalytics

/// Training Load plan, phase 2 (docs/fork/TRAINING_LOAD_PLAN.md §8): the focus, "enough?", the verdict
/// against the goal, the morning advice, the offers and the Lab instruments.
final class TrainingGuidanceTests: XCTestCase {
    private let today = "2026-11-28"

    // MARK: Focus

    func testTheDietPlanDecidesBothLanesAndAWeightGoalStandsInWithoutOne() {
        let lose = TrainingFocusResolver.resolve(lane: .cardio, chosen: nil, diet: .lose, dietStartDay: "2026-10-01",
                                                 goals: [], today: today)
        XCTAssertEqual(lose.focus, .loseWeight)
        XCTAssertEqual(lose.source, .dietPlan)
        let gain = TrainingFocusResolver.resolve(lane: .strength, chosen: nil, diet: .recomp, dietStartDay: "2026-10-01",
                                                 goals: [], today: today)
        XCTAssertEqual(gain.focus, .strength)
        let weight = TrainingFocusResolver.Goal(kind: .weight, baseline: 120, target: 100, targetDay: nil,
                                                createdDay: "2026-09-01")
        let byGoal = TrainingFocusResolver.resolve(lane: .strength, chosen: nil, diet: nil, dietStartDay: nil,
                                                   goals: [weight], today: today)
        XCTAssertEqual(byGoal.focus, .loseWeight)
        XCTAssertEqual(byGoal.source, .weightGoal)
        XCTAssertEqual(TrainingFocusResolver.resolve(lane: .cardio, chosen: nil, diet: nil, dietStartDay: nil,
                                                     goals: [], today: today), .guideline)
    }

    func testATrainingGoalSpeaksOnlyForItsLaneAndTheNearestDateWins() {
        let run = TrainingFocusResolver.Goal(kind: .run, baseline: nil, target: 10, targetDay: "2027-01-10",
                                             createdDay: "2026-10-01")
        let weight = TrainingFocusResolver.Goal(kind: .weight, baseline: 120, target: 100, targetDay: "2027-06-01",
                                                createdDay: "2026-09-01")
        let cardio = TrainingFocusResolver.resolve(lane: .cardio, chosen: nil, diet: nil, dietStartDay: nil,
                                                   goals: [run, weight], today: today)
        XCTAssertEqual(cardio.focus, .fitness, "the run is due first")
        let strength = TrainingFocusResolver.resolve(lane: .strength, chosen: nil, diet: nil, dietStartDay: nil,
                                                     goals: [run, weight], today: today)
        XCTAssertEqual(strength.focus, .loseWeight, "a running goal says nothing about the strength lane")
    }

    func testAChosenFocusWinsAndKeepsAMatchingPause() {
        let weight = TrainingFocusResolver.Goal(kind: .weight, baseline: 120, target: 100, targetDay: nil,
                                                createdDay: "2026-09-01", pause: .illness)
        let r = TrainingFocusResolver.resolve(lane: .cardio, chosen: .loseWeight, diet: nil, dietStartDay: nil,
                                              goals: [weight], today: today)
        XCTAssertEqual(r.source, .chosen)
        XCTAssertEqual(r.pause, .illness)
    }

    // MARK: Enough

    func testTheTargetFollowsTheFocusWithTheGuidelineAsTheFloor() {
        XCTAssertEqual(EnoughTarget.forFocus(.loseWeight, age: 40)?.minutesLow, 250)
        XCTAssertEqual(EnoughTarget.forFocus(.strength, age: 40)?.strengthDaysHigh, 3)
        XCTAssertEqual(EnoughTarget.forFocus(.health, age: 40), EnoughTarget.guideline)
        XCTAssertNil(EnoughTarget.forFocus(.health, age: 16), "no adult target under 18")
        XCTAssertEqual(EnoughTarget.forFocus(.health, age: 70)?.balanceHint, true)
        let own = EnoughTarget.forFocus(.health, age: 40, ownWeeklyMinutes: 200)
        XCTAssertEqual(own?.minutesLow, 200)
        XCTAssertEqual(own?.fromOwnGoal, true)
    }

    /// A minute inside a session counts by heart rate; outside, only with steps in the same minute; a raised
    /// pulse at rest never counts.
    func testActiveMinutesNeedMovementOutsideSessions() {
        let rest = 60.0, max = 180.0   // reserve 120: moderate from 108, vigorous from 132
        var hr: [HRSample] = []
        var steps: [StepSample] = []
        var counter = 0
        func minute(_ m: Int, bpm: Int, ticks: Int) {
            for s in 0..<60 {
                let ts = m * 60 + s
                hr.append(HRSample(ts: ts, bpm: bpm))
                if ticks > 0 && s % 6 == 0 { counter += ticks / 10; steps.append(StepSample(ts: ts, counter: counter, activityClass: 1)) }
            }
        }
        minute(1000, bpm: 120, ticks: 0)    // session, moderate
        minute(1001, bpm: 140, ticks: 0)    // session, vigorous
        minute(2000, bpm: 120, ticks: 100)  // everyday walk, moderate
        minute(3000, bpm: 140, ticks: 0)    // raised pulse at a desk: never counted
        minute(4000, bpm: 90, ticks: 100)   // a stroll below 40 %: not counted
        let day = ActiveMinutes.day(hr: hr, steps: steps, sessions: [60_000..<60_120], restingHR: rest, maxHR: max)
        XCTAssertEqual(day.sessionModerate, 1)
        XCTAssertEqual(day.sessionVigorous, 1)
        XCTAssertEqual(day.everydayModerate, 1)
        XCTAssertEqual(day.everydayVigorous, 0)
        XCTAssertEqual(day.equivalentMinutes, 4, "vigorous counts double")
    }

    func testARatingSpeaksForASessionWithoutUsablePulse() {
        XCTAssertEqual(ActiveMinutes.ratedMinutes(durationMinutes: 40, rating: 5).moderate, 40)
        XCTAssertEqual(ActiveMinutes.ratedMinutes(durationMinutes: 40, rating: 8).vigorous, 40)
        XCTAssertEqual(ActiveMinutes.ratedMinutes(durationMinutes: 40, rating: 3).moderate, 0)
        XCTAssertEqual(ActiveMinutes.ratedMinutes(durationMinutes: 40, rating: nil).moderate, 0)
    }

    private func week(_ start: String, _ minutes: Int, complete: Bool = true, target: EnoughTarget = .guideline) -> EnoughWeek {
        EnoughWeek(start: start, equivalentMinutes: minutes, everydayMinutes: 0, ratedMinutes: 0, strengthDays: 2,
                   target: target, isComplete: complete)
    }

    func testAGoalIsCarriedInThreeOfFourCompleteWeeks() {
        let weeks = [week("2026-10-26", 160), week("2026-11-02", 100), week("2026-11-09", 200),
                     week("2026-11-16", 151), week("2026-11-23", 10, complete: false)]
        XCTAssertTrue(EnoughCount.isCarried(weeks))
        XCTAssertFalse(EnoughCount.isCarried(Array(weeks.prefix(2))), "fewer than four complete weeks")
    }

    // MARK: The verdict against the goal

    private let losing = TrainingFocusReading(focus: .loseWeight, source: .dietPlan, since: "2026-09-01")

    func testWalkingEnoughToLoseWeightIsNotCalledUnproductive() {
        let t = EnoughTarget.forFocus(.loseWeight, age: 40)!
        let weeks = ["2026-10-26", "2026-11-02", "2026-11-09", "2026-11-16"].map { week($0, 260, target: t) }
        let r = GoalOutcome.cardio(verdict: .status(.unproductive), band: .usual, focus: losing, weeks: weeks,
                                   recovery: .holding, today: today)
        XCTAssertEqual(r.note, .carriesWeightLoss)
        XCTAssertTrue(r.noteIsHeadline)
        let tooMuch = GoalOutcome.cardio(verdict: .status(.overreaching), band: .muchHigher, focus: losing,
                                         weeks: weeks, recovery: .holding, today: today)
        XCTAssertNil(tooMuch.note, "too much stays too much")
    }

    func testANewGoalIsOnlyDescribedAndAPausedOneRests() {
        let fresh = TrainingFocusReading(focus: .loseWeight, source: .weightGoal, since: "2026-11-20")
        let r = GoalOutcome.cardio(verdict: .status(.unproductive), band: .higher, focus: fresh, weeks: [],
                                   recovery: .holding, today: today)
        XCTAssertEqual(r.note, .goalTooNew)
        XCTAssertEqual(r.verdict, .loadOnly(.higher))
        let paused = TrainingFocusReading(focus: .loseWeight, source: .weightGoal, since: "2026-09-01", pause: .pain)
        let p = GoalOutcome.strength(verdict: .status(.unproductive), band: .usual, focus: paused, changePercent: -2,
                                     weightChangePercentPerWeek: nil, recovery: .holding, today: today)
        XCTAssertEqual(p.note, .paused)
        XCTAssertNil(p.verdict)
    }

    func testStrengthHeldInADeficitIsASuccessAndAFastFallAsksForALook() {
        let held = GoalOutcome.strength(verdict: .status(.unproductive), band: .usual, focus: losing,
                                        changePercent: -3, weightChangePercentPerWeek: -0.8, recovery: .holding,
                                        today: today)
        XCTAssertEqual(held.note, .strengthHeld)
        let falling = GoalOutcome.strength(verdict: .status(.unproductive), band: .usual, focus: losing,
                                           changePercent: -8, weightChangePercentPerWeek: -1.4, recovery: .strained,
                                           today: today)
        XCTAssertEqual(falling.note, .checkLoadOrDeficit)
        XCTAssertFalse(falling.noteIsHeadline)
        let building = GoalOutcome.strength(verdict: .status(.unproductive), band: .usual,
                                            focus: TrainingFocusReading(focus: .strength, source: .dietPlan,
                                                                        since: "2026-09-01"),
                                            changePercent: -3, weightChangePercentPerWeek: nil, recovery: .holding,
                                            today: today)
        XCTAssertNil(building.note, "building strength needs rising lifts")
    }

    // MARK: Morning advice

    private func advise(_ i: MorningAdviceInput) -> MorningAdviceReading { MorningAdvice.resolve(i) }

    func testTheFirstRuleThatAppliesDecides() {
        XCTAssertEqual(advise(.init(charge: 90, night: .scored, unwell: true)).stance, .rest)
        XCTAssertEqual(advise(.init(charge: 90, night: .scored, recovery: .strained, cardioBand: .muchHigher)).reason,
                       .strainedRecovery)
        XCTAssertEqual(advise(.init(charge: 20, night: .scored, plannedToday: true)).stance, .easy)
        let cardioHigh = advise(.init(charge: 90, night: .scored, strengthBand: .usual, cardioBand: .muchHigher,
                                      behindGoal: true))
        XCTAssertEqual(cardioHigh.stance, .easy)
        XCTAssertEqual(cardioHigh.limitedLane, .cardio)
        XCTAssertEqual(advise(.init(charge: 50, night: .scored, plannedToday: true)).reason, .plannedShorter)
        XCTAssertEqual(advise(.init(charge: 80, night: .scored, plannedToday: true)).reason, .planned)
        XCTAssertEqual(advise(.init(charge: 80, night: .scored, behindGoal: true)).stance, .push)
        XCTAssertEqual(advise(.init(charge: 80, night: .scored)).stance, .steady)
    }

    func testMissingDataNeverPushesAndEatingTooLittleBlocksPush() {
        XCTAssertNotEqual(advise(.init(charge: nil, night: .missing, behindGoal: true)).stance, .push)
        XCTAssertEqual(advise(.init(charge: nil, night: .missing)).reason, .noNight)
        XCTAssertEqual(advise(.init(charge: nil, night: .pending)).state, .waitingForNight)
        XCTAssertEqual(advise(.init(charge: 80, night: .scored, behindGoal: true, ateTooLittle: true)).stance, .steady)
        XCTAssertEqual(advise(.init(charge: 80, night: .scored, trainedToday: true)).state, .done)
    }

    func testTheEffortTargetIsChargesBandCappedByTheAdvice() {
        XCTAssertEqual(advise(.init(charge: 80, night: .scored)).effortTarget, EffortTargetBand.stored(14...18))
        XCTAssertEqual(advise(.init(charge: 80, night: .scored, cardioBand: .muchHigher)).effortTarget,
                       EffortTargetBand.stored(10...14))
        XCTAssertEqual(advise(.init(charge: 80, night: .scored, unwell: true)).effortTarget,
                       EffortTargetBand.stored(4...10))
        XCTAssertNil(advise(.init(charge: nil, night: .missing)).effortTarget)
    }

    // MARK: Offers

    func testOffersAreInEverydayUnitsWithThePlanFirst() {
        let steady = advise(.init(charge: 80, night: .scored))
        let typical = TrainingOffers.Typical(sport: "Walking", loadPerMinute: 2.0)
        XCTAssertEqual(TrainingOffers.minutes(room: 77, typical: typical), 35, "rounded down to five")
        XCTAssertNil(TrainingOffers.minutes(room: 15, typical: typical), "nothing under ten minutes")
        let offers = TrainingOffers.build(advice: steady, plannedTitle: "Push day", cardioRoom: 77, typical: typical,
                                          strengthGroups: [("Legs", 8), ("Back", 12)])
        XCTAssertEqual(offers, [.planned(title: "Push day"), .cardio(sport: "Walking", minutes: 35),
                                .strength(group: "Back", sets: 12)])
        let fresh = TrainingOffers.build(advice: steady, plannedTitle: nil, cardioRoom: nil, typical: nil,
                                         strengthGroups: [])
        XCTAssertEqual(fresh, [.startWalk(minutes: 30)])
        let rest = TrainingOffers.build(advice: advise(.init(charge: 80, night: .scored, unwell: true)),
                                        plannedTitle: nil, cardioRoom: 200, typical: typical, strengthGroups: [("Legs", 8)])
        XCTAssertEqual(rest, [.easyMovement])
        let cardioHeld = TrainingOffers.build(advice: advise(.init(charge: 80, night: .scored, cardioBand: .muchHigher)),
                                              plannedTitle: nil, cardioRoom: 200, typical: typical,
                                              strengthGroups: [("Legs", 8)])
        XCTAssertEqual(cardioHeld, [.strength(group: "Legs", sets: 8)], "a held lane offers nothing of its own")
    }

    // MARK: Lab instruments

    private func weekOf(_ day: String) -> String {
        // Weeks start on Monday; enough for the synthetic series below.
        guard let n = FitnessInstruments.dayNumber(day) else { return day }
        let monday = n - ((n + 3) % 7)
        return dayKey(monday)
    }

    private func dayKey(_ n: Int) -> String {
        // Inverse of days_from_civil.
        let z = n + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp + (mp < 10 ? 3 : -9)
        let y = yoe + era * 400 + (m <= 2 ? 1 : 0)
        return String(format: "%04d-%02d-%02d", y, m, d)
    }

    /// The CLAUDE.md rule for derived signals: an instrument must recover several injected changes, not one.
    func testThePulseAtCadenceRecoversSeveralInjectedChanges() {
        let start = FitnessInstruments.dayNumber("2026-10-01")!
        for injected in [-10.0, -5.0, 0.0, 6.0] {
            let sessions: [(day: String, minutes: [FitnessInstruments.WalkMinute])] = (0..<16).map { i in
                let bpm = 125 + injected * Double(i) / 15 + (i % 2 == 0 ? 0.4 : -0.4)
                return (dayKey(start + i * 3), (0..<12).map { _ in FitnessInstruments.WalkMinute(cadence: 112, bpm: bpm) })
            }
            let r = FitnessInstruments.pulseAtCadence(sessions: sessions, weekStart: weekOf)
            let expected: InstrumentDirection = injected <= -3 ? .improving : (injected >= 3 ? .worsening : .unclear)
            XCTAssertEqual(r.direction, expected, "injected \(injected)")
            if injected != 0 { XCTAssertEqual(r.change ?? 0, injected, accuracy: 1.5, "injected \(injected)") }
        }
    }

    func testPulseRecoveryAndPaceRecoverTheirDirections() {
        let start = FitnessInstruments.dayNumber("2026-10-01")!
        let recovery = (0..<8).map { (day: dayKey(start + $0 * 6), dropAfterOneMinute: 18 + Double($0)) }
        XCTAssertEqual(FitnessInstruments.pulseRecovery(sessions: recovery, weekStart: weekOf).direction, .improving)
        let pace = (0..<8).map { i in
            (day: dayKey(start + i * 6), splits: [FitnessInstruments.Split(secondsPerKm: 600, ascentM: 2, bpm: 140 - Double(i))])
        }
        XCTAssertEqual(FitnessInstruments.pulseAtPace(sessions: pace, weekStart: weekOf).direction, .improving)
        let hilly = (0..<8).map { i in
            (day: dayKey(start + i * 6), splits: [FitnessInstruments.Split(secondsPerKm: 600, ascentM: 40, bpm: 140)])
        }
        XCTAssertEqual(FitnessInstruments.pulseAtPace(sessions: hilly, weekStart: weekOf).direction, .unknown,
                       "climbing splits are not flat")
    }

    func testTheCheckNeedsEightComparisonsAndSeventyPercentAgreement() {
        let weeks = (0..<10).map { dayKey(FitnessInstruments.dayNumber("2026-09-07")! + 7 * $0) }
        let instrument = weeks.enumerated().map { (start: $1, value: 130 - Double($0)) }        // pulse falls: fitter
        let reference = weeks.enumerated().map { (start: $1, value: 30 + Double($0) * 0.5) }    // VO₂max rises
        let agree = InstrumentCheck.compare(instrument: instrument, instrumentHigherIsBetter: false,
                                            reference: reference, referenceHigherIsBetter: true)
        XCTAssertEqual(agree.pairs, 9)
        XCTAssertTrue(agree.passes)
        let short = InstrumentCheck.compare(instrument: Array(instrument.prefix(5)), instrumentHigherIsBetter: false,
                                            reference: reference, referenceHigherIsBetter: true)
        XCTAssertFalse(short.passes, "four comparisons are too few")
        let opposite = InstrumentCheck.compare(instrument: instrument, instrumentHigherIsBetter: true,
                                               reference: reference, referenceHigherIsBetter: true)
        XCTAssertFalse(opposite.passes)
    }

    // MARK: Strength

    private func workout(_ id: String, _ ts: Int, reps: [Int], weight: Double? = nil) -> HevyWorkout {
        let sets = reps.enumerated().map { HevySet(index: $0.offset, type: .normal, weightKg: weight, reps: $0.element,
                                                   distanceM: nil, durationS: nil, rpe: nil, customMetric: nil) }
        return HevyWorkout(id: id, title: "Home", routineId: nil, notes: nil, startTs: ts, endTs: ts + 1800,
                           updatedAtTs: ts, createdAtTs: ts,
                           exercises: [HevyExercise(index: 0, title: "Push-up", templateId: "pushup", supersetId: nil,
                                                    notes: nil, sets: sets)])
    }

    func testABodyweightMovementCountsByTheRepsOfItsBestSet() {
        let base = 1_793_000_000
        let workouts = (0..<6).map { workout("w\($0)", base + $0 * 5 * 86_400, reps: [10 + $0 * 2, 8]) }
        let day = AnalyticsEngine.dayString(base + 26 * 86_400, offsetSec: 0)
        let r = TrainingStatusModel.strengthResponse(workouts: workouts, templates: [:], through: day)
        XCTAssertEqual(r.lifts.first?.isBodyweight, true)
        XCTAssertEqual(r.lifts.first?.direction, .rising)
    }
}
