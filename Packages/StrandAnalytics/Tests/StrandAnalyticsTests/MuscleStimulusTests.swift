import XCTest
import WhoopStore
@testable import StrandAnalytics

/// Pins the stimulus estimate.
///
/// The first test is the reason the whole file exists: the same three sets of ten must count as almost
/// nothing for someone strong enough that the weight is trivial, and as real work for someone it is
/// heavy for. Set counting cannot tell those apart, and that is precisely what made the old map say
/// little more than "trained = orange".
///
/// Most of the rest hold a piece of RESTRAINT rather than a calculation — the fallbacks that stop the
/// estimate from silently erasing an exercise it cannot judge, and the reference that must not
/// re-colour history after a PR.
final class MuscleStimulusTests: XCTestCase {

    // MARK: - Fixtures

    private func set(_ index: Int, _ type: HevySetType = .normal,
                     kg: Double? = nil, reps: Int? = nil, rpe: Double? = nil) -> HevySet {
        HevySet(index: index, type: type, weightKg: kg, reps: reps,
                distanceM: nil, durationS: nil, rpe: rpe, customMetric: nil)
    }

    private func workout(_ id: String, at ts: Int, _ exercises: [HevyExercise]) -> HevyWorkout {
        HevyWorkout(id: id, title: "Session", routineId: nil, notes: nil,
                    startTs: ts, endTs: ts + 3600, updatedAtTs: ts, createdAtTs: ts,
                    exercises: exercises)
    }

    private func exercise(_ templateId: String?, _ sets: [HevySet]) -> HevyExercise {
        HevyExercise(index: 0, title: templateId ?? "Unknown", templateId: templateId,
                     supersetId: nil, notes: nil, sets: sets)
    }

    private func template(_ id: String, primary: HevyMuscleGroup,
                          secondary: [HevyMuscleGroup] = [],
                          type: String = "weight_reps") -> HevyExerciseTemplate {
        HevyExerciseTemplate(id: id, title: id, type: type, primaryMuscleGroup: primary,
                             secondaryMuscleGroups: secondary, equipment: .barbell, isCustom: false)
    }

    private var bench: [String: HevyExerciseTemplate] {
        ["BP": template("BP", primary: .chest, secondary: [.triceps])]
    }

    private static func ts(_ day: String) -> Int {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return Int((f.date(from: day) ?? Date(timeIntervalSince1970: 0)).timeIntervalSince1970) + 43_200
    }

    /// A history that establishes a one-rep max, then the session under test.
    private func history(maxSingleKg: Double, then session: HevyWorkout) -> [HevyWorkout] {
        [workout("pr", at: Self.ts("2026-07-01"),
                 [exercise("BP", [set(0, kg: maxSingleKg, reps: 1)])]),
         session]
    }

    // MARK: - THE test

    /// Three sets of ten at 20 kg. For a 100 kg bencher that is 20 % of max — a warmup, and the
    /// estimate says so. For a 25 kg bencher it is 80 % — real work, and the estimate says that too.
    ///
    /// Counting sets gives both the same number, which is the defect this replaces.
    func testTheSameSetsCountForLittleWhenTheWeightIsTrivialForYou() {
        let session = workout("s", at: Self.ts("2026-07-08"), [
            exercise("BP", (0..<3).map { set($0, kg: 20, reps: 10, rpe: 8) }),
        ])

        func chestStimulus(maxSingleKg: Double) -> Double {
            let workouts = history(maxSingleKg: maxSingleKg, then: session)
            let reference = MuscleStimulus.StrengthReference(workouts: workouts, templates: bench)
            return MuscleStimulus.stimulus(for: [session], templates: bench,
                                           reference: reference).byMuscle[.chest] ?? 0
        }

        let strong = chestStimulus(maxSingleKg: 100)   // 20 kg = 20 % of max
        let weak = chestStimulus(maxSingleKg: 25)      // 20 kg = 80 % of max

        XCTAssertEqual(strong, 0, "below 30 % of max contributes nothing")
        XCTAssertGreaterThan(weak, 2.0, "80 % of max for three sets is real work")
    }

