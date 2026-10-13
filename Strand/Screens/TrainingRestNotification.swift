import Foundation
import StrandTraining
import UserNotifications

/// The notification that announces the end of a strength rest or timed set: scheduling it, withdrawing it,
/// and how it shows while NOOP is open.
enum TrainingRestNotification {
    static let identifierPrefix = "training-rest-"

    private static func id(_ workoutId: UUID) -> String { identifierPrefix + workoutId.uuidString }

    static func schedule(identifier workoutId: UUID, at date: Date,
                         kind: WorkoutTimerKind, sound: Bool) {
        let center = UNUserNotificationCenter.current()
        Task {
            let settings = await center.notificationSettings()
            let allowed: Bool
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral: allowed = true
            case .notDetermined: allowed = (try? await center.requestAuthorization(options: [.alert, .sound])) == true
            default: allowed = false
            }
            guard allowed else { return }
            center.removePendingNotificationRequests(withIdentifiers: [id(workoutId)])
            let content = UNMutableNotificationContent()
            content.title = String(localized: kind == .timedSet ? "Set complete" : "Rest complete")
            content.body = String(localized: kind == .timedSet ? "Your timed set is ready to finish." : "Your next set is ready.")
            if sound { content.sound = .default }
            let seconds = max(1, date.timeIntervalSinceNow)
            try? await center.add(UNNotificationRequest(identifier: id(workoutId), content: content,
                trigger: UNTimeIntervalNotificationTrigger(timeInterval: seconds, repeats: false)))
        }
    }

    static func cancel(for workoutId: UUID) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [id(workoutId)])
    }

    /// How the notification shows while NOOP is in the foreground; nil for any other notification.
    ///
    /// With the workout logger on screen the banner is dropped: the logger already shows the countdown and
    /// vibrates when it ends, so a banner would only cover the timer it announces. The sound stays, since a
    /// phone lying on the bench is heard rather than read; with "Timer sound" off the notification carries
    /// none. With the logger minimized the banner is the only sign that the rest is over, so it shows.
    static func foregroundOptions(identifier: String, loggerOnScreen: Bool) -> UNNotificationPresentationOptions? {
        guard identifier.hasPrefix(identifierPrefix) else { return nil }
        return loggerOnScreen ? [.sound] : [.banner, .sound, .list]
    }

    /// Whether the strength logger is on screen. Written by `NativeWorkoutLoggerView` as it appears and
    /// disappears, read by `NotificationPresenter`, which iOS may call off the main thread.
    static var loggerOnScreen: Bool {
        get { loggerOnScreenLock.withLock { loggerOnScreenValue } }
        set { loggerOnScreenLock.withLock { loggerOnScreenValue = newValue } }
    }

    private static let loggerOnScreenLock = NSLock()
    nonisolated(unsafe) private static var loggerOnScreenValue = false
}
