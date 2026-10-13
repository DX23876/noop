import Foundation

/// Destinations below a Settings page. All rows use value-driven navigation so deep links and the
/// navigation path have one stable representation.
enum SettingsSubpage: Hashable {
    case bodyMeasurements
    case exerciseMedia
    case equipment
    case testCentre
    case dashboard(String)
    case backupSync
    case appleWatchData
    case storage
    /// The Live Activity switches alone, reached from the Training page (iOS only).
    case liveNotifications
}
