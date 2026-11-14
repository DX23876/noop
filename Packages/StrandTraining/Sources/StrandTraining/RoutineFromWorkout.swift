import Foundation

/// Turns a session that has been done into a routine that can be done again.
///
/// The wish behind it is the plainest one in the training log: someone trains freestyle, likes what
/// they did, and wants it back next week without typing it in again. What was performed becomes the
/// prescription, and nothing is invented: a set nobody completed is not in it, and a figure nobody
/// logged stays empty rather than being guessed at.
public enum RoutineFromWorkout {

    /// The routine a finished session would become.
    ///
    /// - Parameters:
    ///   - repSpan: how wide a repetition range to open when every set of a movement hit the same
    ///     number. Zero keeps the exact number, which is the honest default: the wearer did five, so
    ///     the routine says five until they widen it themselves.
    /// Returns nil when the session holds no completed set at all, which is a session that was
    /// started and abandoned rather than one worth keeping.
    public static func make(workout: NativeWorkout, title: String, programId: UUID? = nil,
                            repSpan: Int = 0, now: Int = Int(Date().timeIntervalSince1970))
        -> TrainingRoutine? {
        var merged: [String: NativeWorkoutExercise] = [:]
        var order: [String] = []
        for logged in workout.exercises {
            let completed = logged.sets.filter(\.isCompleted)
            guard !completed.isEmpty else { continue }
            if var existing = merged[logged.exerciseId] {
                // The same movement logged twice in one session is one entry in the routine: its
                // sets, in the order they were done.
                existing.sets += completed
                merged[logged.exerciseId] = existing
            } else {
                var entry = logged
                entry.sets = completed
                merged[logged.exerciseId] = entry
                order.append(logged.exerciseId)
            }
        }
        guard !order.isEmpty else { return nil }

        var groups: [UUID: UUID] = [:]
        let entries: [RoutineExercise] = order.compactMap { id in
            guard let logged = merged[id] else { return nil }
            let group = logged.supersetId.map { old -> UUID in
                if let fresh = groups[old] { return fresh }
                let fresh = UUID(); groups[old] = fresh; return fresh
            }
            return RoutineExercise(
                exerciseId: logged.exerciseId,
                sets: sets(of: logged, repSpan: repSpan),
                restSeconds: logged.restSeconds,
                warmupRestSeconds: logged.warmupRestSeconds,
                supersetId: group,
                // No progression of its own: the routine's own default applies, which is what a
                // routine built by hand gets too.
                progression: nil,
                barWeightKg: logged.equipmentSnapshot?.barWeightKg,
                loadSemantics: logged.equipmentSnapshot?.loadSemantics,
                note: logged.note)
        }
        guard !entries.isEmpty else { return nil }
        return TrainingRoutine(title: title, exercises: entries,
                               excludeFromProgression: workout.exercises.allSatisfy(\.excludeFromProgression),
                               programId: programId, createdAt: now, updatedAt: now)
    }

    /// One logged exercise's sets as prescriptions. Warm-ups stay warm-ups, so a ramp does not come
    /// back as working volume.
    static func sets(of logged: NativeWorkoutExercise, repSpan: Int) -> [RoutineSetPlan] {
        let work = logged.sets.filter { $0.phase == .work }
        let reps = work.compactMap(\.reps)
        let low = reps.min()
        let high = reps.max()
        return logged.sets.map { set in
            var repsMin = set.reps
            var repsMax = set.reps
            if set.phase == .work, let low, let high {
                if low == high {
                    // Every set hit the same number: keep it, and open it by as much as the caller
                    // asked for and no more.
                    repsMin = low
                    repsMax = high + max(0, repSpan)
                } else {
                    repsMin = low
                    repsMax = high
                }
            }
            return RoutineSetPlan(phase: set.phase, intensifier: set.intensifier,
                                  targetWeightKg: set.weightKg,
                                  repsMin: repsMin, repsMax: repsMax,
                                  targetDurationS: set.durationS ?? set.targetDurationS,
                                  targetDistanceM: set.distanceM,
                                  intensifierConfiguration: nil)
        }
    }
}
