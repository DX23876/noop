import Foundation
import WhoopStore

// MARK: - One session, opened up
//
// Everything else in this lane AGGREGATES: sets per muscle, volume per week, a trend per movement. This
// file does the opposite — it hands back the session exactly as it was performed, exercise by exercise
// and set by set, so the app can finally answer "what did I actually lift on Tuesday" without sending
// the user to another app to find out.
//
// It adds no new arithmetic beyond two things:
//
//   • the per-set e1RM, which is `OneRepMax.forSet` and already carries its own caveats;
//   • BODYWEIGHT LOAD, described below.
//
// ## Bodyweight load, and the number that is deliberately missing
//
// A pull-up logs as `weightKg: nil` (or as the ADDED weight when someone hangs a plate on a belt), so
// volume load counts a set of ten pull-ups as nothing. `volumeSetCount` beside it says the coverage is
// short, but a calisthenics day still reads as an easy one.
//
// What NOOP has that fixes this honestly is the wearer's own MEASURED body weight. So a bodyweight set
// is priced at the body weight recorded around that session — plus what was added, minus what was
// assisted — and reported as a SEPARATE figure that is never folded into `volumeLoadKg`.
//
// What is deliberately absent is a leverage factor: the convention that a push-up is "64 % of body
// weight" and a pull-up "100 %". Those numbers vary with limb length, hand position and where the
// wearer is in the movement, nobody has measured them for this person, and folding one in would put an
// invented constant inside a figure that is otherwise fully accounted for. So a push-up is priced at
// body weight like every other bodyweight movement, and the caption says the figure counts the body,
// not the share of it a given movement carries.
//
// With no measured body weight, the figure is simply absent. It is never estimated from height, age or
// anything else.

/// What shape a movement is logged in, from Hevy's own `type` token.
///
/// The token is a raw string in the model on purpose (Hevy does not enumerate it), so this is the one
/// place that interprets it. Everything unrecognised lands on `.other` and is treated as carrying no
/// bodyweight — the direction that under-reports rather than invents.
public enum StrengthMovementKind: String, Equatable, Sendable {
    /// "weight_reps" — the only shape an e1RM is defined for.
    case weightAndReps
    /// "bodyweight_reps" — a pull-up, a push-up, a dip. The body is the load.
    case bodyweightReps
    /// "weighted_bodyweight" — the body plus what was hung off it.
    case weightedBodyweight
    /// "bodyweight_assisted_reps" — the body minus the machine's help.
    case assistedBodyweight
    /// "duration" — a plank, a hang.
    case duration
    /// "distance" / "weight_distance" / "short_distance_weight" — a carry, a sled.
    case distance
    /// "reps_only" — reps with nothing recorded about the load.
    case repsOnly
    case other

    public static func of(_ template: HevyExerciseTemplate?) -> StrengthMovementKind {
        guard let raw = template?.type.lowercased() else { return .other }
        switch raw {
        case "weight_reps":              return .weightAndReps
        case "bodyweight_reps":          return .bodyweightReps
        case "weighted_bodyweight":      return .weightedBodyweight
        case "bodyweight_assisted_reps": return .assistedBodyweight
        case "duration":                 return .duration
        case "reps_only":                return .repsOnly
        case let s where s.contains("distance"): return .distance
        default:                         return .other
        }
    }

    /// True when the wearer's own mass is part of what moved.
    public var carriesBodyweight: Bool {
        switch self {
        case .bodyweightReps, .weightedBodyweight, .assistedBodyweight: return true
        default: return false
        }
    }
}

/// One set, as performed, ready to render.
public struct StrengthSetLine: Equatable, Sendable {
    public let index: Int
    public let type: HevySetType
    /// False for a warmup. Every figure on this screen that says "working" honours this one flag.
    public let isWorking: Bool
    public let weightKg: Double?
    public let reps: Int?
    public let durationS: Double?
    public let distanceM: Double?
    public let rpe: Double?
    /// Epley, where it is defined for this set. Nil elsewhere — including above 12 reps.
    public let e1rmKg: Double?
    /// Body weight + added − assisted, for a movement that carries the body. Nil when the movement does
    /// not, or when no measured body weight was available for that day.
    public let bodyweightLoadKg: Double?

    public init(index: Int, type: HevySetType, isWorking: Bool, weightKg: Double?, reps: Int?,
                durationS: Double?, distanceM: Double?, rpe: Double?, e1rmKg: Double?,
                bodyweightLoadKg: Double?) {
        self.index = index
        self.type = type
        self.isWorking = isWorking
        self.weightKg = weightKg
        self.reps = reps
        self.durationS = durationS
        self.distanceM = distanceM
        self.rpe = rpe
        self.e1rmKg = e1rmKg
        self.bodyweightLoadKg = bodyweightLoadKg
    }

    /// Kilogram-reps this set contributed to bodyweight volume, or nil when it contributed none.
    public var bodyweightVolumeKg: Double? {
        guard isWorking, let load = bodyweightLoadKg, load > 0, let reps, reps > 0 else { return nil }
        return load * Double(reps)
    }
}

