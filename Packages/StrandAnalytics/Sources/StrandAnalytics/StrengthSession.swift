import Foundation
import WhoopStore

// MARK: - Strength derivations from Hevy sessions — pure, deterministic, DB-free
//
// What NOOP can honestly say about a logged strength session, and nothing more.
//
// THE GOVERNING RULE HERE IS RESTRAINT. There is no "strength score". A single number blending sets,
// volume, RPE and muscle groups would be arithmetic dressed as physiology: the weights would be
// invented, no published model backs them, and the reader could not tell which input moved it. Every
// figure below is instead one thing, computable from the log, and nameable in a sentence:
//
//   • working sets     — sets that were not warmups. A count, not a weighting.
//   • volume load      — Σ(weight × reps). Transparent, and it says so in the name.
//   • e1RM             — one published formula (Epley), applied only where it is defined.
//   • hard sets / group— counted on the PRIMARY muscle only. Secondary involvement is reported
//                        alongside, never folded in with a made-up fraction.
//   • RPE              — as logged, with coverage. Never imputed.
//
// The one place a convention could have crept in is the fractional-set idea (a secondary muscle counts
// as half a set). It is deliberately absent: the "0.5" has no measurement behind it, and it would make
// every per-muscle number look more precise than the log actually is.

/// The estimated one-rep maximum for a set.
///
/// **Epley**: `1RM = w · (1 + r/30)`. When a valid set RPE exists, `r` is completed reps plus the
/// corresponding reps in reserve (`10 − RPE`). This keeps two equally weighted sets from receiving
/// the same estimate when one stopped several repetitions earlier. Without a rating the published
/// completed-rep formula remains unchanged rather than guessing reserve.
///
/// It is an ESTIMATE and the surrounding UI must say so. Two guards keep it from pretending otherwise:
/// a single rep returns the weight itself (the formula's own +3.3% at r=1 is nonsense — a 1-rep max IS
/// the weight lifted), and above `maxRepsForEstimate` it returns nil rather than a number, because
/// rep-max formulas diverge badly in the high-rep range where fatigue, not maximal strength, sets the
/// limit. Nil is the honest answer there; a wrong number would quietly become a "PR".
public enum OneRepMax {

    /// Above this many reps no estimate is offered. 12 is the conventional upper bound for rep-max
    /// prediction; past it the formulas disagree with each other by more than the trend being tracked.
    public static let maxRepsForEstimate = 12

    /// Epley's estimate in kilograms, or nil when the set is outside the formula's domain.
    public static func epley(weightKg: Double, reps: Int) -> Double? {
        guard weightKg > 0, reps >= 1, reps <= maxRepsForEstimate else { return nil }
        if reps == 1 { return weightKg }
        return weightKg * (1.0 + Double(reps) / 30.0)
    }

    /// Epley adjusted for a logged number of repetitions in reserve. The effective repetition count
    /// must remain inside the same 12-rep validity boundary as the unadjusted estimate.
    public static func epley(weightKg: Double, reps: Int, rir: Double) -> Double? {
        guard weightKg > 0, reps >= 1, rir.isFinite, (0...4).contains(rir) else { return nil }
        let effectiveReps = Double(reps) + rir
        guard effectiveReps <= Double(maxRepsForEstimate) else { return nil }
        if effectiveReps == 1 { return weightKg }
        return weightKg * (1.0 + effectiveReps / 30.0)
    }

    /// The estimate for one logged set, honouring the exercise's own type.
    ///
    /// A known template that is NOT `weight_reps` (a plank, a distance row) gets no estimate — a 1RM
    /// is undefined for it. An UNKNOWN template with both a weight and reps does get one: the set
    /// itself is the evidence, and refusing an estimate because the catalogue has not synced yet would
    /// blank the whole trend for a movement the user really did perform.
    public static func forSet(_ set: HevySet, template: HevyExerciseTemplate?) -> Double? {
        guard set.type.countsAsWork else { return nil }
        if let template, !template.isWeightAndReps { return nil }
        guard let w = set.weightKg, let r = set.reps else { return nil }
        if let rpe = set.rpe, rpe.isFinite, (6...10).contains(rpe) {
            return epley(weightKg: w, reps: r, rir: 10 - rpe)
        }
        return epley(weightKg: w, reps: r)
    }
}

