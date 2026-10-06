import SwiftUI
import StrandDesign
import StrandAnalytics

/// Live heart rate in its zone colour. With no reading yet it shows "—" and says so, instead of a zone it
/// has not measured.
struct LiveWorkoutHeartRateRow: View {
    let bpm: Int?
    let zone: Int
    let avgHr: Int
    let peakHr: Int

    private var caption: String {
        if bpm == nil {
            return String(localized: "No heart rate yet. Zones and Effort start with the first reading.")
        }
        if avgHr > 0 { return String(localized: "Avg \(avgHr) · Peak \(peakHr)") }
        return LiveHeartRateStyle.zoneTitle(zone)
    }

    private var tint: Color {
        guard bpm != nil else { return StrandPalette.textTertiary }
        return zone >= 1 ? StrandPalette.hrZoneColor(zone) : StrandPalette.metricRose
    }

    var body: some View {
        LiveWorkoutMetricRow(value: bpm.map(String.init) ?? "—",
                             unit: String(localized: "bpm"),
                             caption: caption,
                             symbol: "heart.fill",
                             tint: tint)
    }
}
