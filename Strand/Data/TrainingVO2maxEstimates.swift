import Foundation
import StrandAnalytics
import WhoopStore
import StrandCore

// TrainingVO2maxEstimates.swift — the one place NOOP estimates VO₂max from walks and runs. Training Load's
// experimental reading reads it (AgeLess did until AI-26), so the same session can never give two figures: fused
// sessions (each bout once), on foot, with a heart-rate trace the cardio load could price, against the
// cardio load's own resting rate (the week's median of the daily resting HR) and maximum heart rate. A
// session's measured climb (v78, resolved by `WorkoutElevationRow.resolve`) enters the oxygen cost (AI-25).

extension Repository {

    /// Every session estimate in `sessions`, and how many sessions were on foot (`TrainingVO2max`).
    nonisolated static func trainingVO2maxEstimates(sessions: [UnifiedTrainingSession],
                                                    resolution: TrainingCardioLoadResolution,
                                                    restingByDay: [String: Double], maxHR: Double,
                                                    offset: Int,
                                                    elevations: [WorkoutKey: WorkoutElevationRow] = [:])
        -> (estimates: [ExerciseVO2max.SessionEstimate], onFoot: Int) {
        TrainingVO2max.estimates(sessions: sessions, resolution: resolution, restingByDay: restingByDay,
                                 maxHR: maxHR, offset: offset, elevations: elevations)
    }

    /// The session estimates of the last `days` days, read the way Training Load reads them.
    func trainingVO2maxEstimates(days: Int) async -> [ExerciseVO2max.SessionEstimate] {
        let now = Date()
        let unified = await trainingSessions(days: days).sessions
        let resolution = await cardioLoads(for: unified)
        let resting = await restingHrByDay(fromDay: Self.localDayKey(now.addingTimeInterval(-Double(days) * 86_400)),
                                           toDay: Self.localDayKey(now))
        let nowTs = Int(now.timeIntervalSince1970)
        let elevations = await workoutElevations(from: nowTs - (days + 1) * 86_400, to: nowTs)
        return Self.trainingVO2maxEstimates(sessions: unified, resolution: resolution, restingByDay: resting,
                                            maxHR: Self.cardioLoadMaxHR(strainProfile),
                                            offset: TimeZone.current.secondsFromGMT(),
                                            elevations: elevations).estimates
    }

    /// The VO₂max inputs AgeLess and the VO₂max goal resolve with `HealthspanVO2`, so the two cannot follow
    /// different readings: the entered value and Apple Health's readings. Since AI-26 the estimate from walks and
    /// runs is not among them; it failed a lab check and stays a Training Load readout.
    func agelessVO2Inputs(days: Int) async -> (manual: (day: String, value: Double)?,
                                               appleHealth: [(day: String, value: Double)]) {
        (Self.enteredVO2max(), await exploreSeries(key: "vo2max", source: Self.appleHealthSource, days: days))
    }

    /// Walks of an hour or more with their oxygen cost, for AgeLess's endurance floor: the sessions
    /// Training Load reads (fused, each bout once, on foot), their measured climb where there is one. No heart
    /// rate enters, so medication, a meal or heat cannot move the bound.
    func agelessLongSessions(days: Int) async -> [HealthspanVO2.LongSession] {
        let now = Date()
        let unified = await trainingSessions(days: days).sessions
        let resolution = await cardioLoads(for: unified)
        let nowTs = Int(now.timeIntervalSince1970)
        let elevations = await workoutElevations(from: nowTs - (days + 1) * 86_400, to: nowTs)
        let offset = TimeZone.current.secondsFromGMT()
        return TrainingVO2max.longSessions(unified, resolution: resolution, elevations: elevations, offset: offset)
    }

    /// The VO₂max the wearer entered in Settings and the day it was measured; nil without one. Read raw, as
    /// AgeLess weighs it: the energy model's rescaling by body weight is its own business.
    nonisolated static func enteredVO2max(defaults: UserDefaults = .standard) -> (day: String, value: Double)? {
        let value = defaults.double(forKey: FitnessPreferences.manualKey)
        guard value > 0, let day = defaults.string(forKey: FitnessPreferences.manualDayKey), !day.isEmpty else { return nil }
        return (day, value)
    }
}
