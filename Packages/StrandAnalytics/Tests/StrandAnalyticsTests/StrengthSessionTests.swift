import XCTest
import WhoopStore
@testable import StrandAnalytics

/// Pins the strength derivations — the arithmetic behind everything the Strength screen and the coach
/// will say about a lifting session.
///
/// Most of these tests exist to hold a piece of RESTRAINT in place rather than a calculation. It is
/// easy, and tempting, for a later change to make these numbers look more precise than the log is:
/// counting a warmup as work, crediting a secondary muscle with half a set, estimating a 1RM from a
/// set of twenty, or defaulting an unrated set to "moderate". Each of those would compile, would look
/// like an improvement, and would put invented data in front of someone making training decisions.
final class StrengthSessionTests: XCTestCase {

    // MARK: - Fixtures

    private func set(_ index: Int, _ type: HevySetType = .normal,
                     kg: Double? = nil, reps: Int? = nil, rpe: Double? = nil) -> HevySet {
        HevySet(index: index, type: type, weightKg: kg, reps: reps,
                distanceM: nil, durationS: nil, rpe: rpe, customMetric: nil)
    }

    private func exercise(_ index: Int, templateId: String?, sets: [HevySet],
                          title: String = "Exercise") -> HevyExercise {
        HevyExercise(index: index, title: title, templateId: templateId,
                     supersetId: nil, notes: nil, sets: sets)
    }

    private func workout(id: String = "w1", startTs: Int = 1_788_282_000,
                         _ exercises: [HevyExercise]) -> HevyWorkout {
        HevyWorkout(id: id, title: "Push", routineId: nil, notes: nil,
                    startTs: startTs, endTs: startTs + 3600,
                    updatedAtTs: startTs, createdAtTs: startTs, exercises: exercises)
    }

    private func template(_ id: String, primary: HevyMuscleGroup,
                          secondary: [HevyMuscleGroup] = [],
                          type: String = "weight_reps") -> HevyExerciseTemplate {
        HevyExerciseTemplate(id: id, title: id, type: type, primaryMuscleGroup: primary,
                             secondaryMuscleGroups: secondary, equipment: .barbell, isCustom: false)
    }

    private var bench: [String: HevyExerciseTemplate] {
        ["T1": template("T1", primary: .chest, secondary: [.triceps, .shoulders])]
    }

    // MARK: - e1RM

    /// A single rep returns the weight itself. Epley's formula gives w·1.033 at r=1, which would
    /// report a 100 kg single as a 103 kg maximum — a "PR" the lifter never made.
    func testASingleRepEstimateIsTheWeightItself() {
        XCTAssertEqual(OneRepMax.epley(weightKg: 100, reps: 1), 100)
    }

    /// The published formula, unaltered, in its normal range.
    func testEpleyMatchesThePublishedFormula() throws {
        let e = try XCTUnwrap(OneRepMax.epley(weightKg: 100, reps: 5))
        XCTAssertEqual(e, 100 * (1 + 5.0 / 30.0), accuracy: 1e-9)   // 116.67
        let f = try XCTUnwrap(OneRepMax.epley(weightKg: 80, reps: 10))
        XCTAssertEqual(f, 80 * (1 + 10.0 / 30.0), accuracy: 1e-9)
    }

    /// THE restraint test. Past twelve reps the rep-max formulas disagree with each other by more than
    /// the trend anyone is trying to read, so no number is offered. Returning one anyway is how a set
    /// of twenty at 60 kg becomes a fake 100 kg "personal record".
    func testNoEstimateIsOfferedAboveTwelveReps() {
        XCTAssertNotNil(OneRepMax.epley(weightKg: 60, reps: 12))
        XCTAssertNil(OneRepMax.epley(weightKg: 60, reps: 13))
        XCTAssertNil(OneRepMax.epley(weightKg: 60, reps: 20))
    }

