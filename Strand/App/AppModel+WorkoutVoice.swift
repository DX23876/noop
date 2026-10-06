import Foundation
import StrandAnalytics

extension AppModel {
    /// The running workout as the voice coach reads it each second; nil once no workout is active.
    func workoutVoiceSnapshot() -> WorkoutVoiceCoach.Snapshot? {
        guard let workout = activeWorkout else { return nil }
        let scale = UnitPrefs.currentEffortScale()
        // Effort is spoken only once heart rate has produced one; "zero" would claim a measured rest.
        let effort = workout.samples.count >= 2
            ? UnitFormatter.effortDisplay(workout.liveStrain, scale: scale) : nil
        return WorkoutVoiceCoach.Snapshot(
            elapsedSeconds: Int(workout.elapsed()),
            distanceMeters: activeWorkoutUsesGPS && gpsRecorder.pointCount > 1 ? gpsRecorder.distanceM : nil,
            samples: workout.samples,
            bpm: bpm,
            targetZone: workout.targetZone,
            zoneSet: profile.hrZoneSet,
            effort: effort)
    }
}
