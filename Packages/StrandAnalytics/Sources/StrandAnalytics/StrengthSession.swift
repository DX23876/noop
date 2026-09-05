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
/// **Epley**: `1RM = w · (1 + r/30)`. One published formula, named, rather than a blend — a blend
/// would have no source to check it against.
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
    /// This is the number the training literature actually uses for volume prescription — hard sets per
    /// muscle per week — rather than tonnage, which conflates a heavy triple with a light set of twenty.
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

    /// The day keys a set of sessions falls on — the shape `EffectRanker` wants for a behaviour, which
    /// is how a "leg day" becomes something the existing lag-aware effect machinery can measure
    /// against tomorrow's Charge without any new statistics.
    public static func dayKeys(_ workouts: [HevyWorkout], tzOffsetSeconds: Int = 0) -> Set<String> {
        Set(workouts.map { AnalyticsEngine.dayString($0.startTs, offsetSec: tzOffsetSeconds) })
    }
}
