import Foundation

/// Which of a day's planned routines are still to do. A routine a saved workout of that day was run from no
/// longer offers its Start: after "Pull and legs" was done, the Training tab kept offering it as planned today
/// (emulator walk-through 2026-11-27). Shared so iOS and the Android core decide it the same way.
public enum PlannedToday {
    /// The routine ids of `planned` that no workout planned for `day` was run from, in the plan's order.
    public static func openRoutineIds(_ planned: [UUID], day: String, workouts: [NativeWorkout]) -> [UUID] {
        let done = Set(workouts.filter { $0.plannedDay == day }.flatMap(\.routineIds))
        return planned.filter { !done.contains($0) }
    }
}
