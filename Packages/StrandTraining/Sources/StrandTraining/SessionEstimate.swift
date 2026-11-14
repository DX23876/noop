import Foundation

/// How long a prescribed session is likely to take, from its own sets and rests.
///
/// One estimator, used by the builder to decide what still fits in the time the wearer asked for and
/// by the plan's own readout to say how long a session is. Two estimators would eventually disagree,
/// and the number a screen shows would stop being the number the plan was trimmed to.
public enum SessionEstimate {

    /// Seconds a set of work takes, before its rest. A prescribed duration is taken at its word; a
    /// set of repetitions is counted at three seconds a repetition, from the top of its range, which
    /// is the slow end of ordinary lifting tempo and so errs towards saying a session is longer.
    public static func workSeconds(_ set: RoutineSetPlan) -> Int {
        if let duration = set.targetDurationS { return max(0, duration) }
        let reps = set.repsMax ?? set.repsMin ?? 10
        return max(10, reps * 3)
    }

    /// Seconds one exercise takes: every set's work plus a rest after each set but the last, since
    /// the rest after the final set belongs to the next exercise's own first rest, not to this one.
    public static func seconds(_ entry: RoutineExercise) -> Int {
        guard !entry.sets.isEmpty else { return 0 }
        let work = entry.sets.reduce(0) { $0 + workSeconds($1) }
        let rests = entry.sets.dropLast().reduce(0) { total, set in
            total + (set.phase == .warmup ? (entry.warmupRestSeconds ?? entry.restSeconds)
                                          : entry.restSeconds)
        }
        return work + rests
    }

    /// Seconds a whole routine takes, with one rest between exercises.
    ///
    /// Exercises paired as a superset are counted once, side by side: their sets alternate, so the
    /// pair costs the longer of the two rather than the sum.
    public static func seconds(_ routine: TrainingRoutine) -> Int {
        var total = 0
        var handled = Set<UUID>()
        for entry in routine.exercises where !handled.contains(entry.id) {
            if let group = entry.supersetId {
                let paired = routine.exercises.filter { $0.supersetId == group }
                paired.forEach { handled.insert($0.id) }
                total += paired.map(seconds).max() ?? 0
                total += entry.restSeconds
            } else {
                handled.insert(entry.id)
                total += seconds(entry) + entry.restSeconds
            }
        }
        // The rest counted after the last exercise is dropped again: nobody rests before leaving.
        return max(0, total - (routine.exercises.last?.restSeconds ?? 0))
    }

    public static func minutes(_ routine: TrainingRoutine) -> Int {
        Int((Double(seconds(routine)) / 60).rounded())
    }
}
