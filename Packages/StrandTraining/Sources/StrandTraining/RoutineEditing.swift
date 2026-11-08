import Foundation

/// Pure routine-editing operations shared by the editor and tests. Supersets are moved as blocks so a
/// drag cannot silently split a group into unrelated positions.
public enum RoutineEditing {
    public static func move(_ exercises: inout [RoutineExercise],
                            from source: IndexSet, to destination: Int) {
        guard !source.isEmpty else { return }
        var expanded = source
        let groups = Set(source.compactMap { index in
            exercises.indices.contains(index) ? exercises[index].supersetId : nil
        })
        for index in exercises.indices where exercises[index].supersetId.map(groups.contains) == true {
            expanded.insert(index)
        }
        let moving = expanded.sorted().compactMap { exercises.indices.contains($0) ? exercises[$0] : nil }
        guard !moving.isEmpty else { return }
        let removedBeforeDestination = expanded.filter { $0 < destination }.count
        for index in expanded.sorted(by: >) where exercises.indices.contains(index) {
            exercises.remove(at: index)
        }
        let insertion = min(exercises.count, max(0, destination - removedBeforeDestination))
        exercises.insert(contentsOf: moving, at: insertion)
    }

    /// The weekdays on which `routineId` appears in the weekly schedule.
    public static func weekdays(of routineId: UUID,
                                in schedule: [TrainingWeekday: [UUID]]) -> Set<TrainingWeekday> {
        Set(schedule.compactMap { $0.value.contains(routineId) ? $0.key : nil })
    }

    /// Schedules one routine on exactly `weekdays`. Other routines and the order of each day stay as
    /// they were; a newly selected day appends the routine after the routines already planned there.
    public static func schedule(_ schedule: [TrainingWeekday: [UUID]], assigning routineId: UUID,
                                to weekdays: Set<TrainingWeekday>) -> [TrainingWeekday: [UUID]] {
        var result = schedule
        for weekday in TrainingWeekday.allCases {
            var ids = result[weekday] ?? []
            let isScheduled = ids.contains(routineId)
            if weekdays.contains(weekday), !isScheduled {
                ids.append(routineId)
            } else if !weekdays.contains(weekday), isScheduled {
                ids.removeAll { $0 == routineId }
            } else {
                continue
            }
            result[weekday] = ids
        }
        return result
    }

    /// Produces an independent routine. Exercise, set and superset identifiers are regenerated while
    /// exercise catalogue identifiers and progression settings remain references to the same domain.
    public static func duplicate(_ routine: TrainingRoutine, title: String, now: Int) -> TrainingRoutine {
        var groupMap: [UUID: UUID] = [:]
        let copiedExercises = routine.exercises.map { entry -> RoutineExercise in
            let copiedSets = entry.sets.map { set in
                RoutineSetPlan(phase: set.phase, intensifier: set.intensifier,
                               targetWeightKg: set.targetWeightKg, repsMin: set.repsMin,
                               repsMax: set.repsMax, targetDurationS: set.targetDurationS,
                               targetDistanceM: set.targetDistanceM,
                               intensifierConfiguration: set.intensifierConfiguration)
            }
            let copiedGroup = entry.supersetId.map { old in
                if let existing = groupMap[old] { return existing }
                let fresh = UUID(); groupMap[old] = fresh; return fresh
            }
            return RoutineExercise(exerciseId: entry.exerciseId, sets: copiedSets,
                                   restSeconds: entry.restSeconds,
                                   warmupRestSeconds: entry.warmupRestSeconds,
                                   supersetId: copiedGroup, progression: entry.progression,
                                   barWeightKg: entry.barWeightKg,
                                   loadSemantics: entry.loadSemantics, note: entry.note)
        }
        return TrainingRoutine(title: title, notes: routine.notes, exercises: copiedExercises,
                               defaultProgression: routine.defaultProgression,
                               excludeFromProgression: routine.excludeFromProgression,
                               createdAt: now, updatedAt: now)
    }
}

/// What a finished workout would change in the routines it was started from when its performed numbers
/// become the new targets: the wish of a tester who went up in weight mid-session and did not want to
/// open the editor afterwards to type the same numbers in again.
public struct RoutineTargetUpdate: Equatable, Sendable {
    /// The routines as they would be saved. Only routines with at least one changed set are listed.
    public let routines: [TrainingRoutine]
    /// How many planned sets would get new numbers, over all routines.
    public let changedSetCount: Int
    /// The exercises with a changed set, in workout order, each once.
    public let exerciseIds: [String]

    public var isEmpty: Bool { changedSetCount == 0 }

    /// Matches the n-th completed working set of each routine exercise to the n-th planned working set
    /// of that line. Warm-ups are left alone: a session may suggest its own, which the plan never held.
    /// Sets added during the session are not added to the routine and an unperformed planned set keeps
    /// its numbers; only targets change, never the shape of the routine.
    ///
    /// Weight becomes the performed weight. Repetitions replace a single-number target; a planned range
    /// is the progression's frame and only widens to include a performed count outside it. A planned
    /// duration becomes the performed duration.
    public static func make(workout: NativeWorkout, routines: [TrainingRoutine], now: Int) -> RoutineTargetUpdate {
        var updated: [TrainingRoutine] = []
        var changedSets = 0
        var exerciseIds: [String] = []
        for routine in routines where workout.routineIds.contains(routine.id) {
            var copy = routine
            var routineChanged = false
            for lineIndex in copy.exercises.indices {
                let line = copy.exercises[lineIndex]
                guard let performed = workout.exercises.first(where: {
                    $0.routineId == routine.id && $0.exerciseId == line.exerciseId
                }) else { continue }
                let done = performed.sets.filter { $0.phase == .work }
                let planIndices = line.sets.indices.filter { line.sets[$0].phase == .work }
                for (planIndex, set) in zip(planIndices, done) where set.isCompleted {
                    let before = copy.exercises[lineIndex].sets[planIndex]
                    let after = adopting(set, into: before)
                    guard after != before else { continue }
                    copy.exercises[lineIndex].sets[planIndex] = after
                    changedSets += 1
                    routineChanged = true
                    if !exerciseIds.contains(line.exerciseId) { exerciseIds.append(line.exerciseId) }
                }
            }
            if routineChanged {
                copy.updatedAt = now
                updated.append(copy)
            }
        }
        let order = workout.exercises.map(\.exerciseId)
        exerciseIds.sort { (order.firstIndex(of: $0) ?? .max) < (order.firstIndex(of: $1) ?? .max) }
        return RoutineTargetUpdate(routines: updated, changedSetCount: changedSets, exerciseIds: exerciseIds)
    }

    static func adopting(_ set: NativeWorkoutSet, into plan: RoutineSetPlan) -> RoutineSetPlan {
        var plan = plan
        if let weight = set.weightKg, weight.isFinite, weight >= 0 { plan.targetWeightKg = weight }
        if let reps = ProgressionReference.reps(of: set), reps > 0 {
            switch (plan.repsMin, plan.repsMax) {
            case let (low?, high?) where low < high:
                if reps < low { plan.repsMin = reps }
                if reps > high { plan.repsMax = reps }
            default:
                plan.repsMin = reps
                plan.repsMax = reps
            }
        }
        if plan.targetDurationS != nil, let duration = set.durationS, duration > 0 {
            plan.targetDurationS = duration
        }
        return plan
    }
}
