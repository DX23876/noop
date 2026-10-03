import Foundation

// MARK: - Explore search, availability filter and collapsible categories (2026-10 redesign)
//
// Pure rules for `MetricExplorerView`. Availability comes only from the cheap `nonEmptyMetricIDs`
// probe the screen already runs; nothing here reads a series. Display-only.

/// `All` shows the whole catalog; `With Data` only measurements with at least one stored value.
enum MetricExplorerAvailability: String, CaseIterable, Identifiable {
    case all
    case withData

    var id: String { rawValue }

    var label: String {
        switch self {
        case .all: return String(localized: "All")
        case .withData: return String(localized: "With Data")
        }
    }
}

enum MetricExplorerFilter {
    /// Remembered `All` / `With Data` choice.
    static let availabilityKey = "explore.availabilityFilter"
    /// Comma-joined raw category identifiers the user collapsed. Unset means every category expanded.
    static let collapsedKey = "explore.collapsedCategories"

    static func availability(_ raw: String) -> MetricExplorerAvailability {
        MetricExplorerAvailability(rawValue: raw) ?? .all
    }

    static func decodeCollapsed(_ raw: String) -> Set<String> {
        Set(raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
    }

    /// Stable order (the catalog's), so the stored string does not churn.
    static func encodeCollapsed(_ categories: Set<String>, order: [String]) -> String {
        order.filter { categories.contains($0) }.joined(separator: ",")
    }

    static func normalised(_ query: String) -> String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whether one measurement (all its sources) matches the search text. Case- and diacritic-insensitive
    /// over the title, the key, every source label and the category's display name.
    static func matches(_ group: [MetricDescriptor], query: String, categoryName: String) -> Bool {
        let needle = normalised(query)
        guard !needle.isEmpty else { return true }
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        let haystacks = group.flatMap { [$0.title, $0.key, $0.sourceLabel] } + [categoryName]
        return haystacks.contains { $0.range(of: needle, options: options) != nil }
    }

    /// A measurement has data when ANY of its sources does. `nonEmptyIDs` is nil until the probe lands;
    /// until then `With Data` shows everything rather than an empty screen.
    static func hasData(_ group: [MetricDescriptor], nonEmptyIDs: Set<String>?) -> Bool {
        guard let nonEmptyIDs else { return true }
        return group.contains { nonEmptyIDs.contains($0.id) }
    }

    static func visibleGroups(_ groups: [[MetricDescriptor]], query: String, categoryName: String,
                              availability: MetricExplorerAvailability,
                              nonEmptyIDs: Set<String>?) -> [[MetricDescriptor]] {
        groups.filter { group in
            matches(group, query: query, categoryName: categoryName)
                && (availability == .all || hasData(group, nonEmptyIDs: nonEmptyIDs))
        }
    }

    /// A search expands every category it has results in without touching the stored states, so
    /// clearing the search restores exactly what the user had collapsed.
    static func isExpanded(category: String, collapsed: Set<String>, query: String) -> Bool {
        !normalised(query).isEmpty || !collapsed.contains(category)
    }
}