/// One exercise within a session, with its sets in the order they were performed.
public struct StrengthExerciseBlock: Equatable, Sendable {
    public let index: Int
    public let title: String
    public let templateId: String?
    /// Exercises sharing a value were performed as one superset. Rendered as a group; NOT merged, since
    /// the sets belong to different movements.
    public let supersetId: Int?
    public let notes: String?
    public let kind: StrengthMovementKind
    /// Nil when the catalogue could not resolve the exercise — the same "unattributed" case the muscle
    /// map counts, surfaced here as an absent muscle rather than a guessed one.
    public let primaryMuscle: HevyMuscleGroup?
    public let secondaryMuscles: [HevyMuscleGroup]
    public let equipment: HevyEquipment?
    public let sets: [StrengthSetLine]
    public let workingSetCount: Int
    public let totalReps: Int
    public let volumeLoadKg: Double
    public let bodyweightVolumeKg: Double
    /// The heaviest working set, measured.
    public let topSetKg: Double?
    /// The best estimate across the working sets. An estimate, and labelled as one wherever it appears.
    public let bestE1RMKg: Double?

    public init(index: Int, title: String, templateId: String?, supersetId: Int?, notes: String?,
                kind: StrengthMovementKind, primaryMuscle: HevyMuscleGroup?,
                secondaryMuscles: [HevyMuscleGroup], equipment: HevyEquipment?,
                sets: [StrengthSetLine], workingSetCount: Int, totalReps: Int,
                volumeLoadKg: Double, bodyweightVolumeKg: Double,
                topSetKg: Double?, bestE1RMKg: Double?) {
        self.index = index
        self.title = title
        self.templateId = templateId
        self.supersetId = supersetId
        self.notes = notes
        self.kind = kind
        self.primaryMuscle = primaryMuscle
        self.secondaryMuscles = secondaryMuscles
        self.equipment = equipment
        self.sets = sets
        self.workingSetCount = workingSetCount
        self.totalReps = totalReps
        self.volumeLoadKg = volumeLoadKg
        self.bodyweightVolumeKg = bodyweightVolumeKg
        self.topSetKg = topSetKg
        self.bestE1RMKg = bestE1RMKg
    }
}

/// A whole session, as performed.
public struct StrengthSessionBreakdown: Equatable, Sendable {
    public let workoutId: String
    public let title: String
    public let notes: String?
    public let startTs: Int
    public let endTs: Int
    public let durationS: Double?
    public let exercises: [StrengthExerciseBlock]
    /// The same summary every other screen shows, so the detail and the list can never disagree.
    public let summary: StrengthSessionSummary
    /// Bodyweight volume across the session, kept beside `summary.volumeLoadKg` and never added to it.
    public let bodyweightVolumeKg: Double
    /// Working sets that carried the body but had no measured weight to price them with. Surfaced for
    /// the same reason `unattributedSetCount` is: a figure that silently omits work is worse than one
    /// that says how much it omitted.
    public let unpricedBodyweightSetCount: Int

    public init(workoutId: String, title: String, notes: String?, startTs: Int, endTs: Int,
                durationS: Double?, exercises: [StrengthExerciseBlock],
                summary: StrengthSessionSummary, bodyweightVolumeKg: Double,
                unpricedBodyweightSetCount: Int) {
        self.workoutId = workoutId
        self.title = title
        self.notes = notes
        self.startTs = startTs
        self.endTs = endTs
        self.durationS = durationS
        self.exercises = exercises
        self.summary = summary
        self.bodyweightVolumeKg = bodyweightVolumeKg
        self.unpricedBodyweightSetCount = unpricedBodyweightSetCount
    }

    /// Work per minute of session, in kilogram-reps. Measured on both sides, so it needs no caveat —
    /// but it says nothing about the sets that carry no weight, which is why the caller shows it only
    /// where volume covers most of the session.
    public var densityKgPerMinute: Double? {
        guard let durationS, durationS >= 60 else { return nil }
        let total = summary.volumeLoadKg + bodyweightVolumeKg
        return total > 0 ? total / (durationS / 60) : nil
    }

    /// Supersets, in performance order: each entry is one superset's exercises, or a single exercise
    /// performed on its own. The shape the detail view renders straight down.
    public var groups: [[StrengthExerciseBlock]] {
        var out: [[StrengthExerciseBlock]] = []
        var seen: Set<Int> = []
        for block in exercises.sorted(by: { $0.index < $1.index }) {
            guard let superset = block.supersetId else { out.append([block]); continue }
            guard !seen.contains(superset) else { continue }
            seen.insert(superset)
            out.append(exercises.filter { $0.supersetId == superset }.sorted { $0.index < $1.index })
        }
        return out
    }
}

public enum StrengthDetail {

