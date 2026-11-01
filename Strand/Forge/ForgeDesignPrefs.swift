import Foundation
import StrandDesign

/// The "New design (preview)" switch (2026-11 redesign). Off by default: the shipped iPhone shell stays
/// the default until the owner decides otherwise. Read by the iOS shell to swap its tab roots and by
/// Settings › Lab for the toggle. A DEBUG launch argument turns it on for simulator checks without
/// touching the stored value.
///
/// Analysis migration required: no. This only selects which user interface is shown.
enum ForgeDesignPrefs {
    static let previewKey = "noop.forgeDesign.preview"
    static let defaultPreview = false

    /// The day-cycle sky is ON by default in the shipped design. The new design starts plain, so its readers
    /// default the SAME key to off: a person who never touched the switch sees the plain canvas, a person
    /// who turned the sky on keeps it.
    static let skyDefaultInNewDesign = false

    /// `--new-design` in a DEBUG build turns the design on for simulator checks without writing the switch.
    static var launchOverride: Bool {
        #if DEBUG
        return CommandLine.arguments.contains("--new-design")
        #else
        return false
        #endif
    }

    /// True when the new design should be shown: the stored switch, or the DEBUG launch override.
    static func isEnabled(_ defaults: UserDefaults = .standard) -> Bool {
        launchOverride || (defaults.object(forKey: previewKey) as? Bool ?? defaultPreview)
    }

    /// Mirror the switch into the shared app group, where the watch and the Live Activity read it (they
    /// cannot see the app's own defaults). Called at launch and whenever the switch changes.
    static func mirrorToAppGroup(_ defaults: UserDefaults = .standard) {
        UserDefaults(suiteName: WatchScoreSnapshot.appGroupId)?
            .set(isEnabled(defaults), forKey: WatchScoreSnapshot.forgeDesignKey)
    }
}
