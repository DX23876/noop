import Foundation
import StrandAnalytics

// TrainingVO2maxEstimates.swift — the one place NOOP estimates VO₂max from walks and runs. Training Load's
// experimental reading and AgeLess both read it, so the same session can never give two figures: fused
// sessions (each bout once), on foot, with a heart-rate trace the cardio load could price, against the
// cardio load's own resting rate (the week's median of the daily resting HR) and maximum heart rate.

extension Repository {

    /// Every session estimate in `sessions`, and how many sessions were on foot.
    nonisolated static func trainingVO2maxEstimates(sessions: [UnifiedTrainingSession],
                                                    resolution: TrainingCardioLoadResolution,
                                                    restingByDay: [String: Double], maxHR: Double,
                                                    offset: Int) -> (estimates: [ExerciseVO2max.SessionEstimate], onFoot: Int) {
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
                restingHR: cardioLoadRestingHR(day: metrics.day, restingByDay: restingByDay),
                maxHR: maxHR)
            if case let .estimate(estimate) = ExerciseVO2max.estimate(input) { estimates.append(estimate) }
        }
        return (estimates, onFoot)
    }

    /// The session estimates of the last `days` days, read the way Training Load reads them.
    func trainingVO2maxEstimates(days: Int) async -> [ExerciseVO2max.SessionEstimate] {
        let now = Date()
        let unified = await trainingSessions(days: days).sessions
        let resolution = await cardioLoads(for: unified)
        let resting = await restingHrByDay(fromDay: Self.localDayKey(now.addingTimeInterval(-Double(days) * 86_400)),
                                           toDay: Self.localDayKey(now))
        return Self.trainingVO2maxEstimates(sessions: unified, resolution: resolution, restingByDay: resting,
                                            maxHR: Self.cardioLoadMaxHR(strainProfile),
                                            offset: TimeZone.current.secondsFromGMT()).estimates
    }

    /// One value per day for AgeLess: the median of that day's session estimates.
    nonisolated static func trainingVO2maxByDay(_ estimates: [ExerciseVO2max.SessionEstimate]) -> [(day: String, value: Double)] {
        Dictionary(grouping: estimates, by: \.day)
            .compactMap { day, xs in HealthspanVO2.median(xs.map(\.vo2max)).map { (day: day, value: $0) } }
            .sorted { $0.day < $1.day }
    }
}
