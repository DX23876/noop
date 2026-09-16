import Foundation
import StrandAnalytics
import StrandTraining
import WhoopStore

/// Earlier performances of one NOOP exercise across every detailed source, used for "last time",
/// prefills and progression. Native sessions match by exercise id. Imported sessions come from
/// `resolvedStrengthHistory` and match only through the same reviewed anatomy id, so an unmapped or
/// differently mapped import never lends its numbers to another lift. A native session that the
/// resolved history also lists is read from the native log only, so nothing counts twice.
struct TrainingPerformanceHistory: Sendable {
    struct PerformedSet: Equatable, Sendable {
        var isWarmup: Bool
        var weightKg: Double?
        var reps: Int?
        var leftReps: Int?
        var rightReps: Int?
        var durationS: Int?
        var distanceM: Double?
        var effort: TrainingEffortRating?

        var completedReps: Int? {
            if let reps { return reps }
            if let leftReps, let rightReps { return min(leftReps, rightReps) }
            return leftReps ?? rightReps
        }
    }

    struct Entry: Equatable, Sendable {
        let startTs: Int
        let isNative: Bool
        let sets: [PerformedSet]

        var workingSets: [PerformedSet] { sets.filter { !$0.isWarmup } }
    }

    static let empty = TrainingPerformanceHistory(
        native: [], resolved: .init(sessions: [], workouts: [], templates: [:]), exercises: [])

    private let nativeByExercise: [String: [Entry]]
    private let importedByAnatomy: [String: [Entry]]
    private let anatomyByExercise: [String: String]

    init(native: [NativeWorkout], resolved: ResolvedStrengthHistory, exercises: [TrainingExercise]) {
        var nativeEntries: [String: [Entry]] = [:]
        for workout in native {
            for exercise in workout.exercises {
                let sets = exercise.sets.filter(\.isCompleted).map(PerformedSet.init)
                guard !sets.isEmpty else { continue }
                nativeEntries[exercise.exerciseId, default: []]
                    .append(.init(startTs: workout.startedAt, isNative: true, sets: sets))
            }
        }
        var imported: [String: [Entry]] = [:]
        for session in resolved.sessions where session.workout.source != .noopNative {
            for exercise in session.exercises {
                guard let anatomyId = exercise.anatomy?.id else { continue }
                let sets = exercise.source.sets.map(PerformedSet.init)
                guard !sets.isEmpty else { continue }
                imported[anatomyId, default: []]
                    .append(.init(startTs: session.startTs, isNative: false, sets: sets))
            }
        }
        var anatomy: [String: String] = [:]
        for exercise in exercises {
            if let id = TrainingMuscleProjection.anatomy(for: exercise)?.id { anatomy[exercise.id] = id }
        }
        nativeByExercise = nativeEntries
        importedByAnatomy = imported
        anatomyByExercise = anatomy
    }

    /// Every earlier performance of the exercise, oldest first.
    func entries(for exerciseId: String) -> [Entry] {
        let native = nativeByExercise[exerciseId] ?? []
        let imported = anatomyByExercise[exerciseId].flatMap { importedByAnatomy[$0] } ?? []
        return (native + imported).sorted { $0.startTs < $1.startTs }
    }

    func latest(for exerciseId: String) -> Entry? {
        entries(for: exerciseId).last
    }

    /// What this exercise has produced so far. The estimate uses the same Epley formula and RIR
    /// correction as the Strength screen, and only for weight-and-repetition work.
    struct Records: Equatable, Sendable {
        let sessionCount: Int
        let bestEstimatedOneRepMaxKg: Double?
        let heaviestSetKg: Double?
        let lastPerformedTs: Int?
    }

    func records(for exerciseId: String, mode: TrainingMeasurementMode) -> Records {
        let sessions = entries(for: exerciseId)
        let working = sessions.flatMap(\.workingSets)
        let supportsWeight = mode == .weightReps || mode == .weightedBodyweight
        return Records(
            sessionCount: sessions.count,
            bestEstimatedOneRepMaxKg: mode == .weightReps
                ? working.compactMap(Self.estimatedOneRepMax).max() : nil,
            heaviestSetKg: supportsWeight
                ? working.compactMap(\.weightKg).filter { $0 > 0 }.max() : nil,
            lastPerformedTs: sessions.last?.startTs)
    }

    private static func estimatedOneRepMax(_ set: PerformedSet) -> Double? {
        guard let weight = set.weightKg, weight > 0, let reps = set.completedReps else { return nil }
        guard let effort = set.effort else { return OneRepMax.epley(weightKg: weight, reps: reps) }
        let rir = effort.scale == .rir ? effort.value : 10 - effort.value
        return OneRepMax.epley(weightKg: weight, reps: reps, rir: rir)
            ?? OneRepMax.epley(weightKg: weight, reps: reps)
    }

    /// Fills blanks of exercises without native history from their newest imported performance, value
    /// by value and position by position. Explicit routine targets and native prefills always win.
    func prefillImported(_ draft: inout WorkoutDraft) {
        for exerciseIndex in draft.exercises.indices {
            let exerciseId = draft.exercises[exerciseIndex].exerciseId
            guard (nativeByExercise[exerciseId] ?? []).isEmpty,
                  let previous = latest(for: exerciseId), !previous.isNative else { continue }
            for setIndex in draft.exercises[exerciseIndex].sets.indices
            where previous.sets.indices.contains(setIndex) {
                let prior = previous.sets[setIndex]
                var set = draft.exercises[exerciseIndex].sets[setIndex]
                if set.weightKg == nil { set.weightKg = prior.weightKg }
                if set.reps == nil, set.leftReps == nil, set.rightReps == nil { set.reps = prior.reps }
                if set.durationS == nil { set.durationS = prior.durationS }
                if set.distanceM == nil { set.distanceM = prior.distanceM }
                draft.exercises[exerciseIndex].sets[setIndex] = set
            }
        }
    }
}

extension TrainingPerformanceHistory.PerformedSet {
    init(_ set: NativeWorkoutSet) {
        self.init(isWarmup: set.phase == .warmup, weightKg: set.weightKg, reps: set.reps,
                  leftReps: set.leftReps, rightReps: set.rightReps, durationS: set.durationS,
                  distanceM: set.distanceM, effort: set.effort)
    }

    init(_ set: HevySet) {
        self.init(isWarmup: set.type == .warmup, weightKg: set.weightKg, reps: set.reps,
                  leftReps: nil, rightReps: nil, durationS: set.durationS.map { Int($0.rounded()) },
                  distanceM: set.distanceM,
                  effort: set.rpe.flatMap { TrainingEffortRating(scale: .rpe, value: $0) })
    }
}