/// One session, summarised.
public struct StrengthSessionSummary: Equatable, Sendable {
    public let workoutId: String
    public let title: String
    public let startTs: Int
    public let durationS: Double?
    /// Distinct exercises performed, superset members counted individually.
    public let exerciseCount: Int
    /// Sets that were not warmups.
    public let workingSetCount: Int
    /// Reps across working sets.
    public let totalReps: Int
    /// Σ(weight × reps) across the working sets that HAVE both. A bodyweight or timed set contributes
    /// nothing here, which is why `volumeSetCount` is reported beside it: volume load without its
    /// coverage invites reading a calisthenics day as an easy one.
    public let volumeLoadKg: Double
    public let volumeSetCount: Int
    /// The heaviest single working set, in kilograms. Measured, not estimated.
    public let heaviestSetKg: Double?
    /// Mean RPE over the working sets that carry one, and how many did. Nil when none was rated —
    /// never a default, because "not rated" is not "moderate".
    public let meanRpe: Double?
    public let rpeSetCount: Int
    /// Working sets counted on each exercise's PRIMARY muscle group.
    public let hardSetsByMuscle: [HevyMuscleGroup: Int]
    /// Working sets whose exercise lists the group as SECONDARY. Reported separately and never added
    /// to the primary count — see this file's header.
    public let secondarySetsByMuscle: [HevyMuscleGroup: Int]
    /// Working sets whose exercise could not be resolved in the catalogue, so no muscle group could be
    /// attributed to them. Surfaced rather than hidden: a per-muscle chart that silently omits a fifth
    /// of the work is worse than one that says so.
    public let unattributedSetCount: Int

    public init(workoutId: String, title: String, startTs: Int, durationS: Double?,
                exerciseCount: Int, workingSetCount: Int, totalReps: Int,
                volumeLoadKg: Double, volumeSetCount: Int, heaviestSetKg: Double?,
                meanRpe: Double?, rpeSetCount: Int,
                hardSetsByMuscle: [HevyMuscleGroup: Int],
                secondarySetsByMuscle: [HevyMuscleGroup: Int],
                unattributedSetCount: Int) {
        self.workoutId = workoutId
        self.title = title
        self.startTs = startTs
        self.durationS = durationS
        self.exerciseCount = exerciseCount
        self.workingSetCount = workingSetCount
        self.totalReps = totalReps
        self.volumeLoadKg = volumeLoadKg
        self.volumeSetCount = volumeSetCount
        self.heaviestSetKg = heaviestSetKg
        self.meanRpe = meanRpe
        self.rpeSetCount = rpeSetCount
        self.hardSetsByMuscle = hardSetsByMuscle
        self.secondarySetsByMuscle = secondarySetsByMuscle
        self.unattributedSetCount = unattributedSetCount
    }

    /// How much of the RPE picture is actually there, 0…1. The caller shows the fraction rather than
    /// the mean alone: a mean over 2 of 18 sets is a different claim from one over 18 of 18.
    public var rpeCoverage: Double {
        workingSetCount > 0 ? Double(rpeSetCount) / Double(workingSetCount) : 0
    }
}

/// One performance point for a single exercise, on one day.
public struct ExercisePerformancePoint: Equatable, Sendable {
    public let day: String          // yyyy-MM-dd, local
    public let startTs: Int
    public let workoutId: String
    /// The best estimated 1RM across the day's working sets of this exercise, or nil when none was
    /// in the formula's domain.
    public let bestE1RMKg: Double?
    /// The heaviest working set actually lifted. Measured, so it never needs a caveat.
    public let heaviestSetKg: Double?
    public let workingSetCount: Int
    public let totalReps: Int
    public let volumeLoadKg: Double
    /// Mean RPE across the day's rated working sets of this exercise, with its count.
    public let meanRpe: Double?
    public let rpeSetCount: Int