    func testNoEstimateWithoutAPositiveWeightOrRep() {
        XCTAssertNil(OneRepMax.epley(weightKg: 0, reps: 5))
        XCTAssertNil(OneRepMax.epley(weightKg: -10, reps: 5))
        XCTAssertNil(OneRepMax.epley(weightKg: 100, reps: 0))
    }

    /// A warmup never produces an estimate — it is not a maximal effort and was never meant to be.
    func testAWarmupSetYieldsNoEstimate() {
        XCTAssertNil(OneRepMax.forSet(set(0, .warmup, kg: 100, reps: 5),
                                      template: template("T1", primary: .chest)))
    }

    /// A 1RM is undefined for a plank or a distance row, and the catalogue says which is which.
    func testAKnownNonWeightRepsExerciseYieldsNoEstimate() {
        let plank = template("P", primary: .abdominals, type: "duration")
        XCTAssertNil(OneRepMax.forSet(set(0, kg: 20, reps: 5), template: plank))
    }

    /// But an UNKNOWN template with a weight and reps still gets one: the set is the evidence, and
    /// blanking a real movement's trend because the catalogue has not synced yet helps nobody.
    func testAnUnknownTemplateWithWeightAndRepsStillEstimates() {
        XCTAssertNotNil(OneRepMax.forSet(set(0, kg: 100, reps: 5), template: nil))
    }

    // MARK: - Session summary

    func testWarmupsAreExcludedFromEverySessionFigure() {
        let w = workout([exercise(0, templateId: "T1", sets: [
            set(0, .warmup, kg: 40, reps: 10),   // must not count anywhere
            set(1, kg: 100, reps: 5),
            set(2, kg: 100, reps: 5),
        ])])
        let s = StrengthSession.summarize(w, templates: bench)
        XCTAssertEqual(s.workingSetCount, 2)
        XCTAssertEqual(s.totalReps, 10, "the warmup's ten reps are not training volume")
        XCTAssertEqual(s.volumeLoadKg, 1000, accuracy: 1e-9)
        XCTAssertEqual(s.heaviestSetKg, 100)
    }

    /// Dropsets and sets taken to failure are HARDER than a normal set, not softer. Excluding them
    /// would understate exactly the sessions that cost the most to recover from.
    func testDropsetsAndFailureSetsCountAsWork() {
        let w = workout([exercise(0, templateId: "T1", sets: [
            set(0, .normal, kg: 100, reps: 5),
            set(1, .dropset, kg: 70, reps: 8),
            set(2, .failure, kg: 60, reps: 10),
        ])])
        let s = StrengthSession.summarize(w, templates: bench)
        XCTAssertEqual(s.workingSetCount, 3)
        XCTAssertEqual(s.volumeLoadKg, 500 + 560 + 600, accuracy: 1e-9)
    }

    /// A bodyweight set is real work with no volume to claim. Volume load alone would read a
    /// calisthenics day as an easy one, which is why the coverage count sits beside it.
    func testBodyweightSetsCountAsWorkButAddNoVolume() {
        let w = workout([exercise(0, templateId: "T1", sets: [
            set(0, kg: 100, reps: 5),
            set(1, reps: 12),               // pull-ups: reps, no weight
        ])])
        let s = StrengthSession.summarize(w, templates: bench)
        XCTAssertEqual(s.workingSetCount, 2)
        XCTAssertEqual(s.totalReps, 17)
        XCTAssertEqual(s.volumeLoadKg, 500, accuracy: 1e-9)
        XCTAssertEqual(s.volumeSetCount, 1, "one of the two sets could contribute volume")
    }

    // MARK: - Muscle groups

