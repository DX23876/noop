#if os(iOS)
import SwiftUI
import StrandDesign

// The redesign's grouped Settings pages (navigation proposal, 2026-11): one entry where there used to be
// several. Each row opens the page that already holds those controls, so no setting moves or disappears;
// only the index gets shorter.

/// Strap: connection, steps and heart-rate sharing; recording and battery; double-tap and buzz. Before,
/// these were three top-level Settings rows (Strap, Battery & Recording, Strap Actions).
struct ForgeStrapSettingsView<DeviceRow: View>: View {
    @ViewBuilder var deviceRow: () -> DeviceRow

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                deviceRow()
                ForgeGroup {
                    row(.strap, "antenna.radiowaves.left.and.right", .green,
                        String(localized: "Connection, steps and sharing"), String(localized: "Name, reconnecting, step estimate, heart-rate sharing"))
                    ForgeRowDivider()
                    row(.batteryRecording, "battery.75percent", .green,
                        String(localized: "Recording and battery"), String(localized: "Continuous HRV and power saving"))
                    ForgeRowDivider()
                    row(.strapActions, "hand.tap.fill", .orange,
                        String(localized: "Double-tap and buzz"), String(localized: "What a double-tap does, vibration and heart-rate alerts"))
                }
                NavigationLink(value: MoreDestination.devices) {
                    ForgeRow(systemImage: "sensor.tag.radiowaves.forward", tint: .indigo, title: String(localized: "Devices"),
                             subtitle: String(localized: "Pair, find or restart the strap, other devices"), compact: true)
                        .forgeCard(radius: 22, padding: 0)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 32)
        }
        .background(ForgeColor.canvas.ignoresSafeArea())
        .navigationTitle(Text("Strap"))
        .navigationBarTitleDisplayMode(.large)
    }

    private func row(_ page: SettingsPage, _ image: String, _ tint: Color, _ title: String, _ subtitle: String) -> some View {
        NavigationLink(value: MoreDestination.settingsPage(page)) {
            ForgeRow(systemImage: image, tint: tint, title: title, subtitle: subtitle, compact: true)
        }
        .buttonStyle(.plain)
    }
}

/// Devices and data sources: everything that feeds NOOP, and which source each of today's values uses
/// (the former "Your Data, Fused").
struct ForgeDevicesSourcesView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ForgeGroup {
                    link(.devices, "sensor.tag.radiowaves.forward", .indigo, String(localized: "Devices"),
                         String(localized: "Strap, chest strap, ring, Apple Watch"))
                    ForgeRowDivider()
                    link(.dataSources, "arrow.triangle.branch", .indigo, String(localized: "Data sources"),
                         String(localized: "Imports, exports and connected apps"))
                    ForgeRowDivider()
                    link(.appleHealth, "heart.text.square.fill", .red, "Apple Health", String(localized: "Sync, history and permissions"))
                    ForgeRowDivider()
                    link(.miBand, "figure.walk.motion", .blue, "Mi Band", String(localized: "Imported history"))
                }
                ForgeGroup {
                    link(.fusedRecord, "square.stack.3d.up.fill", .purple, String(localized: "Values by source"),
                         String(localized: "Which device each of today's values comes from"))
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 32)
        }
        .background(ForgeColor.canvas.ignoresSafeArea())
        .navigationTitle(Text("Devices and data sources"))
        // Inline: the German title ("Geräte und Datenquellen") does not fit as a large title.
        .navigationBarTitleDisplayMode(.inline)
    }

    private func link(_ destination: MoreDestination, _ image: String, _ tint: Color, _ title: String, _ subtitle: String) -> some View {
        NavigationLink(value: destination) {
            ForgeRow(systemImage: image, tint: tint, title: title, subtitle: subtitle, compact: true)
        }
        .buttonStyle(.plain)
    }
}

/// How NOOP scores: the guide in words and the model working on this iPhone, as two tabs of one page.
/// Before, the guide was "How scores work" in Settings and the model "How Scoring Works" in More.
struct ForgeHowScoresView: View {
    let onClose: () -> Void
    @State private var part = 0

    var body: some View {
        VStack(spacing: 0) {
            Picker("Part", selection: $part) {
                Text("Explained").tag(0)
                Text("Your model").tag(1)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            if part == 0 {
                ScoringGuideView(onClose: onClose)
            } else {
                IntelligenceView()
            }
        }
        .background(ForgeColor.canvas.ignoresSafeArea())
        .navigationTitle(Text("How NOOP scores"))
        .navigationBarTitleDisplayMode(.inline)
    }
}
#endif