    public init(day: String, startTs: Int, workoutId: String, bestE1RMKg: Double?,
                heaviestSetKg: Double?, workingSetCount: Int, totalReps: Int,
                volumeLoadKg: Double, meanRpe: Double?, rpeSetCount: Int) {
        self.day = day
        self.startTs = startTs
        self.workoutId = workoutId
        self.bestE1RMKg = bestE1RMKg
        self.heaviestSetKg = heaviestSetKg
        self.workingSetCount = workingSetCount
        self.totalReps = totalReps
        self.volumeLoadKg = volumeLoadKg
        self.meanRpe = meanRpe
        self.rpeSetCount = rpeSetCount
    }
}

public enum StrengthSession {

    // MARK: - One session

    /// Summarise one logged session. `templates` is the exercise catalogue keyed by template id; an
    /// exercise missing from it still contributes its sets, reps and volume — only its muscle-group
    /// attribution is unavailable, and that is counted in `unattributedSetCount`.
    public static func summarize(_ workout: HevyWorkout,
                                 templates: [String: HevyExerciseTemplate]) -> StrengthSessionSummary {
        var workingSets = 0, totalReps = 0, volumeSets = 0, rpeSets = 0, unattributed = 0
        var volume = 0.0, rpeSum = 0.0
        var heaviest: Double?
        var primary: [HevyMuscleGroup: Int] = [:]
        var secondary: [HevyMuscleGroup: Int] = [:]

        for exercise in workout.exercises {
            let template = exercise.templateId.flatMap { templates[$0] }
            let sets = exercise.workingSets
            workingSets += sets.count

            if let template {
                primary[template.primaryMuscleGroup, default: 0] += sets.count
                // A group listed twice in `secondary_muscle_groups` must not double-count, so the
                // list is de-duplicated before it is tallied.
                for group in Set(template.secondaryMuscleGroups) {
                    secondary[group, default: 0] += sets.count
                }
            } else {
                unattributed += sets.count
            }

            for set in sets {
                if let r = set.reps { totalReps += r }
                if let v = set.volumeLoadKg { volume += v; volumeSets += 1 }
                if let w = set.weightKg, w > 0 { heaviest = max(heaviest ?? 0, w) }
                if let rpe = set.rpe { rpeSum += rpe; rpeSets += 1 }
            }
        }

        return StrengthSessionSummary(
            workoutId: workout.id, title: workout.title, startTs: workout.startTs,
            durationS: workout.durationS,
            exerciseCount: workout.exercises.count,
            workingSetCount: workingSets, totalReps: totalReps,
            volumeLoadKg: volume, volumeSetCount: volumeSets,
            heaviestSetKg: heaviest,
            meanRpe: rpeSets > 0 ? rpeSum / Double(rpeSets) : nil, rpeSetCount: rpeSets,
            hardSetsByMuscle: primary, secondarySetsByMuscle: secondary,
            unattributedSetCount: unattributed)
    }

    // MARK: - One exercise over time

