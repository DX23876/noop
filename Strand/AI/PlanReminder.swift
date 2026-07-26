import Foundation
import UserNotifications

/// A local reminder for a committed, timed session — "A plan with a time is a plan you keep" made real
/// instead of just a line of copy. Opt-in, on-device only, no AI call: scheduling is driven entirely by
/// `CoachPlanStore` whenever a commitment's time changes, exactly the same `UNCalendarNotificationTrigger`
/// mechanism as `CoachCheckIn`/`WindDownNudge` — but ONE-SHOT per session (`repeats: false`) and keyed by
/// the proposal's own id, since each session fires at most once, unlike the daily check-in.
@MainActor
enum PlanReminder {

    private enum K {
        static let enabled = "planReminder.enabled"
    }

    /// Off by default, like every automation in this app.
    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: K.enabled) }

    enum EnableOutcome { case scheduled, denied, off }

    /// Turn the reminder on/off. Enabling gates on notification authorization first (mirrors
    /// `CoachCheckIn.setEnabled`); turning it off cancels every pending plan reminder immediately rather
    /// than leaving them to fire silently for a feature the user just switched off.
    static func setEnabled(_ on: Bool, completion: (@MainActor (EnableOutcome) -> Void)? = nil) {
        guard on else {
            UserDefaults.standard.set(false, forKey: K.enabled)
            cancelAll()
            completion?(.off)
            return
        }

        UNUserNotificationCenter.current().getNotificationSettings { settings in
            Task { @MainActor in
                switch settings.authorizationStatus {
                case .authorized, .provisional, .ephemeral:
                    UserDefaults.standard.set(true, forKey: K.enabled)
                    completion?(.scheduled)
                case .notDetermined:
                    UNUserNotificationCenter.current()
                        .requestAuthorization(options: [.alert, .sound]) { granted, _ in
                            Task { @MainActor in
                                if granted {
                                    UserDefaults.standard.set(true, forKey: K.enabled)
                                    completion?(.scheduled)
                                } else {
                                    UserDefaults.standard.set(false, forKey: K.enabled)
                                    completion?(.denied)
                                }
                            }
                        }
                default:
                    UserDefaults.standard.set(false, forKey: K.enabled)
                    completion?(.denied)
                }
            }
        }
    }

    private static func identifier(for id: UUID) -> String { "plan-reminder-\(id.uuidString)" }

    /// (Re)schedule the reminder for one session, from its CURRENT state. Always removes any existing
    /// request for this id first, so calling this after ANY change (time set, cleared, swapped, skipped,
    /// completed) is enough to keep the notification truthful — no separate cancel path to forget.
    /// Silently no-ops when the reminder is off, there's nothing to fire for, or the time already passed.
    static func schedule(for proposal: PlanProposal) {
        let id = identifier(for: proposal.id)
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [id])
        guard isEnabled, proposal.status.isCommitment,
              let time = proposal.time, time > Date() else { return }

        let content = UNMutableNotificationContent()
        content.title = String(localized: "Time for your planned session")
        content.body = proposal.summary()
        content.sound = .default

        let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: time)
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: id, content: content, trigger: trigger))
    }

    static func cancel(for id: UUID) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [identifier(for: id)])
    }

    private static func cancelAll() {
        UNUserNotificationCenter.current().getPendingNotificationRequests { requests in
            let ids = requests.map(\.identifier).filter { $0.hasPrefix("plan-reminder-") }
            guard !ids.isEmpty else { return }
            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ids)
        }
    }
}
