import Foundation

/// Builds conservative, editable warm-up ramps from a known first work-set load.
/// The result is a suggestion only: warm-ups never become inferred history or working volume.
public enum WarmupPlanner {
    public static func suggestedSets(firstWorkSetKg: Double?, mode: TrainingMeasurementMode,
                                     incrementKg: Double, count: Int = 3,
                                     reps: Int = 6) -> [RoutineSetPlan] {
        guard mode == .weightReps || mode == .weightedBodyweight || mode == .assistedBodyweight,
              let work = firstWorkSetKg, work > 0 else { return [] }
        let requested = min(5, max(1, count))
        let step = max(0.1, incrementKg)
        // The last ramp is deliberately below the work set. A warm-up must never turn into an
        // unplanned top set merely because a coarse equipment increment rounded it upward.
        let fractions: [Double] = requested == 1 ? [0.5]
            : (0..<requested).map { 0.35 + Double($0) * 0.45 / Double(requested - 1) }
        return fractions.map { fraction in
            let raw = max(step, work * fraction)
            let rounded = floor(raw / step) * step
            return RoutineSetPlan(phase: .warmup, targetWeightKg: min(rounded, max(0, work - step)),
                                  repsMin: max(1, reps), repsMax: max(1, reps))
        }
    }
}
