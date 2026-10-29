import Foundation

/// The master availability switch for the AI Coach.
///
/// This is deliberately separate from `CoachEntryPrefs`: those preferences only arrange entry points on
/// Today, whereas this switch turns the Coach feature itself on or off. A new installation starts off —
/// until a person has deliberately connected a provider and chosen to use the feature, the app should
/// neither advertise a dead chat button nor generate coach work in the background. Turning it off hides
/// all Coach entry points but keeps the locally stored chats, preferences and data intact for a later
/// re-enable.
enum CoachFeaturePrefs {
    static let enabledKey = "coach.featureEnabled"

    /// Absent key means a fresh install, where the Coach is intentionally inactive by default.
    static var isEnabled: Bool { isEnabled(defaults: .standard) }

    /// Dependency-injected form keeps the fresh-install default testable without touching a person's
    /// real settings.
    static func isEnabled(defaults: UserDefaults) -> Bool {
        defaults.object(forKey: enabledKey) == nil
            ? false
            : defaults.bool(forKey: enabledKey)
    }
}