    // MARK: - The two factors

    func testIntensityRampMatchesItsAnchors() {
        XCTAssertEqual(MuscleStimulus.intensityFactor(relativeLoad: 0.20), 0)
        XCTAssertEqual(MuscleStimulus.intensityFactor(relativeLoad: 0.30), 0)
        XCTAssertEqual(MuscleStimulus.intensityFactor(relativeLoad: 0.50), 0.5, accuracy: 1e-9)
        XCTAssertEqual(MuscleStimulus.intensityFactor(relativeLoad: 0.70), 1)
        XCTAssertEqual(MuscleStimulus.intensityFactor(relativeLoad: 1.20), 1, "no bonus above max")
    }

    /// An unrated set is UNKNOWN, not maximal. Defaulting it to 1.0 would make a light unrated session
    /// read as a brutal one, which is the failure mode this constant exists to avoid.
    func testAnUnratedSetGetsTheNeutralFactorNotTheMaximalOne() {
        XCTAssertEqual(MuscleStimulus.proximityFactor(rpe: nil), MuscleStimulus.unratedProximity)
        XCTAssertLessThan(MuscleStimulus.proximityFactor(rpe: nil),
                          MuscleStimulus.proximityFactor(rpe: 10))
        XCTAssertGreaterThan(MuscleStimulus.proximityFactor(rpe: 10),
                             MuscleStimulus.proximityFactor(rpe: 6))
        XCTAssertEqual(MuscleStimulus.proximityFactor(rpe: 4), 0.2, "an easy set is not zero work")
    }

    // MARK: - The fallbacks

    /// A plank, a bodyweight pull-up, a machine on its own scale: no weight means no relative load, and
    /// the set falls back to counting as one hard set rather than vanishing from the map.
    func testAnExerciseWithNoStrengthReferenceStillCounts() {
        let templates = ["PLANK": template("PLANK", primary: .abdominals, type: "duration")]
        let session = workout("s", at: Self.ts("2026-07-08"), [
            exercise("PLANK", [set(0, rpe: 9), set(1, rpe: 9)]),
        ])
        let reference = MuscleStimulus.StrengthReference(workouts: [session], templates: templates)
        let out = MuscleStimulus.stimulus(for: [session], templates: templates, reference: reference)
        let abs = try? XCTUnwrap(out.byMuscle[.abdominals])
        XCTAssertEqual(abs ?? 0, 2 * MuscleStimulus.proximityFactor(rpe: 9), accuracy: 1e-9)
    }

    /// Warmups are not work, at any weight.
    func testWarmupSetsContributeNothing() {
        let session = workout("s", at: Self.ts("2026-07-08"), [
            exercise("BP", [set(0, .warmup, kg: 90, reps: 3, rpe: 9)]),
        ])
        let workouts = history(maxSingleKg: 100, then: session)
        let reference = MuscleStimulus.StrengthReference(workouts: workouts, templates: bench)
        XCTAssertTrue(MuscleStimulus.stimulus(for: [session], templates: bench,
                                              reference: reference).byMuscle.isEmpty)
    }

    // MARK: - Secondary muscles

    /// A bench press is not nothing for the triceps, and it is not a triceps session either.
    func testSecondaryMusclesGetHalfCredit() throws {
        let session = workout("s", at: Self.ts("2026-07-08"), [
            exercise("BP", [set(0, kg: 80, reps: 5, rpe: 9)]),
        ])
        let workouts = history(maxSingleKg: 100, then: session)
        let reference = MuscleStimulus.StrengthReference(workouts: workouts, templates: bench)
        let out = MuscleStimulus.stimulus(for: [session], templates: bench, reference: reference)

        let chest = try XCTUnwrap(out.byMuscle[.chest])
        let triceps = try XCTUnwrap(out.byMuscle[.triceps])
        XCTAssertGreaterThan(triceps, 0, "the triceps did work")
        XCTAssertEqual(triceps, chest * MuscleStimulus.secondaryShare, accuracy: 1e-9)
    }