    /// THE convention test. A set counts ONCE, on the primary muscle. Secondary involvement is
    /// reported alongside and never folded in — the "half a set for a secondary muscle" figure that
    /// would otherwise appear has no measurement behind it, and it would make every per-muscle number
    /// look more precise than the log is.
    func testSetsCountOnceOnThePrimaryMuscleWithSecondariesReportedSeparately() {
        let w = workout([exercise(0, templateId: "T1", sets: [
            set(0, kg: 100, reps: 5), set(1, kg: 100, reps: 5), set(2, kg: 100, reps: 5),
        ])])
        let s = StrengthSession.summarize(w, templates: bench)
        XCTAssertEqual(s.hardSetsByMuscle, [.chest: 3])
        XCTAssertEqual(s.secondarySetsByMuscle, [.triceps: 3, .shoulders: 3])
        XCTAssertNil(s.hardSetsByMuscle[.triceps],
                     "a secondary muscle must never appear in the primary tally")
    }

    /// A group listed twice in the catalogue's secondary array must not double-count.
    func testARepeatedSecondaryGroupIsCountedOnce() {
        let templates = ["T1": template("T1", primary: .chest, secondary: [.triceps, .triceps])]
        let w = workout([exercise(0, templateId: "T1", sets: [set(0, kg: 100, reps: 5)])])
        let s = StrengthSession.summarize(w, templates: templates)
        XCTAssertEqual(s.secondarySetsByMuscle[.triceps], 1)
    }

    /// Work whose exercise is not in the catalogue is COUNTED as unattributed, not dropped. A
    /// per-muscle chart that silently omits a fifth of the session is worse than one that says so.
    func testUnattributableWorkIsReportedRatherThanDiscarded() {
        let w = workout([
            exercise(0, templateId: "T1", sets: [set(0, kg: 100, reps: 5)]),
            exercise(1, templateId: "UNKNOWN", sets: [set(0, kg: 50, reps: 8), set(1, kg: 50, reps: 8)]),
        ])
        let s = StrengthSession.summarize(w, templates: bench)
        XCTAssertEqual(s.workingSetCount, 3, "unattributed work is still work")
        XCTAssertEqual(s.unattributedSetCount, 2)
        XCTAssertEqual(s.hardSetsByMuscle, [.chest: 1])
        XCTAssertEqual(s.volumeLoadKg, 500 + 800, accuracy: 1e-9, "and it still has volume")
    }

    // MARK: - RPE

    /// RPE is never imputed and never defaulted. "Not rated" is not "moderate", and a mean that
    /// quietly included unrated sets would drift toward whatever the default was.
    func testRpeIsAveragedOnlyOverRatedSetsAndReportsItsCoverage() {
        let w = workout([exercise(0, templateId: "T1", sets: [
            set(0, kg: 100, reps: 5, rpe: 8),
            set(1, kg: 100, reps: 5, rpe: 9),
            set(2, kg: 100, reps: 5),          // not rated
            set(3, kg: 100, reps: 5),          // not rated
        ])])
        let s = StrengthSession.summarize(w, templates: bench)
        XCTAssertEqual(s.meanRpe, 8.5)
        XCTAssertEqual(s.rpeSetCount, 2)
        XCTAssertEqual(s.rpeCoverage, 0.5, accuracy: 1e-9)
    }

    func testASessionWithNoRpeReportsNilNotAMiddlingDefault() {
        let w = workout([exercise(0, templateId: "T1", sets: [set(0, kg: 100, reps: 5)])])
        let s = StrengthSession.summarize(w, templates: bench)
        XCTAssertNil(s.meanRpe)
        XCTAssertEqual(s.rpeCoverage, 0)
    }

    // MARK: - Exercise history

