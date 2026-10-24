import Foundation
import StrandAnalytics
import WhoopStore

// The one place NOOP estimates VO₂max from walks and runs. Training Load's experimental reading reads it (AgeLess
// did until AI-26), so the same session can never give two figures: fused sessions (each bout once), on foot,
// with a heart-rate trace the cardio load could price, against the cardio load's own resting rate (the week's
// median of the daily resting HR) and maximum heart rate. A session's measured climb (v78, resolved by
// `WorkoutElevationRow.resolve`) enters the oxygen cost (AI-25). Moved from the app (Android plan B3 step 4).
public enum TrainingVO2max {
    /// Every session estimate in `sessions`, and how many sessions were on foot.
    public static func estimates(sessions: [UnifiedTrainingSession], resolution: TrainingCardioLoadResolution,
                                 restingByDay: [String: Double], maxHR: Double, offset: Int,
                                 elevations: [WorkoutKey: WorkoutElevationRow] = [:])
        -> (estimates: [ExerciseVO2max.SessionEstimate], onFoot: Int) {
        var estimates: [ExerciseVO2max.SessionEstimate] = []
        var onFoot = 0
        for session in sessions where !resolution.duplicateSessionIds.contains(session.id) {
            let metrics = CardioSession.metrics(for: session.row, tzOffsetSeconds: offset)
            guard metrics.modality == .foot else { continue }
            onFoot += 1
            let input = ExerciseVO2max.SessionInput(
                day: metrics.day, startTs: metrics.startTs, modality: metrics.modality,
                distanceM: metrics.distanceM, durationS: metrics.durationS,
                averageHR: metrics.avgHr.map(Double.init),
                heartRateMeasured: resolution.loads[session.id] != nil,
                restingHR: CardioLoadPricing.cardioLoadRestingHR(day: metrics.day, restingByDay: restingByDay),
                maxHR: maxHR,
                ascentM: WorkoutElevationRow.resolve(startTs: session.row.startTs, sport: session.row.sport,
                                                     rowSource: session.row.source, in: elevations)?.ascentM)
            if case let .estimate(estimate) = ExerciseVO2max.estimate(input) { estimates.append(estimate) }
        }
        return (estimates, onFoot)
    }


    /// Walks of an hour or more with their oxygen cost, for AgeLess's endurance floor: the sessions
    /// Training Load reads (fused, each bout once, on foot), their measured climb where there is one. No heart
    /// rate enters, so medication, a meal or heat cannot move the bound.
    public static func longSessions(_ unified: [UnifiedTrainingSession], resolution: TrainingCardioLoadResolution,
                                    elevations: [WorkoutKey: WorkoutElevationRow],
                                    offset: Int) -> [HealthspanVO2.LongSession] {
        return unified.compactMap { session in
            guard !resolution.duplicateSessionIds.contains(session.id) else { return nil }
            let metrics = CardioSession.metrics(for: session.row, tzOffsetSeconds: offset)
            guard metrics.modality == .foot, let distance = metrics.distanceM, let duration = metrics.durationS,
                  let cost = HealthspanVO2.longSessionCost(
                      distanceM: distance, durationS: duration,
                      ascentM: WorkoutElevationRow.resolve(startTs: session.row.startTs, sport: session.row.sport,
                                                           rowSource: session.row.source, in: elevations)?.ascentM)
            else { return nil }
            return HealthspanVO2.LongSession(day: metrics.day, oxygenCost: cost)
        }
    }
}
