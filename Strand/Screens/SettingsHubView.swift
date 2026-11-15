import SwiftUI
import StrandDesign

/// The iPhone Settings landing page: a short, searchable index instead of a wall of controls.
struct SettingsHubView: View {
    @Binding var query: String

    private var matches: [SettingsSearchEntry] {
        SettingsSearchCatalog.matching(query)
    }

    private var matchingPages: [SettingsPage] {
        SettingsPage.allCases.filter { page in
            matches.contains(where: { $0.page == page })
        }
    }

    private var isSearching: Bool {
        !SearchMatch.tokens(query).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.sectionSpacing) {
            NoopLiquidGlassSearchField(
                text: $query,
                prompt: String(localized: "Search settings"),
                accessibilityLabel: String(localized: "Search settings")
            )

            if isSearching {
                searchResults
            } else {
                // One card above the groups, without a heading of its own: the quickest reach in
                // Settings, and quiet enough that nobody who does not care ever notices it.
                NoopCard(padding: 0, cornerRadius: NoopMetrics.groupedRadius) {
                    ForEach(SettingsHubLayout.project) { page in
                        SettingsHubRow(page: page)
                    }
                    .clipShape(.rect(cornerRadius: NoopMetrics.groupedRadius))
                }
                SettingsHubGroup(title: "You", pages: SettingsHubLayout.you)
                SettingsHubGroup(title: "Strap & Devices", pages: SettingsHubLayout.strapAndDevices)
                SettingsHubGroup(title: "Training & Everyday", pages: SettingsHubLayout.trainingAndEveryday)
                SettingsHubGroup(title: "Display", pages: SettingsHubLayout.display)
                SettingsHubGroup(title: "Data", pages: SettingsHubLayout.data)
                SettingsHubGroup(title: "Help", pages: SettingsHubLayout.help)
            }
        }
    }

    @ViewBuilder
    private var searchResults: some View {
        if matchingPages.isEmpty {
            VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                Label("No settings found", systemImage: "magnifyingglass")
                    .font(StrandFont.headline)
                    .foregroundStyle(StrandPalette.textPrimary)
                Text("Try a shorter word or a section name.")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, NoopMetrics.space5)
            .accessibilityElement(children: .combine)
        } else {
            SettingsHubGroup(
                title: "Results",
                pages: matchingPages,
                captions: Dictionary(uniqueKeysWithValues: matchingPages.map { page in
                    let caption = matches
                        .filter { $0.page == page }
                        .map { String(localized: $0.title) }
                        .joined(separator: " · ")
                    return (page, caption)
                })
            )
        }
    }
}
