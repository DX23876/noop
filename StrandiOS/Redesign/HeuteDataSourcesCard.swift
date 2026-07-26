import SwiftUI
import StrandDesign

// MARK: - Data-sources card (parity with LiquidTodayView.dataSourcesSection / TodayView.sourcesSection)
//
// The other two Today screens footer a "where the numbers came from" card (strap battery + sync status,
// tap → Data Sources). Heute had none — the on-device provenance was reachable only from Settings. This
// reproduces it in the redesign's OWN token set (`HeuteRedesignPalette`), NOT the private Liquid rows
// (`LiquidStrapBatteryRow`/`LiquidSyncStatusRow`), which are `StrandPalette`-styled — Heute has a fixed
// near-black palette and the CLAUDE.md design rule keeps the two from mixing. The underlying signals are
// the same `LiveState` the Liquid rows read, so the data is identical; only the chrome differs.

/// Strap battery + sync status, styled for Heute, linking into the full Data Sources screen. Shown only
/// on today (a navigated past day has no "live" strap state to honestly report).
struct HeuteDataSourcesCard: View {
    @EnvironmentObject private var live: LiveState

    var body: some View {
        NavigationLink(value: TabRoute.dataSources) {
            VStack(spacing: 12) {
                HStack {
                    Text("Data sources")
                        .font(.system(size: 11, weight: .bold))
                        .tracking(0.9)
                        .textCase(.uppercase)
                        .foregroundStyle(HeuteRedesignPalette.ink3)
                    Spacer()
                    HStack(spacing: 4) {
                        Text("View sources")
                            .font(.system(size: 12.5))
                            .foregroundStyle(HeuteRedesignPalette.ink3)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(HeuteRedesignPalette.ink3)
                    }
                }
                if let battery = batteryText {
                    row(String(localized: "Strap battery"), value: battery)
                }
                if let sync = syncText {
                    row(String(localized: "Strap history"), value: sync)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(HeuteRedesignPalette.tile, in: RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(HeuteRedesignPalette.line, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private func row(_ label: String, value: String) -> some View {
        HStack {
            Text(label).font(.system(size: 13.5)).foregroundStyle(HeuteRedesignPalette.ink2)
            Spacer()
            Text(value).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(HeuteRedesignPalette.ink)
        }
        .accessibilityElement(children: .combine)
    }

    /// "87%", plus a trailing "· Charging" — the same signal the Liquid/classic battery rows show; nil when
    /// the strap isn't connected or hasn't reported a level yet (→ the row simply doesn't render).
    private var batteryText: String? {
        guard live.connected, let pct = live.batteryPct else { return nil }
        let base = "\(Int(pct.rounded()))%"
        return live.charging == true ? "\(base) · \(String(localized: "Charging"))" : base
    }

    /// The sync state: an in-flight backfill, or the last-synced relative time. nil before the first sync
    /// (nothing honest to say yet).
    private var syncText: String? {
        if live.backfilling { return String(localized: "Syncing…") }
        if let ts = live.lastSyncedAt { return String(localized: "Synced \(relativeAgo(ts)) ago") }
        return nil
    }
}