    /// The performance trend for ONE exercise, oldest first.
    ///
    /// Keyed by `templateId` rather than by title: a user who renames an exercise, or Hevy which
    /// localises one, would otherwise split a single movement's history into two unrelated curves.
    public static func exerciseHistory(templateId: String,
                                       workouts: [HevyWorkout],
                                       templates: [String: HevyExerciseTemplate],
                                       tzOffsetSeconds: Int = 0) -> [ExercisePerformancePoint] {
        let template = templates[templateId]
        var points: [ExercisePerformancePoint] = []

        for workout in workouts {
            let sets = workout.exercises
                .filter { $0.templateId == templateId }
                .flatMap(\.workingSets)
            guard !sets.isEmpty else { continue }

            var bestE1RM: Double?
            var heaviest: Double?
            var reps = 0
            var volume = 0.0
            var rpeSum = 0.0
            var rpeCount = 0
            for set in sets {
                if let e = OneRepMax.forSet(set, template: template) { bestE1RM = max(bestE1RM ?? 0, e) }
                if let w = set.weightKg, w > 0 { heaviest = max(heaviest ?? 0, w) }
                if let r = set.reps { reps += r }
                if let v = set.volumeLoadKg { volume += v }
                if let rpe = set.rpe { rpeSum += rpe; rpeCount += 1 }
            }

            points.append(ExercisePerformancePoint(
                day: AnalyticsEngine.dayString(workout.startTs, offsetSec: tzOffsetSeconds),
                startTs: workout.startTs, workoutId: workout.id,
                bestE1RMKg: bestE1RM, heaviestSetKg: heaviest,
                workingSetCount: sets.count, totalReps: reps, volumeLoadKg: volume,
                meanRpe: rpeCount > 0 ? rpeSum / Double(rpeCount) : nil, rpeSetCount: rpeCount))
        }
        return points.sorted { $0.startTs < $1.startTs }
    }

    /// Every exercise present in `workouts`, by template id, with how many sessions it appears in —
    /// the list the Strength screen offers to pick a trend from, most-trained first.
    public static func exerciseFrequency(_ workouts: [HevyWorkout]) -> [(templateId: String, sessions: Int)] {
        var counts: [String: Int] = [:]
        for workout in workouts {
            for id in Set(workout.exercises.compactMap(\.templateId)) {
                counts[id, default: 0] += 1
            }
        }
        return counts.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .map { (templateId: $0.key, sessions: $0.value) }
    }

    // MARK: - Across a window

    /// Working sets per PRIMARY muscle group over a set of sessions, plus what could not be attributed.
    ///
    /// This is a count of logged working sets, with warm-ups excluded. It is useful for volume context
    /// but must not be described as verified hard sets when proximity-to-failure data is missing.
    /// Tonnage is kept separate because it conflates a heavy triple with a light set of twenty.
    public static func hardSetsByMuscle(_ workouts: [HevyWorkout],
                                        templates: [String: HevyExerciseTemplate])
        -> (primary: [HevyMuscleGroup: Int], secondary: [HevyMuscleGroup: Int], unattributed: Int) {
        var primary: [HevyMuscleGroup: Int] = [:]
        var secondary: [HevyMuscleGroup: Int] = [:]
        var unattributed = 0
        for workout in workouts {
            let s = summarize(workout, templates: templates)
            for (group, n) in s.hardSetsByMuscle { primary[group, default: 0] += n }
            for (group, n) in s.secondarySetsByMuscle { secondary[group, default: 0] += n }
            unattributed += s.unattributedSetCount
        }
        return (primary, secondary, unattributed)
    }

    /// When each muscle group was last worked, and by which exercise.
    ///
    /// Two things this deliberately does NOT do. It does not count secondary involvement — a muscle
    /// that merely assisted is not "worked", and the rest of the screen already draws that line, so
    /// drawing it differently here would make the same word mean two things. And it does not decay:
    /// the answer is a date, not a freshness estimate. Turning "three days ago" into "62 % recovered"
    /// requires a decay constant nobody has measured for this wearer, and that is the assumption this
    /// whole section exists to avoid.
    ///
    /// `exercise` is the title of the exercise that contributed the most working sets to that muscle in
    /// the most recent session that trained it — the honest answer to "what did that".
    public static func lastWorkedByMuscle(_ workouts: [HevyWorkout],
                                          templates: [String: HevyExerciseTemplate],
                                          tzOffsetSeconds: Int = 0)
        -> [HevyMuscleGroup: (day: String, startTs: Int, exercise: String)] {
        var out: [HevyMuscleGroup: (day: String, startTs: Int, exercise: String)] = [:]
        // Oldest first, so a later session simply overwrites an earlier one and the last write wins.
        // Sorting rather than comparing timestamps keeps the tie-break explicit: same start time, the
        // one later in the array wins, which is the order the store returned them in.
        for workout in workouts.sorted(by: { $0.startTs < $1.startTs }) {
            var setsPerMuscle: [HevyMuscleGroup: [String: Int]] = [:]
            for exercise in workout.exercises {
                guard let id = exercise.templateId, let template = templates[id] else { continue }
                let group = template.primaryMuscleGroup
                let count = exercise.workingSets.count
                guard count > 0 else { continue }
                setsPerMuscle[group, default: [:]][exercise.title, default: 0] += count
            }
            let day = AnalyticsEngine.dayString(workout.startTs, offsetSec: tzOffsetSeconds)
            for (group, byExercise) in setsPerMuscle {
                // Ties break on the title so the same input always yields the same output.
                let top = byExercise.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
                guard let name = top.first?.key else { continue }
                out[group] = (day: day, startTs: workout.startTs, exercise: name)
            }
        }
        return out
    }

