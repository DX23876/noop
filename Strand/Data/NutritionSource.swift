import Foundation
import WhoopStore

/// One HealthKit writer that supplied at least one nutrition quantity.
struct NutritionHealthSource: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let name: String
}

/// Daily totals from one HealthKit source. Values are already summed within that source and day.
struct NutritionHealthSourceDay: Equatable, Sendable {
    let day: String
    let source: NutritionHealthSource
    var calories: Double?
    var proteinG: Double?
    var carbsG: Double?
    var fatG: Double?

    var points: [MetricPoint] {
        [("calories_in", calories), ("protein_g", proteinG),
         ("carbs_g", carbsG), ("fat_g", fatG)].compactMap { key, value in
            value.map { MetricPoint(day: day, key: key, value: $0) }
        }
    }
}

struct NutritionHealthResolution: Equatable, Sendable {
    let days: [NutritionHealthSourceDay]
    let availableSources: [NutritionHealthSource]
    let unresolvedDays: [String]
}

/// Picks one nutrition writer per day. Nutrition quantities from two apps are never added: they are
/// commonly two copies of the same meal rather than independent measurements.
enum NutritionHealthResolver {
    static func resolve(_ rows: [NutritionHealthSourceDay], preferredSourceId: String?)
        -> NutritionHealthResolution {
        var uniqueSources: [String: NutritionHealthSource] = [:]
        for row in rows where uniqueSources[row.source.id] == nil {
            uniqueSources[row.source.id] = row.source
        }
        let sources = uniqueSources.values.sorted { lhs, rhs in
                lhs.name == rhs.name
                    ? lhs.id < rhs.id
                    : lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
        let byDay = Dictionary(grouping: rows, by: \.day)
        var chosen: [NutritionHealthSourceDay] = []
        var unresolved: [String] = []
        for day in byDay.keys.sorted() {
            let candidates = byDay[day] ?? []
            if let preferredSourceId,
               let preferred = candidates.first(where: { $0.source.id == preferredSourceId }) {
                chosen.append(preferred)
            } else if candidates.count == 1, let only = candidates.first {
                chosen.append(only)
            } else if !candidates.isEmpty {
                unresolved.append(day)
            }
        }
        return .init(days: chosen, availableSources: sources, unresolvedDays: unresolved)
    }
}

/// Small, local metadata that lets the shared Energy screen explain which Health writer won. The
/// readings themselves remain in SQLite; these preferences contain names and selection only.
enum NutritionSourcePreferences {
    static let preferredHealthSourceKey = "nutrition.preferredHealthSource"
    static let availableHealthSourcesKey = "nutrition.availableHealthSources"
    static let healthSourceByDayKey = "nutrition.healthSourceByDay"

    static var preferredHealthSourceId: String? {
        let value = UserDefaults.standard.string(forKey: preferredHealthSourceKey) ?? ""
        return value.isEmpty ? nil : value
    }

    static var availableHealthSources: [NutritionHealthSource] {
        guard let data = UserDefaults.standard.data(forKey: availableHealthSourcesKey) else { return [] }
        return (try? JSONDecoder().decode([NutritionHealthSource].self, from: data)) ?? []
    }

    static func setAvailableHealthSources(_ sources: [NutritionHealthSource]) {
        if let data = try? JSONEncoder().encode(sources) {
            UserDefaults.standard.set(data, forKey: availableHealthSourcesKey)
        }
    }

    static var healthSourceByDay: [String: String] {
        guard let data = UserDefaults.standard.data(forKey: healthSourceByDayKey) else { return [:] }
        return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }

    static func mergeHealthSourceNames(_ names: [String: String], from: String, to: String) {
        var merged = healthSourceByDay.filter { $0.key < from || $0.key > to }
        merged.merge(names, uniquingKeysWith: { _, new in new })
        if let data = try? JSONEncoder().encode(merged) {
            UserDefaults.standard.set(data, forKey: healthSourceByDayKey)
        }
    }
}
