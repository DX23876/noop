import Foundation
import StrandDesign

/// The "New design (preview)" switch (2026-11 redesign). **On by default since 2026-11-18**, when the
/// owner decided the new design ships to everyone; `flipOnce` carries over the installs that had it off.
/// The switch stays, so anyone can go back. Read by the iOS shell to swap its tab roots and by
/// Settings › Lab for the toggle. A DEBUG launch argument turns it on for simulator checks without
/// touching the stored value.
///
/// Analysis migration required: no. This only selects which user interface is shown.
enum ForgeDesignPrefs {
    /// How strongly the page's colour covers Today's picture behind the tiles, in percent. 0 turns it off.
    /// How solid Today's tiles and notes are over the day's picture, in percent.
    static let todaySurfaceKey = "forge.today.surfacePercent"
    static let todaySurfaceDefault = 75
    static let previewKey = "noop.forgeDesign.preview"
    static let defaultPreview = true

    /// Marks that `flipOnce` has run on this install. Its own key, not the switch: the switch cannot say
    /// whether an "off" was the old default or a decision, and the difference is the whole point.
    static let flippedKey = "noop.forgeDesign.flipped"

    /// Turn the new design on for everyone, exactly once per install (owner, 2026-11-18).
    ///
    /// `defaultPreview` alone would not do it. `isEnabled` reads "the stored value, else the default", so
    /// flipping the default moves only those who never touched the switch; whoever had deliberately turned
    /// the preview OFF would keep the old design and report on a screen nobody else is looking at. So the
    /// stored value is cleared once, which hands everyone back to the (now true) default.
    ///
    /// The marker is what keeps this from being a trap: without it the clear would run at every launch and
    /// nobody could ever leave the new design again. With it, an "off" set AFTER the flip is a decision and
    /// survives every later release.
    static func flipOnce(_ defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: flippedKey) else { return }
        defaults.removeObject(forKey: previewKey)
        defaults.set(true, forKey: flippedKey)
    }

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
