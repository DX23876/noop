import Foundation
import StrandDesign

/// The "New design (preview)" switch (2026-11 redesign). Off by default: the shipped iPhone shell stays
/// the default until the owner decides otherwise. Read by the iOS shell to swap its tab roots and by
/// Settings › Lab for the toggle. A DEBUG launch argument turns it on for simulator checks without
/// touching the stored value.
///
/// Analysis migration required: no. This only selects which user interface is shown.
enum ForgeDesignPrefs {
    /// How strongly the page's colour covers Today's picture behind the tiles, in percent. 0 turns it off.
    static let tileVeilKey = "forge.today.tileVeilPercent"
    static let tileVeilDefault = 20
    static let previewKey = "noop.forgeDesign.preview"
    static let defaultPreview = false

    /// The day-cycle sky follows the colour profile until the person sets it: on under Colorful, off under
    /// the calm ones. Choosing a profile also writes the switch, and a person's own choice stays after that.
    static var skyDefaultInNewDesign: Bool { NoopVisualStyle.forgeProfile == .colorful }

    /// The stored colour profile, read before the first frame.
    static func applyStoredProfile(_ defaults: UserDefaults = .standard) {
        NoopVisualStyle.forgeProfile = NoopVisualStyle.ForgeColorProfile.resolve(
            defaults.string(forKey: NoopVisualStyle.ForgeColorProfile.storageKey))
    }

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
        UserDefaults(suiteName: WatchScoreSnapshot.appGroupId)?
            .set(defaults.string(forKey: NoopVisualStyle.ForgeColorProfile.storageKey),
                 forKey: NoopVisualStyle.ForgeColorProfile.storageKey)
    }
}