    /// Working sets per primary muscle group over the last `days` days ending at `now`, inclusive.
    ///
    /// The window is half-open at the start and inclusive at the end: a session exactly `days` days old
    /// is OUT, one from this morning is IN. Stated because an off-by-one here silently changes every
    /// number on the body map, and the boundary is what a test can pin.
    public static func recentSetsByMuscle(_ workouts: [HevyWorkout],
                                          templates: [String: HevyExerciseTemplate],
                                          days: Int,
                                          now: Int) -> [HevyMuscleGroup: Int] {
        let cutoff = now - days * 86_400
        let recent = workouts.filter { $0.startTs > cutoff && $0.startTs <= now }
        return hardSetsByMuscle(recent, templates: templates).primary
    }

    /// Total working sets and volume per LOCAL day, for a trend line.
    public static func dailyTotals(_ workouts: [HevyWorkout], tzOffsetSeconds: Int = 0)
        -> (setsByDay: [String: Int], volumeByDay: [String: Double]) {
        var sets: [String: Int] = [:]
        var volume: [String: Double] = [:]
        for workout in workouts {
            let day = AnalyticsEngine.dayString(workout.startTs, offsetSec: tzOffsetSeconds)
            let working = workout.exercises.flatMap(\.workingSets)
            sets[day, default: 0] += working.count
            volume[day, default: 0] += working.compactMap(\.volumeLoadKg).reduce(0, +)
        }
        return (sets, volume)
    }

    // MARK: - Load, over weeks

    /// One week of strength training, as the weekly view reads it.
    public struct WeekSummary: Equatable, Sendable {
        /// Monday of the week, "yyyy-MM-dd".
        public let mondayKey: String
        public let sessionCount: Int
        public let workingSetCount: Int
        public let volumeLoadKg: Double
        public let setsByMuscle: [HevyMuscleGroup: Int]
        public let secondarySetsByMuscle: [HevyMuscleGroup: Int]
        public let unattributedSetCount: Int

        public init(mondayKey: String, sessionCount: Int, workingSetCount: Int, volumeLoadKg: Double,
                    setsByMuscle: [HevyMuscleGroup: Int], secondarySetsByMuscle: [HevyMuscleGroup: Int],
                    unattributedSetCount: Int) {
            self.mondayKey = mondayKey
            self.sessionCount = sessionCount
            self.workingSetCount = workingSetCount
            self.volumeLoadKg = volumeLoadKg
            self.setsByMuscle = setsByMuscle
            self.secondarySetsByMuscle = secondarySetsByMuscle
            self.unattributedSetCount = unattributedSetCount
        }
    }

