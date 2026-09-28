import Foundation

// How the numbers of a running session move from one set to the next, and which set a hands-free step
// (a strap double-tap, the Watch's "complete set") acts on. Pure, so every surface that logs a set
// shares one answer and `swift test` covers it without the app.

extension NativeWorkoutEngine {
    /// Applies `edit` to one set, then lets the open sets after it follow the change.
    ///
    /// A later set follows a value only while it still holds the value the edited set had before: it was
    /// riding along with the plan. A set that differs was set on purpose (a pyramid of 60, 70, 80 kg) and
    /// keeps its number. Only open sets of the same exercise and phase follow, never a drop-set or
    /// rest-pause segment, and never a completed set. A value cleared to empty stays on the edited set:
    /// emptying a field is a correction of that set, or a step before typing a new number. Effort never
    /// follows, because how hard a set felt is known only after it.
    public static func editSet(_ setIndex: Int, ofExercise exerciseIndex: Int, in draft: inout WorkoutDraft,
                               _ edit: (inout NativeWorkoutSet) -> Void) {
        guard draft.exercises.indices.contains(exerciseIndex),
              draft.exercises[exerciseIndex].sets.indices.contains(setIndex) else { return }
        let before = draft.exercises[exerciseIndex].sets[setIndex]
        edit(&draft.exercises[exerciseIndex].sets[setIndex])
        let after = draft.exercises[exerciseIndex].sets[setIndex]
        guard !before.isClusterSegment else { return }
        let sets = draft.exercises[exerciseIndex].sets
        for index in sets.indices where index > setIndex {
            let later = sets[index]
            guard !later.isCompleted, !later.isClusterSegment, later.phase == after.phase else { continue }
            var followed = later
            follow(\.weightKg, before: before, after: after, in: &followed)
            follow(\.reps, before: before, after: after, in: &followed)
            follow(\.leftReps, before: before, after: after, in: &followed)
            follow(\.rightReps, before: before, after: after, in: &followed)
            follow(\.durationS, before: before, after: after, in: &followed)
            follow(\.distanceM, before: before, after: after, in: &followed)
            draft.exercises[exerciseIndex].sets[index] = followed
        }
    }

    private static func follow<Value: Equatable>(_ field: WritableKeyPath<NativeWorkoutSet, Value?>,
                                                 before: NativeWorkoutSet, after: NativeWorkoutSet,
                                                 in later: inout NativeWorkoutSet) {
        guard let value = after[keyPath: field], value != before[keyPath: field],
              later[keyPath: field] == before[keyPath: field] else { return }
        later[keyPath: field] = value
    }

    /// The set a hands-free step completes: the active exercise's next open set; in a superset, the member
    /// that is behind (the one after the active exercise on a tie), so the step follows the alternation the
    /// lifter is doing; otherwise the next exercise in order that still has an open set.
    public static func nextOpenSet(in draft: WorkoutDraft) -> (exercise: Int, set: Int)? {
        let exercises = draft.exercises
        guard !exercises.isEmpty else { return nil }
        let active = draft.cursor.flatMap { cursor in exercises.firstIndex { $0.id == cursor.exerciseId } } ?? 0
        let order = (0..<exercises.count).map { (active + $0) % exercises.count }
        func openSet(_ index: Int) -> Int? { exercises[index].sets.firstIndex { !$0.isCompleted } }
        if let group = exercises[active].supersetId {
            // Start after the active exercise so a tie moves the step on to the next member.
            let members = (order.dropFirst() + [active]).filter { exercises[$0].supersetId == group }
            let behind = members.filter { openSet($0) != nil }.min {
                exercises[$0].sets.filter(\.isCompleted).count < exercises[$1].sets.filter(\.isCompleted).count
            }
            if let behind, let set = openSet(behind) { return (behind, set) }
        }
        for index in order { if let set = openSet(index) { return (index, set) } }
        return nil
    }

    /// Whether a set holds the numbers its exercise is logged with, so a step that cannot see the row (the
    /// strap, the Watch) may complete it. Loaded work needs a weight and repetitions, bodyweight work only
    /// repetitions, a timed set its time, a distance set its distance or time. `mode` nil (an exercise the
    /// session has no definition for) accepts any repetitions, time or distance.
    public static func hasLoggableValues(_ set: NativeWorkoutSet, mode: TrainingMeasurementMode?) -> Bool {
        let hasReps = set.reps != nil || set.leftReps != nil || set.rightReps != nil
        switch mode {
        case .weightReps, .weightedBodyweight, .assistedBodyweight:
            return set.weightKg != nil && hasReps
        case .bodyweightReps, .repetitions:
            return hasReps
        case .duration:
            return set.durationS != nil
        case .distanceDuration:
            return set.distanceM != nil || set.durationS != nil
        case nil:
            return hasReps || set.durationS != nil || set.distanceM != nil
        }
    }

    /// The rows an exercise added to a running session starts with: its last performance set by set, or,
    /// without one, a single set of 8 repetitions with the weight left EMPTY. An empty weight shows it has
    /// to be entered; 0 kg would look like a real number and be logged as one.
    public static func setsForAddedExercise(lastPerformance: [NativeWorkoutSet],
                                            unilateral: Bool) -> [NativeWorkoutSet] {
        guard lastPerformance.isEmpty else {
            return lastPerformance.enumerated().map { index, prior in
                NativeWorkoutSet(index: index, phase: prior.phase, weightKg: prior.weightKg,
                                 reps: prior.reps, leftReps: prior.leftReps, rightReps: prior.rightReps,
                                 durationS: prior.durationS, distanceM: prior.distanceM)
            }
        }
        return [unilateral ? NativeWorkoutSet(index: 0, leftReps: 8, rightReps: 8)
                           : NativeWorkoutSet(index: 0, reps: 8)]
    }
}
