#if os(iOS)
import SwiftUI
import StrandDesign

/// Pushes inside the redesign's Settings sheet that are not a `MoreDestination`.
enum ForgeSettingsRoute: Hashable {
    /// The full former More index (every screen, with search), so nothing is out of reach.
    case allFeatures
    /// How Charge, Effort and Rest are scored.
    case scoringGuide
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
                        ProfileAvatarView(imageData: profile.avatarImageData, size: 52, fallbackTint: ForgeColor.accent)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Your profile").font(.system(size: 19, weight: .semibold)).foregroundStyle(ForgeColor.text)
                            Text("Body, heart rate and fitness").font(ForgeFont.caption).foregroundStyle(ForgeColor.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(ForgeColor.tertiary)
                    }
                    .forgeCard(radius: 22, padding: 14)
                }
                .buttonStyle(.plain)

                deviceRow()

                group("Goals and coach", [.goals, .coach])
                group("Strap", [.strap, .batteryRecording, .strapActions])
                group("App", [.todayTrends, .notifications, .appearance, .languageUnits, .siri, .training])
                section("Data") {
                    pageRow(.calculations)
                    ForgeRowDivider()
                    pageRow(.dataBackup)
                    ForgeRowDivider()
                    NavigationLink(value: MoreDestination.dataSources) {
                        ForgeRow(systemImage: "arrow.triangle.merge", tint: .indigo,
                                 title: String(localized: "Data sources"),
                                 subtitle: String(localized: "Apple Health, imports and other devices"), compact: true)
                    }
                }
                section("Help") {
                    NavigationLink(value: ForgeSettingsRoute.scoringGuide) {
                        ForgeRow(systemImage: "gauge.with.dots.needle.67percent", tint: .green,
                                 title: String(localized: "How scores work"),
                                 subtitle: String(localized: "Charge, Effort and Rest explained"), compact: true)
                    }
                    ForgeRowDivider()
                    pageRow(.help)
                    ForgeRowDivider()
                    pageRow(.lab)
                    ForgeRowDivider()
                    pageRow(.about)
                }

                section("Everything") {
                    NavigationLink(value: ForgeSettingsRoute.allFeatures) {
                        ForgeRow(systemImage: "square.grid.3x3.fill", tint: ForgeColor.accent,
                                 title: String(localized: "All features"),
                                 subtitle: String(localized: "Every screen and setting, with search"), compact: true)
                    }
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
    private func section<Content: View>(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        let rows = content()
        return VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .textCase(.uppercase)
                .foregroundStyle(ForgeColor.secondary)
                .padding(.leading, 16)
                .padding(.top, 8)
                .accessibilityAddTraits(.isHeader)
            ForgeGroup { rows }
                .buttonStyle(.plain)
        }
    }

    /// One system colour per settings area, like the iOS Settings app.
    private static func tint(_ page: SettingsPage) -> Color {
        switch page {
        case .profile, .goals: return .orange
        case .coach: return .purple
        case .strap: return .blue
        case .batteryRecording: return .green
        case .strapActions: return .orange
        case .training: return .red
        case .todayTrends: return .teal
        case .notifications: return .red
        case .appearance: return .indigo
        case .languageUnits: return .blue
        case .siri: return .pink
        case .calculations: return .green
        case .dataBackup: return .gray
        case .help: return .orange
        case .lab: return .purple
        case .about: return .gray
        }
    }
}
#endif