    /// The trend the Strength screen draws: rising e1RM at a falling RPE is the shape a lifter cares
    /// about, and it has to come out of the log rather than out of a sentence the model wrote.
    func testExerciseHistoryTracksE1rmAndRpeOverTime() throws {
        let day: Int = 86_400
        let workouts = [
            workout(id: "a", startTs: 1_788_282_000, [exercise(0, templateId: "T1",
                sets: [set(0, kg: 100, reps: 5, rpe: 9)])]),
            workout(id: "b", startTs: 1_788_282_000 + 7 * day, [exercise(0, templateId: "T1",
                sets: [set(0, kg: 105, reps: 5, rpe: 8)])]),
            workout(id: "c", startTs: 1_788_282_000 + 14 * day, [exercise(0, templateId: "T1",
                sets: [set(0, kg: 110, reps: 5, rpe: 7.5)])]),
        ]
        let points = StrengthSession.exerciseHistory(templateId: "T1", workouts: workouts,
                                                     templates: bench)
        XCTAssertEqual(points.count, 3)
        XCTAssertEqual(points.map(\.startTs), points.map(\.startTs).sorted(), "oldest first")
        let e1rms = try points.map { try XCTUnwrap($0.bestE1RMKg) }
        XCTAssertEqual(e1rms, e1rms.sorted(), "the estimate rises with the load")
        XCTAssertEqual(points.map(\.meanRpe), [9, 8, 7.5])
        XCTAssertEqual(points.map(\.heaviestSetKg), [100, 105, 110])
    }

    /// The best set of the day wins, not the last one — a lifter's top set is usually not their final.
    func testAdaysBestSetDrivesItsPoint() throws {
        let w = workout([exercise(0, templateId: "T1", sets: [
            set(0, kg: 100, reps: 5),
            set(1, kg: 120, reps: 3),    // the top set
            set(2, kg: 80, reps: 8),     // a back-off set
        ])])
        let p = try XCTUnwrap(StrengthSession.exerciseHistory(templateId: "T1", workouts: [w],
                                                              templates: bench).first)
        XCTAssertEqual(p.heaviestSetKg, 120)
        XCTAssertEqual(try XCTUnwrap(p.bestE1RMKg), 120 * (1 + 3.0 / 30.0), accuracy: 1e-9)
    }

    /// History is keyed by template id, not title. A renamed (or localised) exercise must not split
    /// one movement's history into two unrelated curves.
    func testHistoryFollowsTheTemplateIdNotTheTitle() {
        let workouts = [
            workout(id: "a", startTs: 1_788_282_000,
                    [exercise(0, templateId: "T1", sets: [set(0, kg: 100, reps: 5)], title: "Bench Press")]),
            workout(id: "b", startTs: 1_788_368_400,
                    [exercise(0, templateId: "T1", sets: [set(0, kg: 105, reps: 5)], title: "Bankdrücken")]),
        ]
        XCTAssertEqual(StrengthSession.exerciseHistory(templateId: "T1", workouts: workouts,
                                                       templates: bench).count, 2)
    }

    /// A session containing only warmups of the exercise produces no point at all — there is no
    /// performance to plot.
    func testASessionOfOnlyWarmupsProducesNoPoint() {
        let w = workout([exercise(0, templateId: "T1", sets: [set(0, .warmup, kg: 40, reps: 10)])])
        XCTAssertTrue(StrengthSession.exerciseHistory(templateId: "T1", workouts: [w],
                                                      templates: bench).isEmpty)
    }

    // MARK: - Across a window

    func testHardSetsPerMuscleAccumulateAcrossSessions() {
        let templates = [
            "T1": template("T1", primary: .chest, secondary: [.triceps]),
            "T2": template("T2", primary: .quadriceps),
        ]
        let workouts = [
            workout(id: "a", startTs: 1_788_282_000,
                    [exercise(0, templateId: "T1", sets: [set(0, kg: 100, reps: 5), set(1, kg: 100, reps: 5)])]),
            workout(id: "b", startTs: 1_788_368_400,
                    [exercise(0, templateId: "T2", sets: [set(0, kg: 140, reps: 5)])]),
            workout(id: "c", startTs: 1_788_454_800,
                    [exercise(0, templateId: "T1", sets: [set(0, kg: 100, reps: 5)])]),
        ]
        let out = StrengthSession.hardSetsByMuscle(workouts, templates: templates)
        XCTAssertEqual(out.primary, [.chest: 3, .quadriceps: 1])
        XCTAssertEqual(out.secondary, [.triceps: 3])
        XCTAssertEqual(out.unattributed, 0)
    }

