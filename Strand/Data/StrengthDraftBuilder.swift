import Foundation
import StrandTraining

/// What a strength session needs to know at the moment it starts: the exercise definitions, the plan,
/// and the history that pre-fills last performance and drives progression.
///
/// Loaded once and shared by every entry point — the Training tab, the Today quick action, the Watch —
/// so starting from any of them builds the identical draft and none of them re-reads the full history.
struct TrainingStartContext {
    var exercises: [TrainingExercise] = []
    var plan = TrainingPlan()
    var workouts: [NativeWorkout] = []
    var performance = TrainingPerformanceHistory.empty

    var exerciseById: [String: TrainingExercise] {
        Dictionary(uniqueKeysWithValues: exercises.map { ($0.id, $0) })
    }
}

/// Builds the draft a strength session starts from. Moved out of the Training tab's model so the draft
/// no longer depends on which screen happened to start it.
enum StrengthDraftBuilder {
    static func draft(routines: [TrainingRoutine], tracker: SessionTrackerAttribution?,
                      context: TrainingStartContext, date: Date = Date(),
                      pastDurationS: Int? = nil) -> WorkoutDraft {
        let now = Int(date.timeIntervalSince1970)
        let title = routines.isEmpty ? String(localized: "Freestyle workout")
            : routines.map(\.title).joined(separator: " + ")
        let definitions = context.exerciseById
        var draft = NativeWorkoutEngine.draft(title: title, day: dayString(date), startTs: now,
                                              routines: routines, tracker: tracker,
                                              exerciseDefinitions: definitions)
        normalizeUnilateralSets(in: &draft, definitions: definitions)
        if let pastDurationS { draft.plannedEndTs = now + max(60, pastDurationS) }
        NativeWorkoutEngine.prefillLastPerformance(&draft, history: context.workouts)
        context.performance.prefillImported(&draft)
        applyProgression(to: &draft, routines: routines, definitions: definitions,
                         performance: context.performance)
        return draft
    }

    /// The exercises a routine contributes when it is added to a session already running: prefilled and
    /// progressed exactly as if the session had started with it.
    static func exercises(adding routine: TrainingRoutine, to draft: WorkoutDraft,
                          context: TrainingStartContext) -> [NativeWorkoutExercise] {
        let date = Date(timeIntervalSince1970: TimeInterval(draft.startedAt))
        return Self.draft(routines: [routine], tracker: draft.tracker, context: context, date: date).exercises
    }

    static func dayString(_ date: Date) -> String { dayFormatter.string(from: date) }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static func applyProgression(to draft: inout WorkoutDraft, routines: [TrainingRoutine],
                                         definitions: [String: TrainingExercise],
                                         performance: TrainingPerformanceHistory) {
        let routineExercises = routines.flatMap { routine in
            routine.exercises.map { ($0.id, $0, routine.defaultProgression) }
        }
        let byRoutineExercise = Dictionary(uniqueKeysWithValues: routineExercises.map { ($0.0, ($0.1, $0.2)) })
        for index in draft.exercises.indices {
            guard !draft.exercises[index].excludeFromProgression,
                  let routineId = draft.exercises[index].routineId,
                  let planned = routines.first(where: { $0.id == routineId })?.exercises
                    .first(where: { $0.exerciseId == draft.exercises[index].exerciseId }),
                  let definition = definitions[draft.exercises[index].exerciseId] else { continue }
            let configuration = planned.progression
                ?? byRoutineExercise[planned.id]?.1
                ?? ProgressionConfiguration()
            // Native and imported sessions of the same reviewed exercise, oldest first, each counted once.
            let history = performance.entries(for: planned.exerciseId).compactMap { entry -> ProgressionSession? in
                let work = entry.workingSets
                guard !work.isEmpty else { return nil }
                let reps = work.compactMap(\.completedReps)
                return ProgressionSession(
                    weightKg: work.compactMap(\.weightKg).max(),
                    completedReps: reps,
                    targetReps: Array(repeating: configuration.repsMin, count: reps.count),
                    durationS: work.compactMap(\.durationS).max(),
                    targetDurationS: planned.sets.compactMap(\.targetDurationS).max(),
                    workSetCount: work.count,
                    efforts: work.compactMap(\.effort))
            }
            let currentWork = draft.exercises[index].sets.filter { $0.phase == .work }
            let reference = ProgressionReference(workingSets: currentWork)
            let next = TrainingProgressionEngine.next(
                configuration: configuration, history: history, mode: definition.mode,
                currentWeightKg: reference.weightKg,
                currentReps: reference.reps,
                currentSets: currentWork.count,
                currentDurationS: reference.durationS)
            draft.exercises[index].progressionReason = next.reason
            TrainingProgressionEngine.apply(next, reference: reference, to: &draft.exercises[index].sets,
                                            unilateral: definition.isUnilateral)
            if let count = next.setCount, count > currentWork.count {
                let template = draft.exercises[index].sets.last(where: { $0.phase == .work })
                    ?? NativeWorkoutSet(index: draft.exercises[index].sets.count)
                while draft.exercises[index].sets.filter({ $0.phase == .work }).count < count {
                    draft.exercises[index].sets.append(NativeWorkoutSet(
                        index: draft.exercises[index].sets.count, phase: .work,
                        intensifier: template.intensifier, weightKg: template.weightKg,
                        reps: template.reps, leftReps: template.leftReps, rightReps: template.rightReps,
                        durationS: template.durationS, distanceM: template.distanceM))
                }
            }
        }
    }

    private static func normalizeUnilateralSets(in draft: inout WorkoutDraft,
                                                definitions: [String: TrainingExercise]) {
        for exerciseIndex in draft.exercises.indices {
            guard definitions[draft.exercises[exerciseIndex].exerciseId]?.isUnilateral == true else { continue }
            for setIndex in draft.exercises[exerciseIndex].sets.indices {
                let shared = draft.exercises[exerciseIndex].sets[setIndex].reps
                if draft.exercises[exerciseIndex].sets[setIndex].leftReps == nil {
                    draft.exercises[exerciseIndex].sets[setIndex].leftReps = shared
                }
                if draft.exercises[exerciseIndex].sets[setIndex].rightReps == nil {
                    draft.exercises[exerciseIndex].sets[setIndex].rightReps = shared
                }
                draft.exercises[exerciseIndex].sets[setIndex].reps = nil
            }
        }
    }
}
