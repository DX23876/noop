import Foundation
import StrandAnalytics
import WhoopStore

/// One of the four nutrition fields every intake source carries, so a read can name the field it wants
/// without naming a lane.
enum NutritionField: CaseIterable {
    case calories, protein, carbs, fat

    init?(key: String) {
        switch key {
        case NutritionReads.caloriesKey: self = .calories
        case NutritionReads.proteinKey: self = .protein
        case NutritionReads.carbsKey: self = .carbs
        case NutritionReads.fatKey: self = .fat
        default: return nil
        }
    }

    func value(in day: NutritionDay?) -> Double? {
        switch self {
        case .calories: return day?.calories
        case .protein: return day?.proteinG
        case .carbs: return day?.carbsG
        case .fat: return day?.fatG
        }
    }
}

extension StoreReader {
    /// The same Explore precedence on every platform: the daily column, then computed series, then
    /// imported series. The active strap wins within each layer. Explicitly suppressed sleep days stay hidden.
    public func exploreSeries(key: String, source: String, from: String, to: String,
                              dailyRows: [DailyMetric], suppressedSleepWakeDays: Set<String>) async
        -> [(day: String, value: Double)] {
        // Nutrition is RESOLVED, never read from one lane. Four sources carry the same four fields
        // (Apple Health, Health Connect, a CSV import, the food log, a typed correction) and
        // `NutritionReads` is where their order is decided, field by field, never summed. Reading the
        // catalogue's source alone is how the demo account's seven logged days stood on the Food page and
        // read as no data at all on the Today tile and on the measure's own page, on both phones
        // (2026-11-19): the same fact, answered twice, differently. The source argument is immaterial here
        // by design, because for these keys there is one answer per day and this is where it is given.
        if let field = NutritionField(key: key) {
            let resolved = await NutritionReads.nutritionByDay(store: store, from: from, to: to)
            return resolved.keys.sorted().compactMap { day in
                field.value(in: resolved[day]).map { (day: day, value: $0) }
            }
        }
        guard source == "my-whoop" else {
            return Self.oneSkinTempScale(key: key, await series(key: key, source: source, from: from, to: to, suppressedSleepWakeDays: suppressedSleepWakeDays))
        }
        let store = self.store

        // day → value, lowest-priority source first; higher-priority sources overwrite per day so a
        // real import always wins over the computed strap value.
        var byDay: [String: Double] = [:]

        // Layer 3 (lowest): merged daily column for keys that have one. `self.days` is the published
        // imported ∪ computed daily cache (parameter `days` is the lookback window, not this).
        // A Rest rebuilt from a daily row uses that night's stored traits (AI-34), never a fixed 8 h need.
        let traits = key == "sleep_performance" ? await restTraits(from: from, to: to) : .empty
        for d in dailyRows where byDay[d.day] == nil {
            if let v = MetricResolver.dailyColumn(key: key, day: d, restInputs: traits.inputs(forDay: d.day)) {
                byDay[d.day] = v
            }
        }
        // Layer 2: computed metricSeries (covers sleep_performance, which has no daily column). UNION the
        // active strap's computed sibling + the canonical computed sibling (canonical first so the active
        // strap's value, applied last, wins per day).
        for id in computedReadIds.reversed() {
            for p in (try? await store.metricSeries(deviceId: id, key: key, from: from, to: to)) ?? [] { byDay[p.day] = p.value }
        }
        // Layer 1 (highest): the imported export's metricSeries. UNION active strap + canonical (canonical
        // first so the active strap's value wins per day).
        for id in importedReadIds.reversed() {
            for p in (try? await store.metricSeries(deviceId: id, key: key, from: from, to: to)) ?? [] { byDay[p.day] = p.value }
        }

        let suppressed = MetricResolver.isSleepDayMetricKey(key) ? suppressedSleepWakeDays : Set<String>()
        let visible = byDay.filter { !suppressed.contains($0.key) }
            .sorted { $0.key < $1.key }
            .map { (day: $0.key, value: $0.value) }
        return Self.oneSkinTempScale(key: key, visible)
    }

    private static func oneSkinTempScale(
        key: String,
        _ series: [(day: String, value: Double)]
    ) -> [(day: String, value: Double)] {
        guard key == "skin_temp",
              let keep = SkinTempDisplay.dominantKind(valuesAscendingByDay: series.map(\.value))
        else { return series }
        return series.filter { SkinTempDisplay.kind(of: $0.value) == keep }
    }
}
