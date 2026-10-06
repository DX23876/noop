import Foundation
import StrandAnalytics

extension AppModel {
    /// The running workout as the voice coach reads it each second; nil once no workout is active.
    func workoutVoiceSnapshot(at now: Date) -> WorkoutVoiceCoach.Snapshot? {
        guard let workout = activeWorkout else { return nil }
        let freshBpm = workoutHeartRate(at: now)
        let cadence = live.sensorCadenceReceivedAt.flatMap {
            now.timeIntervalSince($0) >= 0 && now.timeIntervalSince($0) <= 5
                && live.sensorCadenceKind == WorkoutFeedbackPreferences.cadenceKind(sport: workout.sport)
                ? live.sensorCadence : nil
        }
        let scale = UnitPrefs.currentEffortScale()
        // Effort is spoken only once heart rate has produced one; "zero" would claim a measured rest.
        let effort = workout.samples.count >= 2
            ? UnitFormatter.effortDisplay(workout.liveStrain, scale: scale) : nil
        return WorkoutVoiceCoach.Snapshot(
            elapsedSeconds: Int(workout.elapsed(at: now)),
            distanceMeters: activeWorkoutUsesGPS && gpsRecorder.pointCount > 1 ? gpsRecorder.distanceM : nil,
            samples: workout.samples,
            bpm: freshBpm,
            targetZone: workout.targetZone,
            zoneSet: workoutZoneSet,
            effort: effort, now: now, isPaused: workout.isPaused, sport: workout.sport,
            currentSpeedMps: workoutCurrentSpeed(at: now), cadence: cadence,
            distanceFresh: workoutGPSIsFresh(at: now),
            completedSplit: workoutRecording.splits.last, splitLengthM: workoutRecording.splitLengthM,
            splitAverageBpm: WorkoutVoiceCoach.isEnabled ? workoutRecording.splits.last.flatMap { workoutRecording.averageBpm(in: $0) } : nil,
            coachingSuppressed: workoutRangeWarningsSuppressed)
    }
}