    // MARK: - The strength reference

    /// The reference is the max AS OF the set, not the all-time best. Using today's max would make
    /// every past set look easier in hindsight purely because the lifter got stronger, and the map's
    /// history would re-colour itself after every PR.
    func testAPersonalRecordDoesNotRewriteWhatOlderSetsCost() throws {
        let old = workout("old", at: Self.ts("2026-07-08"), [
            exercise("BP", [set(0, kg: 50, reps: 5, rpe: 8)]),
        ])
        let before = [workout("pr", at: Self.ts("2026-07-01"),
                              [exercise("BP", [set(0, kg: 100, reps: 1)])]),
                      old]
        let after = before + [workout("newpr", at: Self.ts("2026-08-01"),
                                      [exercise("BP", [set(0, kg: 200, reps: 1)])])]

        func stimulus(_ workouts: [HevyWorkout]) -> Double {
            let reference = MuscleStimulus.StrengthReference(workouts: workouts, templates: bench)
            return MuscleStimulus.stimulus(for: [old], templates: bench,
                                           reference: reference).byMuscle[.chest] ?? 0
        }
        XCTAssertEqual(stimulus(before), stimulus(after), accuracy: 1e-9)
        XCTAssertGreaterThan(stimulus(before), 0)
    }

    /// A max from beyond the window no longer defines what is heavy today.
    func testTheReferenceForgetsAMaxOlderThanItsWindow() {
        let ancient = workout("old", at: Self.ts("2026-01-01"),
                              [exercise("BP", [set(0, kg: 200, reps: 1)])])
        let today = workout("s", at: Self.ts("2026-07-08"),
                            [exercise("BP", [set(0, kg: 100, reps: 1)])])
        let reference = MuscleStimulus.StrengthReference(workouts: [ancient, today], templates: bench)
        XCTAssertEqual(reference.best(templateId: "BP", asOf: Self.ts("2026-07-08")), 100,
                       "the 200 kg single is more than 12 weeks old")
    }

    // MARK: - Rated share

    /// Without RPE the proximity term is a constant, so half the model is inert. The screen has to be
    /// able to say that, so the count travels with the result.
    func testTheRatedShareIsReported() {
        let session = workout("s", at: Self.ts("2026-07-08"), [
            exercise("BP", [set(0, kg: 80, reps: 5, rpe: 9), set(1, kg: 80, reps: 5)]),
        ])
        let workouts = history(maxSingleKg: 100, then: session)
        let reference = MuscleStimulus.StrengthReference(workouts: workouts, templates: bench)
        let out = MuscleStimulus.stimulus(for: [session], templates: bench, reference: reference)
        XCTAssertEqual(out.workingSetCount, 2)
        XCTAssertEqual(out.ratedSetCount, 1)
        XCTAssertEqual(out.ratedShare, 0.5, accuracy: 1e-9)
    }

    // MARK: - What "usual" means

    /// Weeks without training are skipped, not counted as zero. Averaging a fortnight of illness in
    /// would drag the anchor down and then report the return to normal training as a heavy week.
    func testRestWeeksDoNotDragTheAnchorDown() throws {
        var workouts: [HevyWorkout] = [
            workout("pr", at: Self.ts("2026-05-04"), [exercise("BP", [set(0, kg: 100, reps: 1)])]),
        ]
        // Four training weeks of identical work, then two weeks off before the anchor.
        for (i, day) in ["2026-05-11", "2026-05-18", "2026-05-25", "2026-06-01"].enumerated() {
            workouts.append(workout("w\(i)", at: Self.ts(day), [
                exercise("BP", (0..<4).map { set($0, kg: 80, reps: 5, rpe: 9) }),
            ]))
        }
        let anchor = "2026-06-22"   // two blank weeks sit between the last session and here
        let typical = MuscleStimulus.typicalWeeklyStimulus(workouts, templates: bench,
                                                           endingBefore: anchor)
        let chest = try XCTUnwrap(typical[.chest])

        let oneWeek = MuscleStimulus.weeklyStimulus(containing: "2026-05-11", workouts: workouts,
                                                    templates: bench)
        XCTAssertEqual(chest, oneWeek.byMuscle[.chest] ?? 0, accuracy: 1e-9,
                       "the anchor is the median of the TRAINING weeks, unaffected by the blank ones")
    }

