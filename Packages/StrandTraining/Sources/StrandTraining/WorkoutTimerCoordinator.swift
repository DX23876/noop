import Foundation

/// Pure timer transitions. Deadlines, rather than a decrementing counter, make a resumed workout
/// correct after backgrounding, a clock tick, or process recreation.
public enum WorkoutTimerCoordinator {
    public static func start(kind: WorkoutTimerKind, seconds: Int, exerciseId: UUID? = nil,
                             setId: UUID? = nil, now: Int) -> WorkoutTimerState? {
        guard seconds > 0 else { return nil }
        return WorkoutTimerState(kind: kind, exerciseId: exerciseId, setId: setId,
                                 startedAtTs: now, endsAtTs: now + seconds)
    }

    public static func remaining(_ timer: WorkoutTimerState, now: Int) -> Int {
        if let paused = timer.pausedRemainingSeconds { return max(0, paused) }
        return max(0, timer.endsAtTs - now)
    }

    public static func isFinished(_ timer: WorkoutTimerState, now: Int) -> Bool {
        timer.pausedRemainingSeconds == nil && remaining(timer, now: now) == 0
    }

    public static func pause(_ timer: WorkoutTimerState, now: Int) -> WorkoutTimerState {
        var value = timer
        value.pausedRemainingSeconds = remaining(timer, now: now)
        return value
    }

    public static func resume(_ timer: WorkoutTimerState, now: Int) -> WorkoutTimerState {
        guard let paused = timer.pausedRemainingSeconds else { return timer }
        var value = timer
        value.startedAtTs = now
        value.endsAtTs = now + max(0, paused)
        value.pausedRemainingSeconds = nil
        return value
    }

    public static func adjust(_ timer: WorkoutTimerState, by seconds: Int, now: Int) -> WorkoutTimerState {
        let adjusted = max(1, remaining(timer, now: now) + seconds)
        var value = timer
        value.startedAtTs = now
        value.endsAtTs = now + adjusted
        value.pausedRemainingSeconds = timer.pausedRemainingSeconds == nil ? nil : adjusted
        return value
    }
}
