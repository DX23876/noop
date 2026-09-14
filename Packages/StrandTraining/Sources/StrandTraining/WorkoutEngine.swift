import Foundation

public enum WorkoutMutationError: Error, Equatable {
    case exerciseNotFound
    case setNotFound
    case invalidPosition
    case noCompletedWork
    case invalidEndTime
}

public enum NativeWorkoutEngine {
    public static func draft(title: String, day: String, startTs: Int,
                             routines: [TrainingRoutine], tracker: SessionTrackerAttribution? = nil) -> WorkoutDraft {
        var entries: [NativeWorkoutExercise] = []
        for routine in routines {
            entries += routine.exercises.map { planned in
                NativeWorkoutExercise(
                    exerciseId: planned.exerciseId,
                    routineId: routine.id,
                    sets: planned.sets.enumerated().map { offset, set in
                        NativeWorkoutSet(index: offset, phase: set.phase, intensifier: set.intensifier,
                                         weightKg: set.targetWeightKg, reps: set.repsMin,
                                         durationS: set.targetDurationS, distanceM: set.targetDistanceM)
                    },
                    restSeconds: planned.restSeconds,
                    supersetId: planned.supersetId,
                    excludeFromProgression: routine.excludeFromProgression,
                    note: planned.note)
            }
        }
        return WorkoutDraft(title: title, startedAt: startTs, plannedDay: day,
                            routineIds: routines.map(\.id), exercises: entries, tracker: tracker)
    }

    public static func addExercise(_ exerciseId: String, to draft: inout WorkoutDraft,
                                   sets: [NativeWorkoutSet] = []) {
        draft.exercises.append(.init(exerciseId: exerciseId, sets: sets))
        touch(&draft)
    }

    /// Appends an editable set using the preceding set's measurable targets. Completion and effort
    /// belong to the performed set, so a new row never inherits either of them.
    public static func appendSet(to exerciseId: UUID, in draft: inout WorkoutDraft) throws {
        guard let exerciseIndex = draft.exercises.firstIndex(where: { $0.id == exerciseId }) else {
            throw WorkoutMutationError.exerciseNotFound
        }
        let previous = draft.exercises[exerciseIndex].sets.last
        draft.exercises[exerciseIndex].sets.append(.init(
            index: draft.exercises[exerciseIndex].sets.count,
            phase: previous?.phase ?? .work,
            intensifier: previous?.intensifier ?? .none,
            weightKg: previous?.weightKg,
            reps: previous?.reps,
            leftReps: previous?.leftReps,
            rightReps: previous?.rightReps,
            durationS: previous?.durationS,
            distanceM: previous?.distanceM))
        touch(&draft)
    }

    /// Fills planned blanks from the newest completed performance of the same exercise. Explicit
    /// routine targets always win, and history is copied value-by-value rather than as a JSON draft.
    public static func prefillLastPerformance(_ draft: inout WorkoutDraft,
                                              history: [NativeWorkout]) {
        let newest = history.sorted { $0.startedAt > $1.startedAt }
        for exerciseIndex in draft.exercises.indices {
            let exerciseId = draft.exercises[exerciseIndex].exerciseId
            guard let previous = newest.lazy.compactMap({ workout in
                workout.exercises.first { $0.exerciseId == exerciseId }
            }).first else { continue }
            for setIndex in draft.exercises[exerciseIndex].sets.indices {
                guard previous.sets.indices.contains(setIndex) else { continue }
                let prior = previous.sets[setIndex]
                if draft.exercises[exerciseIndex].sets[setIndex].weightKg == nil {
                    draft.exercises[exerciseIndex].sets[setIndex].weightKg = prior.weightKg
                }
                if draft.exercises[exerciseIndex].sets[setIndex].reps == nil,
                   draft.exercises[exerciseIndex].sets[setIndex].leftReps == nil,
                   draft.exercises[exerciseIndex].sets[setIndex].rightReps == nil {
                    draft.exercises[exerciseIndex].sets[setIndex].reps = prior.reps
                    draft.exercises[exerciseIndex].sets[setIndex].leftReps = prior.leftReps
                    draft.exercises[exerciseIndex].sets[setIndex].rightReps = prior.rightReps
                }
                if draft.exercises[exerciseIndex].sets[setIndex].durationS == nil {
                    draft.exercises[exerciseIndex].sets[setIndex].durationS = prior.durationS
                }
                if draft.exercises[exerciseIndex].sets[setIndex].distanceM == nil {
                    draft.exercises[exerciseIndex].sets[setIndex].distanceM = prior.distanceM
                }
            }
        }
        touch(&draft)
    }

    public static func removeExercise(_ id: UUID, from draft: inout WorkoutDraft) throws {
        guard let index = draft.exercises.firstIndex(where: { $0.id == id }) else {
            throw WorkoutMutationError.exerciseNotFound
        }
        let group = draft.exercises[index].supersetId
        draft.exercises.remove(at: index)
        if let group, draft.exercises.filter({ $0.supersetId == group }).count < 2 {
            for i in draft.exercises.indices where draft.exercises[i].supersetId == group {
                draft.exercises[i].supersetId = nil
            }
        }
        touch(&draft)
    }

    public static func moveExercise(_ id: UUID, to position: Int,
                                    in draft: inout WorkoutDraft) throws {
        guard draft.exercises.indices.contains(position) else { throw WorkoutMutationError.invalidPosition }
        guard let old = draft.exercises.firstIndex(where: { $0.id == id }) else {
            throw WorkoutMutationError.exerciseNotFound
        }
        let value = draft.exercises.remove(at: old)
        draft.exercises.insert(value, at: min(position, draft.exercises.count))
        touch(&draft)
    }

    public static func formSuperset(_ ids: [UUID], in draft: inout WorkoutDraft) throws {
        let unique = Array(Set(ids))
        guard unique.count >= 2,
              unique.allSatisfy({ id in draft.exercises.contains { $0.id == id } }) else {
            throw WorkoutMutationError.exerciseNotFound
        }
        let group = UUID()
        for i in draft.exercises.indices where unique.contains(draft.exercises[i].id) {
            draft.exercises[i].supersetId = group
        }
        touch(&draft)
    }

    public static func dissolveSuperset(_ group: UUID, in draft: inout WorkoutDraft) {
        for i in draft.exercises.indices where draft.exercises[i].supersetId == group {
            draft.exercises[i].supersetId = nil
        }
        touch(&draft)
    }

    public static func complete(draft: WorkoutDraft, endTs: Int,
                                sessionRPE: Double? = nil) throws -> NativeWorkout {
        guard endTs >= draft.startedAt else { throw WorkoutMutationError.invalidEndTime }
        let exercises = draft.exercises.compactMap { exercise -> NativeWorkoutExercise? in
            var value = exercise
            value.sets = exercise.sets.filter(\.isCompleted)
            return value.sets.isEmpty ? nil : value
        }
        guard !exercises.isEmpty else { throw WorkoutMutationError.noCompletedWork }
        let validRPE = sessionRPE.flatMap { (1...10).contains($0) ? $0 : nil }
        return NativeWorkout(id: draft.id, title: draft.title,
                             startedAt: draft.startedAt, endedAt: endTs,
                             plannedDay: draft.plannedDay, routineIds: draft.routineIds,
                             exercises: exercises, tracker: draft.tracker,
                             sessionRPE: validRPE, note: draft.note)
    }

    private static func touch(_ draft: inout WorkoutDraft) {
        draft.updatedAt = max(draft.updatedAt + 1, Int(Date().timeIntervalSince1970))
    }
}