    /// The bridge to the existing effect machinery: a set of day keys is exactly what
    /// `EffectRanker.rank` takes as a behaviour, so "leg day" becomes measurable against tomorrow's
    /// Charge with no new statistics at all.
    func testDayKeysAreTheShapeTheEffectRankerWants() {
        let workouts = [
            workout(id: "a", startTs: 1_788_282_000, []),   // 2026-09-01 UTC
            workout(id: "b", startTs: 1_788_368_400, []),   // 2026-09-02 UTC
            workout(id: "c", startTs: 1_788_290_000, []),   // same day as `a`
        ]
        XCTAssertEqual(StrengthSession.dayKeys(workouts), ["2026-09-01", "2026-09-02"])
    }

    func testExerciseFrequencyRanksTheMostTrainedFirst() {
        let workouts = [
            workout(id: "a", startTs: 1, [exercise(0, templateId: "T1", sets: [set(0, kg: 1, reps: 1)]),
                                          exercise(1, templateId: "T2", sets: [set(0, kg: 1, reps: 1)])]),
            workout(id: "b", startTs: 2, [exercise(0, templateId: "T1", sets: [set(0, kg: 1, reps: 1)])]),
        ]
        let ranked = StrengthSession.exerciseFrequency(workouts)
        XCTAssertEqual(ranked.first?.templateId, "T1")
        XCTAssertEqual(ranked.first?.sessions, 2)
    }

    // MARK: - Weeks, load and the user's own range

    /// A day-noon timestamp, so a session lands unambiguously on its day key.
    private func ts(_ day: String) -> Int {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return Int((f.date(from: day) ?? Date(timeIntervalSince1970: 0)).timeIntervalSince1970) + 43_200
    }

    private func dayWorkout(_ day: String, sets: Int, templateId: String = "T1") -> HevyWorkout {
        HevyWorkout(id: "\(day)-\(templateId)", title: "", routineId: nil, notes: nil,
                    startTs: ts(day), endTs: ts(day) + 3600, updatedAtTs: ts(day),
                    createdAtTs: ts(day),
                    exercises: [exercise(0, templateId: templateId,
                                         sets: (0..<sets).map { set($0, kg: 100, reps: 5) })])
    }

    /// The week is Monday–Sunday and anchored the same way `WeeklyDigestEngine` anchors it. Two
    /// different week boundaries in one app is how the same session lands in different weeks on two
    /// screens.
    func testTheWeekIsMondayToSundayAndExcludesNeighbours() {
        // 2026-06-01 is a Monday.
        let workouts = [
            dayWorkout("2026-05-31", sets: 5),   // the Sunday before
            dayWorkout("2026-06-01", sets: 4),
            dayWorkout("2026-06-07", sets: 6),   // the Sunday inside
            dayWorkout("2026-06-08", sets: 9),   // the Monday after
        ]
        let week = StrengthSession.week(containing: "2026-06-03", workouts: workouts,
                                        templates: bench)
        XCTAssertEqual(week.mondayKey, "2026-06-01")
        XCTAssertEqual(week.sessionCount, 2)
        XCTAssertEqual(week.workingSetCount, 10)
    }

    // MARK: - Acute vs chronic

    /// THE reason this is a ratio and not a score: it says something checkable. A steady routine sits
    /// near 1.0 whatever the absolute volume, so the figure means the same thing for someone doing four
    /// sets a week and someone doing forty.
    func testASteadyRoutineSitsNearOne() throws {
        var workouts: [HevyWorkout] = []
        var day = "2026-04-01"
        for index in 0..<60 {
            if index % 2 == 0 { workouts.append(dayWorkout(day, sets: 10)) }
            day = WeeklyDigestEngine.addDays(day, 1)
        }
        let now = Self.date("2026-05-30")
        let load = try XCTUnwrap(StrengthSession.setLoadRatio(workouts, asOf: now))
        XCTAssertEqual(load.ratio, 1.0, accuracy: 0.15)
        XCTAssertEqual(load.band, .steady)
    }