    // MARK: - Decay, and the wearer's correction

    /// After one time constant about 37 % is left, and two sessions add up. Pinned because these two
    /// facts are the whole behaviour of the "right now" view.
    func testFatigueDecaysByOneTimeConstantAndSessionsAccumulate() throws {
        let tau = 48.0 * 3600
        let first = workout("a", at: Self.ts("2026-07-08"), [
            exercise("BP", [set(0, rpe: 10)]),          // no weight -> one hard set, factor 1
        ])
        let templates = ["BP": template("BP", primary: .chest, type: "duration")]

        let now = Self.ts("2026-07-08") + Int(tau)
        let single = MuscleRecovery.fatigue(workouts: [first], templates: templates,
                                            now: now, tau: { _ in tau })
        XCTAssertEqual(try XCTUnwrap(single[.chest]), exp(-1), accuracy: 1e-6)

        let second = workout("b", at: now, [exercise("BP", [set(0, rpe: 10)])])
        let both = MuscleRecovery.fatigue(workouts: [first, second], templates: templates,
                                          now: now, tau: { _ in tau })
        XCTAssertEqual(try XCTUnwrap(both[.chest]), exp(-1) + 1, accuracy: 1e-6)
    }

    /// A session dated in the future — a clock skew, a bad import — must not contribute more fatigue
    /// than it could possibly have caused.
    func testAFutureSessionAddsNoFatigue() {
        let templates = ["BP": template("BP", primary: .chest, type: "duration")]
        let tomorrow = workout("a", at: Self.ts("2026-07-09"), [exercise("BP", [set(0, rpe: 10)])])
        let out = MuscleRecovery.fatigue(workouts: [tomorrow], templates: templates,
                                         now: Self.ts("2026-07-08"))
        XCTAssertNil(out[.chest])
    }

    /// The point of the whole correction mechanism: someone who repeatedly says they feel fine sooner
    /// than the model expects ends up with a shorter constant than the assumed default.
    func testRepeatedlyFeelingFreshEarlyShortensTheConstant() {
        let templates = ["BP": template("BP", primary: .chest, type: "duration")]
        // One session a week, and every time the wearer reports being fresh again after 24 hours.
        var workouts: [HevyWorkout] = []
        var observations: [MuscleRecovery.Observation] = []
        var day = "2026-05-04"
        for i in 0..<8 {
            let ts = Self.ts(day)
            workouts.append(workout("w\(i)", at: ts, [exercise("BP", [set(0, rpe: 10)])]))
            observations.append(.init(group: .chest, ts: ts + 24 * 3600, feeling: .fresh))
            day = WeeklyDigestEngine.addDays(day, 7)
        }
        let fitted = MuscleRecovery.fittedTauSeconds(for: .chest, observations: observations,
                                                     workouts: workouts, templates: templates)
        XCTAssertLessThan(fitted, MuscleRecovery.defaultTauSeconds(for: .chest),
                          "eight answers of \"fresh after a day\" should pull the curve in")
    }