    /// Open one session up.
    ///
    /// `bodyweightKgAt` is asked for the body weight around a moment in time rather than handed one
    /// number: a session from a year ago must be priced at the body that performed it, not at today's.
    /// Returning nil is entirely allowed and means "no measured weight" — the bodyweight figures then
    /// simply do not appear.
    public static func breakdown(_ workout: HevyWorkout,
                                 templates: [String: HevyExerciseTemplate],
                                 bodyweightKgAt: (Int) -> Double? = { _ in nil })
        -> StrengthSessionBreakdown {
        let bodyweight = bodyweightKgAt(workout.startTs)
        var blocks: [StrengthExerciseBlock] = []
        var sessionBodyweightVolume = 0.0
        var unpriced = 0

        for exercise in workout.exercises {
            let template = exercise.templateId.flatMap { templates[$0] }
            let kind = StrengthMovementKind.of(template)
            var lines: [StrengthSetLine] = []
            var working = 0, reps = 0
            var volume = 0.0, bodyweightVolume = 0.0
            var top: Double?
            var bestE1RM: Double?

            for set in exercise.sets {
                let isWorking = set.type.countsAsWork
                let load = bodyweightLoad(for: set, kind: kind, bodyweightKg: bodyweight)
                let line = StrengthSetLine(
                    index: set.index, type: set.type, isWorking: isWorking,
                    weightKg: set.weightKg, reps: set.reps, durationS: set.durationS,
                    distanceM: set.distanceM, rpe: set.rpe,
                    e1rmKg: OneRepMax.forSet(set, template: template),
                    bodyweightLoadKg: load)
                lines.append(line)

                guard isWorking else { continue }
                working += 1
                if let r = set.reps { reps += r }
                if let v = set.volumeLoadKg { volume += v }
                if let w = set.weightKg, w > 0 { top = max(top ?? 0, w) }
                if let e = line.e1rmKg { bestE1RM = max(bestE1RM ?? 0, e) }
                if let bodyweightSet = line.bodyweightVolumeKg {
                    bodyweightVolume += bodyweightSet
                } else if kind.carriesBodyweight, set.reps ?? 0 > 0 {
                    unpriced += 1
                }
            }

            sessionBodyweightVolume += bodyweightVolume
            blocks.append(StrengthExerciseBlock(
                index: exercise.index, title: exercise.title, templateId: exercise.templateId,
                supersetId: exercise.supersetId, notes: exercise.notes, kind: kind,
                primaryMuscle: template?.primaryMuscleGroup,
                secondaryMuscles: template.map { Array(Set($0.secondaryMuscleGroups)).sorted { $0.rawValue < $1.rawValue } } ?? [],
                equipment: template?.equipment,
                sets: lines, workingSetCount: working, totalReps: reps,
                volumeLoadKg: volume, bodyweightVolumeKg: bodyweightVolume,
                topSetKg: top, bestE1RMKg: bestE1RM))
        }

        return StrengthSessionBreakdown(
            workoutId: workout.id, title: workout.title, notes: workout.notes,
            startTs: workout.startTs, endTs: workout.endTs, durationS: workout.durationS,
            exercises: blocks,
            summary: StrengthSession.summarize(workout, templates: templates),
            bodyweightVolumeKg: sessionBodyweightVolume,
            unpricedBodyweightSetCount: unpriced)
    }

    /// What one set of a bodyweight movement actually carried, in kilograms.
    ///
    /// Body weight for a plain bodyweight rep, plus the added plate for a weighted one, minus the
    /// machine's help for an assisted one — floored at zero, because an assistance greater than body
    /// weight is a logging slip, not a negative load. No leverage factor anywhere; see this file's
    /// header for why.
    public static func bodyweightLoad(for set: HevySet,
                                      kind: StrengthMovementKind,
                                      bodyweightKg: Double?) -> Double? {
        guard kind.carriesBodyweight, let bodyweightKg, bodyweightKg > 0 else { return nil }
        switch kind {
        case .bodyweightReps:     return bodyweightKg
        case .weightedBodyweight: return bodyweightKg + max(0, set.weightKg ?? 0)
        case .assistedBodyweight: return max(0, bodyweightKg - max(0, set.weightKg ?? 0))
        default:                  return nil
        }
    }

    /// Bodyweight volume over a set of sessions, with the count of sets it rests on.
    ///
    /// Separate from `StrengthSession.summarize` on purpose: that function is the app's stable
    /// definition of a session's figures and must keep meaning the same thing it did before body weight
    /// entered the picture.
    public static func bodyweightVolume(_ workouts: [HevyWorkout],
                                        templates: [String: HevyExerciseTemplate],
                                        bodyweightKgAt: (Int) -> Double?) -> (kg: Double, sets: Int) {
        var kg = 0.0
        var sets = 0
        for workout in workouts {
            let bodyweight = bodyweightKgAt(workout.startTs)
            guard bodyweight != nil else { continue }
            for exercise in workout.exercises {
                let kind = StrengthMovementKind.of(exercise.templateId.flatMap { templates[$0] })
                guard kind.carriesBodyweight else { continue }
                for set in exercise.workingSets {
                    guard let load = bodyweightLoad(for: set, kind: kind, bodyweightKg: bodyweight),
                          load > 0, let reps = set.reps, reps > 0 else { continue }
                    kg += load * Double(reps)
                    sets += 1
                }
            }
        }
        return (kg, sets)
    }
}
