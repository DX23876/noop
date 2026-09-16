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
                             routines: [TrainingRoutine], tracker: SessionTrackerAttribution? = nil,
                             exerciseDefinitions: [String: TrainingExercise] = [:]) -> WorkoutDraft {
        var entries: [NativeWorkoutExercise] = []
        for routine in routines {
            entries += routine.exercises.map { planned in
                let definition = exerciseDefinitions[planned.exerciseId]
                let semantics = planned.loadSemantics
                    ?? ExerciseLoadSemantics.defaultValue(for: definition?.mode ?? .weightReps,
                                                          equipmentIds: definition?.equipmentIds ?? [])
                return NativeWorkoutExercise(
                    exerciseId: planned.exerciseId,
                    routineId: routine.id,
                    sets: plannedSets(planned.sets),
                    restSeconds: planned.restSeconds,
                    warmupRestSeconds: planned.warmupRestSeconds,
                    supersetId: planned.supersetId,
                    excludeFromProgression: routine.excludeFromProgression,
                    equipmentSnapshot: EquipmentSnapshot(
                        equipmentIds: definition?.equipmentIds ?? [], loadSemantics: semantics,
                        barWeightKg: planned.barWeightKg),
                    note: planned.note)
            }
        }
        return WorkoutDraft(title: title, startedAt: startTs, plannedDay: day,
                            routineIds: routines.map(\.id), exercises: entries, tracker: tracker)
    }

    /// Converts routine targets into performed-set rows and links drop/rest-pause rows to the nearest
    /// preceding work set. The relationship is explicit without creating a second set hierarchy.
    public static func plannedSets(_ plans: [RoutineSetPlan]) -> [NativeWorkoutSet] {
        var result: [NativeWorkoutSet] = []
        var originIndex: Int?
        var segmentCount = 0
        for (offset, plan) in plans.enumerated() {
            var set = NativeWorkoutSet(index: offset, phase: plan.phase,
                intensifier: plan.intensifier, weightKg: plan.targetWeightKg, reps: plan.repsMin,
                targetDurationS: plan.targetDurationS, durationS: plan.targetDurationS,
                distanceM: plan.targetDistanceM)
            if plan.phase == .work && (plan.intensifier == .dropSet || plan.intensifier == .restPause),
               let originIndex {
                let cluster = result[originIndex].clusterId ?? UUID()
                result[originIndex].clusterId = cluster
                set.clusterId = cluster
                set.parentSetId = result[originIndex].id
                segmentCount += 1
                set.segmentIndex = segmentCount
            } else if plan.phase == .work {
                originIndex = result.count
                segmentCount = 0
            } else {
                originIndex = nil
                segmentCount = 0
            }
            result.append(set)
        }
        return result
    }

    public static func addExercise(_ exerciseId: String, to draft: inout WorkoutDraft,
                                   sets: [NativeWorkoutSet] = [],
                                   definition: TrainingExercise? = nil,
                                   loadSemantics: ExerciseLoadSemantics? = nil) {
        let semantics = loadSemantics
            ?? ExerciseLoadSemantics.defaultValue(for: definition?.mode ?? .weightReps,
                                                   equipmentIds: definition?.equipmentIds ?? [])
        draft.exercises.append(.init(
            exerciseId: exerciseId, sets: sets,
            equipmentSnapshot: EquipmentSnapshot(
                equipmentIds: definition?.equipmentIds ?? [], loadSemantics: semantics)))
        touch(&draft)
    }

    /// Appends an editable set using the preceding set's measurable targets. Completion and effort
    /// belong to the performed set, so a new row never inherits either of them.
    public static func appendSet(to exerciseId: UUID, in draft: inout WorkoutDraft) throws {
        guard let exerciseIndex = draft.exercises.firstIndex(where: { $0.id == exerciseId }) else {
            throw WorkoutMutationError.exerciseNotFound
        }
        let previous = draft.exercises[exerciseIndex].sets.last
        let measurementSource: NativeWorkoutSet?
        if let parentId = previous?.parentSetId {
            measurementSource = draft.exercises[exerciseIndex].sets.first { $0.id == parentId }
        } else {
            measurementSource = previous
        }
        draft.exercises[exerciseIndex].sets.append(.init(
            index: draft.exercises[exerciseIndex].sets.count,
            phase: measurementSource?.phase ?? .work,
            intensifier: .none,
            weightKg: measurementSource?.weightKg,
            reps: measurementSource?.reps,
            leftReps: measurementSource?.leftReps,
            rightReps: measurementSource?.rightReps,
            targetDurationS: measurementSource?.targetDurationS,
            durationS: measurementSource?.durationS,
            distanceM: measurementSource?.distanceM))
        touch(&draft)
    }

    /// Appends one technique segment to a work set. The origin and every segment share one cluster;
    /// analytics can therefore distinguish one logical effort from several recorded rows.
    public static func appendSegment(to originSetId: UUID, intensifier: TrainingSetIntensifier,
                                     in draft: inout WorkoutDraft) throws {
        guard intensifier == .dropSet || intensifier == .restPause else {
            throw WorkoutMutationError.invalidPosition
        }
        for exerciseIndex in draft.exercises.indices {
            guard let originIndex = draft.exercises[exerciseIndex].sets.firstIndex(where: {
                $0.id == originSetId && $0.phase == .work && $0.parentSetId == nil
            }) else { continue }
            let origin = draft.exercises[exerciseIndex].sets[originIndex]
            let cluster = origin.clusterId ?? UUID()
            draft.exercises[exerciseIndex].sets[originIndex].clusterId = cluster
            let segmentNumber = draft.exercises[exerciseIndex].sets.filter {
                $0.clusterId == cluster && $0.parentSetId == originSetId
            }.count + 1
            draft.exercises[exerciseIndex].sets.append(.init(
                index: draft.exercises[exerciseIndex].sets.count, phase: .work,
                intensifier: intensifier, weightKg: origin.weightKg, reps: origin.reps,
                leftReps: origin.leftReps, rightReps: origin.rightReps,
                targetDurationS: origin.targetDurationS, durationS: origin.durationS,
                distanceM: origin.distanceM, clusterId: cluster,
                parentSetId: originSetId, segmentIndex: segmentNumber))
            touch(&draft)
            return
        }
        throw WorkoutMutationError.setNotFound
    }

    public static func clusters(in exercise: NativeWorkoutExercise) -> [SetCluster] {
        let grouped = Dictionary(grouping: exercise.sets.compactMap { set -> NativeWorkoutSet? in
            set.clusterId == nil ? nil : set
        }, by: { $0.clusterId! })
        return grouped.compactMap { id, sets in
            guard let origin = sets.first(where: { $0.parentSetId == nil }) else { return nil }
            let segments = sets.filter { $0.parentSetId == origin.id }
                .sorted { ($0.segmentIndex ?? 0) < ($1.segmentIndex ?? 0) }
            return SetCluster(id: id, originSetId: origin.id, segmentSetIds: segments.map(\.id))
        }.sorted { $0.originSetId.uuidString < $1.originSetId.uuidString }
    }

    public static func restSeconds(after set: NativeWorkoutSet,
                                   in exercise: NativeWorkoutExercise) -> Int {
        set.phase == .warmup ? (exercise.warmupRestSeconds ?? exercise.restSeconds) : exercise.restSeconds
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

    /// Ends an exercise early. Completed sets stay; unfinished sets are removed. An exercise without a
    /// completed set is removed entirely, dissolving a superset that would be left with one member.
    public static func skipRemainingSets(of exerciseId: UUID, in draft: inout WorkoutDraft) throws {
        guard let index = draft.exercises.firstIndex(where: { $0.id == exerciseId }) else {
            throw WorkoutMutationError.exerciseNotFound
        }
        let completed = draft.exercises[index].sets.filter(\.isCompleted)
        guard !completed.isEmpty else {
            try removeExercise(exerciseId, from: &draft)
            return
        }
        let kept = Set(completed.map(\.id))
        draft.exercises[index].sets = completed.enumerated().map { offset, set in
            var value = set
            value.index = offset
            if let parent = value.parentSetId, !kept.contains(parent) {
                value.parentSetId = nil
                value.segmentIndex = nil
            }
            return value
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
                                sessionRPE: Double? = nil,
                                sessionRPEOrigin: SessionRPEOrigin? = nil) throws -> NativeWorkout {
        guard endTs >= draft.startedAt else { throw WorkoutMutationError.invalidEndTime }
        let validation = completionValidation(for: draft)
        guard validation.canComplete else { throw WorkoutMutationError.noCompletedWork }
        let exercises = draft.exercises.compactMap { exercise -> NativeWorkoutExercise? in
            var value = exercise
            value.sets = exercise.sets.filter(\.isCompleted)
            return value.sets.isEmpty ? nil : value
        }
        let validRPE = sessionRPE.flatMap { (1...10).contains($0) ? $0 : nil }
        return NativeWorkout(id: draft.id, title: draft.title,
                             startedAt: draft.startedAt, endedAt: endTs,
                             plannedDay: draft.plannedDay, routineIds: draft.routineIds,
                             exercises: exercises, tracker: draft.tracker,
                             sessionRPE: validRPE,
                             sessionRPEOrigin: validRPE == nil ? nil
                                : (sessionRPEOrigin ?? .workoutCompletion),
                             note: draft.note,
                             pauseIntervals: draft.pauseIntervals)
    }

    public static func completionValidation(for draft: WorkoutDraft) -> WorkoutCompletionValidation {
        let all = draft.exercises.flatMap(\.sets)
        let completed = all.filter(\.isCompleted).count
        let incomplete = all.count - completed
        let state: WorkoutCompletionState
        if completed == 0 { state = .empty }
        else if incomplete > 0 { state = .partial }
        else { state = .complete }
        return .init(state: state, completedSetCount: completed,
                     incompleteSetCount: incomplete,
                     completedExerciseCount: draft.exercises.filter {
                         $0.sets.contains(where: \.isCompleted)
                     }.count)
    }

    /// A compact, source-of-truth session recap. `loadedVolumeKg` deliberately counts only external
    /// load with recorded repetitions; bodyweight and assisted movements need a dated body mass and
    /// therefore stay out of this specific statistic instead of being guessed.
    public static func summary(for workout: NativeWorkout) -> NativeWorkoutSummary {
        let sets = workout.exercises.flatMap(\.sets).filter(\.isCompleted)
        let work = sets.filter { $0.phase == .work }
        let warmup = sets.filter { $0.phase == .warmup }
        let loadedVolume = work.reduce(0.0) { total, set in
            guard let weight = set.weightKg, weight >= 0 else { return total }
            let reps = set.reps ?? ((set.leftReps ?? 0) + (set.rightReps ?? 0))
            return total + weight * Double(max(0, reps))
        }
        let elapsed = max(0, workout.endedAt - workout.startedAt)
        let paused = pausedSeconds(workout.pauseIntervals ?? [], start: workout.startedAt,
                                   end: workout.endedAt)
        return .init(exerciseCount: workout.exercises.count, workingSetCount: work.count,
                     warmupSetCount: warmup.count, loadedVolumeKg: loadedVolume,
                     elapsedDurationS: elapsed, activeDurationS: max(0, elapsed - paused))
    }

    private static func pausedSeconds(_ intervals: [WorkoutPauseInterval], start: Int, end: Int) -> Int {
        let clipped = intervals.compactMap { interval -> (Int, Int)? in
            let lower = max(start, interval.startedAtTs)
            let upper = min(end, interval.endedAtTs ?? end)
            return upper > lower ? (lower, upper) : nil
        }.sorted { $0.0 < $1.0 }
        var total = 0
        var current: (Int, Int)?
        for interval in clipped {
            guard let active = current else { current = interval; continue }
            if interval.0 <= active.1 {
                current = (active.0, max(active.1, interval.1))
            } else {
                total += active.1 - active.0
                current = interval
            }
        }
        if let current { total += current.1 - current.0 }
        return total
    }

    private static func touch(_ draft: inout WorkoutDraft) {
        draft.updatedAt = max(draft.updatedAt + 1, Int(Date().timeIntervalSince1970))
    }
}
