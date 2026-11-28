import Foundation
@preconcurrency import UserNotifications
import StrandAnalytics

/// The morning advice as one notification (Training Load plan, phase 2, Q16 and Q25): only when the wearer
/// switched it on, once a day, as soon as last night is scored, and never while the coach's morning brief is
/// on, which opens with the same advice. Default off, like every notification in the project.
@MainActor
enum MorningAdviceNotifier {
    static let identifier = "noop.morningAdvice"

    /// Posts today's advice when it is ready and has not gone out today. The text is the one Today shows.
    static func postIfDue(_ guidance: TrainingGuidanceReader.Snapshot, defaults: UserDefaults = .standard) {
        guard defaults.bool(forKey: TrainingGuidancePrefs.morningAdviceKey), !CoachBriefScheduler.isEnabled,
              guidance.advice.state == .ready,
              defaults.string(forKey: TrainingGuidancePrefs.morningAdviceDayKey) != guidance.today else { return }
        let hour = Calendar.current.component(.hour, from: Date())
        guard hour >= 5, hour < 12 else { return }
        defaults.set(guidance.today, forKey: TrainingGuidancePrefs.morningAdviceDayKey)
        let content = UNMutableNotificationContent()
        content.title = TrainingGuidanceText.title(guidance.advice.stance)
        content.body = TrainingGuidanceText.reason(guidance.advice)
        content.sound = nil
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: identifier, content: content,
                                                                     trigger: nil))
    }
}
