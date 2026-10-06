import Foundation

/// Remembered, default-off feedback choices. All ranges are user targets, not medical thresholds.
enum WorkoutFeedbackPreferences {
    static let speakerKey = "workout.voice.speaker"
    static let distanceIntervalKey = "workout.voice.distanceInterval"
    static let timeIntervalKey = "workout.voice.timeInterval"
    static let heartRateAlertKey = "workout.alert.heartRate"
    static let motionAlertKey = "workout.alert.motion"
    static let fastPaceKey = "workout.alert.fastPace"
    static let slowPaceKey = "workout.alert.slowPace"
    static let lowSpeedKey = "workout.alert.lowSpeed"
    static let highSpeedKey = "workout.alert.highSpeed"
    static let cadenceAlertKey = "workout.alert.cadence"
    static let lowCadenceKey = "workout.alert.lowCadence"
    static let highCadenceKey = "workout.alert.highCadence"
    static let autoPauseKey = "workout.autoPause"
    static let notificationsKey = "workout.alert.notifications"

    static func distanceInterval(_ defaults: UserDefaults = .standard) -> Double {
        let value = defaults.object(forKey: distanceIntervalKey) as? Double ?? 1
        return [0, 0.5, 1, 2].contains(value) ? value : 1
    }

    static func timeInterval(_ defaults: UserDefaults = .standard) -> Double {
        let value = defaults.object(forKey: timeIntervalKey) as? Double ?? 600
        return [300, 600, 900].contains(value) ? value : 600
    }

    static func supportsAutoPause(sport: String, gps: Bool) -> Bool {
        gps && ["Running", "Cycling", "Mountain biking"].contains(sport)
    }

    static func cadenceKind(sport: String) -> String? {
        if ["Running", "Treadmill run", "Walking", "Treadmill walk"].contains(sport) { return "running" }
        if ["Cycling", "Mountain biking", "Indoor cycle", "Spinning"].contains(sport) { return "cycling" }
        return nil
    }

    /// Deferred until independent sensor pairing and simultaneous strap use are supported and tested.
    /// Keep saved choices and the range engine for a later implementation, but never activate them now.
    static func cadenceWarningRange(_ defaults: UserDefaults = .standard) -> ClosedRange<Double>? {
        nil
    }

    static func range(low key: String, high other: String, defaults: UserDefaults = .standard,
                      fallback: ClosedRange<Double>, bounds: ClosedRange<Double>) -> ClosedRange<Double>? {
        let low = defaults.object(forKey: key) as? Double ?? fallback.lowerBound
        let high = defaults.object(forKey: other) as? Double ?? fallback.upperBound
        guard low.isFinite, high.isFinite, bounds.contains(low), bounds.contains(high), low <= high else { return nil }
        return low...high
    }
}
