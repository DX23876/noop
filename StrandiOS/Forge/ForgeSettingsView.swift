#if os(iOS)
import SwiftUI
import StrandDesign

/// Pushes inside the redesign's Settings sheet that are not a `MoreDestination`.
enum ForgeSettingsRoute: Hashable {
    /// The full former More index (every screen, with search). No longer listed in Settings, where the one
    /// search covers every screen; kept as a route for deep links.
    case allFeatures
    /// How Charge, Effort and Rest are scored: the guide and the model, as one page.
    case scoringGuide
    /// The grouped Strap page and the Devices and data sources page.
    case strap
    case devicesSources
}

/// The redesign's Settings (opened from the profile photo): profile and strap first, then the existing
/// Settings pages grouped as in the prototype. Every row opens a page that already exists
/// (`MoreDestination.settingsPage`), so this is a new index, not new settings.
struct ForgeSettingsView<DeviceRow: View>: View {
    @ViewBuilder var deviceRow: () -> DeviceRow

    @EnvironmentObject private var profile: ProfileStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                NavigationLink(value: MoreDestination.settingsPage(.profile)) {
                    HStack(spacing: 14) {
                        ProfileAvatarView(imageData: profile.avatarImageData, size: 64, fallbackTint: ForgeColor.accent)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Your profile").font(.system(.title2, weight: .bold)).foregroundStyle(ForgeColor.text)
                            Text("Body, heart rate and fitness").font(ForgeFont.caption).foregroundStyle(ForgeColor.secondary)
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 4)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                NavigationLink(value: ForgeRoute.search) {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                        Text("Search settings and screens")
                        Spacer()
                    }
                    .font(.system(.body))
                    .foregroundStyle(ForgeColor.secondary)
                    .padding(.horizontal, 12)
                    .frame(minHeight: 44)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(ForgeColor.fill))
                }
                .buttonStyle(.plain)

                group("You", [.goals])
                section("Strap and devices") {
                    NavigationLink(value: ForgeSettingsRoute.strap) {
                        ForgeRow(systemImage: "antenna.radiowaves.left.and.right", tint: .green, title: String(localized: "Strap"),
                                 subtitle: String(localized: "Connection, recording, battery, double-tap, steps"), compact: true)
                    }
                    ForgeRowDivider()
                    NavigationLink(value: ForgeSettingsRoute.devicesSources) {
                        ForgeRow(systemImage: "arrow.triangle.branch", tint: .indigo, title: String(localized: "Devices and data sources"),
                                 subtitle: String(localized: "Apple Health, imports, other devices"), compact: true)
                    }
                }
                section("Alerts") {
                    NavigationLink(value: MoreDestination.settingsPage(.notifications)) {
                        ForgeRow(systemImage: "bell.badge.fill", tint: .red, title: String(localized: "Alerts and reminders"),
                                 subtitle: String(localized: "Lock Screen, wrist alerts and reminders"), compact: true)
                    }
                }
                group("App", [.appearance, .languageUnits, .todayTrends, .training, .coach, .siri])
                section("Data and help") {
                    pageRow(.dataBackup)
                    ForgeRowDivider()
                    pageRow(.calculations)
                    ForgeRowDivider()
                    NavigationLink(value: ForgeSettingsRoute.scoringGuide) {
                        ForgeRow(systemImage: "gauge.with.dots.needle.67percent", tint: .green,
                                 title: String(localized: "How NOOP scores"),
                                 subtitle: String(localized: "The three scores explained, and your own model"), compact: true)
                    }
                    ForgeRowDivider()
                    pageRow(.help)
                }
                section(nil) {
                    pageRow(.lab)
                    ForgeRowDivider()
                    pageRow(.about)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 32)
        }
        .background(ForgeColor.canvas.ignoresSafeArea())
        .navigationTitle(Text("Settings"))
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
    }

    private func group(_ title: LocalizedStringKey, _ pages: [SettingsPage]) -> some View {
        section(title) {
            ForEach(Array(pages.enumerated()), id: \.element) { index, page in
                if index > 0 { ForgeRowDivider() }
                pageRow(page)
            }
        }
    }

    private func pageRow(_ page: SettingsPage) -> some View {
        NavigationLink(value: MoreDestination.settingsPage(page)) {
            ForgeRow(systemImage: page.icon, tint: Self.tint(page),
                     title: String(localized: page.title), subtitle: String(localized: page.subtitle), compact: true)
        }
    }

    /// An iOS Settings section: a small uppercase header over a grouped card.
    private func section<Content: View>(_ title: LocalizedStringKey?, @ViewBuilder content: () -> Content) -> some View {
        let rows = content()
        return VStack(alignment: .leading, spacing: 6) {
            if let title {
                Text(title)
                    .font(.system(.footnote, weight: .semibold))
                    .textCase(.uppercase)
                    .foregroundStyle(ForgeColor.secondary)
                    .padding(.leading, 16)
                    .padding(.top, 8)
                    .accessibilityAddTraits(.isHeader)
            }
            ForgeGroup { rows }
                .buttonStyle(.plain)
        }
    }

    /// The prototype keeps the settings tiles to three system colours, so no area shouts louder than another.
    private static func tint(_ page: SettingsPage) -> Color {
        switch page {
        case .profile, .goals, .batteryRecording, .todayTrends, .calculations: return .green
        case .strapActions, .notifications, .siri, .help, .training: return .orange
        case .coach, .strap, .appearance, .languageUnits, .dataBackup, .lab, .about: return .indigo
        }
    }
}
#endif