    /// A genuine ramp is reported as one, in the band the literature uses.
    func testARampIsReportedAsBuildingOrSpiking() throws {
        var workouts: [HevyWorkout] = []
        var day = "2026-04-01"
        for index in 0..<60 {
            // The last week carries three times the usual volume.
            let sets = index >= 53 ? 30 : 10
            if index % 2 == 0 { workouts.append(dayWorkout(day, sets: sets)) }
            day = WeeklyDigestEngine.addDays(day, 1)
        }
        let load = try XCTUnwrap(StrengthSession.setLoadRatio(workouts, asOf: Self.date("2026-05-30")))
        XCTAssertGreaterThan(load.ratio, 1.5)
        XCTAssertEqual(load.band, .spiking)
    }

    /// Rest days are ZEROS, not gaps. Averaging only the days that held a session would make someone who
    /// trained twice this week look identical to someone who trained six times — which is the difference
    /// between "load" and "how hard were the days I trained".
    func testRestDaysCountAsZeroLoad() throws {
        var workouts: [HevyWorkout] = []
        var day = "2026-04-01"
        for index in 0..<60 {
            // Trains every other day for a month, then only once in the final week.
            let trains = index >= 53 ? (index == 55) : (index % 2 == 0)
            if trains { workouts.append(dayWorkout(day, sets: 10)) }
            day = WeeklyDigestEngine.addDays(day, 1)
        }
        let load = try XCTUnwrap(StrengthSession.setLoadRatio(workouts, asOf: Self.date("2026-05-30")))
        XCTAssertLessThan(load.ratio, 0.8, "a week that was mostly rest is a ramp DOWN")
        XCTAssertEqual(load.band, .rampingDown)
    }

    /// Too little history means NO ratio. One computed from a fortnight is mostly a statement about how
    /// little data there is.
    func testTooLittleHistoryYieldsNoRatio() {
        let workouts = (0..<4).map { dayWorkout(WeeklyDigestEngine.addDays("2026-05-20", $0), sets: 10) }
        XCTAssertNil(StrengthSession.setLoadRatio(workouts, asOf: Self.date("2026-05-24")))
    }

    /// The windows and the bands are READ from `ReadinessEngine`, never copied — so the app cannot hold
    /// two definitions of "acute load", one for heart rate and one for sets.
    func testTheWindowsComeFromTheOneDefinition() {
        XCTAssertEqual(ReadinessEngine.acuteWindow, 7)
        XCTAssertEqual(ReadinessEngine.chronicWindow, 28)
        XCTAssertEqual(ReadinessEngine.LoadBand.of(ratio: 0.5), .rampingDown)
        XCTAssertEqual(ReadinessEngine.LoadBand.of(ratio: 1.0), .steady)
        XCTAssertEqual(ReadinessEngine.LoadBand.of(ratio: 1.4), .buildingFast)
        XCTAssertEqual(ReadinessEngine.LoadBand.of(ratio: 2.0), .spiking)
    }

    // MARK: - The user's own range

    /// A BAND, not a target — built from the user's own completed weeks. This is what replaces the
    /// "12 / 14" of a design mockup: NOOP has no evidence about what anyone's correct weekly volume is,
    /// but it knows what this person has been doing.
    func testTheTypicalBandComesFromTheUsersOwnWeeks() throws {
        var workouts: [HevyWorkout] = []
        // Eight completed weeks of 10, 12, 10, 14, 10, 12, 10, 14 chest sets.
        let weekly = [10, 12, 10, 14, 10, 12, 10, 14]
        var monday = "2026-04-06"
        for sets in weekly {
            workouts.append(dayWorkout(monday, sets: sets))
            monday = WeeklyDigestEngine.addDays(monday, 7)
        }
        let bands = StrengthSession.typicalWeeklySets(workouts, templates: bench,
                                                      endingBefore: monday)
        let chest = try XCTUnwrap(bands[.chest])
        XCTAssertGreaterThanOrEqual(chest.lowerBound, 10)
        XCTAssertLessThanOrEqual(chest.upperBound, 14)
        XCTAssertLessThan(chest.lowerBound, chest.upperBound)
    }

