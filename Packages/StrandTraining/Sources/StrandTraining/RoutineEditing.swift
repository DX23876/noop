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