    /// And the guard on it: one answer on a bad evening must not redraw the curve. Shrinkage keeps the
    /// default in charge until there is enough said to overrule it.
    func testOneAnswerBarelyMovesTheConstant() {
        let templates = ["BP": template("BP", primary: .chest, type: "duration")]
        let workouts = [
            workout("a", at: Self.ts("2026-05-04"), [exercise("BP", [set(0, rpe: 10)])]),
            workout("b", at: Self.ts("2026-05-11"), [exercise("BP", [set(0, rpe: 10)])]),
        ]
        let one = [MuscleRecovery.Observation(group: .chest, ts: Self.ts("2026-05-12"),
                                              feeling: .stillWrecked)]
        let fitted = MuscleRecovery.fittedTauSeconds(for: .chest, observations: one,
                                                     workouts: workouts, templates: templates)
        XCTAssertEqual(fitted, MuscleRecovery.defaultTauSeconds(for: .chest), accuracy: 1,
                       "below two answers the default stands unchanged")
    }

    /// A muscle nobody has rated keeps the assumed default rather than borrowing another muscle's fit.
    func testAnUnratedMuscleKeepsTheDefault() {
        let templates = ["BP": template("BP", primary: .chest, type: "duration")]
        let workouts = [workout("a", at: Self.ts("2026-05-04"), [exercise("BP", [set(0, rpe: 10)])])]
        XCTAssertEqual(
            MuscleRecovery.fittedTauSeconds(for: .quadriceps, observations: [], workouts: workouts,
                                            templates: templates),
            MuscleRecovery.defaultTauSeconds(for: .quadriceps))
    }

    /// Under three training weeks there is no typical value to report — and a caller that gets nothing
    /// is expected to say so rather than draw a reference out of two points.
    func testFewerThanThreeTrainingWeeksYieldNoAnchor() {
        // The max single shares a week with the first session ON PURPOSE. My first attempt put it in a
        // week of its own, which made three training weeks instead of two and the test passed for the
        // wrong reason — a lifted set is a lifted set, even when its job in the fixture is to
        // establish a reference.
        let workouts = [
            workout("pr", at: Self.ts("2026-05-11"), [exercise("BP", [set(0, kg: 100, reps: 1)])]),
            workout("a", at: Self.ts("2026-05-13"), [exercise("BP", [set(0, kg: 80, reps: 5, rpe: 9)])]),
            workout("b", at: Self.ts("2026-05-20"), [exercise("BP", [set(0, kg: 80, reps: 5, rpe: 9)])]),
        ]
        XCTAssertTrue(MuscleStimulus.typicalWeeklyStimulus(workouts, templates: bench,
                                                           endingBefore: "2026-05-27").isEmpty)
    }

    // MARK: - The secondary tally counts a group once

    /// A template that names the same secondary group twice must be credited ONCE for a set.
    ///
    /// Hevy's `secondary_muscle_groups` is a list, not a set, and two of its labels can map onto one of
    /// ours — `HevyMuscleGroup.parse` folds everything it does not recognise onto `.other`, so two
    /// unknown labels on one exercise arrive as `[.other, .other]`. `StrengthSession` de-duplicated its
    /// count and the stimulus estimate did not, which meant one screen's set count and the same
    /// screen's colour disagreed with nothing on it to say which was right.
    func testASecondaryGroupListedTwiceIsCreditedOnce() throws {
        let templates = ["BP": template("BP", primary: .chest, secondary: [.triceps, .triceps])]
        let session = workout("a", at: Self.ts("2026-07-08"),
                              [exercise("BP", [set(0, kg: 100, reps: 5, rpe: 9)])])
        let result = MuscleStimulus.stimulus(
            for: [session], templates: templates,
            reference: MuscleStimulus.StrengthReference(workouts: [session], templates: templates))
        let chest = try XCTUnwrap(result.byMuscle[.chest])
        XCTAssertGreaterThan(chest, 0)
        XCTAssertEqual(try XCTUnwrap(result.byMuscle[.triceps]),
                       chest * MuscleStimulus.secondaryShare, accuracy: 1e-9)
    }

    // MARK: - The index says exactly what the one-shot computation says