    /// Summarise the Monday–Sunday week containing `anchorDay`.
    ///
    /// Weeks are the unit strength training is actually prescribed in, and Monday-anchored to match
    /// `WeeklyDigestEngine` — two different week boundaries in one app is how the same session ends up
    /// in different weeks on two screens.
    public static func week(containing anchorDay: String,
                            workouts: [HevyWorkout],
                            templates: [String: HevyExerciseTemplate],
                            tzOffsetSeconds: Int = 0) -> WeekSummary {
        guard let monday = WeeklyDigestEngine.mondayOfWeek(containing: anchorDay) else {
            return WeekSummary(mondayKey: anchorDay, sessionCount: 0, workingSetCount: 0,
                               volumeLoadKg: 0, setsByMuscle: [:], secondarySetsByMuscle: [:],
                               unattributedSetCount: 0)
        }
        let sunday = WeeklyDigestEngine.addDays(monday, 6)
        let inWeek = workouts.filter { workout in
            let day = AnalyticsEngine.dayString(workout.startTs, offsetSec: tzOffsetSeconds)
            return day >= monday && day <= sunday
        }
        let tally = hardSetsByMuscle(inWeek, templates: templates)
        let summaries = inWeek.map { summarize($0, templates: templates) }
        return WeekSummary(
            mondayKey: monday,
            sessionCount: inWeek.count,
            workingSetCount: summaries.reduce(0) { $0 + $1.workingSetCount },
            volumeLoadKg: summaries.reduce(0) { $0 + $1.volumeLoadKg },
            setsByMuscle: tally.primary,
            secondarySetsByMuscle: tally.secondary,
            unattributedSetCount: tally.unattributed)
    }

    /// Effort-weighted working sets per day, for the load comparison.
    ///
    /// Weighted, not counted. A plain set count is a decent proxy for weekly fatigue — better than
    /// tonnage, which ranks four sets of ten at 100 kg above five triples at 180 kg and gets the harder
    /// session wrong — but it still treats an easy set and a set to failure alike. `TrainingLoad`
    /// prices each set by how close it went to failure, on the same curve the muscle map uses.
    public static func weightedSetsByDay(_ workouts: [HevyWorkout],
                                         tzOffsetSeconds: Int = 0) -> [String: Double] {
        var byDay: [String: Double] = [:]
        for workout in workouts {
            let day = AnalyticsEngine.dayString(workout.startTs, offsetSec: tzOffsetSeconds)
            let rpes = workout.exercises.flatMap(\.workingSets).map(\.rpe)
            byDay[day, default: 0] += TrainingLoad.strengthLoad(setRpes: rpes).weightedSets
        }
        return byDay
    }

    /// Strength load pooled over every working set in `workouts`, for saying what the weighting rests on.
    ///
    /// `weightedSetsByDay` keeps only the weighted figure, which is right for the trend and silent about
    /// how much of it is the unrated default. This is the same arithmetic over the same sets, pooled, so
    /// the screen can report the rated count alongside the number it qualifies.
    public static func strengthLoad(_ workouts: [HevyWorkout]) -> StrengthLoad {
        TrainingLoad.strengthLoad(setRpes: workouts.flatMap { $0.exercises.flatMap(\.workingSets).map(\.rpe) })
    }

    /// How this week's strength load compares with the wearer's own recent level.
    ///
    /// Returns `TrainingLoad`'s signed percentage rather than a bare ratio: "18 % above your usual" is
    /// a sentence someone can act on, where "1.18" has to be looked up against bands borrowed from
    /// team-sport distance research that never covered set counts.
    public static func strengthLoadTrend(_ workouts: [HevyWorkout],
                                         asOf now: Date = Date(),
                                         tzOffsetSeconds: Int = 0) -> LoadTrend? {
        let byDay = weightedSetsByDay(workouts, tzOffsetSeconds: tzOffsetSeconds)
        let today = AnalyticsEngine.dayString(Int(now.timeIntervalSince1970), offsetSec: tzOffsetSeconds)
        return TrainingLoad.trend(dailyByDay: byDay, through: today)
    }

