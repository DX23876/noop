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
                SettingsHubGroup(title: "Personal", pages: SettingsHubLayout.personal)
                SettingsHubGroup(title: "Training & Devices", pages: SettingsHubLayout.trainingAndDevices)
                SettingsHubGroup(title: "Health & Data", pages: SettingsHubLayout.healthAndData)
                SettingsHubGroup(title: "Support", pages: SettingsHubLayout.support)
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
