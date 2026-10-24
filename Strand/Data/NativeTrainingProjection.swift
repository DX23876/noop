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
}