    /// Whole days between two "yyyy-MM-dd" keys, or 0 when either is unparseable.
    ///
    /// Returns 0 when `from` is not before `to`, which makes a day in the future read as "today"
    /// rather than as a negative age. Callers rendering "N days ago" want exactly that.
    ///
    /// Two day numbers subtracted, not a walk. The walk it replaced stepped one calendar day at a time
    /// — allocating and re-parsing a date string per step — and every "last worked 40 days ago" row on
    /// the muscle list paid for forty of them while scrolling.
    public static func daysBetween(_ from: String, and to: String) -> Int {
        guard from < to,
              let (fy, fm, fd) = WeeklyDigestEngine.parseYMD(from),
              let (ty, tm, td) = WeeklyDigestEngine.parseYMD(to) else { return 0 }
        let delta = WeeklyDigestEngine.julianDayNumber(ty, tm, td)
            - WeeklyDigestEngine.julianDayNumber(fy, fm, fd)
        return max(0, delta)
    }

    // MARK: - The user's own range

    /// The user's typical weekly working-set count per muscle group, as a p25…p75 band over the last
    /// `weeks` complete weeks (this week excluded — it is the thing being compared).
    ///
    /// A BAND, not a target. NOOP has no evidence about what anyone's correct weekly volume is, and a
    /// textbook number presented as "your goal" would be exactly the invented figure this whole lane
    /// avoids. What it does have is what this person has actually been doing, which is enough to say
    /// "this week is unusual for you" — and that is a claim the data supports.
    ///
    /// Quartiles rather than mean ± SD: a single deload week would drag a mean and widen an SD, while
    /// the interquartile range simply ignores it.
    public static func typicalWeeklySets(_ workouts: [HevyWorkout],
                                         templates: [String: HevyExerciseTemplate],
                                         endingBefore anchorDay: String,
                                         weeks: Int = 8,
                                         tzOffsetSeconds: Int = 0) -> [HevyMuscleGroup: ClosedRange<Double>] {
        guard let thisMonday = WeeklyDigestEngine.mondayOfWeek(containing: anchorDay) else { return [:] }
        var byGroup: [HevyMuscleGroup: [Double]] = [:]
        var monday = WeeklyDigestEngine.addDays(thisMonday, -7)
        for _ in 0..<max(weeks, 1) {
            let summary = week(containing: monday, workouts: workouts, templates: templates,
                               tzOffsetSeconds: tzOffsetSeconds)
            // Only weeks that HELD training contribute. A stretch when someone was ill or away is not
            // evidence about their usual volume, and including it as a run of zeros would drag every
            // band down and then report the return to normal as unusually high.
            if summary.sessionCount > 0 {
                for group in HevyMuscleGroup.allCases {
                    byGroup[group, default: []].append(Double(summary.setsByMuscle[group] ?? 0))
                }
            }
            monday = WeeklyDigestEngine.addDays(monday, -7)
        }

        var out: [HevyMuscleGroup: ClosedRange<Double>] = [:]
        for (group, values) in byGroup where values.count >= 3 {
            let sorted = values.sorted()
            let lo = percentile(sorted, 0.25)
            let hi = percentile(sorted, 0.75)
            // A group never trained has a 0…0 band, which says nothing; omit it rather than draw an
            // empty reference the reader would have to interpret.
            if hi > 0 { out[group] = lo...hi }
        }
        return out
    }

    /// Linear-interpolated percentile over a sorted array.
    static func percentile(_ sorted: [Double], _ p: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        if sorted.count == 1 { return sorted[0] }
        let position = p * Double(sorted.count - 1)
        let lower = Int(position.rounded(.down))
        let upper = min(lower + 1, sorted.count - 1)
        let fraction = position - Double(lower)
        return sorted[lower] + (sorted[upper] - sorted[lower]) * fraction
    }

    /// The day keys a set of sessions falls on — the shape `EffectRanker` wants for a behaviour, which
    /// is how a "leg day" becomes something the existing lag-aware effect machinery can measure
    /// against tomorrow's Charge without any new statistics.
    public static func dayKeys(_ workouts: [HevyWorkout], tzOffsetSeconds: Int = 0) -> Set<String> {
        Set(workouts.map { AnalyticsEngine.dayString($0.startTs, offsetSec: tzOffsetSeconds) })
    }
}
