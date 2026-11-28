import Foundation
import StrandAnalytics
import StrandTraining
import WhoopStore
import StrandCore

extension Repository {
    /// Pins the native set component and its chosen physiological component to one canonical session.
    /// This is additive metadata; neither workout row nor heart-rate buckets are copied.
    func linkNativeWorkoutPhysiology(_ workout: NativeWorkout) async {
        guard let sessionId = workout.trainingSessionId, let store = await storeHandle() else { return }
        let native = NativeTrainingProjection.workoutRow(workout)
        let nativeKey = "\(native.source)|\(native.startTs)|\(WorkoutSource.sportKey(native.sport))"
        var keys = [nativeKey]
        if let physiology = workout.physiologyComponentKey { keys.append(physiology) }
        let now = Int(Date().timeIntervalSince1970)
        try? await store.upsertTrainingSessionLinks(keys.map {
            .init(componentKey: $0, sessionId: sessionId.uuidString,
                  origin: "native-lifecycle", updatedAtTs: now)
        })
        if let primary = workout.physiologyComponentKey {
            try? await store.upsertTrainingSessionPreference(.init(
                sessionId: sessionId.uuidString, activityKind: TrainingActivityKind.strength.rawValue,
                primaryComponentKey: primary, updatedAtTs: now))
        }
    }

    /// The names the wearer gave the strength sessions of the last `days` days, keyed by
    /// `NativeTrainingProjection.titleKey`, so a Workouts list shows "Push day" where the row's sport reads
    /// only "Strength Training". The same core read Android's lists use (`read.sessionTitles`).
    func sessionTitles(days: Int) async -> [String: String] {
        guard let store = await storeHandle() else { return [:] }
        let now = Int(Date().timeIntervalSince1970)
        return await storeReader(store).sessionTitles(from: now - days * 86_400, to: now + 1)
    }

    /// Re-reads `sessionTitles` off the refresh path; a list that appears before it lands shows the sport for
    /// a moment, never a stale name for another session (the key carries the start).
    func scheduleSessionTitlesRefresh() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let titles = await self.sessionTitles(days: 92)
            if titles != self.sessionTitles { self.sessionTitles = titles }
        }
    }

    /// A list row's name: the session's own when the wearer gave it one, else its sport.
    nonisolated static func sessionName(_ row: WorkoutRow, titles: [String: String]) -> String {
        titles[NativeTrainingProjection.titleKey(source: row.source, startTs: row.startTs)]
            ?? WorkoutSource.localizedDisplaySport(row.sport)
    }
}
