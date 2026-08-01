import Foundation

/// The metrics eligible for the Heute-screen Vitals grid, as MetricCatalog ids (`MetricDescriptor.id`,
/// `"<source>:<key>"`). docs/fork/feature-spec.md §4: adding a metric is appending one id here — nothing
/// else in the grid/edit logic changes. The first six match the design-spec's tile accent-color table
/// (HRV, Ruhepuls, Atmung, Blutsauerstoff, Fitness-Alter, Schritte); `weight`/`energy_kcal` were added
/// for parity with the old Today grid's `KeyMetric` set (on-device feedback) — Charge/Effort/Rest stay
/// excluded on purpose, they're already the three rings ("ein Wert erscheint genau einmal").
///
/// The `heute:…` trio (Sleep/Hydration/Coupled view) are Liquid Today's remaining "Your Cards" that don't
/// resolve through `MetricCatalog` (Sleep shows a duration and routes to the Sleep screen; Hydration
/// routes to its logging screen; Coupled view carries no value at all). They flow through the SAME
/// visibility / reorder / hidden-tray machinery as every other tile — the synthetic `heute:` source keeps
/// the persisted `"source:key"` string format unchanged — but `HeuteVitalsGridView` resolves their
/// title/icon/route locally instead of from the catalog. See `HeuteVitalsGridView.specialDescriptors`.
enum VitalGridMetric {
    static let available: [String] = [
        "my-whoop:hrv",
        "my-whoop:rhr",
        "my-whoop:resp_rate",
        "my-whoop:spo2",
        "my-whoop:fitness_age",
        "apple-health:steps",
        "apple-health:weight",
        "my-whoop:energy_kcal",
        // Liquid Today parity (on-device feedback): the "Your Cards" trio the redesign was missing.
        // Charge/Effort/Rest stay excluded (already the three rings).
        "my-whoop:vitality",
        "my-whoop:stress",
        "my-whoop:skin_temp",
        // Special tiles — value+sparkline shape doesn't fit, resolved locally (see doc above).
        "heute:sleep",
        "heute:hydration",
        "heute:coupled",
    ]
}

/// One Vitals-grid tile's persisted state. docs/fork/feature-spec.md §4.
struct VitalTileConfig: Codable, Equatable {
    var metricId: String
    var visible: Bool
    var sortOrder: Int
}

enum VitalTileConfigStore {
    static let configKey = "today.vitalTiles"
    static let densityKey = "today.vitalGridDensity"
    static let densityChoices = [2, 3]

    /// Clamps a stored/possible density to something the grid can draw; unset (0) lands on 3, matching
    /// `KeyMetricPrefs.columns`'s convention for the existing macOS/Liquid grid.
    static func density(_ raw: Int) -> Int {
        densityChoices.contains(raw) ? raw : 3
    }

    /// Merges saved configs against the current available-metrics list: known saved entries keep their
    /// visible/sortOrder untouched; ids present in `availableIds` but missing from `saved` (a newly added
    /// metric, or a fresh install) are appended as visible, in registry order, after the highest existing
    /// sortOrder; ids in `saved` no longer in `availableIds` (a retired metric) are dropped. Always
    /// returns entries sorted by `sortOrder`.
    static func normalize(_ saved: [VitalTileConfig], availableIds: [String] = VitalGridMetric.available) -> [VitalTileConfig] {
        var byId = Dictionary(uniqueKeysWithValues: saved.map { ($0.metricId, $0) })
        var nextOrder = (saved.map(\.sortOrder).max() ?? -1) + 1
        var result: [VitalTileConfig] = []
        for id in availableIds {
            if let existing = byId.removeValue(forKey: id) {
                result.append(existing)
            } else {
                result.append(VitalTileConfig(metricId: id, visible: true, sortOrder: nextOrder))
                nextOrder += 1
            }
        }
        return result.sorted { $0.sortOrder < $1.sortOrder }
    }

    /// Tiles the grid should actually render — hidden entries dropped, in order. "Keine leeren Kacheln"
    /// (spec §4 / design-spec §0.2): a caller with no data for a still-visible metric is responsible for
    /// that per-tile check; this only applies the user's visibility choice.
    static func visibleTiles(_ configs: [VitalTileConfig]) -> [VitalTileConfig] {
        configs.filter(\.visible).sorted { $0.sortOrder < $1.sortOrder }
    }

    static func load(from d: UserDefaults = .standard) -> [VitalTileConfig] {
        guard let data = d.data(forKey: configKey),
              let decoded = try? JSONDecoder().decode([VitalTileConfig].self, from: data) else {
            return normalize([])
        }
        return normalize(decoded)
    }

    static func save(_ configs: [VitalTileConfig], to d: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(configs) else { return }
        d.set(data, forKey: configKey)
    }
}