    /// Weeks with NO training are excluded. A stretch away or ill is not evidence about someone's usual
    /// volume, and counting it as a run of zeros would drag every band down and then report the return
    /// to normal as unusually high.
    func testWeeksWithoutTrainingDoNotDragTheBandDown() throws {
        var workouts: [HevyWorkout] = []
        var monday = "2026-04-06"
        for index in 0..<8 {
            if index != 3 && index != 4 {           // two weeks off in the middle
                workouts.append(dayWorkout(monday, sets: 12))
            }
            monday = WeeklyDigestEngine.addDays(monday, 7)
        }
        let bands = StrengthSession.typicalWeeklySets(workouts, templates: bench,
                                                      endingBefore: monday)
        let chest = try XCTUnwrap(bands[.chest])
        XCTAssertEqual(chest.lowerBound, 12, accuracy: 0.001)
        XCTAssertEqual(chest.upperBound, 12, accuracy: 0.001)
    }

    /// A muscle group never trained gets NO band rather than a 0…0 reference the reader would have to
    /// interpret.
    func testAnUntrainedGroupHasNoBand() {
        var workouts: [HevyWorkout] = []
        var monday = "2026-04-06"
        for _ in 0..<8 {
            workouts.append(dayWorkout(monday, sets: 12))
            monday = WeeklyDigestEngine.addDays(monday, 7)
        }
        let bands = StrengthSession.typicalWeeklySets(workouts, templates: bench,
                                                      endingBefore: monday)
        XCTAssertNil(bands[.quadriceps])
    }

    /// Fewer than three completed weeks is not a range. Two points would produce a "band" that is really
    /// just the two values, presented with the authority of a distribution.
    func testFewerThanThreeWeeksYieldsNoBand() {
        let workouts = [
            dayWorkout("2026-04-06", sets: 12),
            dayWorkout("2026-04-13", sets: 14),
        ]
        let bands = StrengthSession.typicalWeeklySets(workouts, templates: bench,
                                                      endingBefore: "2026-04-20")
        XCTAssertTrue(bands.isEmpty)
    }

    private static func date(_ day: String) -> Date {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return (f.date(from: day) ?? Date(timeIntervalSince1970: 0)).addingTimeInterval(43_200)
    }

    // MARK: - Muscle load: what was worked, and when

    private func tsAt(_ day: String) -> Int { Int(Self.date(day).timeIntervalSince1970) }

    private var legsAndPush: [String: HevyExerciseTemplate] {
        ["SQ": template("SQ", primary: .quadriceps),
         "LP": template("LP", primary: .quadriceps),
         "BP": template("BP", primary: .chest, secondary: [.triceps])]
    }

    /// The most recent session that trained a muscle wins, and the exercise reported is the one that
    /// did the most work on it — not merely the first one listed.
    func testLastWorkedReportsTheMostRecentSessionAndItsMainExercise() throws {
        let older = workout(id: "a", startTs: tsAt("2026-08-01"), [
            exercise(0, templateId: "SQ", sets: [set(0, kg: 100, reps: 5)], title: "Back Squat"),
        ])
        let newer = workout(id: "b", startTs: tsAt("2026-08-05"), [
            exercise(0, templateId: "SQ", sets: [set(0, kg: 100, reps: 5)], title: "Back Squat"),
            exercise(1, templateId: "LP", sets: [set(0, kg: 200, reps: 8), set(1, kg: 200, reps: 8),
                                                 set(2, kg: 200, reps: 8)], title: "Leg Press"),
        ])
        // Deliberately out of order: the function must not depend on the caller sorting for it.
        let out = StrengthSession.lastWorkedByMuscle([newer, older], templates: legsAndPush)
        let quads = try XCTUnwrap(out[.quadriceps])
        XCTAssertEqual(quads.day, "2026-08-05")
        XCTAssertEqual(quads.exercise, "Leg Press", "three sets beat one, regardless of listing order")
    }

