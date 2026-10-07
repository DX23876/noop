import Foundation
import UserNotifications

/// Surfaces the illness early-warning as a macOS user notification when the banner transitions
/// from clear to raised — today it is silent unless the window is open (the menu-bar extra keeps
/// NOOP alive). Rate-limited to once per local calendar day; the in-app banner stays the live
/// surface. On-device only; the summary is APPROXIMATE — informational, not a diagnosis.
enum IllnessNotifier {
    private static let lastDayKey = "behavior.illnessLastNotifiedDay"
    /// Whether the last evaluation was raised. Persisted because the caller's previous state lives in
    /// memory and starts clear on every launch, so a cold start turned a still-raised alert into a fresh
    /// clear-to-raised edge and the day gate let it notify again (upstream #2586, fixed there on Android
    /// only in d1bee8bd7). Global, not per device: the signal describes the wearer.
    static let wasRaisedKey = "behavior.illnessWasRaised"

    /// Notify only on a genuine clear-to-raised transition, at most once a day. Pure, so the edge is
    /// testable without UserDefaults. Twin of Android `IllnessAlertPolicy.shouldNotify`.
    static func shouldNotify(raised: Bool, previouslyRaised: Bool,
                             lastNotifiedDay: String?, today: String) -> Bool {
        raised && !previouslyRaised && lastNotifiedDay != today
    }

    /// Report every evaluation, raised or clear, and post on the persisted edge. Recording the cleared
    /// evaluations is what lets a later genuine transition be recognised. The flag is written only when
    /// it changes, since this runs on every days republish.
    static func report(raised: Bool, message: String) {
        let defaults = UserDefaults.standard
        let wasRaised = defaults.bool(forKey: wasRaisedKey)
        let notify = shouldNotify(raised: raised, previouslyRaised: wasRaised,
                                  lastNotifiedDay: defaults.string(forKey: lastDayKey), today: dayKey(Date()))
        if wasRaised != raised { defaults.set(raised, forKey: wasRaisedKey) }
        guard notify else { return }
        post(message)
    }

    /// Ask up front (called when the user enables the watch) so the system dialog appears at a
    /// predictable moment, not on the first 3 a.m. transition.
    static func requestAuthorization() {
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Post the early-warning, at most once per local calendar day.
    static func post(_ message: String) {
        let day = dayKey(Date())
        let d = UserDefaults.standard
        guard d.string(forKey: lastDayKey) != day else { return }
        // Mark the day up front so the once-per-day limit holds even if the user declined
        // notifications or delivery is deferred — the in-app banner stays the live surface either
        // way, and we never re-prompt or retry on every transition.
        d.set(day, forKey: lastDayKey)
        AlertInbox.post(.illness,
                        title: String(localized: "Early warning: take it easy"),
                        message: message)
        let center = UNUserNotificationCenter.current()
        // Authorization is requested once via requestAuthorization() when the watch is enabled;
        // here we only check status (no second system prompt).
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized else { return }
            let content = UNMutableNotificationContent()
            content.title = String(localized: "Early warning: take it easy")
            content.subtitle = String(localized: "On-device estimate (approximate), not a diagnosis.")
            content.body = message
            content.sound = .default
            center.add(UNNotificationRequest(identifier: "illness-watch",
                                             content: content, trigger: nil))
        }
    }

    private static func dayKey(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }
}
