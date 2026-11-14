import Foundation

/// The routine as THIS WEEK of a block prescribes it: the week's own step, and a lighter week's
/// damping on top.
///
/// It works on the way out, never in the store. The stored routine stays the first week of the
/// block, so the week after a lighter one is the full prescription again with nothing to repair, and
/// a wearer who leaves the block behind has their routine back exactly as they wrote it.
///
/// One funnel: everything that shows or starts a session asks this, so a card, a session and a
/// countdown cannot each work out the week's load for themselves.
public enum BlockPrescription {

    /// How many extra work sets a volume block may add, however long it runs. Without a ceiling a
    /// twelve week block would end at a session nobody finishes.
    public static let maxAddedSets = 3

    /// The routine as `state` prescribes it. Returns it untouched when there is no block running, so
    /// a caller can apply this unconditionally.
    public static func apply(_ routine: TrainingRoutine, state: TrainingBlockState.State?,
                             policy: BlockProgressionPolicy, weightStepKg: Double) -> TrainingRoutine {
        guard let state, !state.isFinished else { return routine }
        var out = routine
        out.exercises = routine.exercises.map { entry in
            var changed = entry
            if policy != .none, state.week > 1 {
                changed.sets = stepped(entry.sets, weeks: state.week - 1, policy: policy,
                                       weightStepKg: weightStepKg)
            }
            if state.isDeload {
                changed.sets = damped(changed.sets, factor: state.loadFactor)
            }
            return changed
        }
        return out
    }

    /// What a block does to a weight the session's prefill supplied, rather than one the plan carries.
    ///
    /// A plan the builder or a ready-made template wrote carries no target weights at all, so the
    /// week's step and a lighter week had nothing to act on: both were silently no-ops for exactly
    /// the plans the app creates. This is the other half, applied to the weight the wearer last
    /// lifted, and the step is counted from the week THAT session belonged to, so a week's step is
    /// added once rather than once per week since the block began.
    ///
    /// - Parameter weeksSince: block weeks between the session the weight came from and this one.
    public static func prefilledWeight(_ weight: Double, weeksSince: Int,
                                       policy: BlockProgressionPolicy, loadFactor: Double,
                                       weightStepKg: Double) -> Double {
        let stepped = policy == .weeklyLoad
            ? weight + Double(max(0, weeksSince)) * max(0.5, weightStepKg)
            : weight
        return stepped * min(1, max(0.5, loadFactor))
    }

    /// The week's step applied to one exercise's sets.
    static func stepped(_ sets: [RoutineSetPlan], weeks: Int, policy: BlockProgressionPolicy,
                        weightStepKg: Double) -> [RoutineSetPlan] {
        switch policy {
        case .none:
            return sets
        case .weeklyLoad:
            // Only a set that already carries a weight is stepped: adding kilograms to a set the plan
            // left open would invent a load nobody chose.
            return sets.map { set in
                guard set.phase == .work, let weight = set.targetWeightKg, weight > 0 else { return set }
                var changed = set
                changed.targetWeightKg = weight + Double(weeks) * max(0.5, weightStepKg)
                return changed
            }
        case .weeklyVolume:
            let added = min(maxAddedSets, weeks)
            guard added > 0, let template = sets.last(where: { $0.phase == .work }) else { return sets }
            var out = sets
            for _ in 0..<added {
                out.append(RoutineSetPlan(phase: .work, intensifier: template.intensifier,
                                          targetWeightKg: template.targetWeightKg,
                                          repsMin: template.repsMin, repsMax: template.repsMax,
                                          targetDurationS: template.targetDurationS,
                                          targetDistanceM: template.targetDistanceM,
                                          intensifierConfiguration: template.intensifierConfiguration))
            }
            return out
        }
    }

    /// A lighter week: the work keeps its share of the load, and the number of work sets comes down
    /// with it. Warm-ups are left alone, since a ramp is not the work.
    static func damped(_ sets: [RoutineSetPlan], factor: Double) -> [RoutineSetPlan] {
        let work = sets.filter { $0.phase == .work }
        guard !work.isEmpty else { return sets }
        let keep = max(1, Int((Double(work.count) * factor).rounded(.down)))
        var kept = 0
        var out: [RoutineSetPlan] = []
        for set in sets {
            guard set.phase == .work else { out.append(set); continue }
            kept += 1
            guard kept <= keep else { continue }
            var changed = set
            if let weight = set.targetWeightKg { changed.targetWeightKg = weight * factor }
            if let duration = set.targetDurationS {
                changed.targetDurationS = max(5, Int((Double(duration) * factor).rounded()))
            }
            out.append(changed)
        }
        return out
    }
}
