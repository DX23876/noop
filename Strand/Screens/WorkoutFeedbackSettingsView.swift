import SwiftUI
import StrandDesign

/// The same remembered choices are editable before starting and during a live workout.
struct WorkoutFeedbackSettingsView: View {
    let sport: String
    let gpsEnabled: Bool
    let hasTargetZone: Bool
    @Environment(\.dismiss) private var dismiss
    @AppStorage(WorkoutVoiceCoach.enabledKey) private var voice = false
    @AppStorage(WorkoutFeedbackPreferences.speakerKey) private var speaker = false
    @AppStorage(WorkoutFeedbackPreferences.distanceIntervalKey) private var distance = 1.0
    @AppStorage(WorkoutFeedbackPreferences.timeIntervalKey) private var time = 600.0
    @AppStorage(WorkoutFeedbackPreferences.heartRateAlertKey) private var heartRate = false
    @AppStorage(WorkoutFeedbackPreferences.motionAlertKey) private var motion = false
    @AppStorage(WorkoutFeedbackPreferences.fastPaceKey) private var fastPace = 300.0
    @AppStorage(WorkoutFeedbackPreferences.slowPaceKey) private var slowPace = 420.0
    @AppStorage(WorkoutFeedbackPreferences.lowSpeedKey) private var lowSpeed = 15.0
    @AppStorage(WorkoutFeedbackPreferences.highSpeedKey) private var highSpeed = 30.0
    @AppStorage(WorkoutFeedbackPreferences.autoPauseKey) private var autoPause = false
    @AppStorage(WorkoutFeedbackPreferences.notificationsKey) private var notifications = false
    @State private var notificationError: String?
    @AppStorage(UnitPrefs.systemKey) private var units = UnitSystem.metric.rawValue
    @AppStorage(UnitPrefs.distanceSystemKey) private var distanceUnits = ""

    private var imperial: Bool {
        UnitPrefs.resolveDistance(system: UnitSystem(rawValue: units) ?? .metric, override: distanceUnits) == .imperial
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Voice feedback", isOn: $voice)
                    if voice {
                        if gpsEnabled {
                            Picker("Distance announcements", selection: $distance) {
                                Text("Time only").tag(0.0)
                                ForEach([0.5, 1.0, 2.0], id: \.self) { value in
                                    Text(UnitFormatter.distanceFromMeters(value * (imperial ? 1609.344 : 1000), system: imperial ? .imperial : .metric)).tag(value)
                                }
                            }
                        }
                        Picker("Time announcements", selection: $time) {
                            ForEach([300.0, 600.0, 900.0], id: \.self) { value in
                                Text(WorkoutAnnouncementText.duration(Int(value))).tag(value)
                            }
                        }
                        Toggle("Allow speaker", isOn: $speaker)
                    }
                } header: {
                    Text("Voice feedback")
                } footer: {
                    Text("Offline, in the app language. Headphones by default. If GPS is missing, only time and measured heart rate are announced.")
                }
                Section {
                    Toggle("Target-zone warnings", isOn: $heartRate).disabled(!hasTargetZone)
                    Toggle("Warnings while minimized", isOn: $notifications)
                        .onChangeCompat(of: notifications) { value in
                            if value { Task { await authorizeNotifications() } }
                        }
                    if let notificationError { Text(notificationError).foregroundStyle(StrandPalette.statusWarningForeground) }
                    if !hasTargetZone { Text("Choose a target zone before starting to enable zone warnings.").foregroundStyle(.secondary) }
                    if gpsEnabled {
                        Toggle("Pace or speed warnings", isOn: $motion)
                        if motion {
                            if WorkoutCatalog.usesSpeedReadout(for: sport) {
                                Stepper(value: $lowSpeed, in: 1...100, step: 1) {
                                    Text("Minimum speed: \(UnitFormatter.speedFromKilometersPerHour(lowSpeed, system: imperial ? .imperial : .metric) ?? "")")
                                }
                                Stepper(value: $highSpeed, in: 1...100, step: 1) {
                                    Text("Maximum speed: \(UnitFormatter.speedFromKilometersPerHour(highSpeed, system: imperial ? .imperial : .metric) ?? "")")
                                }
                            } else {
                                Stepper(value: $fastPace, in: 120...1800, step: 30) {
                                    Text("Fastest pace: \(ActiveWorkoutClock.clock(Int(fastPace))) /\(imperial ? "mi" : "km")")
                                }
                                Stepper(value: $slowPace, in: 120...1800, step: 30) {
                                    Text("Slowest pace: \(ActiveWorkoutClock.clock(Int(slowPace))) /\(imperial ? "mi" : "km")")
                                }
                            }
                        }
                    }
                    if invalidRange { Text("The lower limit must not exceed the upper limit. This warning is inactive until corrected.").foregroundStyle(StrandPalette.statusWarningForeground) }
                } header: {
                    Text("Training warnings")
                } footer: {
                    Text("Only after ten seconds outside your range, at most once a minute. No warnings while paused or without fresh measurements.")
                }
                if WorkoutFeedbackPreferences.supportsAutoPause(sport: sport, gps: gpsEnabled) {
                    Section {
                        Toggle("Auto-pause", isOn: $autoPause)
                    } footer: {
                        Text("GPS running and cycling only. Pauses after five seconds stopped, resumes after three seconds moving. A manual pause stays paused.")
                    }
                }
            }
            .tint(StrandPalette.accent)
            .navigationTitle("Workout settings")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task { sanitizeValues() }
        }
    }

    private var invalidRange: Bool {
        motion && (WorkoutCatalog.usesSpeedReadout(for: sport) ? lowSpeed > highSpeed : fastPace > slowPace)
    }

    private func sanitizeValues() {
        distance = WorkoutFeedbackPreferences.distanceInterval()
        time = WorkoutFeedbackPreferences.timeInterval()
        if !fastPace.isFinite || !(120...1800).contains(fastPace) { fastPace = 300 }
        if !slowPace.isFinite || !(120...1800).contains(slowPace) { slowPace = 420 }
        if !lowSpeed.isFinite || !(1...100).contains(lowSpeed) { lowSpeed = 15 }
        if !highSpeed.isFinite || !(1...100).contains(highSpeed) { highSpeed = 30 }
    }

    private func authorizeNotifications() async {
        do {
            let granted = try await WorkoutWarningNotifier.requestAuthorization()
            if !granted {
                notifications = false
                notificationError = String(localized: "Notifications unavailable. Check system settings.")
            } else { notificationError = nil }
        } catch {
            notifications = false
            notificationError = String(localized: "Notifications unavailable. Check system settings.")
        }
    }
}
