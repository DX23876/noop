import Foundation

/// The decision behind the Training Load alert: one notification when a lane's last seven days move into
/// "well above your usual", and not again until that lane has left the band. A week that stays high is one
/// alert, not seven. Pure, so the iPhone's notifier and the Android worker decide the same way; what to say
/// and how to post it stay with each platform.
public enum TrainingLoadAlert {
    /// Whether to post for a lane, and the lane's new episode state. An episode opens when the band reaches
    /// "well above" and closes as soon as it reads anything else, including no band at all. The episode is
    /// tracked while the alert is off, so turning it on during a high week does not post for a week already
    /// under way.
    public static func decide(enabled: Bool, band: RelativeLoadBand?, episodeOpen: Bool) -> (notify: Bool, episodeOpen: Bool) {
        guard band == .muchHigher else { return (false, false) }
        return (enabled && !episodeOpen, true)
    }
}