    /// The priced index must agree with `stimulus(for:)` muscle for muscle.
    ///
    /// This is the guard on the optimisation, not on the arithmetic: the index exists only so a screen
    /// stops rebuilding the strength reference dozens of times, and the moment it answers differently
    /// it has stopped being the same feature. Asserted over a history with a rated set, an unrated set,
    /// an exercise with no reference and an unattributable one, because those are the four paths
    /// `setStimulus` can take.
    func testTheIndexAgreesWithTheOneShotComputation() throws {
        let templates = [
            "BP": template("BP", primary: .chest, secondary: [.triceps]),
            "PL": template("PL", primary: .abdominals, type: "duration"),
        ]
        let workouts = [
            workout("pr", at: Self.ts("2026-07-01"), [exercise("BP", [set(0, kg: 100, reps: 1)])]),
            workout("a", at: Self.ts("2026-07-03"), [exercise("BP", [set(0, kg: 80, reps: 5, rpe: 9)]),
                                                     exercise("PL", [set(0, rpe: 8)])]),
            workout("b", at: Self.ts("2026-07-06"), [exercise("BP", [set(0, kg: 60, reps: 8)]),
                                                     exercise(nil, [set(0, kg: 20, reps: 12)])]),
        ]
        let reference = MuscleStimulus.StrengthReference(workouts: workouts, templates: templates)
        let oneShot = MuscleStimulus.stimulus(for: workouts, templates: templates, reference: reference)
        let index = MuscleStimulus.SessionStimulusIndex(workouts: workouts, templates: templates)
        let fromIndex = index.total()

        XCTAssertEqual(fromIndex.workingSetCount, oneShot.workingSetCount)
        XCTAssertEqual(fromIndex.ratedSetCount, oneShot.ratedSetCount)
        XCTAssertEqual(Set(fromIndex.byMuscle.keys), Set(oneShot.byMuscle.keys))
        for (group, value) in oneShot.byMuscle {
            XCTAssertEqual(try XCTUnwrap(fromIndex.byMuscle[group]), value, accuracy: 1e-9,
                           "\(group) disagrees between the index and the one-shot computation")
        }
    }

    /// The index-fed decay must equal the history-fed one. Same guard, one layer up: `fatigue` is what
    /// the "right now" map is coloured by, and the convenience overload is what the tests above use.
    func testTheIndexFedDecayMatchesTheHistoryFedOne() throws {
        let templates = ["BP": template("BP", primary: .chest, secondary: [.triceps])]
        let workouts = [
            workout("pr", at: Self.ts("2026-07-01"), [exercise("BP", [set(0, kg: 100, reps: 1)])]),
            workout("a", at: Self.ts("2026-07-04"), [exercise("BP", [set(0, kg: 85, reps: 5, rpe: 9)])]),
        ]
        let now = Self.ts("2026-07-06")
        let direct = MuscleRecovery.fatigue(workouts: workouts, templates: templates, now: now)
        let indexed = MuscleRecovery.fatigue(
            index: MuscleStimulus.SessionStimulusIndex(workouts: workouts, templates: templates),
            now: now)
        XCTAssertEqual(Set(direct.keys), Set(indexed.keys))
        for (group, value) in direct {
            XCTAssertEqual(try XCTUnwrap(indexed[group]), value, accuracy: 1e-9)
        }
    }

    /// A session in the FUTURE contributes nothing, through the index as it did through the history.
    /// The window guard is the sort of thing an optimisation quietly drops.
    func testAFutureSessionStillContributesNothing() {
        let templates = ["BP": template("BP", primary: .chest)]
        let workouts = [workout("later", at: Self.ts("2026-08-01"),
                                [exercise("BP", [set(0, kg: 80, reps: 5, rpe: 9)])])]
        let indexed = MuscleRecovery.fatigue(
            index: MuscleStimulus.SessionStimulusIndex(workouts: workouts, templates: templates),
            now: Self.ts("2026-07-20"))
        XCTAssertTrue(indexed.isEmpty)
    }
}
