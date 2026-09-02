import Foundation

/// Which four metrics the Trends dashboard's metric strip shows, and where they are configured.
///
/// Deliberately DIFFERENT from `DashboardCardPrefs` ("Your cards"): that feature has a visible
/// "CUSTOMISE" link right in its section header. The Trends dashboard must look like a finished, static
/// screen with no edit affordance anywhere on it — so these four choices live ONLY in
/// Settings → Dashboard, as four plain pickers, never as a sheet reachable from the dashboard itself.
enum TrendsMetricSlotsPrefs {
    static let slot1Key = "trendsDashboard.slot1"
    static let slot2Key = "trendsDashboard.slot2"
    static let slot3Key = "trendsDashboard.slot3"
    static let slot4Key = "trendsDashboard.slot4"

    /// HRV / Resting HR / Steps / Blood oxygen — the reference screenshot's own four slots.
    static let defaultSlots: [DashboardCard] = [.hrv, .restingHr, .steps, .bloodOxygen]
}
