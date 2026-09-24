import Foundation
import UserNotifications
import StrandAnalytics

// MARK: - Training load alert (P6)
//
// Opt-in, default OFF. Posts once when a lane's last seven days move into "well above your usual" — the
// band the Training Load screen and Today already show — and not again until that lane has left the band.
// A week that stays high is one alert, not seven. It describes load only: whether the load is working or
// is too much is what the Training Load statement decides from performance and recovery.
enum TrainingLoadNotifier {
    private static func activeKey(_ lane: TrainingLaneKind) -> String { "behavior.trainingLoadAlert.\(lane.rawValue).active" }

    /// Pure, testable policy.
    enum Policy {
        /// Whether to post for a lane, and the lane's new episode state. An episode opens when the band
        /// reaches "well above" and closes as soon as it reads anything else, including no band at all.
        static func decide(enabled: Bool, band: RelativeLoadBand?, episodeOpen: Bool) -> (notify: Bool, episodeOpen: Bool) {
            guard band == .muchHigher else { return (false, false) }
            return (enabled && !episodeOpen, true)
        }

        static func copy(_ lane: TrainingLaneKind) -> (title: String, body: String) {
            switch lane {
            case .strength:
                return (String(localized: "Strength load well above your usual"),
                        String(localized: "Your last seven days of lifting are well above your usual. This describes the load only — Training Load shows what it rests on."))
            case .cardio:
                return (String(localized: "Cardio load well above your usual"),
                        String(localized: "Your last seven days of cardio are well above your usual. This describes the load only — Training Load shows what it rests on."))
            }
        }
    }

    static func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Runs the policy for each lane of a freshly read context. The episode state is tracked even while the
    /// alert is off, so turning it on during a high week does not post for a week already under way.
    static func onLoadContext(_ context: ReadinessLoadContext?, enabled: Bool) {
        guard let context else { return }
        let defaults = UserDefaults.standard
        for lane in context.lanes {
            let key = activeKey(lane.kind)
            let decision = Policy.decide(enabled: enabled, band: lane.band, episodeOpen: defaults.bool(forKey: key))
            defaults.set(decision.episodeOpen, forKey: key)
            guard decision.notify else { continue }
            let copy = Policy.copy(lane.kind)
            let center = UNUserNotificationCenter.current()
            center.getNotificationSettings { settings in
                guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
                else { return }
                let content = UNMutableNotificationContent()
                content.title = copy.title
                content.body = copy.body
                content.sound = .default
                center.add(UNNotificationRequest(identifier: "training-load-\(lane.kind.rawValue)",
                                                 content: content, trigger: nil))
            }
        }
    }
}
