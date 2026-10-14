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
    /// Heart rate sharing owns the phone-side broadcaster, so it is a screen of its own: the phone
    /// shares only while that screen is open.
    case heartRateSharing
    case appleHealth
    case dataSources
    /// iOS only (the Shortcuts drop file is an iPhone sideload path).
    case shortcutsExport
    case noopLimitations
}