    /// A muscle that only ASSISTED was not worked. The bench press lists triceps as secondary, and the
    /// rest of the screen counts a set once on its primary muscle — reporting "triceps, today" here
    /// would make the same word mean two different things in two places on one screen.
    func testSecondaryInvolvementDoesNotCountAsWorked() {
        let w = workout(id: "a", startTs: tsAt("2026-08-05"), [
            exercise(0, templateId: "BP", sets: [set(0, kg: 80, reps: 5)], title: "Bench Press"),
        ])
        let out = StrengthSession.lastWorkedByMuscle([w], templates: legsAndPush)
        XCTAssertNotNil(out[.chest])
        XCTAssertNil(out[.triceps], "assisting is not being trained")
    }

    /// Warmup sets are not work, so a muscle that only saw warmups was not worked at all.
    func testAMuscleWithOnlyWarmupSetsIsNotWorked() {
        let w = workout(id: "a", startTs: tsAt("2026-08-05"), [
            exercise(0, templateId: "SQ", sets: [set(0, .warmup, kg: 60, reps: 5)], title: "Back Squat"),
        ])
        XCTAssertTrue(StrengthSession.lastWorkedByMuscle([w], templates: legsAndPush).isEmpty)
    }

    /// The window boundary, pinned. Half-open at the start, inclusive at the end: a session exactly
    /// `days` old is out, one from today is in. An off-by-one here silently changes every number on
    /// the body map, and nothing on screen would look wrong.
    func testTheRecentWindowExcludesTheOldestEdgeAndIncludesToday() {
        let now = tsAt("2026-08-08")
        let exactlySevenDaysOld = workout(id: "a", startTs: now - 7 * 86_400, [
            exercise(0, templateId: "SQ", sets: [set(0, kg: 100, reps: 5)]),
        ])
        let justInside = workout(id: "b", startTs: now - 7 * 86_400 + 1, [
            exercise(0, templateId: "SQ", sets: [set(0, kg: 100, reps: 5)]),
        ])
        let today = workout(id: "c", startTs: now, [
            exercise(0, templateId: "SQ", sets: [set(0, kg: 100, reps: 5)]),
        ])
        let out = StrengthSession.recentSetsByMuscle([exactlySevenDaysOld, justInside, today],
                                                     templates: legsAndPush, days: 7, now: now)
        XCTAssertEqual(out[.quadriceps], 2, "the 7-day-old session is out; the other two are in")
    }

    /// A session in the future — a clock skew, a bad import — must not be counted as recent.
    func testAFutureSessionIsNotCountedAsRecent() {
        let now = tsAt("2026-08-08")
        let tomorrow = workout(id: "a", startTs: now + 86_400, [
            exercise(0, templateId: "SQ", sets: [set(0, kg: 100, reps: 5)]),
        ])
        let out = StrengthSession.recentSetsByMuscle([tomorrow], templates: legsAndPush,
                                                     days: 7, now: now)
        XCTAssertNil(out[.quadriceps])
    }

    /// An exercise performed twice in ONE session counts as one session for it, not two.
    func testFrequencyCountsSessionsNotOccurrences() {
        let w = workout([
            exercise(0, templateId: "T1", sets: [set(0, kg: 100, reps: 5)]),
            exercise(1, templateId: "T1", sets: [set(0, kg: 90, reps: 8)]),
        ])
        XCTAssertEqual(StrengthSession.exerciseFrequency([w]).first?.sessions, 1)
    }
}
